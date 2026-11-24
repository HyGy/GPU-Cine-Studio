#include "CodecCheck.h"

#include <QClipboard>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QRegularExpression>
#include <QSet>
#include <QTextStream>
#include <QVariantMap>
#include <gst/gst.h>
#include <unistd.h>

namespace {

// Plugins whose elements run on a GPU / dedicated codec hardware. Anything
// else (libav, openh264, x264, fdkaac, faad, mpg123, ...) counts as software.
bool isHardwareFeature(GstPluginFeature *feature)
{
    static const QSet<QString> kHwPlugins = {
        QStringLiteral("nvcodec"), QStringLiteral("va"), QStringLiteral("vaapi"),
        QStringLiteral("v4l2codecs"), QStringLiteral("qsv"), QStringLiteral("msdk"),
        QStringLiteral("amfcodec"), QStringLiteral("video4linux2"),
    };
    const gchar *plugin = gst_plugin_feature_get_plugin_name(feature);
    if (plugin && kHwPlugins.contains(QString::fromUtf8(plugin))) return true;
    const gchar *klass = gst_element_factory_get_metadata(GST_ELEMENT_FACTORY(feature),
                                                          GST_ELEMENT_METADATA_KLASS);
    return klass && strstr(klass, "Hardware");
}

struct Found {
    QStringList sw, hw;
    bool any() const { return !sw.isEmpty() || !hw.isEmpty(); }
};

// Factories of `type` whose pad in `direction` can take/produce `caps`, with
// the rank decodebin/encodebin actually consider (>= MARGINAL), best first.
Found findFactories(GstElementFactoryListType type, const char *caps, GstPadDirection direction,
                    GstRank minRank = GST_RANK_MARGINAL)
{
    Found found;
    GstCaps *c = gst_caps_from_string(caps);
    GList *all = gst_element_factory_list_get_elements(type, minRank);
    GList *filtered = gst_element_factory_list_filter(all, c, direction, FALSE);
    filtered = g_list_sort(filtered, (GCompareFunc)gst_plugin_feature_rank_compare_func);
    for (GList *it = filtered; it; it = it->next) {
        GstPluginFeature *f = GST_PLUGIN_FEATURE(it->data);
        const QString name = QString::fromUtf8(gst_plugin_feature_get_name(f));
        (isHardwareFeature(f) ? found.hw : found.sw) << name;
    }
    gst_plugin_feature_list_free(filtered);
    gst_plugin_feature_list_free(all);
    gst_caps_unref(c);
    return found;
}

const GstElementFactoryListType kVideoDec = (GstElementFactoryListType)
    (GST_ELEMENT_FACTORY_TYPE_DECODER | GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO);
const GstElementFactoryListType kAudioDec = (GstElementFactoryListType)
    (GST_ELEMENT_FACTORY_TYPE_DECODER | GST_ELEMENT_FACTORY_TYPE_MEDIA_AUDIO);
const GstElementFactoryListType kVideoEnc = GST_ELEMENT_FACTORY_TYPE_VIDEO_ENCODER;
const GstElementFactoryListType kAudioEnc = GST_ELEMENT_FACTORY_TYPE_AUDIO_ENCODER;

// Default whitelist/search dirs - the AppRun exports the authoritative ones
// (GCS_HOST_GST_PLUGINS / GCS_HOST_GST_SEARCH_DIRS); keep in sync with
// build_appimage.sh.
const char *kDefaultHostPlugins =
    "libgstlibav.so libgstx264.so libgstx265.so libgstopenh264.so libgstfdkaac.so libgstfaad.so libgstlame.so";
const char *kDefaultHostDirs =
    "/usr/lib/x86_64-linux-gnu/gstreamer-1.0:/usr/lib64/gstreamer-1.0:/usr/lib/gstreamer-1.0";

QStringList hostPluginWhitelist()
{
    QString v = qEnvironmentVariable("GCS_HOST_GST_PLUGINS");
    if (v.isEmpty()) v = QString::fromLatin1(kDefaultHostPlugins);
    return v.split(QLatin1Char(' '), Qt::SkipEmptyParts);
}

QStringList hostPluginDirs()
{
    QString v = qEnvironmentVariable("GCS_HOST_GST_SEARCH_DIRS");
    if (v.isEmpty()) v = QString::fromLatin1(kDefaultHostDirs);
    return v.split(QLatin1Char(':'), Qt::SkipEmptyParts);
}

// Host GStreamer core version from libgstreamer's real file name
// (libgstreamer-1.0.so.0.2402.0 -> 1.24), without loading it. -1 if unknown.
int hostGstMinor()
{
    const QStringList libDirs = {
        QStringLiteral("/usr/lib/x86_64-linux-gnu"), QStringLiteral("/usr/lib64"), QStringLiteral("/usr/lib")
    };
    static const QRegularExpression re(QStringLiteral("libgstreamer-1\\.0\\.so\\.0\\.(\\d+)\\.\\d+$"));
    for (const QString &d : libDirs) {
        const QFileInfo fi(d + QStringLiteral("/libgstreamer-1.0.so.0"));
        if (!fi.exists()) continue;
        const auto m = re.match(fi.canonicalFilePath());
        if (m.hasMatch()) return m.captured(1).toInt() / 100;
    }
    return -1;
}

// Short plugin name for the feature->plugin mapping: "libgstlibav.so" -> "libav".
QString shortPluginName(const QString &file)
{
    QString s = QFileInfo(file).fileName();
    if (s.startsWith(QLatin1String("libgst"))) s = s.mid(6);
    if (s.endsWith(QLatin1String(".so"))) s.chop(3);
    return s;
}

} // namespace

CodecCheck::CodecCheck(QObject *parent)
    : QObject(parent)
{
    const bool noHost = qEnvironmentVariableIsSet("GCS_NO_HOST_CODECS")
                        && qEnvironmentVariable("GCS_NO_HOST_CODECS") != QLatin1String("0");
    // GCS_APPIMAGE is exported by the AppImage's AppRun (build_appimage.sh).
    if (qEnvironmentVariableIsSet("GCS_APPIMAGE"))
        m_pluginMode = noHost ? QStringLiteral("appimage-nohost") : QStringLiteral("appimage");
    else m_pluginMode = QStringLiteral("native");
    detectDistro();
    evaluate();
}

QString CodecCheck::gstreamerVersion() const
{
    guint major, minor, micro, nano;
    gst_version(&major, &minor, &micro, &nano);
    return QStringLiteral("%1.%2.%3").arg(major).arg(minor).arg(micro);
}

QString CodecCheck::preferredAacEncoder()
{
    // Any rank: ProxyGenerator names the element explicitly.
    const Found f = findFactories(kAudioEnc, "audio/mpeg,mpegversion=4", GST_PAD_SRC, GST_RANK_NONE);
    QStringList all = f.sw + f.hw;
    if (all.contains(QStringLiteral("avenc_aac"))) return QStringLiteral("avenc_aac");
    return all.isEmpty() ? QString() : all.first();
}

void CodecCheck::copyToClipboard(const QString &text) const
{
    if (QClipboard *cb = QGuiApplication::clipboard()) cb->setText(text);
}

void CodecCheck::refreshHostPluginLinks()
{
    const QString current = qEnvironmentVariable("GCS_HOST_GST_PLUGIN_DIR");
    if (current.isEmpty()) return;
    // A NEW directory every time (see the AppRun in build_appimage.sh): the
    // registry caches plugins by path + mtime, so a codec library swapped
    // under an unchanged plugin file (Fedora's ffmpeg-free -> ffmpeg) is
    // only picked up under a path it has not seen yet.
    const QString root = QFileInfo(current).absolutePath();
    const QString dir = root + QStringLiteral("/recheck-%1").arg(QDateTime::currentMSecsSinceEpoch());
    if (!QDir().mkpath(dir)) {
        qWarning() << "CodecCheck: cannot create" << dir;
        return;
    }
    for (const QString &plugin : hostPluginWhitelist()) {
        for (const QString &d : hostPluginDirs()) {
            const QString found = d + QLatin1Char('/') + plugin;
            if (!QFileInfo(found).isFile()) continue;
            const QString link = dir + QLatin1Char('/') + plugin;
            if (::symlink(found.toLocal8Bit().constData(), link.toLocal8Bit().constData()) != 0)
                qWarning() << "CodecCheck: could not link" << found << "->" << link;
            break;
        }
    }
    // gst_update_registry() re-reads GST_PLUGIN_PATH; the old directory's
    // plugins drop out of the registry as no longer present.
    const QByteArray d8 = dir.toLocal8Bit();
    qputenv("GST_PLUGIN_PATH_1_0", d8);
    qputenv("GST_PLUGIN_PATH", d8);
    qputenv("GCS_HOST_GST_PLUGIN_DIR", d8);
    if (QFileInfo(current).fileName().startsWith(QLatin1String("recheck-")))
        QDir(current).removeRecursively();   // our own previous re-check dir (symlinks only)
}

void CodecCheck::recheck()
{
    refreshHostPluginLinks();
    // Rescans every plugin path (incl. GST_PLUGIN_PATH, i.e. the host
    // whitelist dir) and loads features of newly found plugins.
    const gboolean changed = gst_update_registry();
    qInfo() << "CodecCheck: registry rescanned, changed =" << bool(changed);
    evaluate();
}

void CodecCheck::detectDistro()
{
    QFile f(QStringLiteral("/etc/os-release"));
    if (!f.exists()) f.setFileName(QStringLiteral("/usr/lib/os-release"));
    QString id, idLike, pretty;
    if (f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        QTextStream in(&f);
        while (!in.atEnd()) {
            const QString line = in.readLine().trimmed();
            const int eq = line.indexOf(QLatin1Char('='));
            if (eq <= 0) continue;
            const QString key = line.left(eq);
            QString val = line.mid(eq + 1);
            if (val.size() >= 2 && (val.startsWith(QLatin1Char('"')) || val.startsWith(QLatin1Char('\''))))
                val = val.mid(1, val.size() - 2);
            if (key == QLatin1String("ID")) id = val.toLower();
            else if (key == QLatin1String("ID_LIKE")) idLike = val.toLower();
            else if (key == QLatin1String("PRETTY_NAME")) pretty = val;
        }
    }
    m_distroName = pretty.isEmpty() ? (id.isEmpty() ? QStringLiteral("Unknown Linux") : id) : pretty;
    const QStringList ids = (id + QLatin1Char(' ') + idLike).split(QLatin1Char(' '), Qt::SkipEmptyParts);
    auto is = [&](const char *x) { return ids.contains(QString::fromLatin1(x)); };

    if (m_pluginMode == QLatin1String("native")) {
        // Dev / source build: which GStreamer is it running against?
        QString corePath;
        if (GstPlugin *core = gst_registry_find_plugin(gst_registry_get(), "coreelements")) {
            corePath = QString::fromUtf8(gst_plugin_get_filename(core));
            gst_object_unref(core);
        }
        if (!corePath.isEmpty() && !corePath.startsWith(QLatin1String("/usr/"))) {
            m_installCommand = QStringLiteral("scripts/build-gstreamer.sh --enable-patented");
            m_installNote = QStringLiteral(
                "This build runs against a private GStreamer prefix (%1), so the distribution's codec "
                "packages are not used. Rebuild that prefix with the patent-encumbered codecs enabled "
                "(gst-libav, x264, x265, OpenH264, fdk-aac, faad), or use the AppImage, which loads the "
                "distribution's codec plugins.").arg(QFileInfo(corePath).absolutePath());
            return;
        }
    }

    if (is("ubuntu") || is("debian")) {
        m_installCommand = QStringLiteral("sudo apt install gstreamer1.0-libav gstreamer1.0-plugins-ugly");
    } else if (is("arch")) {
        m_installCommand = QStringLiteral("sudo pacman -S gst-libav gst-plugins-ugly");
    } else if (is("opensuse") || is("suse") || id.startsWith(QLatin1String("opensuse"))) {
        m_installCommand = QStringLiteral("sudo zypper install opi && opi codecs");
        m_installNote = QStringLiteral(
            "opi codecs adds the Packman repository and installs the full FFmpeg and "
            "gstreamer-plugins-libav from it (openSUSE's own packages leave out H.264/AAC).");
    } else if (id == QLatin1String("fedora") || (is("fedora") && !is("rhel"))) {
        m_installCommand = QStringLiteral(
            "sudo dnf install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
            " && sudo dnf swap ffmpeg-free ffmpeg --allowerasing"
            " && sudo dnf install gstreamer1-plugin-libav gstreamer1-plugins-ugly");
        m_installNote = QStringLiteral(
            "Fedora's own ffmpeg-free has no H.264/H.265, so gstreamer1-plugin-libav alone is not "
            "enough: it needs the full FFmpeg from RPM Fusion (the command enables RPM Fusion and "
            "swaps ffmpeg-free for ffmpeg).");
    } else {
        m_installNote = QStringLiteral(
            "Install your distribution's GStreamer FFmpeg plugin (usually called gst-libav, "
            "gstreamer1.0-libav or gstreamer1-plugin-libav) built with H.264/H.265/AAC enabled, "
            "and the \"ugly\" plugin set (x264).");
    }
}

// gst-libav registers avenc_aac with rank NONE, and encodebin (i.e. the MP4
// render's audio profile) only considers encoders of rank >= MARGINAL. With
// the distribution's gst-libav as the only AAC encoder (Ubuntu/Debian ship
// no fdk-aac/voaacenc plugin) an MP4 render would therefore
// find no AAC encoder at all. Only in exactly that case avenc_aac is raised
// to MARGINAL; when any other AAC encoder is ranked, nothing changes.
void CodecCheck::ensureAacEncoderRank()
{
    if (!findFactories(kAudioEnc, "audio/mpeg,mpegversion=4", GST_PAD_SRC).any()) {
        if (GstElementFactory *f = gst_element_factory_find("avenc_aac")) {
            if (gst_plugin_feature_get_rank(GST_PLUGIN_FEATURE(f)) < GST_RANK_MARGINAL) {
                gst_plugin_feature_set_rank(GST_PLUGIN_FEATURE(f), GST_RANK_MARGINAL);
                qInfo() << "CodecCheck: avenc_aac is the only AAC encoder - rank raised to MARGINAL for encodebin";
            }
            gst_object_unref(f);
        }
    }
}

void CodecCheck::evaluate()
{
    ensureAacEncoderRank();
    // --- what is registered ---------------------------------------------------
    const Found h264Dec = findFactories(kVideoDec, "video/x-h264", GST_PAD_SINK);
    const Found h265Dec = findFactories(kVideoDec, "video/x-h265", GST_PAD_SINK);
    const Found aacDec = findFactories(kAudioDec, "audio/mpeg,mpegversion=4", GST_PAD_SINK);
    const Found mp3Dec = findFactories(kAudioDec, "audio/mpeg,mpegversion=1,layer=3", GST_PAD_SINK);
    const Found h264Enc = findFactories(kVideoEnc, "video/x-h264", GST_PAD_SRC);
    const Found aacEnc = findFactories(kAudioEnc, "audio/mpeg,mpegversion=4", GST_PAD_SRC);

    QStringList sw;
    for (const QString &n : h264Dec.sw + h265Dec.sw)
        if (!sw.contains(n)) sw << n;
    m_softwareVideoDecoders = sw;

    // --- host plugins that exist but did not load (AppImage) -------------------
    m_incompatiblePlugins.clear();
    QSet<QString> brokenShort;
    const QString hostDir = qEnvironmentVariable("GCS_HOST_GST_PLUGIN_DIR");
    if (!hostDir.isEmpty()) {
        guint major, minor, micro, nano;
        gst_version(&major, &minor, &micro, &nano);
        const int hostMinor = hostGstMinor();
        GList *plugins = gst_registry_get_plugin_list(gst_registry_get());
        for (GList *it = plugins; it; it = it->next) {
            GstPlugin *p = GST_PLUGIN(it->data);
            if (!GST_OBJECT_FLAG_IS_SET(p, GST_PLUGIN_FLAG_BLACKLISTED)) continue;
            const gchar *fn = gst_plugin_get_filename(p);
            if (!fn) continue;
            const QString file = QString::fromUtf8(fn);
            if (QFileInfo(file).absolutePath() != QDir(hostDir).absolutePath()) continue;
            brokenShort.insert(shortPluginName(file));
            QString why;
            if (hostMinor > int(minor))
                why = QStringLiteral("built for GStreamer 1.%1, newer than this app's 1.%2").arg(hostMinor).arg(minor);
            else
                why = QStringLiteral("could not be loaded - missing or incompatible libraries");
            m_incompatiblePlugins << QStringLiteral("%1 (%2)").arg(QFileInfo(file).fileName(), why);
        }
        gst_plugin_list_free(plugins);
    }
    auto anyBroken = [&](std::initializer_list<const char *> names) {
        for (const char *n : names)
            if (brokenShort.contains(QString::fromLatin1(n))) return true;
        return false;
    };

    // --- features ------------------------------------------------------------
    m_features.clear();
    QStringList missingIds;
    auto add = [&](const QString &id, const QString &title, QString status, QString detail,
                   bool essential, std::initializer_list<const char *> providers) {
        if (status != QLatin1String("ok") && anyBroken(providers)) {
            status = QStringLiteral("incompatible");
            detail += QStringLiteral(" The distribution's codec plugin is installed, but this "
                                     "version of the app cannot load it (see below).");
        }
        QVariantMap m;
        m[QStringLiteral("id")] = id;
        m[QStringLiteral("title")] = title;
        m[QStringLiteral("status")] = status;
        m[QStringLiteral("detail")] = detail;
        m[QStringLiteral("essential")] = essential;
        m_features << m;
        if (essential && (status == QLatin1String("missing") || status == QLatin1String("incompatible")))
            missingIds << id;
    };
    auto names = [](const QStringList &l) { return l.join(QStringLiteral(", ")); };
    auto sentence = [](const QStringList &parts) {
        QString t = parts.join(QStringLiteral(", "));
        if (!t.isEmpty()) t[0] = t[0].toUpper();
        return t;
    };

    {   // H.264/H.265 playback
        QString status, detail;
        const bool swBoth = !h264Dec.sw.isEmpty() && !h265Dec.sw.isEmpty();
        if (swBoth) {
            status = QStringLiteral("ok");
            detail = QStringLiteral("Software: %1").arg(names(m_softwareVideoDecoders));
            if (!h264Dec.hw.isEmpty() || !h265Dec.hw.isEmpty())
                detail += QStringLiteral("; GPU: %1").arg(names(h264Dec.hw + h265Dec.hw));
        } else if (h264Dec.any() && h265Dec.any()) {
            status = QStringLiteral("hardware-only");
            detail = QStringLiteral("Only the GPU decoders (%1). Files the GPU cannot decode "
                                    "(e.g. 4:2:2 or 10-bit H.264) will not play.").arg(names(h264Dec.hw + h265Dec.hw));
        } else {
            status = QStringLiteral("missing");
            QStringList parts;
            if (!h264Dec.any()) parts << QStringLiteral("no H.264 decoder");
            if (!h265Dec.any()) parts << QStringLiteral("no H.265 decoder");
            detail = sentence(parts) + QStringLiteral(" - such clips cannot be imported or played.");
        }
        add(QStringLiteral("video_playback"), QStringLiteral("H.264/H.265 playback"), status, detail, true,
            {"libav", "openh264"});
    }
    {   // AAC playback
        const bool ok = aacDec.any();
        add(QStringLiteral("aac_playback"), QStringLiteral("AAC audio playback"),
            ok ? QStringLiteral("ok") : QStringLiteral("missing"),
            ok ? QStringLiteral("Decoder: %1").arg(names(aacDec.sw + aacDec.hw))
               : QStringLiteral("No AAC decoder - the audio of most MP4/MOV files (phones, cameras) stays silent."),
            true, {"libav", "fdkaac", "faad"});
    }
    {   // MP4 render
        QString status, detail;
        if (!aacEnc.any() || !h264Enc.any()) {
            status = QStringLiteral("missing");
            QStringList parts;
            if (!h264Enc.any()) parts << QStringLiteral("no H.264 encoder");
            if (!aacEnc.any()) parts << QStringLiteral("no AAC encoder");
            detail = sentence(parts) + QStringLiteral(" - MP4/MOV renders fail. MKV/WebM (Opus audio) still work.");
        } else if (h264Enc.sw.isEmpty()) {
            status = QStringLiteral("hardware-only");
            detail = QStringLiteral("H.264 only via the GPU encoder (%1), AAC: %2. No software (CPU) H.264 encoder.")
                         .arg(names(h264Enc.hw), names(aacEnc.sw + aacEnc.hw));
        } else {
            status = QStringLiteral("ok");
            detail = QStringLiteral("H.264: %1; AAC: %2").arg(names(h264Enc.hw + h264Enc.sw), names(aacEnc.sw + aacEnc.hw));
        }
        add(QStringLiteral("mp4_render"), QStringLiteral("MP4 render"), status, detail, true,
            {"libav", "fdkaac", "x264", "openh264"});
    }
    {   // Proxy generation (H.264 proxies; audio AAC, PCM fallback)
        QString status, detail;
        if (!h264Enc.any()) {
            status = QStringLiteral("missing");
            detail = QStringLiteral("No H.264 encoder - only MJPEG / raw proxies can be generated.");
        } else {
            status = h264Enc.sw.isEmpty() ? QStringLiteral("hardware-only") : QStringLiteral("ok");
            detail = QStringLiteral("H.264: %1").arg(names(h264Enc.hw + h264Enc.sw));
        }
        if (!aacEnc.any() && h264Enc.any())
            detail += QStringLiteral("; no AAC encoder - proxy audio is stored uncompressed (PCM).");
        add(QStringLiteral("proxy"), QStringLiteral("Proxy generation"), status, detail, false,
            {"libav", "x264", "openh264"});
    }
    {   // MP3 playback (bundled mpg123 normally covers it)
        const bool ok = mp3Dec.any();
        add(QStringLiteral("mp3_playback"), QStringLiteral("MP3 audio playback"),
            ok ? QStringLiteral("ok") : QStringLiteral("missing"),
            ok ? QStringLiteral("Decoder: %1").arg(names(mp3Dec.sw + mp3Dec.hw))
               : QStringLiteral("No MP3 decoder."),
            false, {"libav"});
    }

    m_essentialMissing = !missingIds.isEmpty();
    m_missingSignature = missingIds.join(QLatin1Char(','));
    qInfo().noquote() << "CodecCheck: mode" << m_pluginMode << "| missing:"
                      << (m_missingSignature.isEmpty() ? QStringLiteral("-") : m_missingSignature)
                      << "| sw video decoders:" << names(m_softwareVideoDecoders)
                      << "| AAC enc:" << names(aacEnc.sw + aacEnc.hw)
                      << (m_incompatiblePlugins.isEmpty() ? QString()
                          : QStringLiteral("| incompatible: ") + m_incompatiblePlugins.join(QStringLiteral("; ")));
    emit changed();
}
