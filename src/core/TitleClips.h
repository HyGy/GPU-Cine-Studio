#ifndef TITLECLIPS_H
#define TITLECLIPS_H

#include <QString>
#include <QVariant>

// Qt "signals" kulcsszó ütközik a GLib-bel (lásd TimelineEngine.h)
#ifdef signals
#undef signals
#endif
#include <ges/ges.h>
#define signals Q_SIGNALS

// Shared GES-application layer for TITLE (text) clips, used by both
// TimelineEngine (live preview) and RenderEngine (export) so the two
// pipelines can never silently diverge - same pattern as ClipEffects and
// GesTransitions.
//
// A GESTitleClip is internally `videotestsrc (pattern=solid-color) !
// textoverlay`, wrapped in GES's usual videoscale/videoconvert/
// framepositioner source bin. Everything below was verified live against
// GES/GStreamer 1.24.2 on this machine (standalone GES probe + frame
// pixel inspection), NOT from documentation:
//
//  * TRANSPARENCY: the background is OPAQUE WHITE by default
//    (foreground-color == 0xFFFFFFFF, big-endian ARGB on the videotestsrc)
//    and covers the whole frame, hiding any lower video layer. Setting
//    foreground-color's alpha byte to 0 makes the title composite
//    correctly over the layer below - text (with its outline/shadow)
//    stays fully opaque. kDefaults below therefore ships 0x00000000.
//  * POSITIONING: halignment/valignment set to the "position" nick
//    makes the textoverlay honour xpos/ypos, which are NORMALISED
//    0.0-1.0 of the frame and CLAMPED so the text can never leave the
//    canvas (x = xpos * (frameW - textW), hence a wide line barely
//    moves). The x-absolute/y-absolute pair ("absolute") is the
//    unclamped variant; we use the clamped one.
//    The two enums do NOT share numbering: "position" is 4 for
//    halignment but 3 for valignment (4 there is "center"). kDefaults
//    therefore writes the NICKS, never the integers - see the comment
//    in defaultParamsJson().
//  * FONT SIZE is resolution-RELATIVE: the same font-desc renders
//    proportionally at 1280x720 / 1920x1080 / 3840x2160 (measured cap
//    box 183 / 274 / 549 px for "Sans Bold 72"), i.e. ~25% of frame
//    height for size 72. kDefaults uses a more title-sized 36.
//  * NOT EXPOSED by GES 1.24's child-property API, despite existing on
//    textoverlay itself: wrap-mode, line-alignment, auto-resize,
//    draw-outline, deltax/deltay, shading-value, silent. Do not put them
//    in titleParams - ges_timeline_element_lookup_child() cannot find
//    them and the write is a no-op + warning.
//  * ENUM child properties only became settable at all after the
//    G_TYPE_ENUM case was added to ClipEffects' setChildProperty().
namespace TitleClips {

// Default titleParams JSON for a freshly created title clip. Keys are
// 1:1 GES child-property names on the title source.
QString defaultParamsJson(const QString &text);

// Parses `titleParamsJson` (a JSON object string) and writes every key as
// a GES child property on `clip`. Unknown/unsupported keys are skipped
// with a warning rather than failing the whole clip. A no-op for an empty
// string.
void applyToClip(GESClip *clip, const QString &titleParamsJson);

// Live-updates a single title parameter on an already-placed title clip
// (used by TimelineEngine::setTitleParam() for responsive side-panel
// editing without a full timeline rebuild). NOTE: on a PAUSED pipeline
// the new value does NOT reach the screen until a flushing seek - the
// caller must re-seek to the current position, exactly like
// EffectParamSlider.qml already does for effect params.
bool setParam(GESClip *clip, const QString &param, const QVariant &value);

} // namespace TitleClips

#endif // TITLECLIPS_H
