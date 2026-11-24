#pragma once
// GL timeline mode: the preview timeline is composited by glvideomixer and
// the per-clip source chain, transitions and the effects that have a GPU
// implementation keep frames in GLMemory end to end (decoder -> effects ->
// mixer -> qml6glsink) instead of round-tripping through system memory.
// This needs our patched GES (see the gstreamer/ tree: GES_GL_MODE, read by
// GES when a video track is created) - with a stock GES the env var is just
// ignored and the pipeline stays on the CPU path, so enabled() also checks
// that the patch is present.
//
// GCS_GL_TIMELINE=0 forces the old CPU path, =1 forces GL; unset means the
// built-in default below.

#include <QByteArray>
#include <QtGlobal>
#include <gst/gst.h>

namespace GlTimeline {

static constexpr bool kDefaultEnabled = true;

inline bool elementsAvailable()
{
    static const bool avail = []() {
        static const char *names[] = { "glvideomixer", "glupload", "glcolorconvert", "gccbc", nullptr };
        for (const char **n = names; *n; ++n) {
            GstElementFactory *f = gst_element_factory_find(*n);
            if (!f) return false;
            gst_object_unref(f);
        }
        return true;
    }();
    return avail;
}

// True when the loaded libges carries patches/ges-gl-mode.patch. The patch's
// own functions are G_GNUC_INTERNAL (not exported), so detect it by what it
// adds to the public type system: the "gl-mode" property on GES's smart mixer,
// registered by ges_init() as the "gescompositor" element. Stock GES has no
// such property and would silently ignore GES_GL_MODE, while we would still
// put GLMemory restriction caps on the video track (black preview,
// not-negotiated). Requires ges_init() to have run.
inline bool gesPatchPresent()
{
    static const bool present = []() {
        GstElementFactory *f = gst_element_factory_find("gescompositor");
        if (!f) return false;
        GstPluginFeature *loaded = gst_plugin_feature_load(GST_PLUGIN_FEATURE(f));
        GType t = loaded ? gst_element_factory_get_element_type(GST_ELEMENT_FACTORY(loaded)) : G_TYPE_INVALID;
        bool has = false;
        if (t != G_TYPE_INVALID) {
            gpointer klass = g_type_class_ref(t);
            has = g_object_class_find_property(G_OBJECT_CLASS(klass), "gl-mode") != nullptr;
            g_type_class_unref(klass);
        }
        if (loaded) gst_object_unref(loaded);
        gst_object_unref(f);
        return has;
    }();
    return present;
}

inline bool enabled()
{
    const QByteArray v = qgetenv("GCS_GL_TIMELINE");
    const bool want = v.isEmpty() ? kDefaultEnabled : (v != "0");
    if (!want || !elementsAvailable()) return false;
    if (!gesPatchPresent()) {
        static bool logged = false;
        if (!logged) {
            logged = true;
            qInfo("GL timeline mode unavailable: the loaded GES lacks the GL-mode patch "
                  "(patches/ges-gl-mode.patch) - using the CPU timeline path");
        }
        return false;
    }
    return true;
}

// GES decides GL vs CPU per video track, when the track is created, from
// this env var. Callers creating a timeline set it around the creation.
inline void setGesGlMode(bool gl)
{
    qputenv("GES_GL_MODE", gl ? "1" : "0");
}

// Forces GES_GL_MODE for a span of synchronous code and restores the previous
// value afterwards (also on early returns). Needed because the patched GES
// reads the env var not only at track creation but also whenever a track
// element's source/filter chain is built: that happens in
// ges_layer_add_asset()/transition creation, BEFORE the element has a track
// to ask (ges_track_element_is_gl() falls back to the env var then). A
// non-GL export timeline therefore has to keep GES_GL_MODE=0 for its whole
// build, not just around ges_timeline_new_audio_video(), or its sources get
// the GL chain (glupload/glcolorconvert/glcolorscale) inside a system-memory
// track. Main-thread only, and the span must not pump the event loop (use
// release() around anything that might, then engage() again).
class GesGlModeGuard {
public:
    explicit GesGlModeGuard(bool gl)
        : m_hadPrev(qEnvironmentVariableIsSet("GES_GL_MODE")),
          m_prev(qgetenv("GES_GL_MODE")),
          m_gl(gl)
    {
        engage();
    }
    ~GesGlModeGuard() { release(); }
    GesGlModeGuard(const GesGlModeGuard &) = delete;
    GesGlModeGuard &operator=(const GesGlModeGuard &) = delete;

    void engage()
    {
        if (m_engaged) return;
        setGesGlMode(m_gl);
        m_engaged = true;
    }
    void release()
    {
        if (!m_engaged) return;
        if (m_hadPrev) qputenv("GES_GL_MODE", m_prev);
        else qunsetenv("GES_GL_MODE");
        m_engaged = false;
    }

private:
    bool m_hadPrev;
    QByteArray m_prev;
    bool m_gl;
    bool m_engaged = false;
};

} // namespace GlTimeline
