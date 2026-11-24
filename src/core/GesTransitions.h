#ifndef GESTRANSITIONS_H
#define GESTRANSITIONS_H

#include <ges/ges.h>
#include <QMap>
#include <QString>
#include <QVector>

// Shared between TimelineEngine (live preview) and RenderEngine (export) -
// both rely on GES's own "auto-transition" to create a transition clip
// for every clip overlap on a track, and both need to then override that
// clip's wipe shape away from the default crossfade. See
// KdenliveImporter.cpp's gesWipeNickForLumaResource()/kLumaMappings for
// where the nicks consumed here originate (Kdenlive import), though
// TimelinePanel.qml's manually-applied transitions use this too.
namespace GesTransitions {

struct PendingTransition {
    QString trackId;
    GstClockTime endTime; // absolute end of clip A == where the GES auto-transition clip ends
    QString gesNick;      // "crossfade"/"dissolve", or a GESVideoStandardTransitionType nick
};

// Resolves a GES transition-type nick to its enum value. Empty, unknown,
// "dissolve" and "crossfade" all resolve to CROSSFADE - GES has no
// separate "dissolve" type, a dissolve IS what GES calls a crossfade.
// Unknown non-empty nicks log a warning and fall back to CROSSFADE rather
// than failing the whole import/render.
GESVideoStandardTransitionType nickToType(const QString &nick);

// Walks every layer in `layers`, finds each GES auto-created transition
// clip (GES_IS_TRANSITION_CLIP()), and - for the video ones only, guarded
// via ges_clip_get_supported_formats() & GES_TRACK_TYPE_VIDEO, since an
// audio-only transition clip has no video-transition child and setting
// "vtype" on it is at best a no-op - sets its "vtype" property to match
// whichever `pending` entry's (trackId, endTime) falls within
// `toleranceNs` of the transition clip's own (start + duration). A
// single g_object_set(clip, "vtype", ...) does the full job, INCLUDING
// the asset swap - verified against GES 1.24's
// ges_transition_clip_update_vtype_internal(), which itself loops the
// clip's video transitions and re-requests/sets the asset; no separate
// "look up a TransitionClip asset by name" step is needed.
void applyTransitionTypes(const QMap<QString, GESLayer *> &layers,
                           const QVector<PendingTransition> &pending,
                           GstClockTime toleranceNs = 40 * GST_MSECOND);

} // namespace GesTransitions

#endif // GESTRANSITIONS_H
