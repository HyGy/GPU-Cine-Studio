#pragma once

// Queries the GStreamer registry for actual video encoder/decoder factories
// instead of matching against a hand-maintained list of element names. Names
// are not stable across GStreamer releases - e.g. GStreamer 1.28 renamed the
// nvcodec plugin's CUDA-mode encoders from "nvcudah264enc"/"nvcudah265enc" to
// plain "nvh264enc"/"nvh265enc" (and renamed the old auto-GPU-select
// "nvh264enc" to "nvautogpuh264enc"), which silently broke any code that
// probed for the old literal names. Filtering by caps + backend plugin
// survives that kind of rename.

#include <QString>
#include <QStringList>
#include <gst/gst.h>

namespace GstElementDiscovery {

inline QString backendOfFeature(GstPluginFeature *feature)
{
    const gchar *plugin = gst_plugin_feature_get_plugin_name(feature);
    if (!plugin) return QStringLiteral("cpu");
    const QString name = QString::fromUtf8(plugin);
    if (name == QStringLiteral("nvcodec")) return QStringLiteral("nvidia");
    if (name == QStringLiteral("va")) return QStringLiteral("vaapi");
    return QStringLiteral("cpu");
}

// Factory names, highest GstRank first, for video codec elements whose
// relevant pad matches capsString, restricted to one backend
// ("nvidia"/"vaapi"/"cpu"). `type` must already include
// GST_ELEMENT_FACTORY_TYPE_ENCODER or _DECODER plus a MEDIA_* flag; `direction`
// is GST_PAD_SRC for encoders (caps come out) or GST_PAD_SINK for decoders
// (caps go in).
inline QStringList findVideoCodecFactories(GstElementFactoryListType type,
                                            const char *capsString,
                                            GstPadDirection direction,
                                            const QString &backend)
{
    QStringList result;
    GstCaps *caps = gst_caps_from_string(capsString);
    GList *all = gst_element_factory_list_get_elements(type, GST_RANK_NONE);
    GList *filtered = gst_element_factory_list_filter(all, caps, direction, FALSE);
    filtered = g_list_sort(filtered, (GCompareFunc)gst_plugin_feature_rank_compare_func);
    for (GList *it = filtered; it; it = it->next) {
        GstPluginFeature *feature = GST_PLUGIN_FEATURE(it->data);
        if (backendOfFeature(feature) == backend)
            result << QString::fromUtf8(gst_plugin_feature_get_name(feature));
    }
    gst_plugin_feature_list_free(filtered);
    gst_plugin_feature_list_free(all);
    gst_caps_unref(caps);
    // App policy for software encoders: x264enc/x265enc first (High profile,
    // the full property set), openh264enc only as the last resort (baseline
    // only, no key-int-max/speed-preset, and it stalls on profile=high).
    // The registry rank can't express this: RenderEngine pins every encoder
    // to the same rank at startup, so ties fall to registry order.
    if (backend == QLatin1String("cpu") && (type & GST_ELEMENT_FACTORY_TYPE_ENCODER)) {
        QStringList preferred, middle, last;
        for (const QString &n : result) {
            if (n == QLatin1String("x264enc") || n == QLatin1String("x265enc")) preferred << n;
            else if (n == QLatin1String("openh264enc")) last << n;
            else middle << n;
        }
        result = preferred + middle + last;
    }
    return result;
}

inline QStringList findEncoderFactories(const char *capsString, const QString &backend)
{
    return findVideoCodecFactories(GST_ELEMENT_FACTORY_TYPE_VIDEO_ENCODER,
                                    capsString, GST_PAD_SRC, backend);
}

inline QStringList findDecoderFactories(const char *capsString, const QString &backend)
{
    static const GstElementFactoryListType kVideoDecoder =
        (GstElementFactoryListType)(GST_ELEMENT_FACTORY_TYPE_DECODER | GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO);
    return findVideoCodecFactories(kVideoDecoder, capsString, GST_PAD_SINK, backend);
}

// Every registered video decoder factory name for one backend, across all
// codecs - used to bulk rank-boost/demote decodebin's autoplug choice.
inline QStringList allDecoderFactories(const QString &backend)
{
    static const GstElementFactoryListType kVideoDecoder =
        (GstElementFactoryListType)(GST_ELEMENT_FACTORY_TYPE_DECODER | GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO);
    QStringList result;
    GList *all = gst_element_factory_list_get_elements(kVideoDecoder, GST_RANK_NONE);
    for (GList *it = all; it; it = it->next) {
        GstPluginFeature *feature = GST_PLUGIN_FEATURE(it->data);
        if (backendOfFeature(feature) == backend)
            result << QString::fromUtf8(gst_plugin_feature_get_name(feature));
    }
    gst_plugin_feature_list_free(all);
    return result;
}

// Forces the preferred backend's hardware video decoders to win decodebin's
// next autoplug: demotes every NVIDIA + VA-API decoder to GST_RANK_MARGINAL,
// then boosts the chosen backend's decoders to GST_RANK_PRIMARY + 1. Ranks
// are process-global, so this affects the NEXT pipeline built, not one that
// is already running. "cpu" (or any unknown token) only demotes the hardware
// decoders, leaving software decoders to win. Mirrors
// TimelineEngine::applyDecoderRanks() and VideoEngine::setupPipeline().
inline void applyDecoderRankPreference(const QString &backend)
{
    GstRegistry *registry = gst_registry_get();
    const QStringList nvDecoders = allDecoderFactories("nvidia");
    const QStringList vaDecoders = allDecoderFactories("vaapi");

    for (const QString &name : nvDecoders + vaDecoders) {
        GstPluginFeature *feature = gst_registry_lookup_feature(registry, name.toUtf8().constData());
        if (feature) {
            gst_plugin_feature_set_rank(feature, GST_RANK_MARGINAL);
            gst_object_unref(feature);
        }
    }

    const QStringList boost = (backend == QLatin1String("nvidia")) ? nvDecoders
                              : (backend == QLatin1String("vaapi")) ? vaDecoders
                              : QStringList();
    for (const QString &name : boost) {
        GstPluginFeature *feature = gst_registry_lookup_feature(registry, name.toUtf8().constData());
        if (feature) {
            gst_plugin_feature_set_rank(feature, GST_RANK_PRIMARY + 1);
            gst_object_unref(feature);
        }
    }
}

// Every registered video encoder factory name, any backend - used to pin all
// encoders to a known rank before a render job sets its own preset-name.
inline QStringList allEncoderFactories()
{
    QStringList result;
    GList *all = gst_element_factory_list_get_elements(GST_ELEMENT_FACTORY_TYPE_VIDEO_ENCODER, GST_RANK_NONE);
    for (GList *it = all; it; it = it->next)
        result << QString::fromUtf8(gst_plugin_feature_get_name(GST_PLUGIN_FEATURE(it->data)));
    gst_plugin_feature_list_free(all);
    return result;
}

} // namespace GstElementDiscovery
