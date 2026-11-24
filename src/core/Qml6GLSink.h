#pragma once

// qml6glsink spike (feature/qml6-gl-video-sink branch) - builds the small
// conversion bin that lets qml6glsink render directly into a QQuickItem in
// the Qt Quick scene graph, instead of the native-child-X11-window overlay
// VideoOutput.cpp uses. Two upstream memory layouts need two different
// converter chains:
//
//   - CudaMemory: NVDEC-decoded sources (playbin autoplugging nvh264dec/
//     nvh265dec). A 10-bit source (P010_10LE) must be downconverted to
//     NV12 BEFORE the GL stage: glcolorconvert's own P010_10LE-as-GLMemory
//     conversion is broken in this GStreamer build (fails "could not
//     transform ... in anything we support" despite its static caps
//     template listing P010_10LE as supported - verified live with
//     gst-launch-1.0). Doing the downconvert in CUDA memory via
//     cudaconvertscale, before cudadownload/glupload, sidesteps the broken
//     GL shader path entirely (verified live: the same pipeline reaches
//     EOS cleanly with this inserted, errors without it).
//     The chain starts with cudaupload: it passes CUDA memory through
//     untouched (verified: sink and src caps both video/x-raw(memory:
//     CUDAMemory) for nvh264dec/nvh265dec incl. P010) but uploads
//     system-memory raw video (pngdec/jpegdec stills, software-decoded
//     video), which otherwise fails with not-negotiated.
//   - SystemMemory: GES's preview pipeline (TimelineEngine) composites in
//     plain system-memory raw video (ges_track_set_restriction_caps sets no
//     memory feature) - there is no CUDA memory at playsink's input here,
//     so the CudaMemory chain would not even negotiate. The system-memory
//     analogue is videoconvert (not cudaconvertscale) forced to one of
//     qml6glsink's own native 8-bit formats, for the same P010-avoidance
//     reason.
//
// qml6glsink's own sink pad caps only declare 8-bit formats (RGBA, BGRA,
// RGB, YV12 - verified against this build with gst-inspect-1.0; note it
// does NOT accept NV12, despite what the pre-GL capsfilter below offers)
// - no 10-bit format at all - so this downconvert is required for any
// 10-bit source regardless of upstream memory type.
//
// The GL-side output format is then pinned to RGBA (see kGLSinkFormat).
// Letting glcolorconvert choose freely from qml6glsink's advertised set
// is not safe: it picks RGB for some sources (verified live with a 4K
// 8-bit H264 DJI file - gst-launch-1.0 negotiated
// video/x-raw(memory:GLMemory),format=RGB), and qml6glsink then aborts
// the whole process in its own scene-graph material code:
//   ERROR:../ext/qt6/gstqsg6material.cc:517:
//   video_format_to_rhi_format(): code should not be reached
// i.e. the sink advertises RGB on its pad but has no QRhiTexture::Format
// for it (QRhi has no 24-bit RGB texture format at all). Pinning RGBA
// sidesteps that upstream caps/material mismatch; the same file plays to
// EOS cleanly with format=RGBA forced.

#include <QQuickItem>
#include <QDebug>
#include <QFile>
#include <gst/gst.h>

namespace Qml6GLSink {

// GLMemory: upstream already delivers GL textures (GL timeline mode, see
// GlTimeline.h) - no download/convert hop at all.
enum class Upstream { CudaMemory, SystemMemory, GLMemory };

// The one GL format qml6glsink both advertises and can actually build a
// QSG material for - see the RGB abort described in the header comment.
static constexpr const char *kGLSinkFormat =
    "video/x-raw(memory:GLMemory),format=RGBA";

// CudaMemory chain only: qml6glsink's QSG material is drawn opaque (no
// Blending flag), so a PNG's alpha=0 pixels would show whatever RGB the
// file stores under them (white/black patches). Premultiplying here turns
// them into black over the black monitor. For NVDEC video alpha is always
// 1, i.e. this is an identity pass.
static constexpr const char *kPremultiplyFrag =
    "#ifdef GL_ES\n"
    "precision mediump float;\n"
    "#endif\n"
    "varying vec2 v_texcoord;\n"
    "uniform sampler2D tex;\n"
    "void main () {\n"
    "  vec4 c = texture2D(tex, v_texcoord);\n"
    "  gl_FragColor = vec4(c.rgb * c.a, c.a);\n"
    "}\n";

// One-time registry probe, cached - gst_element_factory_make("qml6glsink")
// itself would work as an availability check too, but that actually
// instantiates the element; this only asks whether the factory exists.
inline bool elementAvailable()
{
    static const bool avail = []() {
        GstElementFactory *f = gst_element_factory_find("qml6glsink");
        if (!f) return false;
        gst_object_unref(f);
        return true;
    }();
    return avail;
}

// Whether the installed "qml6" GStreamer plugin was built with Wayland
// support. Builds without qt6-wayland-dev (the stock Ubuntu/Mint gstreamer
// packages, and our own build before scripts/build-gstreamer.sh enabled
// qt-wayland) cannot create a GstGLDisplay for Qt's wayland platform, so
// qml6glsink never initialises there and the preview stays black.
//
// Detection is file-based on purpose: the plugin links libQt6WaylandClient
// only when Wayland support is compiled in, and DT_NEEDED entries are plain
// strings in the shared object's .dynstr, so searching the plugin file for
// "libQt6WaylandClient.so" is robust and needs neither dlopen() (which would
// load Qt libraries before QGuiApplication exists) nor any Qt/GStreamer
// symbol. It only needs the registry, so it is valid right after gst_init()
// - i.e. before the Qt platform is chosen in main(). The result is cached.
inline bool pluginSupportsWayland()
{
    static const bool supported = []() {
        GstPlugin *plugin = gst_registry_find_plugin(gst_registry_get(), "qml6");
        if (!plugin) return false;
        const gchar *fn = gst_plugin_get_filename(plugin);
        bool found = false;
        if (fn) {
            QFile f(QString::fromLocal8Bit(fn));
            if (f.open(QIODevice::ReadOnly))
                found = f.readAll().contains("libQt6WaylandClient.so");
        }
        gst_object_unref(plugin);
        return found;
    }();
    return supported;
}

// GCS_VIDEO_SINK semantics: unset or "qml6glsink" both mean "use the GL
// scene-graph path" (it's the default now - the whole point of this
// branch was to stop needing a native child X11 window). Any OTHER value
// ("native", a literal sink name like "ximagesink" for debugging, ...)
// opts out and falls back to the native-window path, same as before.
// Automatically falls back too if qml6glsink genuinely isn't in this
// GStreamer build's registry - see fellBackToNative() for surfacing that
// in the UI instead of just silently downgrading.
inline bool enabled()
{
    const QByteArray v = qgetenv("GCS_VIDEO_SINK");
    const bool wantsGL = v.isEmpty() || v == "qml6glsink";
    return wantsGL && elementAvailable();
}

// True exactly when the GL path was requested (by default or explicitly)
// but qml6glsink isn't actually available, i.e. VideoEngine/TimelineEngine
// silently fell back to the native-window overlay. Surfaced in the About
// dialog - see BackendManager::videoOutputFallback().
inline bool fellBackToNative()
{
    const QByteArray v = qgetenv("GCS_VIDEO_SINK");
    const bool wantsGL = v.isEmpty() || v == "qml6glsink";
    return wantsGL && !elementAvailable();
}

// Builds "qml6glsink" wired to `item`'s "widget" property, wrapped in a
// converter bin appropriate for `upstream`. Returns the bin (what a
// playbin "video-sink" property or ges_pipeline_preview_set_video_sink()
// should receive) with a floating ref (caller must gst_object_ref_sink()
// before handing it to an API that only does transfer-none/plain-ref).
// Writes the real qml6glsink element to *outSinkElement - callers need
// this distinct from the returned bin for the "widget" property, since
// once wrapped, the bin itself has no such property.
inline GstElement *makeSinkBin(QQuickItem *item, GstElement **outSinkElement, Upstream upstream)
{
    GstElement *sink = gst_element_factory_make("qml6glsink", nullptr);
    if (!sink) {
        qWarning() << "Qml6GLSink: qml6glsink element not available";
        if (outSinkElement) *outSinkElement = nullptr;
        return nullptr;
    }
    if (item) {
        g_object_set(G_OBJECT(sink), "widget", item, NULL);
    } else {
        qWarning() << "Qml6GLSink: makeSinkBin() called with a null QQuickItem";
    }
    if (outSinkElement) *outSinkElement = sink;

    GstElement *conv1 = nullptr;
    GstElement *cudaUp = nullptr;  // CudaMemory only: head of the bin
    GstElement *capsFilter = gst_element_factory_make("capsfilter", nullptr);
    GstElement *conv2 = nullptr;
    GstElement *glUp = gst_element_factory_make("glupload", nullptr);
    GstElement *glConv = gst_element_factory_make("glcolorconvert", nullptr);
    // Pins glcolorconvert's output to RGBA so it can never settle on the
    // RGB that makes qml6glsink abort - see kGLSinkFormat.
    GstElement *glCapsFilter = gst_element_factory_make("capsfilter", nullptr);
    GstElement *glPremul = nullptr;  // CudaMemory only, optional (see kPremultiplyFrag)
    GstCaps *caps = nullptr;

    if (upstream == Upstream::CudaMemory) {
        cudaUp = gst_element_factory_make("cudaupload", nullptr);
        conv1 = gst_element_factory_make("cudaconvertscale", nullptr);
        conv2 = gst_element_factory_make("cudadownload", nullptr);
        caps = gst_caps_from_string("video/x-raw(memory:CUDAMemory),format={ NV12, RGBA }");
        glPremul = gst_element_factory_make("glshader", nullptr);
        if (glPremul)
            g_object_set(G_OBJECT(glPremul), "fragment", kPremultiplyFrag, NULL);
    } else if (upstream == Upstream::GLMemory) {
        conv1 = gst_element_factory_make("identity", nullptr);
        caps = gst_caps_from_string("video/x-raw(memory:GLMemory)");
    } else {
        conv1 = gst_element_factory_make("videoconvert", nullptr);
        caps = gst_caps_from_string("video/x-raw,format={ NV12, YV12, RGBA, BGRA, RGB }");
    }

    if (!conv1 || !capsFilter || !glUp || !glConv || !glCapsFilter || (upstream == Upstream::CudaMemory && (!conv2 || !cudaUp))) {
        qWarning() << "Qml6GLSink: converter elements unavailable - qml6glsink will only work with already-8-bit sources";
        if (conv1) gst_object_unref(conv1);
        if (cudaUp) gst_object_unref(cudaUp);
        if (capsFilter) gst_object_unref(capsFilter);
        if (conv2) gst_object_unref(conv2);
        if (glUp) gst_object_unref(glUp);
        if (glConv) gst_object_unref(glConv);
        if (glCapsFilter) gst_object_unref(glCapsFilter);
        if (glPremul) gst_object_unref(glPremul);
        if (caps) gst_caps_unref(caps);
        return sink;
    }

    g_object_set(G_OBJECT(capsFilter), "caps", caps, NULL);
    gst_caps_unref(caps);

    GstCaps *glCaps = gst_caps_from_string(kGLSinkFormat);
    g_object_set(G_OBJECT(glCapsFilter), "caps", glCaps, NULL);
    gst_caps_unref(glCaps);

    GstElement *sinkBin = gst_bin_new(upstream == Upstream::CudaMemory ? "qml6_gl_sink_bin_cuda"
                                                         : upstream == Upstream::GLMemory ? "qml6_gl_sink_bin_gl"
                                                                                          : "qml6_gl_sink_bin_sysmem");
    bool linked;
    if (upstream == Upstream::CudaMemory && glPremul) {
        gst_bin_add_many(GST_BIN(sinkBin), cudaUp, conv1, capsFilter, conv2, glUp, glConv, glPremul, glCapsFilter, sink, NULL);
        linked = gst_element_link_many(cudaUp, conv1, capsFilter, conv2, glUp, glConv, glPremul, glCapsFilter, sink, NULL);
    } else if (upstream == Upstream::CudaMemory) {
        gst_bin_add_many(GST_BIN(sinkBin), cudaUp, conv1, capsFilter, conv2, glUp, glConv, glCapsFilter, sink, NULL);
        linked = gst_element_link_many(cudaUp, conv1, capsFilter, conv2, glUp, glConv, glCapsFilter, sink, NULL);
    } else {
        gst_bin_add_many(GST_BIN(sinkBin), conv1, capsFilter, glUp, glConv, glCapsFilter, sink, NULL);
        linked = gst_element_link_many(conv1, capsFilter, glUp, glConv, glCapsFilter, sink, NULL);
    }

    if (!linked) {
        qWarning() << "Qml6GLSink: failed to link downconvert bin, using qml6glsink directly (10-bit sources will fail)";
        // sink was handed to sinkBin via gst_bin_add_many() above, which
        // took over its only reference - unreffing sinkBin therefore also
        // disposes sink, and the old `return sink;` here returned a
        // dangling pointer. Take our own reference first so sink survives
        // the bin's teardown; verified live (standalone GstBin test
        // against this project's GStreamer 1.28.8 build): refcount goes
        // 1 (bin-owned) -> 2 (+ our ref) -> 1 (after bin unref) with sink
        // still a valid, usable element afterward.
        //
        // Known minor imperfection, left as-is rather than chased further:
        // every caller treats makeSinkBin()'s return value uniformly as a
        // FLOATING ref (TimelineEngine.cpp explicitly calls
        // gst_object_ref_sink() on it, matching the success path, where
        // gst_bin_new() itself returns floating). gst_bin_add() already
        // sank sink's original floating ref when it first became a child
        // of sinkBin, and there is no public GStreamer/GObject API to make
        // an object floating again - so the gst_object_ref() above hands
        // back a normal (non-floating) ref instead. A caller's
        // gst_object_ref_sink() on a non-floating object is defined to
        // behave as a second plain ref(), meaning their single matching
        // gst_object_unref() leaves one extra reference un-released - a
        // harmless one-element leak, not a crash, and only on this
        // already-exceptional path (gst_element_link_many() failing among
        // a fixed set of known-good element types essentially never
        // happens in practice).
        gst_object_ref(sink);
        gst_object_unref(sinkBin); // also removes/unrefs every OTHER element added above
        return sink;
    }

    GstPad *binSinkPad = gst_element_get_static_pad(cudaUp ? cudaUp : conv1, "sink");
    gst_element_add_pad(sinkBin, gst_ghost_pad_new("sink", binSinkPad));
    gst_object_unref(binSinkPad);
    return sinkBin;
}

} // namespace Qml6GLSink
