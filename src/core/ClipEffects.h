#ifndef CLIPEFFECTS_H
#define CLIPEFFECTS_H

#include <QString>
#include <QVariant>

// Qt "signals" kulcsszó ütközik a GLib-bel (lásd TimelineEngine.h)
#ifdef signals
#undef signals
#endif
#include <ges/ges.h>
#define signals Q_SIGNALS

// Shared GES-application layer for per-clip effects, used by both
// TimelineEngine (live preview) and RenderEngine (export) so the two
// pipelines can never silently diverge on what an effect actually does.
namespace ClipEffects {

// effectsJson: JSON array string, e.g.
//   [{"id":"e1","type":"lut3d","enabled":true,"params":{"lut-file":"luts/x.cube","intensity":1.0}}]
// Applied in array order (top-effect index == array index). Disabled
// entries are skipped entirely - re-enabling one requires the caller to
// go through the full rebuild path (see TimelineEngine::setClips()'s
// coreChanged classifier), there is no in-place "re-add" here.
// glMode: the clip's timeline runs in GL timeline mode (GlTimeline.h), i.e.
// the effect chain receives/returns GLMemory - effects with a GPU
// implementation drop their glupload/gldownload bracket, CPU-only ones get
// a gldownload/glupload bracket instead.
void applyToClip(GESClip *clip, const QString &effectsJson, const QString &projectDir, bool glMode = false);

// Live-updates a single parameter on an already-applied effect (found by
// its "id" via GESMetaContainer metadata - see applyToClip()). Returns
// false if the effect isn't found on this clip or the property doesn't
// exist on the underlying GStreamer element.
bool setParam(GESClip *clip, const QString &effectId, const QString &param,
              const QVariant &value, const QString &projectDir);

// Sets one named GES child property from a QVariant, picking the GValue
// type from the property's own GParamSpec (double/float/int/uint/bool/
// string/enum). Shared with TitleClips so title params and effect params
// can never diverge on type handling. Returns false if the element has no
// such child property or its type isn't supported.
bool setChildProperty(GESTimelineElement *element, const QString &propName, const QVariant &value);

// Resolves a possibly-relative asset path (LUT file, overlay image) stored
// in effects JSON against the project directory. Absolute paths and
// file:// URIs pass through (prefix stripped for the latter).
QString resolveAssetPath(const QString &projectDir, const QString &path);

}

#endif // CLIPEFFECTS_H
