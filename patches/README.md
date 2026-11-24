# Local patches to GStreamer

`gstreamer/` is gitignored (it is a local 1.28.8 build made by
`scripts/build-gstreamer.sh`). Patches that the app depends on live here so the
tree can be rebuilt from scratch. They modify GStreamer Editing Services and are
under its license, LGPL-2.1-or-later.

## ges-gl-mode.patch  (gst-editing-services)

Adds a GL mode to GES: a video track created while `GES_GL_MODE=1` is set
composites with `glvideomixer`, its clip source chain is
`glupload ! glcolorconvert` (instead of videoconvert/videoflip/videoscale/
videoconvert) and crossfades/fade-ins are plain GL alpha blends (pad blend
functions) instead of `smptealpha` + CPU `compositor`. Wipes keep
`smptealpha` behind a gldownload/glupload bracket. Without the env var GES
behaves exactly as upstream. The mode is stored per track at creation, so a
GL preview timeline and a CPU export timeline can coexist.

It also pins each video transition's output to the track's `restriction-caps`
via an internal `capsfilter` (`ges-video-transition.c`). Without it the
transition's internal mixer negotiates its output at the sources' natural
size, which for a (smaller) preview proxy is far below the project size - the
main mixer then draws that frame in the top-left corner of the project canvas
on the first play after switching Original -> proxy.

`scripts/build-gstreamer.sh` clones GStreamer 1.28.8 and applies every
`patches/*.patch` before building. To apply it to an existing tree by hand and
rebuild only GES:

    cd gstreamer/src && git apply ../../patches/ges-gl-mode.patch
    ninja -C build subprojects/gst-editing-services/ges/libges-1.0.so.0.2808.0

Then install libges atomically (write a temp file next to the installed
library and `mv` it over it; never overwrite a library a running process has
mapped). The app side is src/core/GlTimeline.h (GCS_GL_TIMELINE=0 turns GL
mode off).
