#include "ProxyGenerator.h"
#include "GstElementDiscovery.h"
#include "CodecCheck.h"

#include <QFile>
#include <QFileInfo>
#include <QDebug>
#include <gst/gst.h>

namespace {

bool elementExists(const QString &name)
{
    GstElementFactory *f = gst_element_factory_find(name.toUtf8().constData());
    if (!f) return false;
    gst_object_unref(f);
    return true;
}

// Picks an encoder implementing `caps`, honoring an explicit backend
// request (Phase 4's proxy computeDevice setting - "nvidia"/"vaapi"/"cpu",
// the same vocabulary RenderEngine's own device picker already uses) when
// one is given and it actually has an encoder for this format; otherwise
// (or if the requested backend can't do this format) falls back to
// nvidia-then-cpu, the pre-Phase-4 default order. Never a hardcoded
// element name (this project was already burned once by GStreamer
// renaming nvcodec's encoder elements) - same discovery-by-caps approach
// RenderEngine.cpp's selectEncoderElement() uses.
//
// `actualBackend` is reported directly from WHICH discovery list the
// match came from, not guessed from the element's name afterward -
// nvcodec's actual GPU-select element is "nvautogpuh264enc", which
// contains neither "nvh264" as a prefix nor as a substring, so a
// name-pattern check would misidentify it as a CPU encoder (a real bug
// caught empirically on this exact element). It is reported for logging
// only - the all-intra property string is derived from the chosen
// element's ACTUAL properties (see allIntraProperties()), never from the
// backend token, because "which backend" does not determine "which
// property names" (two different CPU H.264 encoders on this very machine
// disagree: x264enc has key-int-max, openh264enc has gop-size).
QString pickVideoEncoder(const char *caps, const QString &preferredBackend,
                          QString *actualBackend, QString *fellBackTo)
{
    auto tryBackend = [&](const QString &backend) -> QString {
        const QStringList candidates = GstElementDiscovery::findEncoderFactories(caps, backend);
        for (const QString &c : candidates) {
            if (elementExists(c)) return c;
        }
        return QString();
    };

    // Why the requested backend was not used, if it wasn't - prefixed onto
    // the fallback message so the log always names BOTH the reason and the
    // element actually chosen. An empty preferredBackend ("auto") has no
    // reason to report, but a fallback away from the GPU still does.
    QString reason;
    if (!preferredBackend.isEmpty()) {
        const QString enc = tryBackend(preferredBackend);
        if (!enc.isEmpty()) {
            if (actualBackend) *actualBackend = preferredBackend;
            return enc;
        }
        reason = QStringLiteral("requested device '%1' has no encoder for this format; ").arg(preferredBackend);
    }

    const QString nv = tryBackend("nvidia");
    if (!nv.isEmpty()) {
        if (actualBackend) *actualBackend = "nvidia";
        if (fellBackTo && !reason.isEmpty()) *fellBackTo = reason + QStringLiteral("using nvidia's %1").arg(nv);
        return nv;
    }
    const QString cpu = tryBackend("cpu");
    if (!cpu.isEmpty()) {
        if (actualBackend) *actualBackend = "cpu";
        // Always reported, including on the "auto" path - a silent drop to
        // software encoding is exactly the thing worth seeing in the log
        // (the pre-Phase-4 code reported it; the device-aware rewrite
        // initially only reported the explicit-request miss).
        if (fellBackTo) *fellBackTo = reason + QStringLiteral("no GPU encoder for this format, using CPU %1").arg(cpu);
        return cpu;
    }
    return QString();
}

// True if the encoder element really has `prop`. Probed on the actual
// element instance, not inferred from the backend token: the backend does
// NOT determine the property vocabulary. On this machine the "cpu" H.264
// list contains BOTH x264enc (key-int-max/speed-preset/tune) and
// openh264enc (gop-size only, no key-int-max/speed-preset/tune at all),
// and RenderEngine's normaliseEncoderRanks() pins every encoder to
// GST_RANK_SECONDARY at startup, which flattens the rank difference and
// used to let openh264enc win the tie. GstElementDiscovery now lists
// x264enc first and openh264enc last for the cpu backend, but when
// x264 is not installed openh264enc still wins - so "cpu means x264enc"
// is not guaranteed, and assuming it produced a gst_parse_launch failure
// ("no property speed-preset in element openh264enc") for every
// explicitly-CPU all-intra proxy. nvenc's elements are a second trap:
// they DO have a `tune` property, but it is GstNvEncoderTune (default/
// high-quality/low-latency/...) with no "zerolatency" member, so
// speed-preset/tune are gated on speed-preset - the property only x264's
// family has - rather than on `tune` alone. All confirmed via
// gst-inspect-1.0 against the project-local GStreamer 1.28.8.
bool encoderHasProperty(const QString &element, const char *prop)
{
    GstElement *e = gst_element_factory_make(element.toUtf8().constData(), nullptr);
    if (!e) return false;
    const bool has = g_object_class_find_property(G_OBJECT_GET_CLASS(e), prop) != nullptr;
    gst_object_unref(e);
    return has;
}

// " prop=val ..." suffix that makes `encoder` emit every frame as a
// keyframe, built from the properties that encoder actually exposes.
QString allIntraProperties(const QString &encoder)
{
    QStringList props;
    // Keyframe interval: nvenc/openh264 spell it gop-size, VA-API/x264
    // spell it key-int-max. No encoder here has both; checking in this
    // order is safe either way since both mean the same thing at 1.
    if (encoderHasProperty(encoder, "gop-size")) props << QStringLiteral("gop-size=1");
    else if (encoderHasProperty(encoder, "key-int-max")) props << QStringLiteral("key-int-max=1");
    // x264/x265 only - and `tune=zerolatency` is only a valid value for
    // that family's flags type (see encoderHasProperty's note on nvenc).
    if (encoderHasProperty(encoder, "speed-preset")) {
        props << QStringLiteral("speed-preset=ultrafast");
        if (encoderHasProperty(encoder, "tune")) props << QStringLiteral("tune=zerolatency");
    }
    return props.isEmpty() ? QString() : (QStringLiteral(" ") + props.join(QLatin1Char(' ')));
}

// Quality target for the H.264/H.265 proxies (the editing source). Lower =
// higher quality / larger files, on the 0-51 scale shared by x264 (used as a
// CRF value via pass=qual), nvenc (constant QP, qp-const-*) and vaapi
// (constant QP, qpi/qpp). Pinned here so a proxy is quality-deterministic no
// matter which backend wins - without this pinning the encoder default would
// decide (x264enc: 2 Mbps CBR; nvenc: its default rate control with an
// automatic bitrate), too weak / not deterministic for a proxy (todo item
// [8]). 16 was measured at ~29 Mbps for a 720p proxy on nvenc/vaapi
// constant-QP (about 60% of the size of the 50 Mbps 1080p source), far too
// big for a proxy; 23 is the compromise. Tunable later, once a settings knob
// exists.
static constexpr int kProxyQualityQp = 23;

// " prop=val ..." suffix that pins the encoder's rate control. Property
// names/units differ per encoder (same trap as gop-size vs key-int-max in
// allIntraProperties()), so every branch is gated on encoderHasProperty();
// the enum nicks below were read off gst-inspect-1.0 against the
// project-local GStreamer 1.28.8:
//   x264      -> pass=qual quantizer=<Q>            (CRF; quantizer alone is
//                                                    ignored in the default pass=cbr)
//   (x265enc is not installed in this GStreamer build, so it was never
//    verified; if it lacks these properties it falls through to the generic
//    bitrate branch.)
//   nvenc     -> rc-mode=constqp qp-const-i/p=<Q>   (constant QP)
//   vaapi     -> rate-control=cqp qpi=<Q> qpp=<Q>   (constant QP)
//   openh264  -> bitrate=<bps>                      (bitrate mode only; bps!)
//   other     -> bitrate=<kbps>                     (safe generic fallback)
QString qualityProperties(const QString &encoder, int qp)
{
    if (encoderHasProperty(encoder, "quantizer") && encoderHasProperty(encoder, "pass")) {
        return QStringLiteral(" pass=qual quantizer=%1").arg(qp);
    }
    if (encoderHasProperty(encoder, "rc-mode") && encoderHasProperty(encoder, "qp-const-i")) {
        return QStringLiteral(" rc-mode=constqp qp-const-i=%1 qp-const-p=%1").arg(qp);
    }
    if (encoderHasProperty(encoder, "rate-control") && encoderHasProperty(encoder, "qpi")) {
        return QStringLiteral(" rate-control=cqp qpi=%1 qpp=%1").arg(qp);
    }
    // No constant-QP control: explicit bitrate. 12 Mbps is a safe editing-
    // proxy floor. openh264enc is the only encoder here that spells bitrate
    // in BITS/sec, detected by its "gop-size but no key-int-max" signature
    // (x264/vaapi have key-int-max; nvenc was already caught by rc-mode
    // above, so this cannot match it). Everyone else uses kbit/sec.
    const int kbps = 12000;
    if (encoderHasProperty(encoder, "gop-size") && !encoderHasProperty(encoder, "key-int-max")) {
        return QStringLiteral(" bitrate=%1").arg(kbps * 1000);
    }
    if (encoderHasProperty(encoder, "bitrate")) {
        return QStringLiteral(" bitrate=%1").arg(kbps);
    }
    return QString();
}

} // namespace

// === ProxyGeneratorWorker ===

ProxyGeneratorWorker::ProxyGeneratorWorker(QObject *parent)
    : QObject(parent)
{
}

ProxyGeneratorWorker::~ProxyGeneratorWorker()
{
}

QString ProxyGeneratorWorker::cancelKey(const QString &itemId, const QString &resolution)
{
    return itemId + "|" + resolution;
}

bool ProxyGeneratorWorker::isCancelled(const QString &key)
{
    QMutexLocker locker(&m_mutex);
    return m_cancelledKeys.contains(key);
}

void ProxyGeneratorWorker::cancelGeneration(const QString &itemId, const QString &resolution)
{
    QMutexLocker locker(&m_mutex);
    const QString key = cancelKey(itemId, resolution);
    if (!m_cancelledKeys.contains(key)) m_cancelledKeys.append(key);
}

void ProxyGeneratorWorker::generateProxy(const QString &sourceFilePath,
                                          const QString &outputPath,
                                          const QString &itemId,
                                          const QString &resolution,
                                          const QString &format,
                                          int targetWidth,
                                          int targetHeight,
                                          const QString &device)
{
    const QString key = cancelKey(itemId, resolution);
    if (isCancelled(key)) {
        QMutexLocker locker(&m_mutex);
        m_cancelledKeys.removeAll(key);
        emit proxyError(itemId, resolution, "Cancelled");
        return;
    }

    qDebug() << "ProxyGenerator: starting generation for" << itemId << resolution << format;
    emit proxyProgress(itemId, resolution, 0);

    // --- 1. Stream presence probe (playbin + fakesink, PAUSED) ---
    // Same technique WaveformGenerator.cpp's no-audio pre-check and
    // MetadataExtractor already use and document as reliable - "n-video"/
    // "n-audio" after a successful PAUSED preroll, not container tags.
    // Determines whether to include an audio branch in the pipeline at
    // all (a video-only drone/action-cam source must not reference a
    // dec. audio pad that will never appear) and fails fast+cleanly on a
    // source that can't preroll, instead of risking the exact kind of
    // silent hang this project has already hit once in WaveformGenerator
    // (see CacheManager.cpp/WaveformGenerator.cpp's "no-audio" history).
    bool hasAudio = false;
    bool hasVideo = false;
    int sourceWidth = 0, sourceHeight = 0;
    {
        GstElement *probe = gst_element_factory_make("playbin", nullptr);
        if (!probe) {
            emit proxyError(itemId, resolution, "Could not create probe pipeline (playbin unavailable)");
            return;
        }
        QString cleanPath = sourceFilePath;
        if (cleanPath.startsWith("file://")) cleanPath = cleanPath.mid(7);
        gchar *uriRaw = gst_filename_to_uri(cleanPath.toUtf8().constData(), nullptr);
        const QByteArray uri = QByteArray(uriRaw ? uriRaw : "");
        g_free(uriRaw);
        if (!uri.isEmpty()) {
            g_object_set(G_OBJECT(probe), "uri", uri.constData(), NULL);
        } else {
            g_object_set(G_OBJECT(probe), "uri", sourceFilePath.toUtf8().constData(), NULL);
        }
        GstElement *fakeVideoSink = gst_element_factory_make("fakesink", nullptr);
        GstElement *fakeAudioSink = gst_element_factory_make("fakesink", nullptr);
        if (fakeVideoSink) g_object_set(G_OBJECT(probe), "video-sink", fakeVideoSink, nullptr);
        if (fakeAudioSink) g_object_set(G_OBJECT(probe), "audio-sink", fakeAudioSink, nullptr);

        gst_element_set_state(probe, GST_STATE_PAUSED);
        const GstStateChangeReturn probeRet =
            gst_element_get_state(probe, nullptr, nullptr, 5 * GST_SECOND);

        gint nAudio = 0, nVideo = 0;
        g_object_get(G_OBJECT(probe), "n-audio", &nAudio, "n-video", &nVideo, NULL);

        // Real source dimensions, read off the fakesink's negotiated sink
        // pad caps while still PAUSED - needed to fit the target
        // resolution box to the source's ACTUAL aspect ratio (A.4/F.1:
        // "fits inside the box preserving the source's actual aspect
        // ratio - the drone/action-cam material isn't always 16:9").
        // Plain videoscale to a literal WxH stretches/squashes instead;
        // confirmed live (a 21:9-ish source into a 16:9 960x540 box came
        // out with a non-square pixel-aspect-ratio annotation, i.e.
        // visibly squashed, before this fit-box computation was added.
        if (nVideo > 0 && fakeVideoSink) {
            GstPad *sinkPad = gst_element_get_static_pad(fakeVideoSink, "sink");
            if (sinkPad) {
                GstCaps *caps = gst_pad_get_current_caps(sinkPad);
                if (caps) {
                    GstStructure *s = gst_caps_get_structure(caps, 0);
                    gst_structure_get_int(s, "width", &sourceWidth);
                    gst_structure_get_int(s, "height", &sourceHeight);
                    gst_caps_unref(caps);
                }
                gst_object_unref(sinkPad);
            }
        }

        gst_element_set_state(probe, GST_STATE_NULL);
        gst_object_unref(probe);

        const bool probePrerolled = (probeRet == GST_STATE_CHANGE_SUCCESS ||
                                      probeRet == GST_STATE_CHANGE_NO_PREROLL);
        if (!probePrerolled) {
            emit proxyError(itemId, resolution, "Source could not be opened (probe failed to preroll)");
            return;
        }
        if (nVideo == 0) {
            emit proxyError(itemId, resolution, "Source has no video stream");
            return;
        }
        hasVideo = true;
        hasAudio = (nAudio > 0);
    }

    // Fit targetWidth x targetHeight AS A BOX: scale the source's actual
    // aspect ratio to fit inside it, never stretch to fill it exactly.
    // Dimensions rounded down to multiples of 16, not just even numbers -
    // found empirically (proxy_build_plan.md J.4.6's "verify with a real
    // A/B screenshot" caveat, finally hit for real): a 640x512 source fit
    // into a 640x360 box lands on 450x360. Played back standalone that
    // .mov is fine, but composited live in the timeline (with a frei0r
    // colorkey effect on the same clip) the frame comes out visibly
    // SHEARED. Root cause confirmed by elimination, not guessed: a
    // height of 360 is divisible by 4 but NOT by 16, so the H.264
    // encoder (16x16 macroblocks) actually codes 368 rows and crops to
    // 360 via SPS frame-cropping - something in the colorkey chain
    // (gst-plugins-bad's frei0r wrapper, gstfrei0rfilter.c, maps buffers
    // with plain gst_buffer_map() and hands frei0r a raw pointer with no
    // stride/crop awareness at all - frei0r's own C API has no stride
    // concept) doesn't carry that crop through cleanly. Re-rounding both
    // dimensions to multiples of 16 (448x352 for this exact source) and
    // regenerating fixed it completely - confirmed via live A/B
    // screenshot, not assumed. Matches TimelineEngine.cpp's own 16-
    // alignment on the PROJECT's track caps, same underlying reason
    // (H.264/H.265 macroblock size), now applied here too. A clip with
    // no effects that care about raw pixel data (plain video, GL-only
    // effects like lut3d/curves) was never at risk - only a non-GL, C-
    // level filter like frei0r's actually dereferences pixels assuming
    // no cropping/padding exists.
    if (sourceWidth > 0 && sourceHeight > 0) {
        const double boxAspect = (double)targetWidth / (double)targetHeight;
        const double srcAspect = (double)sourceWidth / (double)sourceHeight;
        int fitW, fitH;
        if (srcAspect > boxAspect) {
            fitW = targetWidth;
            fitH = (int)qRound(targetWidth / srcAspect);
        } else {
            fitH = targetHeight;
            fitW = (int)qRound(targetHeight * srcAspect);
        }
        fitW -= fitW % 16;
        fitH -= fitH % 16;
        targetWidth = qMax(16, fitW);
        targetHeight = qMax(16, fitH);
    }
    // else: could not read source dimensions (unusual) - fall back to the
    // literal target box, same as before this fit-box computation existed.

    // --- 2. Pick the video encoder + per-format element config ---
    QString encoderFellBackTo;
    QString videoElement; // full "elementname prop=val prop=val"
    QString muxerElement; // bare element name
    // DNxHR's encoder only accepts two fixed resolutions (1920x1080 or
    // 1280x720) - confirmed via gst-inspect-1.0 during Phase 0b
    // measurement (see proxy_build_plan.md B.5). Silently overriding the
    // requested target here (rather than failing the job) matches the
    // Settings UI's own "fixed resolution, ignores the setting" helper
    // text for this format.
    int effectiveWidth = targetWidth;
    int effectiveHeight = targetHeight;
    // Normalizes the encoder's bitstream into something every muxer can
    // actually link to. Needed unconditionally, not just for vaapi: VA-API's
    // vah264enc/vah265enc only ever produce stream-format=byte-stream
    // (confirmed via gst-inspect-1.0's SRC template), while qtmux requires
    // stream-format=avc - without a parser to convert it, linking the
    // encoder straight to qtmux fails outright ("queue1 cannot be linked to
    // mux", reproduced live the moment the vaapi backend was wired up in
    // Phase 4; nvh264enc/x264enc happened to already emit avc, which is why
    // this went unnoticed through Phase 3). h264parse/h265parse are also
    // cheap and harmless for backends that didn't strictly need them.
    QString parserElement;
    // Which backend the encoder actually came from - for the log line below
    // only; the per-element property string no longer depends on it.
    QString actualBackend;

    if (format == "h264_intra" || format == "h264_longgop") {
        const char *caps = "video/x-h264";
        QString enc = pickVideoEncoder(caps, device, &actualBackend, &encoderFellBackTo);
        if (enc.isEmpty()) {
            emit proxyError(itemId, resolution, "No H.264 encoder available");
            return;
        }
        if (format == "h264_intra") {
            // All-intra property names differ PER ELEMENT, not per backend
            // (gop-size vs key-int-max; speed-preset/tune exist only on
            // x264's family) - allIntraProperties() asks the element.
            videoElement = enc + allIntraProperties(enc) + qualityProperties(enc, kProxyQualityQp);
        } else {
            videoElement = enc + qualityProperties(enc, kProxyQualityQp); // long-GOP: rate control only
        }
        parserElement = "h264parse";
        muxerElement = "qtmux";
    } else if (format == "h265_intra") {
        const char *caps = "video/x-h265";
        QString enc = pickVideoEncoder(caps, device, &actualBackend, &encoderFellBackTo);
        if (enc.isEmpty()) {
            emit proxyError(itemId, resolution, "No H.265 encoder available");
            return;
        }
        videoElement = enc + allIntraProperties(enc) + qualityProperties(enc, kProxyQualityQp);
        parserElement = "h265parse";
        muxerElement = "qtmux";
    } else if (format == "mjpeg") {
        if (!elementExists("jpegenc")) {
            emit proxyError(itemId, resolution, "jpegenc not available");
            return;
        }
        videoElement = "jpegenc quality=90";
        muxerElement = "matroskamux";
    } else if (format == "raw_i420") {
        videoElement.clear(); // no encoder - raw passthrough
        muxerElement = "matroskamux";
    } else if (format == "dnxhr_lb") {
        if (!elementExists("avenc_dnxhd")) {
            emit proxyError(itemId, resolution, "avenc_dnxhd not available");
            return;
        }
        effectiveWidth = 1920;
        effectiveHeight = 1080;
        // 36 Mbps: in the ballpark of Avid's published DNxHR LB spec at
        // 1080p - not independently re-measured here (B.6 flags DNxHR as
        // a secondary, not-the-default format); avenc_dnxhd's own
        // default (200 kbps) is far too low to produce a valid DNxHR
        // bitstream at this resolution.
        videoElement = "avenc_dnxhd profile=dnxhr_lb bitrate=36000000";
        muxerElement = "mxfmux";
    } else {
        emit proxyError(itemId, resolution, "Unknown proxy format: " + format);
        return;
    }

    // --- 2b. Force hardware decoding to match the encoder backend ---
    // uridecodebin autoplugs a decoder by registry rank; without this a GPU
    // encode (nvidia/vaapi) can be paired with a CPU decode. Boosting the
    // same backend's decoders here makes decode match encode. An empty
    // actualBackend (mjpeg / raw_i420 / dnxhr_lb) skips this - those formats
    // have no meaningful hardware decoder and keep the default autoplug.
    if (!actualBackend.isEmpty()) {
        GstElementDiscovery::applyDecoderRankPreference(actualBackend);
        qDebug() << "ProxyGenerator: decode backend ->" << actualBackend;
    }

    // --- 3. Build the pipeline description ---
    QString cleanPath = sourceFilePath;
    cleanPath.replace("\"", "\\\"");
    gchar *uriRaw2 = gst_filename_to_uri(sourceFilePath.toUtf8().constData(), nullptr);
    QString uri = QString::fromUtf8(uriRaw2 ? uriRaw2 : "");
    g_free(uriRaw2);
    if (uri.isEmpty()) uri = sourceFilePath; // already a URI

    QString outPath = outputPath;
    outPath.replace("\"", "\\\"");

    // VFR guarantee (proxy_build_plan.md Part C): the scale capsfilter
    // below deliberately has NO framerate field, and nothing here ever
    // inserts a videorate element - cuts made against a VFR proxy must
    // land on the same instants as the original, which only holds if
    // every frame's original PTS passes through untouched.
    //
    // Colorimetry is per format:
    //  - h264/h265: bt709 (HD video convention).
    //  - mjpeg: 1:4:0:0 (JPEG is full-range BT.601, which is what jpegdec
    //    reports), so videoconvert converts into what playback will assume;
    //    a blanket bt709 would mislabel it and shift colours.
    //  - raw_i420 (no colorimetry) and dnxhr_lb: none - forcing bt709 makes
    //    avenc_dnxhd fail to negotiate (not-negotiated, pipeline never starts).
    QString videoCaps = QString("video/x-raw,width=%1,height=%2").arg(effectiveWidth).arg(effectiveHeight);
    if (format == "raw_i420") {
        videoCaps = QString("video/x-raw,format=I420,width=%1,height=%2").arg(effectiveWidth).arg(effectiveHeight);
    } else if (format == "h264_intra" || format == "h264_longgop" || format == "h265_intra") {
        videoCaps += ",colorimetry=bt709";
    } else if (format == "mjpeg") {
        videoCaps += ",colorimetry=1:4:0:0";
    }

    QString videoBranch;
    if (videoElement.isEmpty()) {
        // raw_i420 has no encoder element (and therefore no parser either).
        videoBranch = QString(
            "dec. ! queue ! videoconvert ! videoscale ! %1 ! queue ! mux."
        ).arg(videoCaps);
    } else if (parserElement.isEmpty()) {
        videoBranch = QString(
            "dec. ! queue ! videoconvert ! videoscale ! %1 ! %2 ! queue ! mux."
        ).arg(videoCaps, videoElement);
    } else {
        videoBranch = QString(
            "dec. ! queue ! videoconvert ! videoscale ! %1 ! %2 ! %3 ! queue ! mux."
        ).arg(videoCaps, videoElement, parserElement);
    }

    QString audioBranch;
    // avenc_aac first (the encoder the proxies were tuned with), else any
    // other AAC encoder the registry has (fdkaacenc, voaacenc, ...).
    const QString aacEncoder = hasAudio ? CodecCheck::preferredAacEncoder() : QString();
    if (hasAudio) {
        if (muxerElement == "mxfmux") {
            // mxfmux's audio sink pad only accepts raw PCM (bwf_audio_sink,
            // confirmed via gst-inspect-1.0) - MXF's native convention,
            // not a compressed codec the way MOV/MKV accept AAC.
            audioBranch = "dec. ! queue ! audioconvert ! audio/x-raw,format=S16LE ! queue ! mux.";
        } else if (!aacEncoder.isEmpty()) {
            audioBranch = QStringLiteral("dec. ! queue ! audioconvert ! audioresample ! %1 ! queue ! mux.").arg(aacEncoder);
        } else {
            // No AAC encoder registered at all (e.g. the AppImage on a host
            // without gst-libav): keep the proxy usable with uncompressed
            // PCM, which both qtmux and matroskamux accept.
            audioBranch = "dec. ! queue ! audioconvert ! audioresample ! audio/x-raw,format=S16LE ! queue ! mux.";
        }
    }

    const QString pipelineDesc = QString(
        "uridecodebin name=dec uri=\"%1\" "
        "%2 "
        "%3 "
        "%4 name=mux ! filesink location=\"%5\""
    ).arg(uri, videoBranch, audioBranch, muxerElement, outPath);

    qDebug() << "ProxyGenerator: format" << format
             << "requested device" << (device.isEmpty() ? QStringLiteral("auto") : device)
             << "-> encoder backend" << (actualBackend.isEmpty() ? QStringLiteral("n/a") : actualBackend);
    if (!actualBackend.isEmpty()) {
        emit proxyBackendResolved(itemId, resolution, actualBackend);
    }
    qDebug() << "ProxyGenerator: pipeline:" << pipelineDesc;
    if (!encoderFellBackTo.isEmpty()) {
        qDebug() << "ProxyGenerator: encoder fallback:" << encoderFellBackTo;
    }

    GError *error = nullptr;
    GstElement *pipeline = gst_parse_launch(pipelineDesc.toUtf8().constData(), &error);
    if (error) {
        const QString msg = QString::fromUtf8(error->message);
        g_error_free(error);
        emit proxyError(itemId, resolution, "Pipeline error: " + msg);
        return;
    }
    if (!pipeline) {
        emit proxyError(itemId, resolution, "Failed to create pipeline");
        return;
    }

    GstStateChangeReturn ret = gst_element_set_state(pipeline, GST_STATE_PLAYING);
    if (ret == GST_STATE_CHANGE_FAILURE) {
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(pipeline);
        emit proxyError(itemId, resolution, "Failed to start pipeline");
        return;
    }

    // --- 4. Run to EOS/ERROR, polling for cancel + progress in between ---
    // A bounded poll timeout (not GST_CLOCK_TIME_NONE) is required so this
    // loop can notice a cross-thread cancel request and a periodic
    // position query for progress, while still blocking (cheaply) between
    // polls rather than busy-spinning - this worker runs on its own
    // QThread with no GLib main loop driving an async bus-watch, so a
    // purely async gst_bus_add_watch() callback would never fire here.
    GstBus *bus = gst_element_get_bus(pipeline);
    bool success = false;
    bool cancelled = false;
    QString errorMsg;
    gint64 duration = -1;

    while (true) {
        if (isCancelled(key)) {
            cancelled = true;
            break;
        }

        GstMessage *msg = gst_bus_timed_pop_filtered(
            bus, 300 * GST_MSECOND,
            (GstMessageType)(GST_MESSAGE_EOS | GST_MESSAGE_ERROR));
        if (msg) {
            if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_EOS) {
                success = true;
                gst_message_unref(msg);
                break;
            }
            // GST_MESSAGE_ERROR
            GError *err = nullptr;
            gchar *dbg = nullptr;
            gst_message_parse_error(msg, &err, &dbg);
            errorMsg = err ? QString::fromUtf8(err->message) : QStringLiteral("unknown error");
            if (err) g_error_free(err);
            if (dbg) g_free(dbg);
            gst_message_unref(msg);
            break;
        }

        if (duration <= 0) {
            gst_element_query_duration(pipeline, GST_FORMAT_TIME, &duration);
        }
        gint64 pos = 0;
        if (duration > 0 && gst_element_query_position(pipeline, GST_FORMAT_TIME, &pos)) {
            int pct = (int)((pos * 100) / duration);
            emit proxyProgress(itemId, resolution, qBound(0, pct, 99));
        }
    }

    gst_object_unref(bus);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(pipeline);

    {
        QMutexLocker locker(&m_mutex);
        m_cancelledKeys.removeAll(key);
    }

    if (cancelled) {
        // No partial file left behind (proxy_build_plan.md Phase 3
        // verification: "cancel leaves no partial file").
        QFile::remove(outputPath);
        emit proxyError(itemId, resolution, "Cancelled");
        return;
    }
    if (!success) {
        QFile::remove(outputPath);
        emit proxyError(itemId, resolution, errorMsg.isEmpty() ? "Unknown pipeline error" : errorMsg);
        return;
    }

    emit proxyProgress(itemId, resolution, 100);
    emit proxyGenerated(itemId, resolution, outputPath);
    qDebug() << "ProxyGenerator: completed" << itemId << resolution << "->" << outputPath;
}

// === ProxyGenerator ===

ProxyGenerator::ProxyGenerator(QObject *parent)
    : QObject(parent)
{
    m_workerThread = new QThread(this);
    m_worker = new ProxyGeneratorWorker();
    m_worker->moveToThread(m_workerThread);

    connect(this, &ProxyGenerator::startGeneration, m_worker, &ProxyGeneratorWorker::generateProxy);
    // requestCancel is NOT connected to the worker's cancelGeneration()
    // slot - a queued cross-thread signal only gets DELIVERED when the
    // worker thread's event loop processes its queue, but generateProxy()
    // runs as one long synchronous call on that thread and never returns
    // to the event loop until generation is already finished. A cancel
    // sent this way would never actually take effect mid-generation
    // (confirmed live: cancelling a 4.5-minute source's proxy generation
    // left it running to completion with a 136MB file already on disk).
    // ProxyGenerator::cancelGeneration() below instead calls the worker's
    // method DIRECTLY (plain C++ call, no signal/slot), which is safe
    // across threads because cancelGeneration() only touches
    // QMutex-guarded state - no queueing needed or wanted here.

    connect(m_worker, &ProxyGeneratorWorker::proxyGenerated, this, &ProxyGenerator::proxyReady);
    connect(m_worker, &ProxyGeneratorWorker::proxyProgress, this, &ProxyGenerator::proxyProgress);
    connect(m_worker, &ProxyGeneratorWorker::proxyError, this, &ProxyGenerator::proxyFailed);
    connect(m_worker, &ProxyGeneratorWorker::proxyBackendResolved, this, &ProxyGenerator::proxyBackendResolved);

    // Clear m_generating on either terminal outcome, so the destructor
    // knows whether there's actually anything left to cancel.
    connect(m_worker, &ProxyGeneratorWorker::proxyGenerated, this,
            [this](const QString &, const QString &, const QString &) { m_generating = false; });
    connect(m_worker, &ProxyGeneratorWorker::proxyError, this,
            [this](const QString &, const QString &, const QString &) { m_generating = false; });

    connect(m_workerThread, &QThread::finished, m_worker, &QObject::deleteLater);
    m_workerThread->start();
}

ProxyGenerator::~ProxyGenerator()
{
    if (m_generating) {
        // Ask the in-flight job to stop instead of just waiting for it -
        // without this, app shutdown blocked for however long the
        // remaining encode took (minutes, on 4K), because quit() below
        // only asks the worker thread's event loop to exit, which it
        // can't act on until generateProxy()'s blocking call returns on
        // its own. cancelGeneration() is a direct cross-thread call (see
        // its own comment), so it takes effect immediately regardless.
        m_worker->cancelGeneration(m_currentItemId, m_currentResolution);
    }

    m_workerThread->quit();
    // Bounded, not unconditional: gst_element_set_state(..., GST_STATE_NULL)
    // during the worker's own teardown can itself block forever against a
    // pathologically stalled source (e.g. a FIFO or a hung network mount -
    // GstFileSrc's blocking read() has no unlock(), a known, documented
    // limitation - see the bus-polling loop's comments above). The app is
    // exiting either way, so after a generous timeout, abandon the thread
    // rather than hang the whole app closed over one stuck pipeline.
    if (!m_workerThread->wait(20000)) {
        qWarning() << "ProxyGenerator: worker thread did not stop within 20s "
                      "(likely a stalled source) - abandoning it so app shutdown "
                      "isn't blocked; the OS reclaims it on process exit";
        // Detach it from us before we (and therefore our QObject children)
        // get destroyed - QThread's own destructor running on a thread
        // that's still actually running is documented by Qt as producing
        // undefined behavior. Orphaning it here is deliberate and only
        // safe BECAUSE the whole process is about to exit anyway.
        m_workerThread->setParent(nullptr);
    }
}

void ProxyGenerator::generateProxy(const QString &sourceFilePath,
                                    const QString &outputPath,
                                    const QString &itemId,
                                    const QString &resolution,
                                    const QString &format,
                                    int targetWidth,
                                    int targetHeight,
                                    const QString &device)
{
    m_generating = true;
    m_currentItemId = itemId;
    m_currentResolution = resolution;
    emit startGeneration(sourceFilePath, outputPath, itemId, resolution, format, targetWidth, targetHeight, device);
}

void ProxyGenerator::cancelGeneration(const QString &itemId, const QString &resolution)
{
    // Direct call, not a queued signal - see the constructor's comment on
    // why requestCancel is not wired up as one. cancelGeneration() itself
    // only does a QMutexLocker-guarded list append, so calling it from
    // this (GUI) thread while generateProxy() runs on m_workerThread is
    // safe.
    m_worker->cancelGeneration(itemId, resolution);
}
