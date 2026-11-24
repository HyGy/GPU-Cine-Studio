#include "BackendManager.h"
#include "AppPaths.h"
#include "TitleClips.h"
#include "KdenliveImporter.h"
#include "GstElementDiscovery.h"
#include "Qml6GLSink.h"
#include <QGuiApplication>
#include "ProxyAssets.h"
#include "AssetLoader.h"
#include "ProjectSettings.h"
#include <QSettings>
#include <QDebug>
#include <gst/gst.h>
// Qt "signals" keyword collides with GLib's (same fix as TimelineEngine.h)
#ifdef signals
#undef signals
#endif
#include <ges/ges.h>
#define signals Q_SIGNALS
#include <QVector>
#include <QPair>
#include <QStandardPaths>
#include <QFile>
#include <QSaveFile>
#include <QFileInfo>
#include <QTextStream>
#include <QProcess>
#include <QSet>
#include <QRegularExpression>
#include <QDesktopServices>
#include <QUrl>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QDir>
#include <QDirIterator>
#include <QDateTime>
#include <QLocale>
#include <cstdio>

BackendManager::BackendManager(QObject *parent)
    : QObject(parent)
    , m_projectBinModel(this)
    , m_cacheManager(this)
    , m_mediaAvailability(this)
    , m_waveformGenerator(this)
    , m_selectedProjectBinItemId("")
    , m_unavailableDecoder("")
{
    // Initialize GStreamer
    gst_init(nullptr, nullptr);

    // project/... keys live in ProjectSettings' process-local memory now
    // (see ProjectSettings.h), not in the shared QSettings file. Drop any
    // stale values a previous version left in the shared file so they cannot
    // be read back by another instance.
    { QSettings s; s.remove("project"); }

    // Detect available decoders FIRST (needed by detectGPUDevices)
    detectDecoders();

    // Detect GPU devices with detailed capabilities
    detectGPUDevices();

    // Load saved preference or select best
    loadDecoderPreference();

    // Detect available encoders
    detectEncoders();

    // Load encoder preference
    loadEncoderPreference();

    // --- ÚJ: Global Config betöltése ---
    loadGlobalConfig();

    m_debugLoggingEnabled = getSetting("debug/operationLogging", false).toBool();

    // Connect CacheManager and WaveformGenerator
    connectCacheAndWaveform();

    // Bin selections must not point at items that no longer exist, and a
    // model reset (new project / project load) drops all per-view state.
    auto dropStaleSelections = [this]() {
        auto stale = [this](const QString &id) {
            return !id.isEmpty() && !m_projectBinModel.indexFromItemId(id).isValid();
        };
        if (stale(m_selectedProjectBinItemId))
            setSelectedProjectBinItemId(QString());
        if (stale(m_loggingSelectedBinItemId))
            setLoggingSelectedBinItemId(QString());
    };
    connect(&m_projectBinModel, &ProjectBinModel::itemRemoved, this, dropStaleSelections);
    connect(&m_projectBinModel, &QAbstractItemModel::modelReset, this, [this]() {
        m_expandedItemIds.clear();
        setSelectedProjectBinItemId(QString());
        setLoggingSelectedBinItemId(QString());
    });

    // Set CacheManager for ProjectBinModel
    m_projectBinModel.setCacheManager(&m_cacheManager);

    // Warn if no GPU acceleration
    if (!hasGPUAcceleration()) {
        emit noGPUWarning();
    }
}

BackendManager::~BackendManager()
{
}

void BackendManager::setSelectedProjectBinItemId(const QString &itemId)
{
    if (m_selectedProjectBinItemId != itemId) {
        m_selectedProjectBinItemId = itemId;
        emit selectedProjectBinItemIdChanged(itemId);
    }
}

void BackendManager::setLoggingSelectedBinItemId(const QString &itemId)
{
    if (m_loggingSelectedBinItemId != itemId) {
        m_loggingSelectedBinItemId = itemId;
        emit loggingSelectedBinItemIdChanged(itemId);
    }
}

void BackendManager::setItemExpanded(const QString &view, const QString &itemId, bool expanded)
{
    QStringList &ids = m_expandedItemIds[view];
    bool wasExpanded = ids.contains(itemId);

    if (expanded && !wasExpanded) {
        ids.append(itemId);
        emit itemExpandStateChanged(view, itemId, true);
    } else if (!expanded && wasExpanded) {
        ids.removeAll(itemId);
        emit itemExpandStateChanged(view, itemId, false);
    }
}

bool BackendManager::isItemExpanded(const QString &view, const QString &itemId) const
{
    return m_expandedItemIds.value(view).contains(itemId);
}

void BackendManager::detectDecoders()
{
    m_availableDecoders.clear();

    qDebug() << "=== Detecting available hardware decoders (actual load test) ===";

    auto testDecoderElement = [](const QString &factoryName) -> bool {
        GstElement *element = gst_element_factory_make(factoryName.toUtf8().constData(), nullptr);
        if (!element) {
            return false;
        }

        GstStateChangeReturn stateResult = gst_element_set_state(element, GST_STATE_READY);
        gst_element_set_state(element, GST_STATE_NULL);
        gst_object_unref(element);

        return stateResult != GST_STATE_CHANGE_FAILURE;
    };

    // Query the registry for whatever H.264 decoder each backend's plugin
    // actually registers right now, instead of a hand-maintained name list.
    for (const QString &name : GstElementDiscovery::findDecoderFactories("video/x-h264", "nvidia")) {
        if (testDecoderElement(name)) {
            m_availableDecoders.append("nvidia");
            break;
        }
    }

    for (const QString &name : GstElementDiscovery::findDecoderFactories("video/x-h264", "vaapi")) {
        if (testDecoderElement(name)) {
            m_availableDecoders.append("vaapi");
            break;
        }
    }

    // CPU software decoder is always available
    m_availableDecoders.append("cpu");
    emit availableDecodersChanged();
}

bool BackendManager::hasGPUAcceleration() const
{
    return m_availableDecoders.contains("nvidia") || m_availableDecoders.contains("vaapi");
}

QString BackendManager::gstreamerVersion() const
{
    guint major, minor, micro, nano;
    gst_version(&major, &minor, &micro, &nano);
    QString version = QString("%1.%2.%3").arg(major).arg(minor).arg(micro);
    if (nano == 1) version += " (git)";
    else if (nano >= 2) version += " (prerelease)";
    return version;
}

QString BackendManager::qtVersion() const
{
    return QString::fromUtf8(qVersion());
}

QString BackendManager::platformName() const
{
    return QGuiApplication::platformName();
}

bool BackendManager::qml6SupportsWayland() const
{
    return Qml6GLSink::pluginSupportsWayland();
}

QString BackendManager::videoOutputMethod() const
{
    const QString platform = QGuiApplication::platformName();
    if (Qml6GLSink::enabled())
        return QStringLiteral("QML scene graph (qml6glsink, %1 platform)").arg(platform);
    if (platform == QLatin1String("xcb"))
        return QStringLiteral("Native window (xvimagesink/ximagesink, xcb platform)");
    return QStringLiteral("None (the native-window fallback needs the xcb platform; running on %1)").arg(platform);
}

bool BackendManager::videoOutputFallback() const
{
    return Qml6GLSink::fellBackToNative();
}

void BackendManager::detectEncoders()
{
    m_availableEncoders.clear();
    
    auto testEncoderElement = [](const QString &factoryName) -> bool {
        GstElement *element = gst_element_factory_make(factoryName.toUtf8().constData(), nullptr);
        if (!element) return false;
        GstStateChangeReturn ret = gst_element_set_state(element, GST_STATE_READY);
        gst_element_set_state(element, GST_STATE_NULL);
        gst_object_unref(element);
        return ret != GST_STATE_CHANGE_FAILURE;
    };

    // Query the registry for whatever H.264 encoder each backend's plugin
    // actually registers right now (see GstElementDiscovery.h for why).
    for (const QString &name : GstElementDiscovery::findEncoderFactories("video/x-h264", "nvidia")) {
        if (testEncoderElement(name)) {
            m_availableEncoders.append("nvidia");
            break;
        }
    }

    for (const QString &name : GstElementDiscovery::findEncoderFactories("video/x-h264", "vaapi")) {
        if (testEncoderElement(name)) {
            m_availableEncoders.append("vaapi");
            break;
        }
    }

    m_availableEncoders.append("cpu");
    emit availableEncodersChanged();
}

QString BackendManager::getEncoderDisplayName(const QString &encoderId) const
{
    if (encoderId == "nvidia") return "NVIDIA GPU";
    else if (encoderId == "vaapi") return "Intel/AMD GPU";
    else if (encoderId == "cpu") return "Software (CPU)";
    return encoderId;
}

void BackendManager::setPreferredEncoder(const QString &encoder)
{
    if (m_preferredEncoder != encoder && m_availableEncoders.contains(encoder)) {
        m_preferredEncoder = encoder;
        saveEncoderPreference();
        emit preferredEncoderChanged();
    }
}

QString BackendManager::selectBestEncoder() const
{
    if (m_availableEncoders.contains("nvidia")) return "nvidia";
    else if (m_availableEncoders.contains("vaapi")) return "vaapi";
    return "cpu";
}

void BackendManager::loadEncoderPreference()
{
    QSettings settings;
    QString saved = settings.value("encoder/preferred", "").toString();
    if (!saved.isEmpty() && m_availableEncoders.contains(saved)) {
        m_preferredEncoder = saved;
    } else {
        m_preferredEncoder = selectBestEncoder();
    }
    emit preferredEncoderChanged();
}

void BackendManager::saveEncoderPreference()
{
    QSettings settings;
    settings.setValue("encoder/preferred", m_preferredEncoder);
}

QString BackendManager::getDecoderDisplayName(const QString &decoderId) const
{
    if (decoderId == "nvidia") return "NVIDIA GPU";
    else if (decoderId == "vaapi") return "Intel/AMD GPU";
    else if (decoderId == "cpu") return "Software (CPU)";
    return decoderId;
}

void BackendManager::setPreferredDecoder(const QString &decoder)
{
    if (m_preferredDecoder != decoder && m_availableDecoders.contains(decoder)) {
        m_preferredDecoder = decoder;
        saveDecoderPreference();
        emit preferredDecoderChanged();
    }
}

QString BackendManager::selectBestDecoder() const
{
    if (m_availableDecoders.contains("nvidia")) return "nvidia";
    else if (m_availableDecoders.contains("vaapi")) return "vaapi";
    return "cpu";
}

void BackendManager::loadDecoderPreference()
{
    QSettings settings;
    QString saved = settings.value("decoder/preferred", "").toString();
    if (!saved.isEmpty() && m_availableDecoders.contains(saved)) {
        m_preferredDecoder = saved;
    } else {
        m_preferredDecoder = selectBestDecoder();
        if (!saved.isEmpty() && !m_availableDecoders.contains(saved)) {
            m_unavailableDecoder = saved;
        }
    }
    emit preferredDecoderChanged();
}

void BackendManager::saveDecoderPreference()
{
    QSettings settings;
    settings.setValue("decoder/preferred", m_preferredDecoder);
}

void BackendManager::setSetting(const QString &key, const QVariant &value)
{
    if (ProjectSettings::isProjectKey(key)) { ProjectSettings::setValue(key, value); return; }
    QSettings settings;
    settings.setValue(key, value);
}

QVariant BackendManager::getSetting(const QString &key, const QVariant &defaultValue) const
{
    if (ProjectSettings::isProjectKey(key)) return ProjectSettings::value(key, defaultValue);
    QSettings settings;
    return settings.value(key, defaultValue);
}

void BackendManager::setDebugLoggingEnabled(bool enabled)
{
    if (m_debugLoggingEnabled == enabled) return;
    m_debugLoggingEnabled = enabled;
    setSetting("debug/operationLogging", enabled);
    emit debugLoggingEnabledChanged();
}

QString BackendManager::getOperationLogPath() const
{
    // Same directory as the global config (~/.config/gpu-cine-studio/ on
    // Linux) - a plain append-only text file, not JSON, since it's meant
    // to be read top-to-bottom as a timeline of what the user did, not
    // parsed back by the app itself.
    QString configDir = AppPaths::configDir();
    QDir dir(configDir);
    if (!dir.exists()) dir.mkpath(".");
    return configDir + "/operation_log.txt";
}

void BackendManager::logOperation(const QString &action, const QVariantMap &details)
{
    if (!m_debugLoggingEnabled) return;

    QFile file(getOperationLogPath());
    if (!file.open(QIODevice::Append | QIODevice::Text)) {
        qWarning() << "logOperation: could not open" << file.fileName() << "for append";
        return;
    }

    QTextStream out(&file);
    out << QDateTime::currentDateTime().toString(Qt::ISODateWithMs) << " | " << action;
    for (auto it = details.constBegin(); it != details.constEnd(); ++it) {
        out << " | " << it.key() << "=" << it.value().toString();
    }
    out << "\n";
    file.close();
}

QString BackendManager::operationLogSize() const
{
    QFileInfo info(getOperationLogPath());
    if (!info.exists()) return QStringLiteral("-");
    return QLocale().formattedDataSize(info.size());
}

bool BackendManager::clearOperationLog()
{
    QFile file(getOperationLogPath());
    if (!file.exists()) return true;
    // Truncate rather than remove, so the path stays valid for any
    // append already in flight and the next logOperation() doesn't have
    // to recreate it.
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        qWarning() << "clearOperationLog: could not truncate" << file.fileName();
        return false;
    }
    file.close();
    return true;
}

void BackendManager::checkStartupWarnings()
{
    if (!m_unavailableDecoder.isEmpty()) {
        emit savedDecoderUnavailable(m_unavailableDecoder);
    }
}

QString BackendManager::getDefaultVideosPath() const
{
    QString videosPath = QStandardPaths::writableLocation(QStandardPaths::MoviesLocation);
    if (videosPath.isEmpty()) {
        videosPath = QStandardPaths::writableLocation(QStandardPaths::HomeLocation);
    }
    return videosPath;
}

QString BackendManager::sanitizeFolderName(const QString &name) const
{
    QString s = name.trimmed();

    // Path separators, Windows-illegal characters and control chars.
    s.replace(QRegularExpression(QStringLiteral("[/\\\\:*?\"<>|\\x00-\\x1F]")),
              QStringLiteral("_"));

    // Windows refuses names ending in '.' or ' '.
    while (!s.isEmpty() && (s.endsWith(QLatin1Char('.')) || s.endsWith(QLatin1Char(' ')))) {
        s.chop(1);
    }

    if (s.isEmpty() || s == QStringLiteral(".") || s == QStringLiteral("..")) {
        return QStringLiteral("Untitled Project");
    }

    // Windows reserved device names (checked on the part before the
    // first dot, which is how Windows itself resolves them).
    static const QStringList reserved = {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
    };
    const QString base = s.section(QLatin1Char('.'), 0, 0).toUpper();
    if (reserved.contains(base)) {
        s.prepend(QLatin1Char('_'));
    }

    // Keep room for a " (999)" suffix inside typical path limits.
    if (s.length() > 100) {
        s.truncate(100);
        while (!s.isEmpty() && (s.endsWith(QLatin1Char('.')) || s.endsWith(QLatin1Char(' ')))) {
            s.chop(1);
        }
        if (s.isEmpty()) return QStringLiteral("Untitled Project");
    }

    return s;
}

// Shared helper: resolves parentDir to a clean absolute path, or an
// empty string if it's blank. NOT exposed to QML directly.
static QString cleanParentDir(const QString &parentDir)
{
    QString parent = parentDir;
    if (parent.startsWith(QStringLiteral("file://"))) {
        parent = parent.mid(7);
    }
    return QDir::cleanPath(parent.trimmed());
}

QString BackendManager::resolveProjectFolderPath(const QString &parentDir,
                                                 const QString &projectName) const
{
    // No collision suffixing here - this is a single candidate path for
    // the New Project dialog's live preview and for createProjectFolder()
    // to check. A name that's already taken is reported as an error to
    // the user (see createProjectFolder()) rather than silently renamed
    // to "... (2)" - the user explicitly wants to be asked to pick a
    // different name/location instead of the app deciding for them.
    const QString parent = cleanParentDir(parentDir);
    if (parent.isEmpty()) return QString();

    return parent + QLatin1Char('/') + sanitizeFolderName(projectName);
}

bool BackendManager::projectFolderWouldConflict(const QString &parentDir,
                                                const QString &projectName) const
{
    const QString candidate = resolveProjectFolderPath(parentDir, projectName);
    if (candidate.isEmpty()) return false;

    const QFileInfo info(candidate);
    if (!info.exists()) return false;
    if (!info.isDir()) return true;   // a FILE sits at that path - always a conflict

    // An existing but COMPLETELY empty folder is not a conflict - it's
    // reused (typically an orphan from an earlier New Project attempt
    // that was abandoned before anything was ever written into it).
    const QDir d(candidate);
    return !d.entryList(QDir::AllEntries | QDir::Hidden | QDir::System
                         | QDir::NoDotAndDotDot).isEmpty();
}

QString BackendManager::createProjectFolder(const QString &parentDir,
                                            const QString &projectName)
{
    const QString target = resolveProjectFolderPath(parentDir, projectName);
    if (target.isEmpty()) {
        return QString();
    }

    if (projectFolderWouldConflict(parentDir, projectName)) {
        qWarning() << "BackendManager: project folder already exists:" << target;
        return QString();
    }

    if (!QDir().mkpath(target)) {
        qWarning() << "BackendManager: failed to create project folder:" << target;
        return QString();
    }

    // mkpath() succeeds on an existing dir too - verify it is actually
    // usable before the caller commits project/location to it.
    const QFileInfo info(target);
    if (!info.isDir() || !info.isWritable()) {
        qWarning() << "BackendManager: project folder not writable:" << target;
        return QString();
    }

    qDebug() << "BackendManager: created dedicated project folder:" << target;
    return target;
}

bool BackendManager::copyProjectCache(const QString &sourceProjectDir,
                                      const QString &targetProjectDir)
{
    const QString src = cleanParentDir(sourceProjectDir) + QStringLiteral("/.cache");
    const QString dst = cleanParentDir(targetProjectDir) + QStringLiteral("/.cache");

    if (src == dst) return true;               // nothing to do
    if (!QFileInfo(src).isDir()) {
        qDebug() << "BackendManager: no cache to copy from" << src;
        return true;                            // absent cache is not a failure
    }

    if (!QDir().mkpath(dst)) {
        qWarning() << "BackendManager: failed to create cache dir:" << dst;
        return false;
    }

    bool allOk = true;
    QDirIterator it(src,
                    QDir::Files | QDir::Dirs | QDir::Hidden | QDir::NoDotAndDotDot,
                    QDirIterator::Subdirectories);
    while (it.hasNext()) {
        const QString from = it.next();
        const QString rel  = QDir(src).relativeFilePath(from);
        const QString to   = dst + QLatin1Char('/') + rel;

        if (it.fileInfo().isDir()) {
            if (!QDir().mkpath(to)) {
                qWarning() << "BackendManager: failed to create" << to;
                allOk = false;
            }
            continue;
        }

        if (!QDir().mkpath(QFileInfo(to).absolutePath())) {
            allOk = false;
            continue;
        }
        // QFile::copy() refuses to overwrite - the destination is a
        // freshly created project folder, so anything already there was
        // not put there by us and is left alone.
        if (!QFile::exists(to) && !QFile::copy(from, to)) {
            qWarning() << "BackendManager: failed to copy" << from << "->" << to;
            allOk = false;
        }
    }

    qDebug() << "BackendManager: copied project cache" << src << "->" << dst
             << "complete:" << allOk;
    return allOk;
}

static std::atomic<bool> g_signalQuitRequested{false};

void BackendManager::markSignalQuit() { g_signalQuitRequested.store(true); }
bool BackendManager::signalQuitRequested() const { return g_signalQuitRequested.load(); }

bool BackendManager::saveProjectToFile(const QString &filePath, const QString &jsonContent)
{
    // Create the containing directory if needed - without this, saving
    // into a folder that does not exist yet (a freshly created dedicated
    // project folder that has not had its cache touched yet, or a Save
    // As target) fails with nothing but a warning on the console.
    const QString dirPath = QFileInfo(filePath).absolutePath();
    if (!dirPath.isEmpty() && !QDir().mkpath(dirPath)) {
        qWarning() << "Failed to create directory for project file:" << dirPath;
        return false;
    }

    // Atomic write: QSaveFile writes to a temporary file in the same
    // directory and renames it over the target on commit(), so the target
    // holds either the old complete content or the new complete content -
    // never a half-written file if the app dies mid-save.
    QSaveFile file(filePath);
    if (!file.open(QIODevice::WriteOnly)) {
        qWarning() << "Failed to open file for writing:" << filePath;
        return false;
    }
    const QByteArray bytes = jsonContent.toUtf8();
    if (file.write(bytes) != bytes.size()) {
        file.cancelWriting();
        qWarning() << "Failed to write project file:" << filePath;
        return false;
    }
    if (!file.commit()) {
        qWarning() << "Failed to commit project file:" << filePath << file.errorString();
        return false;
    }

    qDebug() << "Project saved successfully to:" << filePath;
    return true;
}

QString BackendManager::loadProjectFromFile(const QString &filePath)
{
    // No QIODevice::Text: read raw UTF-8 bytes so the encoding matches
    // saveProjectToFile()'s QString::toUtf8() exactly.
    QFile file(filePath);
    if (!file.open(QIODevice::ReadOnly)) {
        qWarning() << "Failed to open file for reading:" << filePath;
        return QString();
    }

    const QString jsonContent = QString::fromUtf8(file.readAll());
    file.close();

    qDebug() << "Project loaded successfully from:" << filePath;
    return jsonContent;
}

bool BackendManager::fileExists(const QString &filePath) const
{
    QFileInfo info(filePath);
    return info.exists() && info.isFile();
}

bool BackendManager::removeFile(const QString &filePath)
{
    // Safety restriction: from QML only the app's own recovery copies may
    // be deleted. Anything else (media, a real .gpucs) is refused - a
    // wrong or malicious QML-side path can never destroy user data.
    if (!(filePath.endsWith(QLatin1String(".autosave"))
          || filePath.endsWith(QLatin1String(".autosave.corrupt")))) {
        qWarning() << "removeFile: refusing to delete non-autosave path:" << filePath;
        return false;
    }
    QFile file(filePath);
    if (!file.exists())
        return true; // already gone - nothing to remove
    if (!file.remove()) {
        qWarning() << "removeFile: failed to remove:" << filePath;
        return false;
    }
    return true;
}

QString BackendManager::fileModifiedText(const QString &filePath) const
{
    QFileInfo info(filePath);
    if (!info.exists() || !info.isFile())
        return QString();
    return info.lastModified().toString(QStringLiteral("yyyy-MM-dd HH:mm:ss"));
}

bool BackendManager::backupProjectFile(const QString &filePath)
{
    QFileInfo info(filePath);
    if (!info.exists() || !info.isFile())
        return true; // nothing to back up

    // Copy to a temp file first and only then replace the old .bak, so a
    // failed copy (disk full, I/O error) never leaves the user with no
    // backup at all. rename() over an existing file is atomic on POSIX;
    // QFile::rename() refuses to overwrite, hence ::rename().
    const QString bak = filePath + QStringLiteral(".bak");
    const QString tmp = bak + QStringLiteral(".tmp");
    QFile::remove(tmp);   // leftover of an interrupted earlier backup
    if (!QFile::copy(filePath, tmp)) {
        qWarning() << "backupProjectFile: copy failed:" << filePath << "->" << tmp;
        QFile::remove(tmp);
        return false;
    }
    if (::rename(QFile::encodeName(tmp).constData(), QFile::encodeName(bak).constData()) != 0) {
        qWarning() << "backupProjectFile: could not replace old backup:" << bak;
        QFile::remove(tmp);
        return false;
    }
    return true;
}

QVariantMap BackendManager::inspectKdenliveProject(const QString &filePath, const QVariantMap &options) const
{
    return KdenliveImporter::inspect(filePath, options);
}

QVariantMap BackendManager::convertKdenliveProject(const QString &filePath, const QVariantMap &options) const
{
    return KdenliveImporter::convert(filePath, options);
}

bool BackendManager::writeKdenliveImportReport(const QString &projectDir, const QVariantMap &report) const
{
    return KdenliveImporter::writeReport(projectDir, report);
}

// GPU detection placeholders - in real app implementation these execute nvidia-smi/vainfo
QString BackendManager::detectNVIDIAGPUName() const { return "NVIDIA GPU"; }
QString BackendManager::detectIntelGPUName() const { return "Intel GPU"; }
QString BackendManager::detectAMDGPUName() const { return "AMD GPU"; }

QStringList BackendManager::detectCodecsForElement(const QString &backend, bool isEncoder) const {
    // Real probe: every codec the UI offers is only offered if the registry
    // actually has a matching encoder/decoder for THAT backend's plugin and
    // it really reaches READY. The candidate element names are looked up
    // dynamically by caps (see GstElementDiscovery.h) rather than matched
    // against a hand-maintained list, so a GStreamer release renaming an
    // element (as 1.28 did to the nvcodec CUDA-mode encoders) can't silently
    // make a codec vanish from the UI again.
    //
    // This is also what answers "why can't I pick VP9 under NVIDIA?": no
    // NVIDIA GPU has ever shipped a VP9 ENCODER (NVENC does H.264/HEVC/AV1
    // only; VP9 is decode-only on NVDEC), so the query for a VP9-capable
    // nvcodec encoder simply comes back empty. Codec labels must match the
    // strings RenderEngine::parseCodec() understands.
    struct Candidate { const char *label; const char *caps; };
    static const Candidate kEncoderCodecs[] = {
        { "H.264",        "video/x-h264" },
        { "H.265 (HEVC)", "video/x-h265" },
        { "AV1",          "video/x-av1"  },
        { "VP9",          "video/x-vp9"  },
    };
    static const Candidate kDecoderCodecs[] = {
        { "H.264",        "video/x-h264" },
        { "H.265 (HEVC)", "video/x-h265" },
        { "VP9",          "video/x-vp9"  },
        { "AV1",          "video/x-av1"  },
    };
    const Candidate *codecs = isEncoder ? kEncoderCodecs : kDecoderCodecs;
    const int codecCount = isEncoder
        ? int(sizeof(kEncoderCodecs) / sizeof(kEncoderCodecs[0]))
        : int(sizeof(kDecoderCodecs) / sizeof(kDecoderCodecs[0]));

    QStringList result;
    for (int i = 0; i < codecCount; ++i) {
        const Candidate &c = codecs[i];
        const QStringList elements = isEncoder
            ? GstElementDiscovery::findEncoderFactories(c.caps, backend)
            : GstElementDiscovery::findDecoderFactories(c.caps, backend);
        for (const QString &elementName : elements) {
            GstElement *element = gst_element_factory_make(elementName.toUtf8().constData(), nullptr);
            if (!element) continue;
            GstStateChangeReturn ret = gst_element_set_state(element, GST_STATE_READY);
            gst_element_set_state(element, GST_STATE_NULL);
            gst_object_unref(element);
            if (ret != GST_STATE_CHANGE_FAILURE) {
                result.append(c.label);
                break;
            }
        }
    }
    if (result.isEmpty()) result.append("H.264");
    return result;
}

void BackendManager::detectGPUDevices()
{
    m_gpuDevices.clear();
    
    // Simulate/Detect devices based on what works
    if (m_availableDecoders.contains("nvidia")) {
        GPUDevice nv;
        nv.id = "nvidia-0";
        nv.name = detectNVIDIAGPUName();
        nv.type = "GPU";
        nv.vendor = "NVIDIA";
        nv.encoders = detectCodecsForElement("nvidia", true);
        nv.decoders = detectCodecsForElement("nvidia", false);
        m_gpuDevices.append(nv);
    }
    
    if (m_availableDecoders.contains("vaapi")) {
        GPUDevice va;
        va.id = "vaapi-0";
        va.name = detectIntelGPUName();
        va.type = "GPU";
        va.vendor = "Intel/AMD";
        va.encoders = detectCodecsForElement("vaapi", true);
        va.decoders = detectCodecsForElement("vaapi", false);
        m_gpuDevices.append(va);
    }
    
    GPUDevice cpu;
    cpu.id = "cpu";
    cpu.name = "Software Encoding";
    cpu.type = "CPU";
    cpu.vendor = "Software";
    // Was a hardcoded {"H.264","H.265","VP9"} - note the bare "H.265", which
    // RenderEngine's old `codec == "H.265 (HEVC)"` test never matched, so a
    // CPU "H.265" export silently produced H.264.
    cpu.encoders = detectCodecsForElement("cpu", true);
    cpu.decoders = detectCodecsForElement("cpu", false);
    m_gpuDevices.append(cpu);

    emit gpuDevicesChanged();
}

QVariantList BackendManager::gpuDevices() const
{
    QVariantList list;
    for (const GPUDevice &device : m_gpuDevices) {
        list.append(device.toVariantMap());
    }
    return list;
}

QVariantMap BackendManager::getGPUDeviceInfo(const QString &deviceId) const
{
    for (const GPUDevice &device : m_gpuDevices) {
        if (device.id == deviceId) {
            return device.toVariantMap();
        }
    }
    return QVariantMap();
}

void BackendManager::openFile(const QString &filePath)
{
    QUrl url = QUrl::fromLocalFile(filePath);
    if (!QDesktopServices::openUrl(url)) {
        qWarning() << "Failed to open file:" << filePath;
    }
}

void BackendManager::forceQuit()
{
    qDebug() << "BackendManager::forceQuit() called";
    // A QCoreApplication::exit(0) nem tud kilépni ha GStreamer GLib
    // source-ok (bus watch, timeout) tartják életben az event loop-ot.
    // Mivel a cleanup már megtörtént (QML loaderek leálltak, engine-ek
    // megsemmisültek), a közvetlen process exit biztonságos.
    ::_exit(0);
}

// ============================================================================
// --- ÚJ: GLOBAL CONFIG IMPLEMENTÁCIÓ ---
// ============================================================================

QString BackendManager::getGlobalConfigPath() const
{
    // AppConfigLocation:
    // Linux: ~/.config/<AppName>/config.json
    // Windows: C:/Users/<User>/AppData/Local/<AppName>/config.json
    QString configDir = AppPaths::configDir();
    
    // Ensure directory exists
    QDir dir(configDir);
    if (!dir.exists()) {
        dir.mkpath(".");
    }
    
    return configDir + "/config.json";
}

void BackendManager::loadGlobalConfig()
{
    QString path = getGlobalConfigPath();
    QFile file(path);

    m_recentProjects.clear();
    m_globalConfig.clear();

    if (file.open(QIODevice::ReadOnly)) {
        QByteArray data = file.readAll();
        QJsonDocument doc = QJsonDocument::fromJson(data);
        
        if (doc.isObject()) {
            QJsonObject root = doc.object();
            m_globalConfig = root.toVariantMap();
            
            // Recent Projects
            if (root.contains("recentProjects") && root["recentProjects"].isArray()) {
                m_recentProjects = root["recentProjects"].toArray().toVariantList();
            }
        }
        file.close();
        qDebug() << "Loaded global config from:" << path;
    } else {
        qDebug() << "No global config found at:" << path << "(Using defaults)";
    }
    
    emit recentProjectsChanged();
}

void BackendManager::saveGlobalConfig()
{
    QString path = getGlobalConfigPath();
    // Atomic (temp file + rename, like saveProjectToFile()): a crash or the
    // _exit() in forceQuit() mid-write must not leave a truncated config
    // that loses the recent-projects list.
    QSaveFile file(path);

    QJsonObject root = QJsonObject::fromVariantMap(m_globalConfig);
    
    // Update specific keys
    root["recentProjects"] = QJsonArray::fromVariantList(m_recentProjects);
    
    QJsonDocument doc(root);
    
    const QByteArray bytes = doc.toJson();
    if (file.open(QIODevice::WriteOnly) && file.write(bytes) == bytes.size() && file.commit()) {
        qDebug() << "Saved global config to:" << path;
    } else {
        file.cancelWriting();
        qWarning() << "Failed to save global config to:" << path << file.errorString();
    }
}

void BackendManager::addToRecentProjects(const QString &path, const QString &name)
{
    QString cleanPath = path;
    if (cleanPath.startsWith("file://")) {
        cleanPath = cleanPath.mid(7);
    }

    // 1. Remove if already exists (to move it to top)
    for (int i = 0; i < m_recentProjects.size(); ++i) {
        QVariantMap project = m_recentProjects[i].toMap();
        if (project["path"].toString() == cleanPath) {
            m_recentProjects.removeAt(i);
            break;
        }
    }

    // 2. Add to top
    QVariantMap newEntry;
    newEntry["path"] = cleanPath;
    newEntry["name"] = name.isEmpty() ? cleanPath.split('/').last() : name;
    newEntry["lastOpened"] = QDateTime::currentDateTime().toString(Qt::ISODate);
    
    m_recentProjects.prepend(newEntry);

    // 3. Limit size (e.g., max 10)
    while (m_recentProjects.size() > 10) {
        m_recentProjects.removeLast();
    }

    // 4. Save and notify
    saveGlobalConfig();
    emit recentProjectsChanged();
}

QVariantList BackendManager::getRecentProjects() const
{
    return m_recentProjects;
}

// ============================================================================
// --- CACHE & WAVEFORM INTEGRATION ---
// ============================================================================

void BackendManager::connectCacheAndWaveform()
{
    // CacheManager waveform generalas kerest kuld -> WaveformGenerator inditja
    connect(&m_cacheManager, &CacheManager::requestWaveformGeneration,
            &m_waveformGenerator, &WaveformGenerator::generateWaveform);

    // WaveformGenerator progress -> CacheManager frissites
    connect(&m_waveformGenerator, &WaveformGenerator::waveformProgress,
            &m_cacheManager, &CacheManager::setWaveformGenerating);

    // WaveformGenerator kesz -> CacheManager frissites
    connect(&m_waveformGenerator, &WaveformGenerator::waveformReady,
            &m_cacheManager, &CacheManager::setWaveformReady);

    // WaveformGenerator hiba -> CacheManager frissites
    connect(&m_waveformGenerator, &WaveformGenerator::waveformFailed,
            &m_cacheManager, &CacheManager::setWaveformFailed);

    // CacheManager proxy generalas kerest kuld -> ProxyGenerator inditja
    connect(&m_cacheManager, &CacheManager::requestProxyGenerationStart,
            &m_proxyGenerator, &ProxyGenerator::generateProxy);
    connect(&m_cacheManager, &CacheManager::requestProxyCancel,
            &m_proxyGenerator, &ProxyGenerator::cancelGeneration);

    // ProxyGenerator progress/kesz/hiba -> CacheManager frissites
    connect(&m_proxyGenerator, &ProxyGenerator::proxyProgress,
            &m_cacheManager, &CacheManager::setProxyGenerating);
    connect(&m_proxyGenerator, &ProxyGenerator::proxyReady,
            &m_cacheManager, &CacheManager::setProxyReady);
    connect(&m_proxyGenerator, &ProxyGenerator::proxyFailed,
            &m_cacheManager, &CacheManager::setProxyFailed);
    connect(&m_proxyGenerator, &ProxyGenerator::proxyBackendResolved,
            &m_cacheManager, &CacheManager::setProxyBackendResolved);

    // proxy_build_plan.md Part J.4.3: a proxy finishing is exactly when
    // it might need installing as the GES-level active asset - re-derives
    // the full desired set rather than hand-rolling "is THIS the one
    // variant that matters" logic twice (refreshProxyInstallations() is
    // the single source of truth also used by the project-load path and
    // by QML after a settings change).
    connect(&m_cacheManager, &CacheManager::proxyReady, this,
            [this](const QString &, const QString &, const QString &, const QString &) {
                refreshProxyInstallations();
            });

    qDebug() << "BackendManager: CacheManager, WaveformGenerator and ProxyGenerator connected";
}

void BackendManager::scheduleProxyInstallationChanged()
{
    if (!m_proxyInstallCoalesceTimer) {
        m_proxyInstallCoalesceTimer = new QTimer(this);
        m_proxyInstallCoalesceTimer->setSingleShot(true);
        connect(m_proxyInstallCoalesceTimer, &QTimer::timeout, this, [this]() {
            emit proxyInstallationChanged();
        });
    }
    // Restart, not just start-if-not-running: a burst of proxies
    // finishing back to back should coalesce into ONE emission after the
    // burst settles, not one 2s after the FIRST of them.
    m_proxyInstallCoalesceTimer->start(2000);
}

void BackendManager::cancelPendingProxyInstallationChanged()
{
    if (m_proxyInstallCoalesceTimer && m_proxyInstallCoalesceTimer->isActive())
        m_proxyInstallCoalesceTimer->stop();
    // The caller's full timeline build waits for a running install pass (the
    // engine parks it) and then reflects every install: no rebuild signal.
    if (m_proxyChainActive) m_proxyChainCovered = true;
}

// Diffs the settings' desired proxies against what is installed: uninstalls
// what is stale (immediately - no discovery needed, the originals' assets are
// kept in m_originalAssets) and returns source -> proxy for what still has to
// be installed.
QHash<QString, QString> BackendManager::computeProxyStep(bool &changed)
{
    const bool proxyEnabled = getSetting("project/proxyEnabled", false).toBool();
    const QString activeRes = getSetting("project/proxyActiveResolution", "Original (no proxy)").toString();
    const QString format = getSetting("project/proxyFormat", "h264_intra").toString();

    // sourcePath -> proxyPath this project's settings currently call for.
    // Resolution-only "active variant" (paired with the project's current
    // format setting), not a full per-variant proxyActiveVariant - same
    // scoping call as the registry-v3 commit's deferred ProjectBinModel
    // role work (see this function's header comment).
    QHash<QString, QString> desired;
    if (proxyEnabled && activeRes != "Original (no proxy)" && !activeRes.isEmpty()) {
        const QStringList ids = m_projectBinModel.videoItemIds();
        for (const QString &itemId : ids) {
            if (m_cacheManager.getProxyStatus(itemId, activeRes, format) != "ready") continue;
            const QString proxyPath = m_cacheManager.getProxyPath(itemId, activeRes, format);
            const CacheItemInfo info = m_cacheManager.getItemInfo(itemId);
            if (proxyPath.isEmpty() || info.sourcePath.isEmpty()) continue;
            if (m_badProxyPaths.contains(proxyPath)) continue; // failed to play earlier this session
            desired.insert(info.sourcePath, proxyPath);
        }
    }

    // Uninstall anything installed that's no longer desired, or whose
    // desired proxy path changed (a different variant became ready/active
    // since the last refresh) - collected first since QHash iterators are
    // invalidated by erasing mid-iteration.
    QStringList toUninstall;
    for (auto it = m_installedProxySourcePaths.constBegin(); it != m_installedProxySourcePaths.constEnd(); ++it) {
        if (!desired.contains(it.key()) || desired.value(it.key()) != it.value()) {
            toUninstall.append(it.key());
        }
    }
    for (const QString &sourcePath : toUninstall) {
        ProxyAssets::uninstall(m_originalAssets.value(sourcePath, nullptr), sourcePath);
        m_installedProxySourcePaths.remove(sourcePath);
        changed = true;
    }

    QHash<QString, QString> toInstall;
    for (auto it = desired.constBegin(); it != desired.constEnd(); ++it) {
        if (m_installedProxySourcePaths.value(it.key()) == it.value()) continue; // already correct
        toInstall.insert(it.key(), it.value());
    }
    return toInstall;
}

bool BackendManager::refreshProxyInstallations()
{
    // A pass is running: let it finish, then repeat once with the settings as
    // they are by then (the caller's change is in them already).
    if (m_proxyChainActive) {
        m_proxyAgain = true;
        return true;
    }

    bool changed = false;
    const QHash<QString, QString> toInstall = computeProxyStep(changed);
    if (toInstall.isEmpty()) {
        if (changed) scheduleProxyInstallationChanged();
        return changed || (m_proxyInstallCoalesceTimer && m_proxyInstallCoalesceTimer->isActive());
    }

    m_proxyChainActive = true;
    m_proxyChainChanged = changed;
    m_proxyChainCovered = false;
    m_proxyAgain = false;
    AssetLoader::shared()->beginProxyPass();   // the engine parks clip lists from now on
    startProxyPass(toInstall);
    return true;
}

void BackendManager::startProxyPass(const QHash<QString, QString> &toInstall)
{
    // The loader thread runs GES calls; the engine normally did this already.
    gst_init(nullptr, nullptr);
    ges_init();

    AssetLoader *loader = AssetLoader::shared();
    if (!m_proxyLoaderConnected) {
        m_proxyLoaderConnected = true;
        connect(loader, &AssetLoader::proxyResultReady, this, &BackendManager::onProxyResult);
        connect(loader, &AssetLoader::pathsDropped, this, &BackendManager::onProxyPathsDropped);
    }

    m_passItems.clear();
    m_passWaiting.clear();
    m_passFailed.clear();
    m_passSkipped.clear();
    m_passDelivered.clear();
    m_passDone = 0;

    // Sorted: a stable, readable order (progress shows file names).
    QStringList sources = toInstall.keys();
    sources.sort();
    QStringList request;
    for (const QString &src : sources) {
        ProxyPassItem it;
        it.source = src;
        it.proxy = toInstall.value(src);
        m_passItems.append(it);
        if (!m_originalAssets.contains(src)) {
            request << src;
            m_passWaiting.insert(src);
        }
        request << it.proxy;
        m_passWaiting.insert(it.proxy);
    }
    qDebug() << "BackendManager: proxy install pass:" << m_passItems.size() << "source(s),"
             << request.size() << "asset(s) to resolve on the loader thread";
    emitProxyProgress();
    loader->enqueue(request, false, AssetLoader::Proxy);
}

void BackendManager::emitProxyProgress()
{
    QString name;
    for (const ProxyPassItem &it : m_passItems) {
        if (!it.done) { name = QFileInfo(it.source).fileName(); break; }
    }
    emit proxyInstallProgress(m_passDone, m_passItems.size(), name);
}

void BackendManager::onProxyResult(const QString &path, int status, quintptr asset,
                                   const QString &error, bool abandoned)
{
    if (!m_proxyChainActive || abandoned || !m_passWaiting.contains(path)) return;
    m_passWaiting.remove(path);
    if (status == AssetLoader::Ok && asset) {
        // Transfer-full reference from the loader. Only the Proxy consumer asked
        // for this path (or the engine shares it and keeps the same reference in
        // m_assetCache): nobody releases it, as everywhere else for GES assets.
        m_passDelivered.insert(path, reinterpret_cast<_GESAsset *>(asset));
    } else {
        m_passFailed.insert(path);
        qWarning() << "ProxyAssets: failed to resolve" << path << "- status" << status << error;
    }
    advanceProxyPass();
}

void BackendManager::onProxyPathsDropped(const QStringList &paths, bool stuck)
{
    if (!m_proxyChainActive) return;
    bool any = false;
    for (const QString &p : paths) {
        if (!m_passWaiting.contains(p)) continue;
        m_passWaiting.remove(p);
        m_passFailed.insert(p);
        if (stuck) m_passSkipped.insert(p);   // else: loading was cancelled, a later refresh may retry
        qWarning() << "ProxyAssets: loading" << p << (stuck ? "was skipped" : "was cancelled") << "- not proxying it now";
        any = true;
    }
    if (any) advanceProxyPass();
}

// Installs every item whose assets (original + proxy) are both settled, and
// ends the pass - or starts the repeat - when none is left.
void BackendManager::advanceProxyPass()
{
    auto settled = [this](const QString &p) { return !m_passWaiting.contains(p); };
    for (ProxyPassItem &it : m_passItems) {
        if (it.done) continue;
        if (!settled(it.proxy) || (!m_originalAssets.contains(it.source) && !settled(it.source))) continue;
        it.done = true;
        ++m_passDone;

        const bool skipped = m_passSkipped.contains(it.source) || m_passSkipped.contains(it.proxy);
        _GESAsset *orig = m_originalAssets.value(it.source, nullptr);
        if (!orig && m_passDelivered.contains(it.source)) {
            orig = ProxyAssets::unwrapOriginal(m_passDelivered.value(it.source));
            // Keep it for later uninstalls/re-installs: one extra reference, never released.
            if (orig) { g_object_ref(orig); m_originalAssets.insert(it.source, orig); }
        }
        _GESAsset *proxy = m_passDelivered.value(it.proxy, nullptr);
        if (skipped) {
            // A file that never answered: do not retry it on every refresh.
            m_badProxyPaths.insert(it.proxy);
        } else if (m_badProxyPaths.contains(it.proxy)) {
            // The preview refused this proxy while the pass was running.
        } else if (!orig || !proxy) {
            qWarning() << "ProxyAssets: not installing" << it.proxy << "for" << it.source
                       << (orig ? "- the proxy file failed to resolve (the original keeps playing)"
                                : "- the original failed to resolve");
        } else if (ProxyAssets::install(orig, proxy, it.source, it.proxy)) {
            m_installedProxySourcePaths.insert(it.source, it.proxy);
            m_proxyChainChanged = true;
        }
        emitProxyProgress();
    }
    if (m_passDone < m_passItems.size()) return;

    // Pass complete. Settings may have changed meanwhile: repeat once.
    if (m_proxyAgain) {
        m_proxyAgain = false;
        bool changed = false;
        const QHash<QString, QString> toInstall = computeProxyStep(changed);
        if (changed) m_proxyChainChanged = true;
        if (!toInstall.isEmpty()) {
            startProxyPass(toInstall);
            return;
        }
    }

    const bool changed = m_proxyChainChanged;
    const bool covered = m_proxyChainCovered;
    m_proxyChainActive = false;
    m_proxyChainChanged = false;
    m_proxyChainCovered = false;
    m_passItems.clear();
    m_passDelivered.clear();
    if (changed && !covered) scheduleProxyInstallationChanged();
    qDebug() << "BackendManager: proxy install pass finished - changed:" << changed
             << "covered by a pending timeline build:" << covered;
    emit proxyInstallPassFinished(m_proxyInstallCoalesceTimer && m_proxyInstallCoalesceTimer->isActive());
    // Last: lets the engine replay the clip list it parked behind this pass.
    AssetLoader::shared()->endProxyPass(changed);
}

void BackendManager::handleProxyPlaybackFailure(const QString &failingFilePath)
{
    QString sourcePath;
    for (auto it = m_installedProxySourcePaths.constBegin(); it != m_installedProxySourcePaths.constEnd(); ++it) {
        if (QFileInfo(it.value()).canonicalFilePath() == QFileInfo(failingFilePath).canonicalFilePath()) {
            sourcePath = it.key();
            break;
        }
    }
    if (sourcePath.isEmpty()) {
        // Not a proxy we installed (an original failing is a different problem).
        qWarning() << "BackendManager: stream failure in" << failingFilePath << "is not an installed proxy - nothing to revert";
        return;
    }
    qWarning() << "BackendManager: preview cannot play proxy" << failingFilePath
               << "- reverting" << sourcePath << "to the original";
    ProxyAssets::uninstall(m_originalAssets.value(sourcePath, nullptr), sourcePath);
    m_badProxyPaths.insert(m_installedProxySourcePaths.value(sourcePath));
    m_installedProxySourcePaths.remove(sourcePath);
    emit proxyRevertedToOriginal(sourcePath,
        QStringLiteral("The preview could not play the proxy for %1; it plays from the original instead.")
            .arg(QFileInfo(sourcePath).fileName()));
    emit proxyInstallationChanged(); // rebuild now, without the 2 s coalescing delay
}

void BackendManager::handleProxyRebuildStuck()
{
    if (m_installedProxySourcePaths.isEmpty()) return; // nothing to revert; TimelineEngine gives up on a 2nd strike
    qWarning() << "BackendManager: rebuild with proxies never prerolled - reverting all" << m_installedProxySourcePaths.size()
               << "installed proxies to their originals for this session";
    for (auto it = m_installedProxySourcePaths.constBegin(); it != m_installedProxySourcePaths.constEnd(); ++it) {
        ProxyAssets::uninstall(m_originalAssets.value(it.key(), nullptr), it.key());
        m_badProxyPaths.insert(it.value());
    }
    m_installedProxySourcePaths.clear();
    emit proxyRevertedToOriginal(QString(),
        QStringLiteral("The preview could not start with proxies; all proxies were turned off for this session and the originals are used."));
    emit proxyInstallationChanged();
}

void BackendManager::setCurrentProjectDir(const QString &dir)
{
    if (m_currentProjectDir != dir) {
        m_badProxyPaths.clear(); // per-project-session blacklist
        m_currentProjectDir = dir;
        emit currentProjectDirChanged();
    }
}

void BackendManager::initializeCacheForProject(const QString &projectFilePath, bool isNewProject)
{
    QString cleanPath = projectFilePath;
    if (cleanPath.startsWith("file://")) {
        cleanPath = cleanPath.mid(7);
    }

    QFileInfo fileInfo(cleanPath);
    QString projectDir = fileInfo.absolutePath();

    setCurrentProjectDir(projectDir);
    m_cacheManager.initialize(projectDir, isNewProject);

    qDebug() << "BackendManager: Cache initialized for project dir:" << projectDir << "isNewProject:" << isNewProject;

    // initialize() already ran validateAllItems() for an existing
    // project, which marks a changed/mismatched source "invalid" - but
    // never re-queues it. Without this call, an item that goes
    // "invalid" once (e.g. a prior false positive from the old
    // mtime-based check this fixes) stays dead forever, since nothing
    // else in the app ever calls regenerateInvalidItems() either.
    m_cacheManager.regenerateInvalidItems();

    // Inditjuk a pending generalasokat
    m_cacheManager.startPendingGeneration();

    // proxy_build_plan.md Part J.4.3: pick up whatever's already ready
    // for this project's proxy settings - the "a ready proxy already
    // exists when the project is (re)opened" install path, distinct from
    // the proxyReady-signal path above which only fires for generation
    // that completes DURING this session.
    refreshProxyInstallations();
}

QString BackendManager::defaultTitleParams(const QString &text) const
{
    return TitleClips::defaultParamsJson(text);
}
