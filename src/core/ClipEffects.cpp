#include "ClipEffects.h"
#include "TimeConv.h"

#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QDebug>
#include <gst/controller/gstinterpolationcontrolsource.h>

namespace ClipEffects {

namespace {

struct RegistryEntry {
    // Passed verbatim to ges_effect_new(). The element whose properties
    // the "params" JSON object addresses MUST be named "effect0" in here
    // (ges_timeline_element_lookup_child() searches all child elements by
    // unqualified property name, which is ambiguous only if two elements
    // in the same bin share a property name - none of the v1 chains do,
    // so no further qualification has been needed).
    const char *binDescription;
    // Same effect as a GPU-native chain for GL timeline mode (frames in
    // GLMemory in and out, no up/download bracket). nullptr = no GPU
    // implementation: GL mode then wraps binDescription in
    // gldownload ! ... ! glupload (or leaves it alone for audio effects).
    const char *glBinDescription = nullptr;
    bool audio = false;
};

const QHash<QString, RegistryEntry> &registry()
{
    static const QHash<QString, RegistryEntry> table = {
        { "colorbalance", { "videobalance name=effect0" } },
        { "gamma",        { "gamma name=effect0" } },
        // GPU 3D LUT - see src/core/gl/gstgllut3d.c for the "gcclut3d"
        // element itself. glupload/gldownload bracket it so the chain
        // accepts/returns ordinary system-memory buffers like every other
        // GES effect - GES itself has no idea this one happens to run on
        // the GPU in between.
        { "lut3d",        { "glupload ! glcolorconvert ! gcclut3d name=effect0 ! glcolorconvert ! gldownload",
                            "glcolorconvert ! gcclut3d name=effect0 ! glcolorconvert" } },
        // Tonal curves (Photoshop/Lightroom-style), GPU, via our own
        // "gcccurves" GstGLFilter (src/core/gl/gstglcurves.c) - same
        // glupload/glcolorconvert/gldownload bracketing as lut3d above.
        // Evaluated over a 3D-LUT-file-based approach for this specific
        // effect: a per-channel 1D curve is only 256*3 meaningful
        // numbers, and a .cube file dense enough to look smooth (64+)
        // takes tens-to-hundreds of ms to reparse per mouse-move during
        // a live curve drag - this element instead keeps the curve as a
        // compact control-point STRING and builds its 256x1 lookup
        // texture directly in memory, no file I/O at all. The "curve-
        // points" param is addressed 1:1 (same convention as every
        // other registry entry here) - see gstglcurves.c's property doc
        // for its exact format.
        { "curves",       { "glupload ! glcolorconvert ! gcccurves name=effect0 ! glcolorconvert ! gldownload",
                            "glcolorconvert ! gcccurves name=effect0 ! glcolorconvert" } },
        { "imageoverlay", { "gdkpixbufoverlay name=effect0" } },
        // Chroma/color key - the REAL frei0r "select0r" filter (Kdenlive's
        // "Chroma Key: Advanced (Colour Selection)"), via gst-plugins-bad's
        // frei0r wrapper (libgstfrei0r.so, part of gstreamer1.0-plugins-bad,
        // already a dependency) dynamically loading the actual frei0r
        // select0r.so plugin at runtime from the frei0r-plugins system
        // package (a REQUIRED runtime dependency - see CMakeLists.txt's
        // CPACK_DEBIAN_PACKAGE_DEPENDS and TODO.txt; without it installed,
        // "frei0r-filter-select0r" simply doesn't exist as a GStreamer
        // element and ges_effect_new() below fails outright). This
        // replaced an earlier glalpha-based approximation once this
        // element was found to exist and actually be installable - no
        // more parameter translation/approximation needed anywhere, the
        // property names and semantics are 1:1 with what Kdenlive's own
        // UI exposes (confirmed via `gst-inspect-1.0 frei0r-filter-select0r`
        // against the real property set: color-to-select-r/g/b,
        // delta-r---a---hue, delta-g---b---chroma, delta-b---i---i,
        // edge-mode, invert-selection, operation, selection-subspace,
        // slope, subspace-shape - all plain double/float/bool, no enums,
        // so setChildPropertyFromVariant() below needs no changes either).
        // select0r is a plain CPU GstVideoFilter requiring RGBA buffers
        // (not GL textures), hence videoconvert brackets instead of
        // glupload/gldownload.
        //
        // frei0r-filter-alpha0ps after it: select0r's alpha output is
        // strictly BINARY (measured: 2 distinct alpha values across a
        // real anti-aliased glyph edge, zero partial-coverage pixels) -
        // an anti-aliased source's edge ramp (e.g. a title's glyph
        // edges, luma 42/67/130/188/217 between background and
        // foreground) stays fully OPAQUE at every one of those ramp
        // pixels as long as it's outside the keyed color's threshold
        // radius, which is exactly what reads as a thin dark fringe
        // around the kept content. alpha0ps's "Shrink hard" (operation=
        // 2/7=0.2857, the plugin's own enum-as-float encoding, same
        // pattern as select0r's) erodes the opaque alpha region by
        // shrink-grow-blur-amount, measured at ~1 source pixel per 0.05
        // (quantized - 0.05 and 0.15 measured identical, so 0.05 is the
        // safe minimum step) - eats exactly the fringe ring and nothing
        // more (measured: ~15% of the kept pixel count at 0.05, vs. the
        // glyphs visibly eroding away by 0.7). Runs at the effect's
        // NATIVE resolution (GES's own capsfilter pins the bin to the
        // clip's source caps before this chain), so a 1-source-pixel
        // erosion stays proportionate regardless of project resolution -
        // no scale-dependent parameter needed. Also from frei0r-plugins,
        // not a new dependency.
        { "colorkey",     { "videoconvert ! video/x-raw,format=RGBA ! frei0r-filter-select0r name=effect0"
                             " ! frei0r-filter-alpha0ps operation=0.2857 shrink-grow-blur-amount=0.05 ! videoconvert" } },
        // Real frei0r brightness/contrast0r filters (Kdenlive's own
        // "Brightness"/"Contrast" effects), same frei0r-plugins
        // dependency as colorkey above. Verified live (melt vs gst,
        // 7+6 values x 4 input luma levels, byte-identical) to be a
        // plain 1:1 passthrough of the single "Brightness"/"Contrast"
        // property, clamped to [0,1] - no rescale needed. The clamp
        // matters: MLT/melt itself clamps an out-of-range value (e.g.
        // Kdenlive's own UI can write 1.06) before rendering, but
        // GStreamer's property setter silently REJECTS an out-of-range
        // double and keeps the 0.5 default instead - so an unclamped
        // value here would make the effect vanish rather than render
        // like Kdenlive. See KdenliveImporter.cpp's frei0r.brightness/
        // frei0r.contrast0r branch for where the clamp is applied.
        //
        // GL timeline mode: "gccbc" (src/core/gl/gstglbrightcontrast.c) is a
        // closed-form GPU port of the same two frei0r lookups (max error 1
        // of 256 levels), with the same "brightness"/"contrast" property
        // names and 0.5-neutral scale, so the importer/UI params carry over
        // unchanged. The frei0r versions run per frame on one CPU core at
        // native 4K and made video stall at dissolves.
        { "brightness",   { "videoconvert ! video/x-raw,format=RGBA ! frei0r-filter-brightness name=effect0 ! videoconvert",
                            "glcolorconvert ! gccbc name=effect0 ! glcolorconvert" } },
        { "contrast",     { "videoconvert ! video/x-raw,format=RGBA ! frei0r-filter-contrast0r name=effect0 ! videoconvert",
                            "glcolorconvert ! gccbc name=effect0 ! glcolorconvert" } },
        // Plain GStreamer "volume" element (audio/x-raw) - its own
        // GstElementFactory klass ("Filter/Effect/Audio") is how GES
        // already auto-routes every other top-effect here to the right
        // track type (e.g. "colorbalance"/videobalance only ever lands
        // on the video track element), so this needs no special-casing
        // beyond being a normal registry entry. "volume" property is a
        // LINEAR amplitude multiplier (1.0=unity) - verified live
        // (direct PCM sample peak/RMS comparison, not just gst-inspect's
        // stated range) against Kdenlive/MLT's own dB-based "level"
        // property: see KdenliveImporter.cpp's volume branch for the
        // 10^(dB/20) conversion this depends on.
        { "volume",       { "volume name=effect0", nullptr, true } },
    };
    return table;
}

// Property names whose value is a filesystem path and must be resolved
// against the project directory before being handed to GStreamer.
bool isPathParam(const QString &name)
{
    return name == QLatin1String("lut-file") || name == QLatin1String("location");
}

// Sets a single named child property on a GESTimelineElement from a
// QVariant, using the property's own GParamSpec to pick the right GValue
// type. This is plain GObject property-introspection bookkeeping (not a
// GES clip/effect lifetime question) - the lookup_child() output GObject
// is unreffed here because we exclusively own that one reference.
bool setChildPropertyFromVariant(GESTimelineElement *element, const QString &propName, const QVariant &value)
{
    GObject *child = nullptr;
    GParamSpec *pspec = nullptr;
    if (!ges_timeline_element_lookup_child(element, propName.toUtf8().constData(), &child, &pspec)) {
        qWarning() << "ClipEffects: no such child property:" << propName;
        return false;
    }

    GValue gval = G_VALUE_INIT;
    g_value_init(&gval, pspec->value_type);
    bool ok = true;
    switch (G_TYPE_FUNDAMENTAL(pspec->value_type)) {
    case G_TYPE_DOUBLE:  g_value_set_double(&gval, value.toDouble()); break;
    case G_TYPE_FLOAT:   g_value_set_float(&gval, static_cast<float>(value.toDouble())); break;
    case G_TYPE_INT:     g_value_set_int(&gval, value.toInt()); break;
    // NOT value.toInt(): an ARGB colour such as 0xFFFFFFFF arrives from
    // JSON as a double above INT_MAX, and QVariant::toInt() fails that
    // conversion and yields 0 (i.e. a fully transparent black) instead.
    case G_TYPE_UINT: {
        bool uok = false;
        const qulonglong uv = value.toULongLong(&uok);
        g_value_set_uint(&gval, static_cast<guint>(uok ? uv : qulonglong(qMax(0, value.toInt()))));
        break;
    }
    case G_TYPE_BOOLEAN: g_value_set_boolean(&gval, value.toBool()); break;
    case G_TYPE_STRING:  g_value_set_string(&gval, value.toString().toUtf8().constData()); break;
    // Enum-valued child properties (e.g. a title source's halignment/
    // valignment). QVariant carries them as the plain integer enum value;
    // a QML/JSON string nick would arrive as a non-numeric QVariant, so
    // accept that form too rather than silently writing 0.
    case G_TYPE_ENUM: {
        bool numOk = false;
        const int enumVal = value.toInt(&numOk);
        if (numOk) {
            g_value_set_enum(&gval, enumVal);
        } else if (GEnumClass *ec = static_cast<GEnumClass *>(g_type_class_ref(pspec->value_type))) {
            const QByteArray nick = value.toString().toUtf8();
            GEnumValue *ev = g_enum_get_value_by_nick(ec, nick.constData());
            if (!ev) ev = g_enum_get_value_by_name(ec, nick.constData());
            if (ev) {
                g_value_set_enum(&gval, ev->value);
            } else {
                qWarning() << "ClipEffects: unknown enum nick" << value.toString() << "for" << propName;
                ok = false;
            }
            g_type_class_unref(ec);
        } else {
            ok = false;
        }
        break;
    }
    default:
        qWarning() << "ClipEffects: unsupported property type for" << propName;
        ok = false;
        break;
    }
    if (ok) ges_timeline_element_set_child_property(element, propName.toUtf8().constData(), &gval);
    g_value_unset(&gval);
    if (child) g_object_unref(child);
    return ok;
}

// Metadata key used to find an already-applied effect again later by its
// QML-side id (setParam(), and a future enable/reorder/delete UI).
constexpr const char *kEffectIdMetaKey = "gcc-effect-id";

// "transform" (Position and Zoom) is NOT a top effect like every other
// entry in registry() - it sets GstFramePositioner child properties
// (fposx/fposy/fwidth/fheight) directly on the CLIP's own track element,
// because a bolted-on top effect's output caps are pinned to the video
// track's restriction caps (the project's own resolution) and cannot
// express "render the source larger/offset than the frame and let the
// compositor crop it" - which is exactly what Kdenlive's pan_zoom/affine
// does and what the imported project needs (verified live: a GES clip's
// frame positioner scales directly onto the output canvas in one
// resample, same as MLT's affine; a top-effect route would need two
// lossy resamples). These are gfloat properties, so the existing
// setChildPropertyFromVariant() G_TYPE_FLOAT case handles them with no
// changes - only the "set directly on the clip, not a new effect
// element" dispatch is special-cased, in applyToClip()/setParam() below.
bool isTransformParam(const QString &name)
{
    return name == QLatin1String("fposx") || name == QLatin1String("fposy")
        || name == QLatin1String("fwidth") || name == QLatin1String("fheight");
}

bool isFadeParam(const QString &name)
{
    return name == QLatin1String("in") || name == QLatin1String("out");
}

// "fade" (Fade from/to black) is, like "transform", not a top effect -
// it drives a 2-keyframe linear ramp on GstFramePositioner's own
// "alpha" child property via GES's native control-binding mechanism
// (ges_track_element_set_control_source()). Verified live before
// implementing (per project policy - never guess GStreamer/GES
// keyframe behaviour): ges_track_element_get_auto_clamp_control_sources()
// defaults to TRUE and silently corrupts/extrapolates these keyframes
// on every later trim/resize (measured: can even produce alpha values
// outside [0,1], e.g. -0.33 or 4.0) - MUST be disabled on the track
// element before attaching a control source, or the user's first trim
// after import would visibly break the fade. Keyframe times are
// inpoint-relative (GES's internal/source time base - confirmed NOT
// timeline-position-relative: the same keyframe times fade correctly
// regardless of where the clip sits on the timeline, but do nothing at
// all if placed relative to the wrong base), so params carry durations
// ("in"/"out" seconds) rather than absolute timestamps - this function
// reads the clip's own current inpoint/duration to place the keyframes
// correctly. A fade with nothing underneath the clip (the normal case)
// is visually identical to a true fade-to/from-black, since GES's
// video track background is black; stacked on another visible layer it
// would cross-dissolve into that layer instead (not fixed here - no
// such case exists in anything imported/built by this app yet).
void applyFade(GESClip *clip, const QJsonObject &params)
{
    double fadeInSec = params.value("in").toDouble(0.0);
    double fadeOutSec = params.value("out").toDouble(0.0);
    if (fadeInSec <= 0.0 && fadeOutSec <= 0.0) return;

    GESTrackElement *te = ges_clip_find_track_element(clip, NULL, GES_TYPE_VIDEO_SOURCE);
    if (!te) {
        qWarning() << "ClipEffects: fade requested but clip has no video track element";
        return;
    }

    ges_track_element_set_auto_clamp_control_sources(te, FALSE);

    GstControlSource *cs = gst_interpolation_control_source_new();
    g_object_set(cs, "mode", GST_INTERPOLATION_MODE_LINEAR, NULL);
    if (!ges_track_element_set_control_source(te, cs, "alpha", "direct-absolute")) {
        qWarning() << "ClipEffects: failed to attach fade control source";
        gst_object_unref(cs);
        gst_object_unref(te);
        return;
    }

    GstTimedValueControlSource *tv = GST_TIMED_VALUE_CONTROL_SOURCE(cs);
    GstClockTime inPoint = ges_timeline_element_get_inpoint(GES_TIMELINE_ELEMENT(clip));
    GstClockTime duration = ges_timeline_element_get_duration(GES_TIMELINE_ELEMENT(clip));

    if (fadeInSec > 0.0) {
        GstClockTime n = TimeConv::secToNs(fadeInSec);
        if (n > duration) n = duration;
        gst_timed_value_control_source_set(tv, inPoint, 0.0);
        gst_timed_value_control_source_set(tv, inPoint + n, 1.0);
    }
    if (fadeOutSec > 0.0) {
        GstClockTime n = TimeConv::secToNs(fadeOutSec);
        if (n > duration) n = duration;
        gst_timed_value_control_source_set(tv, inPoint + duration - n, 1.0);
        gst_timed_value_control_source_set(tv, inPoint + duration, 0.0);
    }

    // set_control_source() took its own ref on cs (verified: refcount
    // 1->2); the binding itself is what GES/the pipeline keeps alive
    // from here, same "owning container sinks/holds the ref" pattern
    // as everywhere else in this file.
    gst_object_unref(cs);
    gst_object_unref(te);
}

// General keyframed-parameter animation, generalizing applyFade()'s
// 2-point mechanism to N arbitrary points. A param is "animated" when
// its JSON value is an object of the shape {"kf":[{"t":secs,"v":val},...]}
// instead of a plain number - everything else (static params, the
// QML slider UI, hand-written effect JSON) is completely unaffected,
// deliberately NOT unified into a "every param is an N=1 keyframe
// list" representation: verified live that an active control binding
// overrides a plain setChildPropertyFromVariant() write on every
// pipeline sync, so giving every static param a 1-point control
// source would silently break EffectParamSlider.qml's live-preview
// path (which writes the property directly via setParam()).
struct Keyframe { double tSec; double v; };

bool isAnimatedParam(const QJsonValue &v)
{
    return v.isObject() && v.toObject().contains(QLatin1String("kf"));
}

QVector<Keyframe> parseKeyframes(const QJsonValue &v)
{
    QVector<Keyframe> out;
    const QJsonArray arr = v.toObject().value(QLatin1String("kf")).toArray();
    out.reserve(arr.size());
    for (const QJsonValue &kv : arr) {
        QJsonObject o = kv.toObject();
        out.append({ o.value("t").toDouble(), o.value("v").toDouble() });
    }
    return out;
}

// Attaches a linear GstInterpolationControlSource for `prop` on `te`.
// `csTimeOffsetSec` converts each keyframe's CLIP-MEDIA-TIME `tSec`
// (the same time base as the clip's own sourceOffset - one base for
// every param regardless of attachment point, so the importer/caller
// never needs to know which one a given effect uses) into that
// specific track element's own control-source time base. Verified
// live (see TODO.txt) that this base differs by ATTACHMENT POINT, not
// by property: the clip's own source track element (as used by
// "transform" and "fade") uses MEDIA time directly (offset 0); a
// GESBaseEffect top-effect uses CLIP-START-relative time instead
// (offset = the clip's current inpoint) - same underlying GStreamer
// control-source mechanism, different base, both confirmed by direct
// rendered-output measurement, not assumed from documentation.
//
// Also verified live and handled here: ges_track_element_get_auto_clamp_control_sources()
// defaults to TRUE and corrupts keyframe values on every later trim/
// resize (same issue applyFade() already works around) - this MUST be
// disabled per track element, not just once globally, since the flag
// lives on each element separately (a clip's source element and a top
// effect on the same clip each need their own call).
bool applyAnimation(GESTrackElement *te, const QString &prop,
                     const QVector<Keyframe> &kfs, double csTimeOffsetSec)
{
    if (kfs.isEmpty()) return false;

    ges_track_element_set_auto_clamp_control_sources(te, FALSE);

    GstControlSource *cs = gst_interpolation_control_source_new();
    g_object_set(cs, "mode", GST_INTERPOLATION_MODE_LINEAR, NULL);
    if (!ges_track_element_set_control_source(te, cs, prop.toUtf8().constData(), "direct-absolute")) {
        qWarning() << "ClipEffects: failed to attach animation control source for" << prop;
        gst_object_unref(cs);
        return false;
    }

    GstTimedValueControlSource *tv = GST_TIMED_VALUE_CONTROL_SOURCE(cs);

    // A keyframe whose offset time lands negative (e.g. a top-effect's
    // clip-start-relative base pushed earlier than the clip's current
    // inpoint by a head trim) can't be expressed as a GstClockTime and
    // would otherwise just be silently dropped, cutting off the start
    // of the curve. GST itself holds flat before the first real
    // control point, so the only adjustment needed is a single
    // synthetic t=0 point holding the linearly-interpolated value at
    // the cut - not applied when no keyframe is actually negative
    // (the normal case, zero behavior change).
    int firstKept = 0;
    while (firstKept < kfs.size() && kfs[firstKept].tSec - csTimeOffsetSec < 0.0) firstKept++;

    if (firstKept > 0 && firstKept < kfs.size()) {
        double t0 = kfs[firstKept - 1].tSec, v0 = kfs[firstKept - 1].v;
        double t1 = kfs[firstKept].tSec, v1 = kfs[firstKept].v;
        double frac = (t1 > t0) ? (csTimeOffsetSec - t0) / (t1 - t0) : 0.0;
        gst_timed_value_control_source_set(tv, 0, v0 + (v1 - v0) * frac);
    } else if (firstKept >= kfs.size() && !kfs.isEmpty()) {
        // Every keyframe was before the offset - hold the last value.
        gst_timed_value_control_source_set(tv, 0, kfs.last().v);
    }
    for (int i = firstKept; i < kfs.size(); ++i) {
        GstClockTime t = TimeConv::secToNs(kfs[i].tSec - csTimeOffsetSec);
        gst_timed_value_control_source_set(tv, t, kfs[i].v);
    }

    gst_object_unref(cs);
    return true;
}

GESBaseEffect *findEffectById(GESClip *clip, const QString &effectId)
{
    GList *effects = ges_clip_get_top_effects(clip); // transfer container
    GESBaseEffect *found = nullptr;
    for (GList *l = effects; l != nullptr; l = l->next) {
        GESBaseEffect *effect = GES_BASE_EFFECT(l->data);
        const gchar *id = ges_meta_container_get_string(
            GES_META_CONTAINER(effect), kEffectIdMetaKey);
        if (id && effectId == QString::fromUtf8(id)) {
            found = effect;
            break;
        }
    }
    g_list_free(effects);
    return found;
}

} // namespace

// Public re-export of the internal helper above, so TitleClips (and any
// future shared GES-application layer) writes child properties through
// exactly one implementation.
bool setChildProperty(GESTimelineElement *element, const QString &propName, const QVariant &value)
{
    return setChildPropertyFromVariant(element, propName, value);
}

QString resolveAssetPath(const QString &projectDir, const QString &path)
{
    if (path.isEmpty()) return path;
    QString p = path;
    if (p.startsWith(QLatin1String("file://"))) p = p.mid(7);
    if (QFileInfo(p).isAbsolute()) return p;
    if (projectDir.isEmpty()) return p;
    return QDir(projectDir).filePath(p);
}

void applyToClip(GESClip *clip, const QString &effectsJson, const QString &projectDir, bool glMode)
{
    if (effectsJson.isEmpty() || effectsJson == QLatin1String("[]")) return;

    QJsonParseError parseErr;
    QJsonDocument doc = QJsonDocument::fromJson(effectsJson.toUtf8(), &parseErr);
    if (parseErr.error != QJsonParseError::NoError || !doc.isArray()) {
        qWarning() << "ClipEffects::applyToClip: invalid effects JSON:" << parseErr.errorString();
        return;
    }

    const auto &reg = registry();
    for (const QJsonValue &v : doc.array()) {
        QJsonObject obj = v.toObject();
        if (!obj.value("enabled").toBool(true)) continue;

        QString type = obj.value("type").toString();

        if (type == QLatin1String("transform")) {
            // At most one per clip - a second one would silently fight
            // the first over the same four properties.
            QJsonObject params = obj.value("params").toObject();
            GESTrackElement *transformTe = nullptr;
            for (auto pit = params.constBegin(); pit != params.constEnd(); ++pit) {
                if (isAnimatedParam(pit.value())) {
                    if (!transformTe) transformTe = ges_clip_find_track_element(clip, NULL, GES_TYPE_VIDEO_SOURCE);
                    if (transformTe) {
                        // Clip's own source element - media-time base, offset 0.
                        applyAnimation(transformTe, pit.key(), parseKeyframes(pit.value()), 0.0);
                    }
                    continue;
                }
                setChildPropertyFromVariant(GES_TIMELINE_ELEMENT(clip), pit.key(), pit.value().toVariant());
            }
            if (transformTe) gst_object_unref(transformTe);
            continue;
        }

        if (type == QLatin1String("fade")) {
            applyFade(clip, obj.value("params").toObject());
            continue;
        }

        auto it = reg.find(type);
        if (it == reg.constEnd()) {
            qWarning() << "ClipEffects: unknown effect type:" << type;
            continue;
        }

        QByteArray binDesc = it->binDescription;
        if (glMode && !it->audio) {
            binDesc = it->glBinDescription
                ? QByteArray(it->glBinDescription)
                : QByteArray("gldownload ! ") + it->binDescription + " ! glupload";
        }
        GESEffect *effect = ges_effect_new(binDesc.constData());
        if (!effect) {
            qWarning() << "ClipEffects: ges_effect_new failed for" << type << "(" << binDesc << ")";
            continue;
        }

        QString id = obj.value("id").toString();
        ges_meta_container_set_string(GES_META_CONTAINER(effect), kEffectIdMetaKey, id.toUtf8().constData());

        QJsonObject params = obj.value("params").toObject();
        for (auto pit = params.constBegin(); pit != params.constEnd(); ++pit) {
            if (isAnimatedParam(pit.value())) continue; // applied below, after the effect is in the clip
            QVariant val = pit.value().toVariant();
            if (isPathParam(pit.key())) val = resolveAssetPath(projectDir, val.toString());
            setChildPropertyFromVariant(GES_TIMELINE_ELEMENT(effect), pit.key(), val);
        }

        GError *err = nullptr;
        // GES applies a top effect at a HIGHER index to the source BEFORE
        // lower ones, so inserting each at index 0 makes array order ==
        // processing order (first array entry runs first), matching
        // MLT/Kdenlive filter order. Index -1 would reverse it.
        if (!ges_clip_add_top_effect(clip, GES_BASE_EFFECT(effect), 0, &err)) {
            qWarning() << "ClipEffects: ges_clip_add_top_effect failed for" << type
                       << ":" << (err ? err->message : "unknown error");
            if (err) g_error_free(err);
            // Do NOT touch `effect` here: ges_container_add() ref_sinks the
            // floating effect and drops that ref again on failure, so it is
            // already finalized. Verified live on GES 1.28.8 (2026-11-18):
            // a weak ref fired inside the failed add, and the old
            // ref_sink+unref cleanup here produced "g_object_ref_sink:
            // assertion 'G_IS_OBJECT (object)' failed" (use-after-free) in
            // the app for an audio effect on a clip without audio.
            continue;
        }
        // A top-effect's control-source time base is CLIP-START-relative,
        // not media-time (verified live - different from the clip's own
        // source element, see applyAnimation()'s comment), so the offset
        // to convert this JSON's media-time keyframes is the clip's
        // current inpoint.
        {
            double inPointSec = (double)ges_timeline_element_get_inpoint(GES_TIMELINE_ELEMENT(clip)) / GST_SECOND;
            for (auto pit = params.constBegin(); pit != params.constEnd(); ++pit) {
                if (!isAnimatedParam(pit.value())) continue;
                applyAnimation(GES_TRACK_ELEMENT(effect), pit.key(), parseKeyframes(pit.value()), inPointSec);
            }
        }
        // INTENTIONALLY NOT UNREFFED past this point: ges_clip_add_top_effect()
        // sinks the floating ref, same pattern as every other GES
        // add-to-container call in this codebase (see TimelineEngine::
        // addClipToGES()'s comment on ges_layer_add_asset()) - flagged for
        // live empirical verification per project policy, not yet confirmed
        // under valgrind/ASan for THIS specific call.
    }
}

bool setParam(GESClip *clip, const QString &effectId, const QString &param,
              const QVariant &value, const QString &projectDir)
{
    GESBaseEffect *effect = findEffectById(clip, effectId);
    if (effect) {
        QVariant resolved = isPathParam(param) ? QVariant(resolveAssetPath(projectDir, value.toString())) : value;
        return setChildPropertyFromVariant(GES_TIMELINE_ELEMENT(effect), param, resolved);
    }
    // No top-effect with this id - "transform" has none to find, by
    // design (see isTransformParam()'s comment): it lives on the clip
    // itself. A real param name match is enough signal here since no
    // top-effect in the registry uses these names.
    if (isTransformParam(param)) {
        return setChildPropertyFromVariant(GES_TIMELINE_ELEMENT(clip), param, value);
    }
    if (isFadeParam(param)) {
        // Live-preview only (same as every other setParam() call - see
        // TimelineEngine::setClipEffectParam()'s callers): this rebuilds
        // the fade with ONLY the side being dragged, so the OTHER side's
        // fade (if any) briefly disappears during the drag instead of
        // being preserved - applyToClip()'s full rebuild on commit
        // (setClipEffects() -> updateTimelineEngine()) always re-applies
        // both sides correctly from the clip's real, persisted params,
        // so this is a cosmetic preview gap, not a data-loss risk.
        QJsonObject params;
        params[param] = value.toDouble();
        applyFade(clip, params);
        return true;
    }
    qWarning() << "ClipEffects::setParam: effect id not found on clip:" << effectId;
    return false;
}

} // namespace ClipEffects
