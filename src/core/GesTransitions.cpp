#include "GesTransitions.h"

#include <QDebug>

namespace GesTransitions {

GESVideoStandardTransitionType nickToType(const QString &nick)
{
    if (nick.isEmpty() || nick == QLatin1String("dissolve") || nick == QLatin1String("crossfade"))
        return GES_VIDEO_STANDARD_TRANSITION_TYPE_CROSSFADE;

    GEnumClass *klass = (GEnumClass *)g_type_class_ref(GES_VIDEO_STANDARD_TRANSITION_TYPE_TYPE);
    GEnumValue *v = g_enum_get_value_by_nick(klass, nick.toUtf8().constData());
    GESVideoStandardTransitionType result = v
        ? static_cast<GESVideoStandardTransitionType>(v->value)
        : GES_VIDEO_STANDARD_TRANSITION_TYPE_CROSSFADE;
    if (!v) {
        qWarning() << "GesTransitions: unknown transition-type nick" << nick << "- falling back to crossfade";
    }
    g_type_class_unref(klass);
    return result;
}

void applyTransitionTypes(const QMap<QString, GESLayer *> &layers,
                           const QVector<PendingTransition> &pending,
                           GstClockTime toleranceNs)
{
    if (pending.isEmpty()) return;

    for (auto it = layers.constBegin(); it != layers.constEnd(); ++it) {
        const QString &trackId = it.key();
        GESLayer *layer = it.value();
        if (!layer) continue;

        GList *layerClips = ges_layer_get_clips(layer);
        for (GList *l = layerClips; l != nullptr; l = l->next) {
            if (!GES_IS_TRANSITION_CLIP(l->data)) continue;
            GESClip *tclip = GES_CLIP(l->data);
            if (!(ges_clip_get_supported_formats(tclip) & GES_TRACK_TYPE_VIDEO)) continue;

            GstClockTime tEnd = ges_timeline_element_get_start(GES_TIMELINE_ELEMENT(tclip))
                               + ges_timeline_element_get_duration(GES_TIMELINE_ELEMENT(tclip));

            for (const PendingTransition &p : pending) {
                if (p.trackId != trackId) continue;
                GstClockTime diff = tEnd > p.endTime ? tEnd - p.endTime : p.endTime - tEnd;
                if (diff > toleranceNs) continue;
                g_object_set(tclip, "vtype", nickToType(p.gesNick), NULL);
                break;
            }
        }
        g_list_free_full(layerClips, gst_object_unref);
    }
}

} // namespace GesTransitions
