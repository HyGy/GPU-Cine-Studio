#include "RenderEngine.h"
#include "FrameRate.h"
#include "ClipEffects.h"
#include "GlTimeline.h"
#include "TitleClips.h"
#include "GesTransitions.h"
#include "TimeConv.h"
#include "GstElementDiscovery.h"
#include <QDebug>
#include <QFileInfo>
#include <QThread>
#include <QElapsedTimer>
#include <gst/gst.h>
#include <gst/pbutils/encoding-profile.h>
#include <algorithm>

// Must undef signals before including GES due to Qt/GLib conflict
#ifdef signals
#undef signals
#endif
#include <ges/ges.h>
#define signals Q_SIGNALS

namespace {

// Pins every registered video encoder to a known rank ONCE at startup,
// instead of being re-shuffled per render - rank is process-global state, so
// the old "boost the chosen encoder to PRIMARY+100 right before building the
// pipeline" trick made two simultaneous renders fight over which encoder
// either of them would get. The chosen encoder is now pinned per-job via the
// encoding profile's preset-name (encodebin skips every factory whose name
// differs), which is job-local and therefore safe to run concurrently.
void normaliseEncoderRanks()
{
    GstRegistry *registry = gst_registry_get();
    for (const QString &name : GstElementDiscovery::allEncoderFactories()) {
        GstPluginFeature *feature = gst_registry_lookup_feature(registry, name.toUtf8().constData());
        if (feature) {
            gst_plugin_feature_set_rank(feature, GST_RANK_SECONDARY);
            gst_object_unref(feature);
        }
    }
}

// --- codec family -----------------------------------------------------------
enum class CodecFamily { H264, H265, AV1, VP9 };

// The codec strings reaching here come straight from the UI combo box, and
// BackendManager has historically produced BOTH "H.265 (HEVC)" and plain
// "H.265" for the same thing - matching only the long spelling silently
// rendered H.264 when the user picked H.265 on the CPU device.
CodecFamily parseCodec(const QString &codec)
{
    const QString c = codec.toUpper();
    if (c.contains("265") || c.contains("HEVC")) return CodecFamily::H265;
    if (c.contains("AV1")) return CodecFamily::AV1;
    if (c.contains("VP9")) return CodecFamily::VP9;
    return CodecFamily::H264;
}

const char *codecCaps(CodecFamily f)
{
    switch (f) {
    case CodecFamily::H265: return "video/x-h265";
    case CodecFamily::AV1:  return "video/x-av1";
    case CodecFamily::VP9:  return "video/x-vp9";
    default:                return "video/x-h264";
    }
}

bool elementExists(const char *name)
{
    GstElementFactory *f = gst_element_factory_find(name);
    if (!f) return false;
    gst_object_unref(f);
    return true;
}

// True when the named encoder factory's src pad template can produce
// video/x-h264,profile=high.
bool encoderSupportsH264High(const QString &factoryName)
{
    // openh264enc's src template advertises "high", but pinning profile=high
    // downstream makes the render stall forever (measured with GStreamer
    // 1.28.8: it only ever produces constrained-baseline). It stays unrequested.
    if (factoryName == QLatin1String("openh264enc")) return false;
    GstElementFactory *f = gst_element_factory_find(factoryName.toUtf8().constData());
    if (!f) return false;
    bool ok = false;
    GstCaps *high = gst_caps_from_string("video/x-h264,profile=(string)high");
    for (const GList *l = gst_element_factory_get_static_pad_templates(f); l; l = l->next) {
        GstStaticPadTemplate *t = static_cast<GstStaticPadTemplate *>(l->data);
        if (t->direction != GST_PAD_SRC) continue;
        GstCaps *tc = gst_static_caps_get(&t->static_caps);
        if (gst_caps_can_intersect(tc, high)) ok = true;
        gst_caps_unref(tc);
    }
    gst_caps_unref(high);
    gst_object_unref(f);
    return ok;
}

// Picks the encoder factory for (backend, codec) by querying the registry for
// whatever actually implements that caps on that backend's plugin right now,
// instead of matching a hand-maintained element-name list (which is what
// silently broke when GStreamer 1.28 renamed the nvcodec CUDA-mode encoders).
// Falls back to the software encoder when the hardware doesn't implement that
// codec (NVENC has no VP9 encoder; the VA plugin has no VP9 encoder either).
QString selectEncoderElement(const QString &backend, CodecFamily codec, QString *fellBackTo)
{
    const char *caps = codecCaps(codec);
    const bool isHardwareBackend = (backend == "nvidia" || backend == "vaapi");
    QStringList candidates = isHardwareBackend
        ? GstElementDiscovery::findEncoderFactories(caps, backend)
        : QStringList();
    for (const QString &c : candidates) {
        if (elementExists(c.toUtf8().constData())) return c;
    }

    const QStringList sw = GstElementDiscovery::findEncoderFactories(caps, "cpu");
    for (const QString &c : sw) {
        if (elementExists(c.toUtf8().constData())) {
            if (fellBackTo && isHardwareBackend) *fellBackTo = c;
            return c;
        }
    }
    return QString();
}

// The raw pixel format to force on the GES video track, derived from what the
// selected encoder's sink pad template ACTUALLY accepts in system memory.
// This used to be hardcoded as `nvidia ? NV12 : I420`, which is why every
// VA-API render died: vah264enc/vah265enc accept NV12 only (no I420), so GES
// could not link the timeline's video track to encodebin and the pipeline
// aborted with "Following encodebin pads are not linked" -> "general stream
// error".
QString pickPixelFormat(const QString &encoderElement, bool preferNV12)
{
    // Hardware encoders want NV12 (it is what the VA/NVENC surfaces are);
    // software encoders are happiest with I420, their native planar layout.
    static const char *const hwPrefs[] = { "NV12", "I420", "Y444", "P010_10LE", nullptr };
    static const char *const swPrefs[] = { "I420", "NV12", "Y444", "P010_10LE", nullptr };
    const char *const *prefs = preferNV12 ? hwPrefs : swPrefs;

    GstElementFactory *factory = gst_element_factory_find(encoderElement.toUtf8().constData());
    if (!factory) return QStringLiteral("I420");

    QString result;
    const GList *templates = gst_element_factory_get_static_pad_templates(factory);
    for (const GList *l = templates; l && result.isEmpty(); l = l->next) {
        GstStaticPadTemplate *tmpl = (GstStaticPadTemplate*)l->data;
        if (tmpl->direction != GST_PAD_SINK) continue;

        GstCaps *caps = gst_static_pad_template_get_caps(tmpl);
        for (guint i = 0; i < gst_caps_get_size(caps) && result.isEmpty(); ++i) {
            // Only plain system-memory caps are usable: GES hands the encoder
            // ordinary raw buffers, not VAMemory/DMABuf/CUDAMemory ones.
            GstCapsFeatures *feat = gst_caps_get_features(caps, i);
            if (feat && !gst_caps_features_is_any(feat)
                && !gst_caps_features_is_equal(feat, GST_CAPS_FEATURES_MEMORY_SYSTEM_MEMORY)) {
                continue;
            }
            const GValue *fv = gst_structure_get_value(gst_caps_get_structure(caps, i), "format");
            if (!fv) continue;
            for (int k = 0; prefs[k] && result.isEmpty(); ++k) {
                if (G_VALUE_HOLDS_STRING(fv)) {
                    if (g_strcmp0(g_value_get_string(fv), prefs[k]) == 0) result = prefs[k];
                } else if (GST_VALUE_HOLDS_LIST(fv)) {
                    for (guint j = 0; j < gst_value_list_get_size(fv); ++j) {
                        const GValue *e = gst_value_list_get_value(fv, j);
                        if (G_VALUE_HOLDS_STRING(e) && g_strcmp0(g_value_get_string(e), prefs[k]) == 0) {
                            result = prefs[k];
                            break;
                        }
                    }
                }
            }
        }
        gst_caps_unref(caps);
    }
    gst_object_unref(factory);
    return result.isEmpty() ? QStringLiteral("I420") : result;
}

// Type-correct encoder property setting.
//
// gst_encoding_profile_set_element_properties() takes a GstStructure whose
// field types must match the target element's property types exactly -
// g_object_set_property() does NOT deserialize strings into enums. The old
// code hardcoded types, which produced (on vah264enc):
//     unable to set property 'rate-control' of type
//     'GstVaEncoderRateControl_H264_renderD128' from value of type 'gchararray'
//     object class 'GstVaH264Enc' has no property named 'keyframe-period'
// Here the real GParamSpec is looked up on the real element and the value is
// deserialized into the property's own GType, so enums, uints, ints, booleans
// and strings all work, and a property the element doesn't have is skipped
// with a readable warning instead of a GLib critical.
void setEncoderProp(GstStructure *props, const QString &element,
                    const char *prop, const QString &value)
{
    GstElement *probe = gst_element_factory_make(element.toUtf8().constData(), nullptr);
    if (!probe) return;

    GParamSpec *pspec = g_object_class_find_property(G_OBJECT_GET_CLASS(probe), prop);
    if (!pspec) {
        qDebug() << "Render:" << element << "has no property" << prop << "- skipping";
        gst_object_unref(probe);
        return;
    }

    GValue v = G_VALUE_INIT;
    g_value_init(&v, pspec->value_type);
    if (gst_value_deserialize(&v, value.toUtf8().constData())) {
        gst_structure_set_value(props, prop, &v);
    } else {
        qWarning() << "Render: cannot convert" << value << "for" << element << prop
                   << "(" << g_type_name(pspec->value_type) << ")";
    }
    g_value_unset(&v);
    gst_object_unref(probe);
}

// --- AV1 tier probe ---------------------------------------------------------
// av1parse first pushes caps with tier=main (before it has seen a sequence
// header) and, once the first frame is parsed, re-negotiates to the tier the
// ENCODER actually picked (NVENC picks tier=high at >=20 Mbps for 4K). Both
// mp4mux ("refused renegotiation") and encodebin's capsfilter reject that
// change, so the render died with "Internal data stream error" / not-negotiated.
// The tier cannot be queried from the encoder, so a tiny synchronous encode of
// a few frames with the SAME encoder properties reveals it; the result is then
// pinned in the profile's caps. Returns an empty string when the probe fails
// (caller falls back to unpinned caps).
QString probeAv1Tier(const QString &encoderElement, const GstStructure *props,
                     const QString &pixelFormat, int width, int height,
                     int fpsNum, int fpsDen)
{
    QString tier;
    GstElement *pipe = gst_pipeline_new("av1-tier-probe");
    GstElement *src = gst_element_factory_make("videotestsrc", nullptr);
    GstElement *cf = gst_element_factory_make("capsfilter", nullptr);
    GstElement *enc = gst_element_factory_make(encoderElement.toUtf8().constData(), nullptr);
    GstElement *parse = gst_element_factory_make("av1parse", nullptr);
    GstElement *sink = gst_element_factory_make("fakesink", nullptr);
    if (!pipe || !src || !cf || !enc || !parse || !sink) {
        for (GstElement *e : { src, cf, enc, parse, sink }) {
            if (e) { gst_object_ref_sink(e); gst_object_unref(e); }
        }
        if (pipe) gst_object_unref(pipe);
        return tier;
    }

    // Same element properties the render applies (typed per property already).
    if (props) {
        gst_structure_foreach(props, [](GQuark f, const GValue *v, gpointer ud) -> gboolean {
            g_object_set_property(G_OBJECT(ud), g_quark_to_string(f), v);
            return TRUE;
        }, enc);
    }

    GstCaps *raw = gst_caps_new_simple("video/x-raw",
        "format", G_TYPE_STRING, pixelFormat.toUtf8().constData(),
        "width", G_TYPE_INT, width, "height", G_TYPE_INT, height,
        "framerate", GST_TYPE_FRACTION, fpsNum, fpsDen, nullptr);
    g_object_set(cf, "caps", raw, nullptr);
    gst_caps_unref(raw);
    g_object_set(src, "num-buffers", 8, nullptr);
    g_object_set(sink, "sync", FALSE, nullptr);

    gst_bin_add_many(GST_BIN(pipe), src, cf, enc, parse, sink, nullptr);
    if (gst_element_link_many(src, cf, enc, parse, sink, nullptr)
            && gst_element_set_state(pipe, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE) {
        GstBus *bus = gst_element_get_bus(pipe);
        GstMessage *msg = gst_bus_timed_pop_filtered(bus, 8 * GST_SECOND,
            GstMessageType(GST_MESSAGE_EOS | GST_MESSAGE_ERROR));
        if (msg && GST_MESSAGE_TYPE(msg) == GST_MESSAGE_EOS) {
            GstPad *pad = gst_element_get_static_pad(parse, "src");
            GstCaps *cur = pad ? gst_pad_get_current_caps(pad) : nullptr;
            if (cur && gst_caps_get_size(cur) > 0) {
                const gchar *t = gst_structure_get_string(gst_caps_get_structure(cur, 0), "tier");
                if (t) tier = QString::fromUtf8(t);
            }
            if (cur) gst_caps_unref(cur);
            if (pad) gst_object_unref(pad);
        } else {
            qWarning() << "Render: AV1 tier probe failed or timed out";
        }
        if (msg) gst_message_unref(msg);
        gst_object_unref(bus);
    }
    gst_element_set_state(pipe, GST_STATE_NULL);
    gst_object_unref(pipe);
    return tier;
}

} // namespace

// ===========================================================================
// RenderJob
// ===========================================================================

RenderJob::RenderJob(int id, const QString &outputPath, const QVariantMap &settings, QObject *parent)
    : QObject(parent)
    , m_id(id)
    , m_outputPath(outputPath)
    , m_settings(settings)
{
    m_projectDir = settings.value("projectDir", "").toString();
    m_backendKey = settings.value("gpuEncoder", "cpu").toString();

    m_timer = new QTimer(this);
    m_timer->setInterval(500);
    connect(m_timer, &QTimer::timeout, this, &RenderJob::tick);
}

RenderJob::~RenderJob()
{
    destroyPipeline();
}

// Retunes the videoscale that encodebin inserts in front of the encoder.
// encodebin hard-codes `method=4-tap add-borders=TRUE` (gstencodebasebin.c);
// the borders would add black bars whenever the output aspect differs from the
// mixed one by a rounding hair (3840x1640 -> 1280x546). We want a plain
// stretch with a better filter. Runs from a "deep-element-added" handler on
// the pipeline, only for scalers living inside the encodebin (GES' own
// per-clip scalers are untouched); property sets only.
namespace {
bool hasAncestorNamed(GstObject *obj, const char *name)
{
    for (GstObject *p = GST_OBJECT_PARENT(obj); p; p = GST_OBJECT_PARENT(p)) {
        if (GST_OBJECT_NAME(p) && g_strcmp0(GST_OBJECT_NAME(p), name) == 0) return true;
    }
    return false;
}

void tuneOutputScaler(GstElement *element)
{
    GstElementFactory *f = gst_element_get_factory(element);
    if (!f || g_strcmp0(GST_OBJECT_NAME(f), "videoscale") != 0) return;
    if (!hasAncestorNamed(GST_OBJECT(element), "internal-encodebin")) return;
    // method 3 = lanczos. n-threads is deliberately left unset: 1.28's
    // videoconvertscale then uses the shared task pool at full width.
    g_object_set(element, "method", 3, "add-borders", FALSE, nullptr);
    qDebug() << "Render: output scaler" << GST_OBJECT_NAME(element) << "set to lanczos, no borders";
}

void onDeepElementAdded(GstBin *, GstBin *, GstElement *element, gpointer)
{
    tuneOutputScaler(element);
}
} // namespace

static void installOutputScalerTuner(GstElement *pipeline)
{
    GstIterator *it = gst_bin_iterate_recurse(GST_BIN(pipeline));
    GValue v = G_VALUE_INIT;
    bool done = false;
    while (!done) {
        switch (gst_iterator_next(it, &v)) {
        case GST_ITERATOR_OK:
            tuneOutputScaler(GST_ELEMENT(g_value_get_object(&v)));
            g_value_reset(&v);
            break;
        case GST_ITERATOR_RESYNC:
            gst_iterator_resync(it);
            break;
        default:
            done = true;
        }
    }
    g_value_unset(&v);
    gst_iterator_free(it);
}

bool RenderJob::start()
{
    qDebug() << "Render job" << m_id << "building pipeline, settings:" << m_settings;

    const QString format = m_settings.value("format", "MP4").toString();
    const QString codecStr = m_settings.value("codec", "H.264").toString();
    const QString resolutionStr = m_settings.value("resolution", "1920x1080").toString();
    const QString framerateStr = m_settings.value("framerate", "30 fps").toString();
    const int bitrateMbps = m_settings.value("bitrate", 50).toInt();
    const QString backend = m_backendKey;
    const CodecFamily codec = parseCodec(codecStr);

    int width = 0, height = 0, fpsNum = 30, fpsDen = 1;
    {
        // Expected form "WxH ..." (e.g. "3840x1600 (Project)"). Anything else
        // fails the job instead of silently rendering 1920x1080.
        const QStringList dim = resolutionStr.split(" ").first().split("x");
        if (dim.size() == 2) {
            bool okW = false, okH = false;
            width = dim[0].toInt(&okW); height = dim[1].toInt(&okH);
            if (!okW || !okH) width = height = 0;
        }
        if (width <= 0 || height <= 0) {
            complete(false, QStringLiteral("Invalid render resolution \"%1\" (expected WxH)").arg(resolutionStr));
            return false;
        }
    }
    // Mixing size: the timeline is composited at the PROJECT canvas size, since
    // clip transforms (fposx/fposy/fwidth/fheight, keyframes) and the other
    // pixel-based effect parameters are absolute canvas pixels. The chosen
    // output size is applied afterwards, by encodebin's scaler (see
    // onDeepElementAdded). The canvas travels in the job's own settings (not
    // read from QSettings here) so a queued job still renders at the canvas
    // it was submitted with, even if the project changes meanwhile. Absent or
    // non-positive (profile "auto"/unknown) -> mix at the output size, which
    // is the pre-existing behaviour. Even-rounded exactly like the preview
    // (TimelineEngine::createTimeline).
    int mixWidth = width, mixHeight = height;
    {
        const int cw = m_settings.value("canvasWidth", 0).toInt();
        const int ch = m_settings.value("canvasHeight", 0).toInt();
        if (cw > 0 && ch > 0) {
            mixWidth = (cw + 1) & ~1;
            mixHeight = (ch + 1) & ~1;
        }
    }
    const bool needsOutputScale = (mixWidth != width || mixHeight != height);
    if (!FrameRate::parse(framerateStr, fpsNum, fpsDen)) {
        complete(false, QStringLiteral("Invalid render frame rate \"%1\" (expected e.g. \"23.98 fps\")").arg(framerateStr));
        return false;
    }
    m_targetFps = double(fpsNum) / double(fpsDen);

    QString fellBackTo;
    const QString encoderElement = selectEncoderElement(backend, codec, &fellBackTo);
    if (encoderElement.isEmpty()) {
        complete(false, QStringLiteral("No encoder available for %1").arg(codecStr));
        return false;
    }
    if (!fellBackTo.isEmpty()) {
        qWarning() << "Render job" << m_id << ":" << backend
                   << "has no hardware encoder for" << codecStr
                   << "- falling back to software" << encoderElement;
    }
    const QString pixelFormat = pickPixelFormat(encoderElement, fellBackTo.isEmpty() && backend != "cpu");
    qDebug() << "Render job" << m_id << "encoder:" << encoderElement
             << "pixel format:" << pixelFormat;

    m_renderStartTime = QDateTime::currentMSecsSinceEpoch();
    m_lastRealTime = m_renderStartTime;
    m_lastPositionSec = 0.0;
    m_progress = 0;

    // --- timeline -----------------------------------------------------------
    // Export stays on the CPU compositing path (the encodebin profile below
    // wants system-memory raw video) even while the preview timeline runs in
    // GL mode - GES picks the mode per video track at creation, from this.
    // The mode must stay off until the timeline is fully built (clips,
    // effects, auto-transitions, commit): track elements build their filter
    // chain before they have a track, and then read the env var (see
    // GesGlModeGuard). Restored on every exit path.
    GlTimeline::GesGlModeGuard glModeGuard(false);
    GESTimeline *timeline = ges_timeline_new_audio_video();
    if (!timeline) {
        complete(false, QStringLiteral("Failed to create GES timeline"));
        return false;
    }
    g_object_set(timeline, "auto-transition", TRUE, NULL);

    GList *tracks = ges_timeline_get_tracks(timeline);
    for (GList *tmp = tracks; tmp; tmp = tmp->next) {
        GESTrack *track = GES_TRACK(tmp->data);
        GESTrackType type = GES_TRACK_TYPE_UNKNOWN;
        g_object_get(track, "track-type", &type, nullptr);
        g_object_set(track, "mixing", TRUE, nullptr);
        if (type == GES_TRACK_TYPE_VIDEO) {
            // format=RGBA pins the mixer output to RGB. GStreamer's YUV->YUV
            // conversion (videoconvert, compositor pad converters) ignores a
            // full/limited RANGE difference and merely relabels the caps, so
            // a full-range source (yuvj420p, e.g. drone/phone footage) used
            // to reach the encoder unsqueezed and mislabelled limited -
            // over-contrasty - whenever the mixer happened to stay in YUV
            // (single opaque layer). With an alpha overlay the mixer already
            // switched to RGBA and the range was converted correctly, so the
            // background changed look while the overlay was present. RGB
            // conversion honours the range, so always going through RGBA
            // makes the result independent of the overlay.
            GstCaps *caps = gst_caps_new_simple("video/x-raw",
                                                "format", G_TYPE_STRING, "RGBA",
                                                "width", G_TYPE_INT, mixWidth,
                                                "height", G_TYPE_INT, mixHeight,
                                                "framerate", GST_TYPE_FRACTION, fpsNum, fpsDen,
                                                nullptr);
            ges_track_set_restriction_caps(track, caps);
            gst_caps_unref(caps);
        }
    }
    g_list_free_full(tracks, gst_object_unref);

    QStringList videoIds, audioIds;
    for (const Clip &clip : clips) {
        const QString &id = clip.trackId;
        if (id.startsWith("V") && !videoIds.contains(id)) videoIds.append(id);
        else if (id.startsWith("A") && !audioIds.contains(id)) audioIds.append(id);
    }
    std::sort(videoIds.begin(), videoIds.end(), [](const QString &a, const QString &b) {
        return a.mid(1).toInt() > b.mid(1).toInt();
    });
    std::sort(audioIds.begin(), audioIds.end(), [](const QString &a, const QString &b) {
        return a.mid(1).toInt() < b.mid(1).toInt();
    });

    const QStringList orderedIds = videoIds + audioIds;
    QMap<QString, GESLayer*> layers;
    for (int i = 0; i < orderedIds.size(); i++) {
        GESLayer *layer = ges_timeline_append_layer(timeline);
        ges_layer_set_priority(layer, i);
        layers[orderedIds[i]] = layer;
    }

    GESAsset *titleAsset = nullptr;
    for (const Clip &clip : clips) {
        QString filePath = clip.itemPath;
        if (filePath.startsWith("file://")) filePath = filePath.mid(7);

        GESLayer *targetLayer = layers.value(clip.trackId, nullptr);
        if (!targetLayer) {
            qWarning() << "Render: Unknown trackId:" << clip.trackId << "- skipping clip";
            continue;
        }

        // Title clips - export parity with TimelineEngine::addClipToGES().
        // Must come before the URI-asset path: a title has no file.
        if (clip.clipKind == QLatin1String("title")) {
            GError *titleErr = nullptr;
            if (!titleAsset) titleAsset = ges_asset_request(GES_TYPE_TITLE_CLIP, nullptr, &titleErr);
            if (!titleAsset) {
                qWarning() << "Render: could not request title asset:"
                           << (titleErr ? titleErr->message : "unknown error");
                if (titleErr) g_error_free(titleErr);
                continue;
            }
            if (titleErr) g_error_free(titleErr);
            const TimeConv::Span titleSpan = TimeConv::span(clip.startTime, clip.durationSeconds);
            GESClip *addedTitle = ges_layer_add_asset(targetLayer, titleAsset,
                titleSpan.start, 0, titleSpan.duration,
                GES_TRACK_TYPE_VIDEO);
            if (addedTitle) TitleClips::applyToClip(addedTitle, clip.titleParams);
            else qWarning() << "Render: layer refused title clip on" << clip.trackId;
            continue;
        }

        GESTrackType trackType;
        if (clip.hasVideo && clip.hasAudio) {
            trackType = (GESTrackType)(GES_TRACK_TYPE_VIDEO | GES_TRACK_TYPE_AUDIO);
        } else if (clip.hasVideo) {
            trackType = GES_TRACK_TYPE_VIDEO;
        } else if (clip.hasAudio) {
            trackType = GES_TRACK_TYPE_AUDIO;
        } else {
            continue;
        }

        gchar *uri = gst_filename_to_uri(filePath.toUtf8().constData(), nullptr);
        GError *gerr = nullptr;
        // Requesting an asset by the ORIGINAL file's URI transparently
        // follows GES's own proxy chain (ges-asset.c's ASSET_PROXIED
        // lookup loop) and hands back whatever ges_asset_set_proxy()
        // last installed for it - i.e. if a preview proxy (ProxyAssets.h)
        // is currently installed, `requestedAsset` here IS that low-
        // resolution proxy, silently. Render must NEVER export proxy
        // quality - this is the one unwrap standing between that
        // silent-downgrade bug and every export, so do not remove or
        // "simplify" this without re-reading proxy_build_plan.md J.4.5.
        // An uncached asset makes this run a nested main loop (Qt's glib
        // dispatcher included), so the preview must see its own GL mode then.
        glModeGuard.release();
        GESAsset *requestedAsset = GES_ASSET(ges_uri_clip_asset_request_sync(uri, &gerr));
        glModeGuard.engage();
        if (requestedAsset && !gerr) {
            GESAsset *target = ges_asset_get_proxy_target(requestedAsset);
            // transfer-none (borrowed) - do not unref target separately
            // from requestedAsset below.
            GESAsset *renderAsset = target ? target : requestedAsset;
            if (target && ges_asset_get_error(target)) {
                // The REAL original is offline/broken - fail loudly rather
                // than silently rendering the clip from the proxy (or
                // skipping it outright). A render missing a clip, or
                // quietly downgraded to proxy quality, is worse than one
                // that stops with a clear error.
                qWarning() << "Render: proxy installed for" << filePath
                           << "but the original asset has an error - failing the job";
                g_object_unref(requestedAsset);
                g_error_free(gerr);
                g_free(uri);
                gst_object_unref(timeline);
                complete(false, QStringLiteral("Original media offline/broken (proxy was installed for preview, "
                                                "cannot render from it): ") + filePath);
                return false;
            }

            const TimeConv::Span clipSpan = TimeConv::span(clip.startTime, clip.durationSeconds);
            GESClip *addedClip = ges_layer_add_asset(targetLayer, renderAsset,
                clipSpan.start,
                TimeConv::secToNs(clip.sourceOffset),
                clipSpan.duration,
                trackType);
            // Unref what was actually REQUESTED, not whatever ended up
            // used - get_proxy_target() is transfer-none, so unreffing
            // `target` instead would be a use-after-free on the asset
            // cache's own reference.
            g_object_unref(requestedAsset);

            // Render-path parity with TimelineEngine::addClipToGES() -
            // without this, effects previewed in the live timeline would
            // silently not appear in the exported file.
            if (addedClip) {
                ClipEffects::applyToClip(addedClip, clip.effects, m_projectDir);

                // Track-level gain: the render builds its own GES timeline, so
                // the preview's per-track volume has to be applied here too.
                // Title clips have no audio source.
                if (clip.clipKind != QLatin1String("title")
                        && qAbs(clip.trackVolume - 1.0) > 0.0005) {
                    GList *elems = ges_clip_find_track_elements(addedClip, NULL,
                        GES_TRACK_TYPE_AUDIO, GES_TYPE_AUDIO_SOURCE);
                    for (GList *e = elems; e; e = e->next) {
                        ges_timeline_element_set_child_properties(
                            GES_TIMELINE_ELEMENT(e->data), "volume", clip.trackVolume, NULL);
                    }
                    g_list_free_full(elems, gst_object_unref);
                }

                // Track pan (stage C3): audiopanorama applied AFTER the
                // user's clip effects, same order as in the preview.
                // "panorama" is a gfloat property. Title clips have no audio.
                if (clip.clipKind != QLatin1String("title")
                        && qAbs(clip.trackPan) > 0.0005) {
                    GESEffect *panFx = ges_effect_new("audiopanorama name=gcspan method=simple");
                    if (panFx) {
                        ges_timeline_element_set_child_properties(
                            GES_TIMELINE_ELEMENT(panFx), "panorama",
                            (gfloat) clip.trackPan, NULL);
                        GError *perr = nullptr;
                        if (!ges_clip_add_top_effect(addedClip, GES_BASE_EFFECT(panFx), 0, &perr)) {
                            qWarning() << "RenderEngine: pan effect could not be added:"
                                       << (perr ? perr->message : "unknown error");
                            if (perr) g_error_free(perr);
                            g_object_ref_sink(panFx);
                            g_object_unref(panFx);
                        }
                        // On success the floating ref is sunk by GES.
                    }
                }
            }
        }
        if (gerr) g_error_free(gerr);
        g_free(uri);
    }

    {
        QVector<GesTransitions::PendingTransition> pending;
        for (const Clip &clip : clips) {
            if (!clip.hasTransition) continue;
            const QString &type = clip.transitionType;
            if (type.isEmpty() || type == QLatin1String("crossfade") || type == QLatin1String("dissolve")) continue;
            GstClockTime endNs = TimeConv::secToNs(clip.startTime + clip.durationSeconds);
            pending.append({ clip.trackId, endNs, type });
        }
        GesTransitions::applyTransitionTypes(layers, pending);
    }

    if (!ges_timeline_commit_sync(timeline)) {
        gst_object_unref(timeline);
        complete(false, QStringLiteral("Failed to commit timeline"));
        return false;
    }
    glModeGuard.release();

    // --- encoding profile ---------------------------------------------------
    GstEncodingContainerProfile *containerProfile;
    GstCaps *containerCaps;
    if (format == "MKV") {
        containerCaps = gst_caps_from_string("video/x-matroska");
        containerProfile = gst_encoding_container_profile_new("matroska", "Matroska", containerCaps, nullptr);
    } else if (format == "WEBM") {
        containerCaps = gst_caps_from_string("video/webm");
        containerProfile = gst_encoding_container_profile_new("webm", "WebM", containerCaps, nullptr);
    } else if (format == "MOV") {
        containerCaps = gst_caps_from_string("video/quicktime");
        containerProfile = gst_encoding_container_profile_new("mov", "QuickTime", containerCaps, nullptr);
    } else {
        containerCaps = gst_caps_from_string("video/quicktime,variant=iso");
        containerProfile = gst_encoding_container_profile_new("mp4", "MP4", containerCaps, nullptr);
    }
    gst_caps_unref(containerCaps);

    GstCaps *videoCaps = gst_caps_from_string(codecCaps(codec));
    // Without a profile in the caps NVENC (and others) negotiate whatever
    // their sink caps allow first, which came out as Constrained Baseline.
    // Ask for High - but only when the pinned encoder's src template can
    // actually produce it, so an encoder limited to baseline/main still
    // renders instead of failing caps negotiation.
    if (codec == CodecFamily::H264 && encoderSupportsH264High(encoderElement)) {
        gst_caps_set_simple(videoCaps, "profile", G_TYPE_STRING, "high", nullptr);
    }
    GstCaps *restrictionCaps = gst_caps_from_string("video/x-raw");
    gst_caps_set_simple(restrictionCaps,
                        "format", G_TYPE_STRING, pixelFormat.toUtf8().constData(),
                        "colorimetry", G_TYPE_STRING, "bt709",
                        "interlace-mode", G_TYPE_STRING, "progressive",
                        "width", G_TYPE_INT, width,
                        "height", G_TYPE_INT, height,
                        "framerate", GST_TYPE_FRACTION, fpsNum, fpsDen,
                        nullptr);
    // Square output pixels. Without it encodebin's videoscale is free to
    // pick a PAR that preserves the DAR exactly (3840x1640 -> 1280x546 would
    // not come out as plain 1:1).
    if (needsOutputScale)
        gst_caps_set_simple(restrictionCaps, "pixel-aspect-ratio", GST_TYPE_FRACTION, 1, 1, nullptr);

    GstEncodingVideoProfile *videoProfile =
        gst_encoding_video_profile_new(videoCaps, nullptr, restrictionCaps, 0);
    gst_caps_unref(videoCaps);
    gst_caps_unref(restrictionCaps);
    gst_encoding_profile_set_name(GST_ENCODING_PROFILE(videoProfile), "video");
    gst_encoding_video_profile_set_pass(videoProfile, 0);

    // Pins the exact encoder factory for THIS job. encodebin skips every
    // candidate factory whose name differs from the profile's preset-name, so
    // the choice is job-local - no process-global plugin-rank shuffling, which
    // is what makes two concurrent renders on different backends safe.
    gst_encoding_profile_set_preset_name(GST_ENCODING_PROFILE(videoProfile),
                                         encoderElement.toUtf8().constData());

    if (bitrateMbps > 0) {
        const int bitrateKbps = bitrateMbps * 1000;
        const QString kbpsStr = QString::number(bitrateKbps);
        GstStructure *props = gst_structure_new_empty("application/x-gst-external-properties");

        // Bitrate property name AND UNIT differ per encoder:
        //   x264enc/x265enc/nv*/va*  -> "bitrate",        kbit/s
        //   av1enc/svtav1enc         -> "target-bitrate", kbit/s
        //   vp9enc                   -> "target-bitrate", BIT/s
        if (encoderElement == "vp9enc") {
            setEncoderProp(props, encoderElement, "target-bitrate",
                           QString::number(qint64(bitrateKbps) * 1000));
        } else if (encoderElement == "av1enc" || encoderElement == "svtav1enc") {
            setEncoderProp(props, encoderElement, "target-bitrate", kbpsStr);
        } else {
            setEncoderProp(props, encoderElement, "bitrate", kbpsStr);
        }

        if (backend == "nvidia") {
            setEncoderProp(props, encoderElement, "preset", "p7");      // best quality
            setEncoderProp(props, encoderElement, "rate-control", "vbr");
            setEncoderProp(props, encoderElement, "gop-size", "60");
            setEncoderProp(props, encoderElement, "max-bitrate", kbpsStr);
        } else if (backend == "vaapi") {
            setEncoderProp(props, encoderElement, "rate-control", "vbr");
            // VA VBR interprets "bitrate" as the MAXIMUM and targets
            // target-percentage of it; without this it aims at 66%.
            setEncoderProp(props, encoderElement, "target-percentage", "95");
            setEncoderProp(props, encoderElement, "key-int-max", "60");
        } else {
            // --- software encoders ------------------------------------------
            // Measured on this machine (22 logical cores, 4K HEVC source):
            // x264enc with its DEFAULT threads=0 ("automatic") already runs
            // the whole process at 1400-1900% CPU, i.e. it is already
            // parallel. x264's own auto value (1.5x cores of frame threads)
            // is better than anything we'd hand it, so x264enc/x265enc are
            // deliberately left alone here.
            // vp9enc is the one that is NOT parallel by default: threads=8,
            // row-mt=false. av1enc/svtav1enc default to auto but not row-mt.
            const int cores = qMax(1, QThread::idealThreadCount());
            setEncoderProp(props, encoderElement, "key-int-max", "60");
            if (codec == CodecFamily::H264 || codec == CodecFamily::H265) {
                setEncoderProp(props, encoderElement, "speed-preset", "medium");
            } else {
                setEncoderProp(props, encoderElement, "threads", QString::number(cores));
                setEncoderProp(props, encoderElement, "logical-processors", "0"); // svtav1: auto
                setEncoderProp(props, encoderElement, "row-mt", "true");
                setEncoderProp(props, encoderElement, "cpu-used", "4");
            }
        }
        // NVENC AV1: pin the tier the encoder will really produce (see
        // probeAv1Tier). Software/VA AV1 encoders are not probed.
        if (codec == CodecFamily::AV1 && backend == "nvidia"
                && encoderElement.contains(QLatin1String("av1enc"))) {
            QElapsedTimer probeTimer; probeTimer.start();
            const QString tier = probeAv1Tier(encoderElement, props, pixelFormat,
                                              width, height, fpsNum, fpsDen);
            qDebug() << "Render: AV1 tier probe ->" << (tier.isEmpty() ? "none" : tier)
                     << "in" << probeTimer.elapsed() << "ms";
            if (!tier.isEmpty()) {
                GstCaps *pinned = gst_caps_from_string(codecCaps(codec));
                gst_caps_set_simple(pinned, "tier", G_TYPE_STRING, tier.toUtf8().constData(), nullptr);
                gst_encoding_profile_set_format(GST_ENCODING_PROFILE(videoProfile), pinned);
                gst_caps_unref(pinned);
            }
        }
        gst_encoding_profile_set_element_properties(GST_ENCODING_PROFILE(videoProfile), props);
    }

    gst_encoding_container_profile_add_profile(containerProfile, GST_ENCODING_PROFILE(videoProfile));

    GstCaps *audioCaps;
    if (format == "MKV" || format == "WEBM") audioCaps = gst_caps_from_string("audio/x-opus");
    else audioCaps = gst_caps_from_string("audio/mpeg,mpegversion=4,stream-format=raw");
    GstEncodingAudioProfile *audioProfile = gst_encoding_audio_profile_new(audioCaps, nullptr, nullptr, 0);
    gst_caps_unref(audioCaps);
    gst_encoding_profile_set_name(GST_ENCODING_PROFILE(audioProfile), "audio");
    gst_encoding_container_profile_add_profile(containerProfile, GST_ENCODING_PROFILE(audioProfile));

    // --- pipeline -----------------------------------------------------------
    m_pipeline = (GstElement*)ges_pipeline_new();
    // Connected this early so a scaler created while the render settings /
    // timeline are attached is caught too; installOutputScalerTuner() below
    // sweeps whatever already exists.
    if (needsOutputScale)
        g_signal_connect(m_pipeline, "deep-element-added", G_CALLBACK(onDeepElementAdded), nullptr);
    ges_pipeline_set_timeline(GES_PIPELINE(m_pipeline), timeline);

    gchar *outputUri = gst_filename_to_uri(m_outputPath.toUtf8().constData(), nullptr);
    gboolean ok = ges_pipeline_set_render_settings(GES_PIPELINE(m_pipeline), outputUri,
                                                   GST_ENCODING_PROFILE(containerProfile));
    gst_encoding_profile_unref(GST_ENCODING_PROFILE(containerProfile));
    g_free(outputUri);

    if (!ok) {
        destroyPipeline();
        complete(false, QStringLiteral("Failed to configure render settings."));
        return false;
    }

    ges_pipeline_set_mode(GES_PIPELINE(m_pipeline), GES_PIPELINE_MODE_RENDER);

    // encodebin builds its own videoconvert ! videoscale ! videoconvert chain
    // (method=4-tap, add-borders=TRUE, not configurable through the profile)
    // when the track is linked. Retune that videoscale when the output size
    // differs from the mixing size; otherwise the pipeline is left exactly as
    // it was (the scaler stays in passthrough).
    if (needsOutputScale)
        installOutputScalerTuner(m_pipeline);

    GstBus *bus = gst_pipeline_get_bus(GST_PIPELINE(m_pipeline));
    gst_bus_add_watch(bus, busCallback, this);
    gst_object_unref(bus);

    if (gst_element_set_state(m_pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        destroyPipeline();
        complete(false, QStringLiteral("Failed to start render pipeline state."));
        return false;
    }

    m_state = Running;
    m_timer->start();
    emit started(m_id);
    qDebug() << "Render job" << m_id << "started ->" << m_outputPath;
    return true;
}

void RenderJob::cancel()
{
    if (m_state != Running && m_state != Queued) return;
    destroyPipeline();
    m_state = Cancelled;
    emit finished(m_id, false, 0, QStringLiteral("Cancelled"));
}

void RenderJob::destroyPipeline()
{
    if (m_timer) m_timer->stop();
    if (m_pipeline) {
        // Removing the watch before NULL-ing avoids a bus callback firing into
        // a half-torn-down job.
        GstBus *bus = gst_pipeline_get_bus(GST_PIPELINE(m_pipeline));
        if (bus) {
            gst_bus_remove_watch(bus);
            gst_object_unref(bus);
        }
        gst_element_set_state(m_pipeline, GST_STATE_NULL);
        gst_object_unref(m_pipeline);
        m_pipeline = nullptr;
    }
}

void RenderJob::complete(bool success, const QString &errorMessage)
{
    if (m_state == Finished || m_state == Failed || m_state == Cancelled) return;

    qint64 fileSize = 0;
    if (success) {
        QFileInfo fi(m_outputPath);
        if (fi.exists()) fileSize = fi.size();
        if (m_progress < 100) {
            m_progress = 100;
            emit progressChanged(m_id, 100);
        }
    }
    destroyPipeline();
    m_state = success ? Finished : Failed;
    emit finished(m_id, success, fileSize, errorMessage);
}

void RenderJob::tick()
{
    if (!m_pipeline || m_state != Running) return;

    gint64 position = 0;
    if (!gst_element_query_position(m_pipeline, GST_FORMAT_TIME, &position)) return;

    const double positionSec = (double)position / GST_SECOND;
    const qint64 currentTime = QDateTime::currentMSecsSinceEpoch();
    const double timeDiffSec = (currentTime - m_lastRealTime) / 1000.0;

    if (timeDiffSec > 0.4) {
        const double videoDiffSec = positionSec - m_lastPositionSec;
        const double currentFps = (videoDiffSec / timeDiffSec) * m_targetFps;
        const double totalElapsedSec = (currentTime - m_renderStartTime) / 1000.0;
        const double avgFps = (totalElapsedSec > 0) ? (positionSec / totalElapsedSec) * m_targetFps : 0.0;
        if (currentFps > 0) emit fpsChanged(m_id, currentFps, avgFps);
        m_lastRealTime = currentTime;
        m_lastPositionSec = positionSec;
    }

    if (totalDuration > 0) {
        const int newProgress = std::min(100, (int)((positionSec / totalDuration) * 100.0));
        if (newProgress != m_progress) {
            m_progress = newProgress;
            emit progressChanged(m_id, m_progress);
        }
    }
}

gboolean RenderJob::busCallback(GstBus *bus, GstMessage *msg, gpointer data)
{
    Q_UNUSED(bus);
    RenderJob *job = static_cast<RenderJob*>(data);

    switch (GST_MESSAGE_TYPE(msg)) {
    case GST_MESSAGE_EOS:
        qDebug() << "Render job" << job->m_id << "finished (EOS)";
        job->complete(true, QString());
        break;
    case GST_MESSAGE_ERROR: {
        GError *err = nullptr;
        gchar *debug = nullptr;
        gst_message_parse_error(msg, &err, &debug);
        const QString errorMsg = QString::fromUtf8(err->message);
        qCritical() << "Render job" << job->m_id << "error:" << errorMsg
                    << "|" << (debug ? debug : "");
        if (debug) g_free(debug);
        g_error_free(err);
        job->complete(false, errorMsg);
        break;
    }
    default:
        break;
    }
    return TRUE;
}

// ===========================================================================
// RenderEngine
// ===========================================================================

RenderEngine::RenderEngine(QObject *parent)
    : QObject(parent)
{
    gst_init(nullptr, nullptr);
    ges_init();
    normaliseEncoderRanks();
}

RenderEngine::~RenderEngine()
{
    for (RenderJob *job : m_jobs) {
        job->cancel();
        delete job;
    }
    m_jobs.clear();
}

bool RenderEngine::isRendering() const { return activeJobCount() > 0; }

int RenderEngine::activeJobCount() const
{
    int n = 0;
    for (const RenderJob *j : m_jobs) if (j->state() == RenderJob::Running) ++n;
    return n;
}

int RenderEngine::queuedJobCount() const
{
    int n = 0;
    for (const RenderJob *j : m_jobs) if (j->state() == RenderJob::Queued) ++n;
    return n;
}

bool RenderEngine::outputPathExists(const QString &outputPath) const
{
    return QFileInfo::exists(outputPath);
}

int RenderEngine::startRender(const QString &outputPath,
                              const QVariantList &clipList,
                              double totalDuration,
                              const QVariantMap &settings)
{
    Q_UNUSED(totalDuration);

    QList<RenderJob::Clip> clips;
    double calculatedDuration = 0.0;
    for (const QVariant &clipVar : clipList) {
        const QVariantMap m = clipVar.toMap();
        RenderJob::Clip clip;
        clip.itemPath = m.value("itemPath").toString();
        clip.trackId = m.value("trackId").toString();
        clip.startTime = m.value("startTime").toDouble();
        clip.durationSeconds = m.value("durationSeconds").toDouble();
        clip.sourceOffset = m.value("sourceOffset", 0.0).toDouble();
        clip.hasVideo = m.value("hasVideo", true).toBool();
        clip.hasAudio = m.value("hasAudio", true).toBool();
        clip.trackVolume = m.value("trackVolume", 1.0).toDouble();
        clip.trackPan = m.value("trackPan", 0.0).toDouble();
        clip.hasTransition = m.value("hasTransition", false).toBool();
        clip.transitionDuration = m.value("transitionDuration", 0.0).toDouble();
        clip.transitionType = m.value("transitionType", "").toString();
        clip.effects = m.value("effects", "").toString();
        clip.clipKind = m.value("clipKind", "").toString();
        clip.titleParams = m.value("titleParams", "").toString();
        clips.append(clip);
        calculatedDuration = qMax(calculatedDuration, clip.startTime + clip.durationSeconds);
    }

    if (clips.isEmpty()) { emit error("No clips to render"); return -1; }
    if (calculatedDuration <= 0.0) { emit error("Total duration is zero"); return -1; }

    RenderJob *job = new RenderJob(m_nextJobId++, outputPath, settings, this);
    job->clips = clips;
    job->totalDuration = calculatedDuration;

    connect(job, &RenderJob::started, this, &RenderEngine::jobStarted);
    connect(job, &RenderJob::progressChanged, this, &RenderEngine::jobProgress);
    connect(job, &RenderJob::fpsChanged, this, &RenderEngine::jobFps);
    connect(job, &RenderJob::finished, this, &RenderEngine::onJobFinished);

    m_jobs.append(job);

    const bool canStartNow = !conflicts(job) && activeJobCount() < m_maxParallel;
    emit jobEnqueued(job->id(), canStartNow, canStartNow ? 0 : queuedJobCount());

    pumpQueue();
    emit renderingChanged();
    return job->id();
}

// A queued job may not start while another RUNNING job would collide with it:
//  - same output file  -> two pipelines writing one file = real corruption
//  - same backend      -> both want the same encoder hardware; GES/encodebin
//                         handles this, but it only makes both slower, and for
//                         "cpu" it would oversubscribe every core twice over
bool RenderEngine::conflicts(const RenderJob *candidate) const
{
    for (const RenderJob *j : m_jobs) {
        if (j == candidate || j->state() != RenderJob::Running) continue;
        if (j->outputPath() == candidate->outputPath()) return true;
        if (j->backendKey() == candidate->backendKey()) return true;
    }
    return false;
}

void RenderEngine::pumpQueue()
{
    // Reentrancy guard: RenderJob::start() can fail synchronously, which emits
    // finished() -> onJobFinished() -> pumpQueue() again while we are still
    // inside this loop (and while m_jobs is being mutated by the reaper).
    if (m_pumping) return;
    m_pumping = true;

    // FIFO: walk jobs in submission order, start the first non-conflicting
    // queued one, until nothing more can start.
    bool progressed = true;
    while (progressed) {
        progressed = false;
        if (activeJobCount() >= m_maxParallel) break;
        const QList<RenderJob*> snapshot = m_jobs;
        for (RenderJob *job : snapshot) {
            if (!m_jobs.contains(job)) continue;
            if (job->state() != RenderJob::Queued) continue;
            if (conflicts(job)) continue;
            job->start();   // emits finished() synchronously on failure
            progressed = true;
            break;
        }
    }
    m_pumping = false;
}

void RenderEngine::onJobFinished(int jobId, bool success, qint64 fileSize, const QString &errorMessage)
{
    emit jobFinished(jobId, success, fileSize, errorMessage);

    // Reap terminal jobs so the list stays bounded, then start whatever the
    // freed-up backend now allows.
    for (int i = m_jobs.size() - 1; i >= 0; --i) {
        RenderJob *j = m_jobs.at(i);
        if (j->state() == RenderJob::Queued || j->state() == RenderJob::Running) continue;
        m_jobs.removeAt(i);
        j->deleteLater();
    }

    pumpQueue();
    emit renderingChanged();
}

void RenderEngine::cancelJob(int jobId)
{
    for (RenderJob *j : m_jobs) {
        if (j->id() == jobId) { j->cancel(); return; }
    }
}

void RenderEngine::cancelRender()
{
    const QList<RenderJob*> snapshot = m_jobs;
    for (RenderJob *j : snapshot) j->cancel();
}
