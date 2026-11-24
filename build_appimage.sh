#!/bin/bash
# Build a self-contained AppImage for GPU Cine Studio.
#
# Usage: ./build_appimage.sh [VERSION]
# Example: ./build_appimage.sh 20261024
#
# Environment:
#   GCS_GST_PREFIX          GStreamer prefix to bundle (default: ./gstreamer/install,
#                           built by scripts/build-gstreamer.sh). It must contain the
#                           patched GES - the system GStreamer is never bundled.
#   GCS_APPIMAGE_BUILD_DIR  build directory (default: ./build-appimage)
#   GCS_APPIMAGE_TOOLS_DIR  where linuxdeploy/appimagetool are downloaded and cached
#                           (default: the build directory)
#   CLEAN_APPDIR=1          wipe and redeploy the AppDir from scratch
#
# What gets bundled: the app, Qt 6 (incl. the QML modules the app imports), the
# whole GStreamer prefix (libraries incl. the patched libges, plugins,
# gst-plugin-scanner) and their non-system dependencies - minus the
# patent-encumbered software codec plugins (libav, x264, x265, openh264,
# fdk-aac, faad, lame, ...). AppRun points GStreamer at the bundled plugins
# plus a small WHITELIST of the host's codec plugin files (symlinked into a
# private directory, see the AppRun below), never at the whole host plugin
# directory, and uses its own registry file.
#
# GPU acceleration note: the AppImage must NOT bundle the host's own
# libGL/libEGL/libvulkan/libnvidia-*/libcuda*/libva* - those always have to
# come from the host's driver at runtime (they're tied to the exact installed
# kernel driver version). Bundling a copy would make the AppImage either
# ignore the GPU or crash on a driver mismatch on another machine. The scrub
# step below runs AFTER linuxdeploy's own dependency walk (which can still
# pull some of these in despite its built-in exclude-list) and deletes
# anything GPU-driver-specific before the image gets packaged.

set -euo pipefail

cd "$(dirname "$0")"
PROJECT_ROOT="$(pwd)"

VERSION=${1:-}
CMAKE_VERSION_ARG=()
if [ -n "$VERSION" ]; then
    CMAKE_VERSION_ARG=("-DBUILD_VERSION=$VERSION")
    echo "=== Building GPU Cine Studio AppImage (version: $VERSION) ==="
else
    # Same auto-date logic as CMakeLists.txt's own fallback (UTC YYYYMMDD) -
    # computed here too so the AppImage's filename carries the same version.
    VERSION="$(date -u +%Y%m%d)"
    echo "=== Building GPU Cine Studio AppImage (auto-generated version: $VERSION) ==="
fi

GST_PREFIX="${GCS_GST_PREFIX:-$PROJECT_ROOT/gstreamer/install}"
BUILD_DIR="${GCS_APPIMAGE_BUILD_DIR:-$PROJECT_ROOT/build-appimage}"
TOOLS_DIR="${GCS_APPIMAGE_TOOLS_DIR:-$BUILD_DIR}"

if [ ! -d "$GST_PREFIX" ]; then
    echo "FAIL: GStreamer prefix $GST_PREFIX not found - run scripts/build-gstreamer.sh first." >&2
    exit 1
fi
GST_PREFIX="$(cd "$GST_PREFIX" && pwd)"
GST_LIBDIR=""
for d in "$GST_PREFIX"/lib/*-linux-gnu "$GST_PREFIX/lib64" "$GST_PREFIX/lib"; do
    if [ -e "$d/libgstreamer-1.0.so.0" ]; then GST_LIBDIR="$d"; break; fi
done
[ -n "$GST_LIBDIR" ] || { echo "FAIL: no libgstreamer-1.0.so.0 under $GST_PREFIX/lib*" >&2; exit 1; }
GST_SCANNER="$(ls "$GST_PREFIX"/libexec/gstreamer-1.0/gst-plugin-scanner "$GST_LIBDIR"/gstreamer-1.0/gst-plugin-scanner 2>/dev/null | head -1 || true)"
[ -n "$GST_SCANNER" ] || { echo "FAIL: gst-plugin-scanner not found in $GST_PREFIX" >&2; exit 1; }
if ! LC_ALL=C grep -aq GES_GL_MODE "$GST_LIBDIR"/libges-1.0.so.0; then
    echo "FAIL: $GST_LIBDIR/libges-1.0.so.0 lacks the GL-mode patch (patches/ges-gl-mode.patch)." >&2
    exit 1
fi
echo "GStreamer prefix: $GST_PREFIX ($("$GST_PREFIX/bin/gst-launch-1.0" --version 2>/dev/null | sed -n 2p || echo '?'))"

echo "Step 1/7: Building application..."
cmake -S "$PROJECT_ROOT" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
    -DGCS_GST_PREFIX="$GST_PREFIX" "${CMAKE_VERSION_ARG[@]}"
cmake --build "$BUILD_DIR" -j"$(nproc)"

echo "Step 2/7: Creating AppDir..."
APPDIR="$BUILD_DIR/AppDir"
# Kept between runs: "make install" overwrites whatever changed, and the slow
# Qt/GStreamer deployment below is skipped when it was already done for the
# same GStreamer prefix. CLEAN_APPDIR=1 forces a full wipe-and-redeploy (e.g.
# after adding a linked library).
STAMP="$APPDIR/.gcs-deployed-from"
if [ -n "${CLEAN_APPDIR:-}" ] || [ ! -d "$APPDIR" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$GST_PREFIX" ]; then
    rm -rf "$APPDIR"
fi
DESTDIR="$APPDIR" cmake --install "$BUILD_DIR"

echo "Step 3/7: Fetching deployment tools (cached in $TOOLS_DIR)..."
mkdir -p "$TOOLS_DIR"
fetch_tool() {
    local file="$1" url="$2"
    if [ ! -f "$TOOLS_DIR/$file" ]; then
        wget -q --show-progress -O "$TOOLS_DIR/$file.part" "$url"
        mv "$TOOLS_DIR/$file.part" "$TOOLS_DIR/$file"
        chmod +x "$TOOLS_DIR/$file"
    fi
}
fetch_tool linuxdeploy-x86_64.AppImage \
    "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
fetch_tool linuxdeploy-plugin-qt-x86_64.AppImage \
    "https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage"
fetch_tool appimagetool-x86_64.AppImage \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"

if [ ! -f "$STAMP" ]; then
    echo "Step 4/7: Copying the GStreamer prefix into the AppDir..."
    mkdir -p "$APPDIR/usr/lib/gstreamer-1.0" "$APPDIR/usr/libexec/gstreamer-1.0"
    # All shared libraries of the prefix (GStreamer, the patched GES, and the
    # meson subproject libraries next to them such as libvpx/opus/orc).
    find "$GST_LIBDIR" -maxdepth 1 -name 'lib*.so*' \( -type f -o -type l \) -exec cp -a {} "$APPDIR/usr/lib/" \;
    cp -a "$GST_LIBDIR"/gstreamer-1.0/*.so "$APPDIR/usr/lib/gstreamer-1.0/"
    cp -a "$GST_SCANNER" "$APPDIR/usr/libexec/gstreamer-1.0/"
    # Development-only leftovers.
    find "$APPDIR/usr/lib" -maxdepth 1 \( -name '*.a' -o -name 'lib*-test-*' -o -name 'libgstcheck-*' \) -delete

    # Software H.264/H.265/AAC codec plugins are patent-encumbered (MPEG-LA/
    # Via Licensing/HEVC Advance etc.) - WE would be the one distributing them
    # if bundled into the AppImage we hand out. scripts/build-gstreamer.sh
    # does not build them by default; this is the backstop for a prefix built
    # with --enable-patented. GPU-vendor plugins (nvcodec/va) are kept: the
    # codec work is done by the GPU and its driver.
    EXCLUDED_CODEC_PLUGINS=(
        "libgstx264.so"       # H.264 software encoder (x264)
        "libgstx265.so"       # H.265 software encoder (x265)
        "libgstlibav.so"      # FFmpeg-wrapped decoders/encoders incl. H.264/H.265/AAC
        "libgstde265.so"      # H.265 software decoder (libde265)
        "libgstopenh264.so"   # H.264 (self-built OpenH264 is not covered by Cisco's patent license)
        "libgstfdkaac.so"     # AAC software encoder/decoder (fdk-aac)
        "libgstvoaacenc.so"   # AAC software encoder
        "libgstfaad.so"       # AAC software decoder
        "libgstsvthevcenc.so" # H.265 software encoder
        "libgstlame.so"       # MP3 encoder - not needed by the app; excluded so the
                              # host's copy (see AppRun) never clashes with ours
    )
    for plugin in "${EXCLUDED_CODEC_PLUGINS[@]}"; do
        if [ -f "$APPDIR/usr/lib/gstreamer-1.0/$plugin" ]; then
            rm -f "$APPDIR/usr/lib/gstreamer-1.0/$plugin"
            echo "  Excluded $plugin (patent-encumbered software codec)"
        fi
    done
    # ...and the codec libraries those plugins would have pulled in.
    find "$APPDIR/usr/lib" -maxdepth 1 \( -name 'libx264.so*' -o -name 'libx265.so*' -o -name 'libopenh264.so*' \
        -o -name 'libfdk-aac.so*' -o -name 'libavcodec.so*' -o -name 'libavformat.so*' -o -name 'libavutil.so*' \
        -o -name 'libavfilter.so*' -o -name 'libswscale.so*' -o -name 'libswresample.so*' -o -name 'libpostproc.so*' \) -delete
    echo "  Plugins bundled: $(ls -1 "$APPDIR/usr/lib/gstreamer-1.0"/*.so | wc -l)"

    echo "Step 5/7: Deploying Qt + shared-library dependencies into the AppDir..."
    # The prefix's libraries must win over any system GStreamer while
    # linuxdeploy resolves dependencies.
    export LD_LIBRARY_PATH="$GST_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    # linuxdeploy-plugin-qt shells out to a bare "qmake" - on Ubuntu that can
    # resolve (via qtchooser) to a Qt5 wrapper, so point it at Qt6's qmake6.
    export QMAKE="${QMAKE:-$(command -v qmake6 || command -v qmake)}"
    # Skips a slow per-library `dpkg -S` lookup for copyright files.
    export DISABLE_COPYRIGHT_FILES_DEPLOYMENT=1
    # QML is compiled into the binary via .qrc, so point the Qt plugin at the
    # source tree to scan the imports (QtQuick, QtQuick.Controls, ...).
    export QML_SOURCES_PATHS="$PROJECT_ROOT/src"
    # Native Wayland (GCS_NATIVE_WAYLAND=1): linuxdeploy-plugin-qt only deploys
    # the Wayland QPA plugin(s) it finds referenced; ask for the EGL and generic
    # compositor backends explicitly (their shell/graphics integration plugins
    # are pulled in with them).
    export EXTRA_PLATFORM_PLUGINS="libqwayland-egl.so;libqwayland-generic.so"
    "$TOOLS_DIR/linuxdeploy-x86_64.AppImage" --appdir="$APPDIR" \
        --executable="$APPDIR/usr/bin/gpu-cine-studio" \
        --deploy-deps-only="$APPDIR/usr/lib" \
        --deploy-deps-only="$APPDIR/usr/lib/gstreamer-1.0" \
        --deploy-deps-only="$APPDIR/usr/libexec/gstreamer-1.0/gst-plugin-scanner" \
        --plugin qt

    # libges' optional Python formatter discovery can pull in libpython3*.
    # NEVER bundle it: a second libpython copy at a different path than the
    # host's own gets loaded as a SEPARATE interpreter instance, which
    # segfaults inside CPython's own locking code.
    find "$APPDIR/usr/lib" -maxdepth 1 -iname "libpython3*" -delete 2>/dev/null || true

    # The app forces the xcb platform on Wayland sessions (src/main.cpp), so the
    # xcb plugin (+ its GL integration) must be in the bundle; linuxdeploy-plugin-qt
    # normally deploys it, fail loudly if it ever does not. The libxcb-* libraries
    # themselves come from the host (they are on linuxdeploy's excludelist).
    for f in platforms/libqxcb.so xcbglintegrations/libqxcb-glx-integration.so; do
        [ -e "$APPDIR/usr/plugins/$f" ] || { echo "FAIL: $f missing from the AppDir (needed for the XWayland default)." >&2; exit 1; }
    done

    # Native Wayland support: qml6glsink links libQt6WaylandClient.so.6 (even when
    # running on X11), and the Wayland QPA plugin + integrations are needed for
    # GCS_NATIVE_WAYLAND=1.
    # linuxdeploy-plugin-qt deploys the Wayland shell/decoration plugins but not
    # wayland-graphics-integration-client (the EGL buffer integration Qt's wayland
    # platform needs for OpenGL/qml6glsink) - add it, and its dependencies, here.
    QT_PLUGIN_DIR="$("$QMAKE" -query QT_INSTALL_PLUGINS)"
    if [ ! -d "$APPDIR/usr/plugins/wayland-graphics-integration-client" ] && [ -d "$QT_PLUGIN_DIR/wayland-graphics-integration-client" ]; then
        mkdir -p "$APPDIR/usr/plugins/wayland-graphics-integration-client"
        cp -a "$QT_PLUGIN_DIR/wayland-graphics-integration-client"/libqt-plugin-wayland-egl.so \
              "$APPDIR/usr/plugins/wayland-graphics-integration-client/" 2>/dev/null || true
        if [ -n "$(ls -A "$APPDIR/usr/plugins/wayland-graphics-integration-client")" ]; then
            "$TOOLS_DIR/linuxdeploy-x86_64.AppImage" --appdir="$APPDIR" \
                --deploy-deps-only="$APPDIR/usr/plugins/wayland-graphics-integration-client"
        else
            rmdir "$APPDIR/usr/plugins/wayland-graphics-integration-client"
        fi
    fi
    [ -e "$APPDIR/usr/lib/libQt6WaylandClient.so.6" ] || { echo "FAIL: libQt6WaylandClient.so.6 missing from the AppDir (libgstqml6.so needs it; install qt6-wayland)." >&2; exit 1; }
    for f in platforms/libqwayland-egl.so wayland-shell-integration wayland-graphics-integration-client; do
        [ -e "$APPDIR/usr/plugins/$f" ] || { echo "FAIL: $f missing from the AppDir (needed for native Wayland; install qt6-wayland)." >&2; exit 1; }
    done

    echo "$GST_PREFIX" > "$STAMP"
else
    echo "Steps 4-5/7: GStreamer + Qt already deployed from $GST_PREFIX, skipping (CLEAN_APPDIR=1 to force a redo)"
fi

# Real (versioned) file names of the bundled libraries, e.g.
# "libmpg123.so.0 libmpg123.so.0.48.2": linuxdeploy copies them under their
# soname only. The AppRun compares these against the host's copies.
echo "Writing the bundled library version manifest..."
: > "$APPDIR/usr/lib/.gcs-lib-versions"
for lib in "$APPDIR"/usr/lib/lib*.so*; do
    name="${lib##*/}"
    src=""
    if [ -e "$GST_LIBDIR/$name" ]; then
        src="$GST_LIBDIR/$name"
    else
        src="$(/sbin/ldconfig -p 2>/dev/null | awk -v n="$name" '$1 == n && /x86-64/ && !f { print $NF; f = 1 }')"
    fi
    real="$name"
    [ -n "$src" ] && real="$(basename "$(readlink -f "$src")")"
    echo "$name $real" >> "$APPDIR/usr/lib/.gcs-lib-versions"
done

echo "Step 6/7: Scrubbing GPU-driver-specific libs from the AppDir..."
# These must come from the host at runtime, never from the bundle.
DRIVER_LIB_PATTERNS=(
    "libGL.so*" "libGLX.so*" "libGLdispatch.so*" "libEGL.so*"
    "libOpenGL.so*" "libGLESv1*" "libGLESv2*"
    "libvulkan.so*" "libnvidia-*" "libcuda.so*" "libcudart.so*"
    "libva.so*" "libva-drm.so*" "libva-glx.so*" "libva-x11.so*" "libva-wayland.so*"
    "libdrm.so*" "libgbm.so*"
)
REMOVED=0
for pattern in "${DRIVER_LIB_PATTERNS[@]}"; do
    while IFS= read -r -d '' f; do
        rm -f "$f"
        REMOVED=$((REMOVED + 1))
    done < <(find "$APPDIR/usr/lib" -maxdepth 2 -iname "$pattern" -print0 2>/dev/null)
done
echo "  Removed $REMOVED host-only driver lib(s) from the bundle."

# Backstop: nothing of the host-provided codec set may end up in the bundle
# (it would also shadow the host's copy - same plugin name / soname).
# libmp3lame itself is not on this list: it is a regular dependency of
# libsndfile (via the bundled pulseaudio client) and MP3 is patent-free.
LEAKED="$(find "$APPDIR/usr/lib" -maxdepth 2 \( -name 'libgstlibav.so' -o -name 'libgstx264.so' -o -name 'libgstx265.so' \
    -o -name 'libgstopenh264.so' -o -name 'libgstfdkaac.so' -o -name 'libgstfaad.so' -o -name 'libgstlame.so' \
    -o -name 'libavcodec.so*' -o -name 'libavformat.so*' -o -name 'libavutil.so*' -o -name 'libx264.so*' -o -name 'libx265.so*' \
    -o -name 'libopenh264.so*' -o -name 'libfdk-aac.so*' -o -name 'libfaad.so*' \) -print)"
if [ -n "$LEAKED" ]; then
    echo "FAIL: host-provided codec files ended up in the AppDir:" >&2
    echo "$LEAKED" >&2
    exit 1
fi

echo "Writing custom AppRun (GStreamer/Qt search paths)..."
# linuxdeploy leaves AppRun as a SYMLINK to usr/bin/gpu-cine-studio - "cat >
# AppRun" would follow it and overwrite the real binary, so unlink it first.
rm -f "$APPDIR/AppRun"
cat > "$APPDIR/AppRun" << 'APPRUN_EOF'
#!/bin/bash
SELF=$(readlink -f "$0")
HERE=${SELF%/*}

# The bundled GStreamer plugins, never the host's whole plugin directory
# (the host has its own copies of core/base/good/... with the same plugin
# names, built for another GStreamer version).
export GST_PLUGIN_SYSTEM_PATH_1_0="$HERE/usr/lib/gstreamer-1.0"
export GST_PLUGIN_SYSTEM_PATH="$HERE/usr/lib/gstreamer-1.0"
unset GST_PLUGIN_PATH GST_PLUGIN_PATH_1_0
export GST_PLUGIN_SCANNER_1_0="$HERE/usr/libexec/gstreamer-1.0/gst-plugin-scanner"
export GST_PLUGIN_SCANNER="$GST_PLUGIN_SCANNER_1_0"
GCS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/gpu-cine-studio"
mkdir -p "$GCS_CACHE" 2>/dev/null

# Patent-encumbered software codecs (H.264/H.265/AAC) are not bundled; they
# come from the host distribution's own GStreamer codec packages. Only this
# whitelist of plugin FILES is exposed, symlinked into a private directory -
# these plugin names are excluded from the bundle, so nothing is duplicated.
# A host plugin built for a NEWER GStreamer minor than the bundled one is
# rejected by GStreamer itself (the in-app codec check reports it as
# "installed but incompatible"). GCS_NO_HOST_CODECS=1 disables all of this
# (bundled plugins only). The app re-does the same linking when the user
# presses "Re-check" in Settings > Codecs - keep both lists in sync
# (src/core/CodecCheck.cpp).
export GCS_APPIMAGE=1
export GCS_HOST_GST_PLUGINS="libgstlibav.so libgstx264.so libgstx265.so libgstopenh264.so libgstfdkaac.so libgstfaad.so libgstlame.so"
export GCS_HOST_GST_SEARCH_DIRS="/usr/lib/x86_64-linux-gnu/gstreamer-1.0:/usr/lib64/gstreamer-1.0:/usr/lib/gstreamer-1.0"
HOST_LIB_DIR=""
if [ -z "${GCS_NO_HOST_CODECS:-}" ] || [ "${GCS_NO_HOST_CODECS}" = "0" ]; then
    IFS=: read -r -a GCS_DIRS <<< "$GCS_HOST_GST_SEARCH_DIRS"
    FOUND_PLUGINS=()
    for plugin in $GCS_HOST_GST_PLUGINS; do
        for dir in "${GCS_DIRS[@]}"; do
            if [ -f "$dir/$plugin" ]; then FOUND_PLUGINS+=("$dir/$plugin"); break; fi
        done
    done
    # "soname /host/path" of everything the host plugins link, resolved the
    # way the host itself resolves it (without our or the caller's
    # LD_LIBRARY_PATH).
    HOST_DEPS="$(
        for f in "${FOUND_PLUGINS[@]}"; do
            env -u LD_LIBRARY_PATH ldd "$f" 2>/dev/null | awk '$2 == "=>" && $3 ~ /^\// { print $1 " " $3 }'
        done | sort -u
    )"
    # A library the host codec stack needs that the bundle ALSO contains
    # (e.g. libmpg123, needed by Arch's ffmpeg via libopenmpt) would resolve
    # to the bundled copy, which may be older than what the host's libraries
    # were built against ("undefined symbol" -> plugin not loadable). Those
    # are taken from the host instead, via an override directory in front of
    # the bundle - but only when the host copy is at least as new as the
    # bundled one (usr/lib/.gcs-lib-versions, written at build time), and
    # never for GStreamer/GLib themselves: our GStreamer 1.28 core must win.
    HOST_LIB_OVERRIDES=()
    while read -r soname path; do
        [ -n "$soname" ] && [ -e "$HERE/usr/lib/$soname" ] || continue
        case "$soname" in
            libgst*|libges-*|libglib-2.0.*|libgobject-2.0.*|libgio-2.0.*|libgmodule-2.0.*|libgthread-2.0.*|liborc-0.4.*|libffi.*|libpcre2-8.*) continue ;;
        esac
        host_real="$(basename "$(readlink -f "$path")")"
        bundled_real="$(awk -v s="$soname" '$1 == s { print $2 }' "$HERE/usr/lib/.gcs-lib-versions" 2>/dev/null)"
        [ -n "$bundled_real" ] || bundled_real="$soname"
        if [ "$(printf '%s\n%s\n' "$bundled_real" "$host_real" | sort -V | tail -n 1)" = "$host_real" ]; then
            HOST_LIB_OVERRIDES+=("$soname $path")
        fi
    done <<< "$HOST_DEPS"
    # The registry caches a plugin's element list - and a failed load - by
    # the plugin file's path and mtime. Swapping the codec LIBRARY underneath
    # an unchanged plugin file (Fedora: "dnf swap ffmpeg-free ffmpeg" adds
    # avdec_h264 to the same libgstlibav.so), or a new AppImage resolving a
    # previous load failure, would otherwise keep the stale entry forever.
    # So the symlink directory is named after a fingerprint of the plugins,
    # the libraries they resolve to, the overrides and the bundle's library
    # manifest: any change gives new paths, which GStreamer rescans.
    FINGERPRINT="$(
        {
            printf '%s\n' "${FOUND_PLUGINS[@]}" "${HOST_LIB_OVERRIDES[@]}"
            printf '%s\n' "$HOST_DEPS" | awk '{ print $2 }' | while read -r lib; do stat -L -c '%n %s %Y' "$lib" 2>/dev/null; done
            for f in "${FOUND_PLUGINS[@]}"; do stat -L -c '%n %s %Y' "$f"; done
            cat "$HERE/usr/lib/.gcs-lib-versions" 2>/dev/null
        } | cksum | cut -d' ' -f1
    )"
    HOST_PLUGIN_ROOT="$GCS_CACHE/host-gst-plugins"
    HOST_PLUGIN_DIR="$HOST_PLUGIN_ROOT/$FINGERPRINT"
    # Not inside HOST_PLUGIN_DIR: GStreamer scans that recursively for *.so.
    HOST_LIB_DIR="$HOST_PLUGIN_ROOT/$FINGERPRINT.lib"
    if [ ! -d "$HOST_PLUGIN_DIR" ]; then
        # Only symlinks live here; old fingerprints are just dropped.
        rm -rf "$HOST_PLUGIN_ROOT" 2>/dev/null
        TMP="$HOST_PLUGIN_DIR.tmp$$"
        mkdir -p "$TMP" "$HOST_LIB_DIR" 2>/dev/null
        for o in "${HOST_LIB_OVERRIDES[@]}"; do ln -sfn "${o#* }" "$HOST_LIB_DIR/${o%% *}"; done
        for f in "${FOUND_PLUGINS[@]}"; do ln -sfn "$f" "$TMP/${f##*/}"; done
        mv -T "$TMP" "$HOST_PLUGIN_DIR" 2>/dev/null || rm -rf "$TMP"
    fi
    export GCS_HOST_GST_PLUGIN_DIR="$HOST_PLUGIN_DIR"
    export GST_PLUGIN_PATH_1_0="$HOST_PLUGIN_DIR"
    export GST_PLUGIN_PATH="$HOST_PLUGIN_DIR"
    REGISTRY_NAME="gstreamer-registry-appimage.bin"
else
    unset GCS_HOST_GST_PLUGIN_DIR
    REGISTRY_NAME="gstreamer-registry-appimage-nohost.bin"
fi
# Own registry file, so the host GStreamer's registry is never read or
# overwritten with paths into this (temporary) AppImage mount.
export GST_REGISTRY_1_0="$GCS_CACHE/$REGISTRY_NAME"
export GST_REGISTRY="$GST_REGISTRY_1_0"
# Bundled libraries before the host's: our GStreamer 1.28 core libs
# (libgstreamer, libgstaudio, libgstvideo, ...) must win when a host plugin is
# loaded. Only the host-lib overrides above come first. The host plugins' own
# codec libraries (libavcodec, libx264, ...) are not in the bundle and
# resolve from the host's default library path.
export LD_LIBRARY_PATH="${HOST_LIB_DIR:+$HOST_LIB_DIR:}$HERE/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export QT_PLUGIN_PATH="$HERE/usr/plugins"
export QML2_IMPORT_PATH="$HERE/usr/qml"
export QML_IMPORT_PATH="$HERE/usr/qml"

exec "$HERE/usr/bin/gpu-cine-studio" "$@"
APPRUN_EOF
chmod +x "$APPDIR/AppRun"

echo "Step 7/7: Packaging the AppImage..."
OUTPUT="$BUILD_DIR/gpu-cine-studio-${VERSION}-x86_64.AppImage"
rm -f "$OUTPUT"
ARCH=x86_64 "$TOOLS_DIR/appimagetool-x86_64.AppImage" "$APPDIR" "$OUTPUT"

echo ""
echo "=== Done ==="
echo "AppImage: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
