#!/usr/bin/env bash
# Build the GStreamer version GPU Cine Studio runs against, with our GES patch
# (patches/*.patch) applied, into a private prefix. The system GStreamer is not
# touched.
#
# Usage: scripts/build-gstreamer.sh [options]
#
#   --src DIR          source checkout       (env GCS_GST_SRC,    default ./gstreamer/src)
#   --build DIR        meson build dir       (env GCS_GST_BUILD,  default <src>/build)
#   --prefix DIR       install prefix        (env GCS_GST_PREFIX, default ./gstreamer/install)
#   --jobs N           parallel build jobs   (env GCS_GST_JOBS,   default: nproc)
#   --enable-patented  also build patent-encumbered / GPL codecs: gst-libav
#                      (FFmpeg), x264, x265, fdk-aac, openh264, voaacenc, faad
#                      (env GCS_GST_PATENTED=1). Off by default.
#   --meson-arg ARG    extra argument for `meson setup` (repeatable; env
#                      GCS_GST_EXTRA_MESON_ARGS, space separated)
#   -h, --help
#
# Safe to re-run: an existing checkout made by this script is reused, patches
# that are already applied are skipped, meson is only reconfigured, ninja only
# rebuilds what changed. A source dir or prefix that this script did NOT create
# (no .gcs-build-gstreamer marker inside) is never modified - the script stops
# instead.

set -euo pipefail

GST_VERSION="1.28.8"
GST_REPO="https://gitlab.freedesktop.org/gstreamer/gstreamer.git"
MARKER=".gcs-build-gstreamer"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCH_DIR="$ROOT/patches"

SRC="${GCS_GST_SRC:-$ROOT/gstreamer/src}"
BUILD="${GCS_GST_BUILD:-}"
PREFIX="${GCS_GST_PREFIX:-$ROOT/gstreamer/install}"
JOBS="${GCS_GST_JOBS:-$(nproc)}"
PATENTED="${GCS_GST_PATENTED:-0}"
# shellcheck disable=SC2206
EXTRA_ARGS=(${GCS_GST_EXTRA_MESON_ARGS:-})

msg()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --src)             SRC="$2"; shift 2 ;;
        --build)           BUILD="$2"; shift 2 ;;
        --prefix)          PREFIX="$2"; shift 2 ;;
        --jobs|-j)         JOBS="$2"; shift 2 ;;
        --enable-patented) PATENTED=1; shift ;;
        --meson-arg)       EXTRA_ARGS+=("$2"); shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        *)                 die "unknown option: $1 (see --help)" ;;
    esac
done

abspath() { mkdir -p "$1" && (cd "$1" && pwd); }

# --- tool check -------------------------------------------------------------
APT_PACKAGES="git build-essential pkg-config ninja-build flex bison nasm python3 python3-pip pipx cmake
libglib2.0-dev libxml2-dev libjson-glib-dev libgudev-1.0-dev libunwind-dev libdw-dev
libx11-dev libxext-dev libxv-dev libxi-dev libxrandr-dev libxdamage-dev libxfixes-dev libx11-xcb-dev
libgl-dev libegl-dev libgles-dev libgbm-dev libdrm-dev libwayland-dev wayland-protocols libxkbcommon-dev
libva-dev libvulkan-dev glslc
libpulse-dev libasound2-dev libjack-jackd2-dev
libcairo2-dev libpango1.0-dev libgdk-pixbuf-2.0-dev libjpeg-dev libpng-dev libwebp-dev libsoup-3.0-dev libssl-dev libcurl4-openssl-dev
libopus-dev libogg-dev libvorbis-dev libflac-dev libmp3lame-dev libmpg123-dev libvpx-dev libbz2-dev zlib1g-dev
qt6-base-dev qt6-base-private-dev qt6-declarative-dev qt6-declarative-private-dev qt6-shadertools-dev qt6-tools-dev-tools qt6-wayland-dev"

missing=()
for tool in git meson ninja pkg-config cc c++ python3; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
    printf 'ERROR: missing tools: %s\n\n' "${missing[*]}" >&2
    printf 'On Ubuntu 24.04 / Linux Mint 22 install the build dependencies with:\n\n' >&2
    printf '  sudo apt install %s\n\n' "$(echo $APT_PACKAGES)" >&2
    printf 'GStreamer %s needs meson >= 1.4 (Ubuntu 24.04 ships 1.3), so install meson with pipx:\n\n' "$GST_VERSION" >&2
    printf '  pipx install meson\n\n' >&2
    exit 1
fi
MESON_VER="$(meson --version)"
if ! printf '1.4.0\n%s\n' "$MESON_VER" | sort -V -C; then
    die "meson $MESON_VER is too old, GStreamer $GST_VERSION needs >= 1.4 (pipx install meson)"
fi

shopt -s nullglob
PATCHES=("$PATCH_DIR"/*.patch)
shopt -u nullglob
[ ${#PATCHES[@]} -gt 0 ] || die "no patches found in $PATCH_DIR"

# --- source -----------------------------------------------------------------
msg "GStreamer $GST_VERSION source: $SRC"
if [ -e "$SRC" ] && [ -n "$(ls -A "$SRC" 2>/dev/null)" ]; then
    [ -f "$SRC/$MARKER" ] || die "$SRC already exists and was not created by this script - refusing to touch it.
       Pass another directory with --src (and --prefix), or remove it yourself."
    tag="$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)"
    [ "$tag" = "$GST_VERSION" ] || die "$SRC is not at tag $GST_VERSION (found: '${tag:-none}')"
    info "reusing existing checkout"
else
    info "cloning $GST_REPO (tag $GST_VERSION)"
    mkdir -p "$(dirname "$SRC")"
    git -c advice.detachedHead=false clone --depth 1 --branch "$GST_VERSION" "$GST_REPO" "$SRC"
    echo "created by GPU Cine Studio scripts/build-gstreamer.sh" > "$SRC/$MARKER"
fi
SRC="$(abspath "$SRC")"
BUILD="${BUILD:-$SRC/build}"

# --- patches ----------------------------------------------------------------
msg "Applying patches"
for p in "${PATCHES[@]}"; do
    name="$(basename "$p")"
    if git -C "$SRC" apply --reverse --check "$p" >/dev/null 2>&1; then
        info "$name: already applied"
    elif git -C "$SRC" apply --check "$p" >/dev/null 2>&1; then
        git -C "$SRC" apply "$p"
        info "$name: applied"
    else
        die "$name does not apply to $SRC (local changes or wrong GStreamer version?)"
    fi
done

# --- prefix -----------------------------------------------------------------
if [ -e "$PREFIX" ] && [ -n "$(ls -A "$PREFIX" 2>/dev/null)" ] && [ ! -f "$PREFIX/$MARKER" ]; then
    die "install prefix $PREFIX already exists and was not created by this script - refusing to install over it.
       Pass another directory with --prefix."
fi
PREFIX="$(abspath "$PREFIX")"
echo "created by GPU Cine Studio scripts/build-gstreamer.sh" > "$PREFIX/$MARKER"

# Debian/Ubuntu multiarch layout (lib/x86_64-linux-gnu) like a default meson
# install on these distros; plain "lib" elsewhere.
MULTIARCH="$(cc -print-multiarch 2>/dev/null || true)"
LIBDIR="lib${MULTIARCH:+/$MULTIARCH}"

# --- configure --------------------------------------------------------------
MESON_ARGS=(
    --prefix="$PREFIX"
    --libdir="$LIBDIR"
    -Dbuildtype=release
    -Dbase=enabled -Dgood=enabled -Dbad=enabled -Dugly=enabled
    -Dges=enabled
    -Dqt6=enabled                  # qml6glsink (preview output)
    # qml6glsink needs the Wayland and X11 platform bindings compiled in (needs
    # qt6-wayland-dev + qt6-base-private-dev); without them it only works on
    # QT_QPA_PLATFORM=xcb. "enabled" makes a missing dependency fail loudly.
    -Dgst-plugins-good:qt-wayland=enabled -Dgst-plugins-good:qt-x11=enabled
    -Dgst-plugins-bad:nvcodec=auto -Dgst-plugins-bad:va=auto
    -Dgst-plugins-bad:frei0r=auto  # frei0r wrapper (colour key effect)
    -Dgst-plugins-good:mpg123=enabled  # MP3 decoder (patent-free); a missing libmpg123-dev fails loudly
    -Ddoc=disabled -Dgtk_doc=disabled -Dorc:hotdoc=disabled
    -Dtests=disabled -Dexamples=disabled -Dgst-examples=disabled
    # Not used by the app; keeps the build shorter and the AppImage smaller.
    -Ddevtools=disabled -Drtsp_server=disabled -Dpython=disabled
    -Dintrospection=disabled -Dlibnice=disabled -Dwebrtc=disabled
)
if [ "$PATENTED" = "1" ]; then
    info "patent-encumbered / GPL codecs: ENABLED (libav, x264, x265, fdk-aac, openh264, ...)"
    MESON_ARGS+=(-Dlibav=enabled -Dgpl=enabled)
else
    info "patent-encumbered / GPL codecs: disabled (use --enable-patented to build them)"
    MESON_ARGS+=(
        -Dlibav=disabled -Dgpl=disabled          # gpl gates x264, x265, faad, mpeg2dec, a52dec, ...
        -Dgst-plugins-bad:fdkaac=disabled
        -Dgst-plugins-bad:openh264=disabled
        -Dgst-plugins-bad:voaacenc=disabled
        -Dgst-plugins-bad:svthevcenc=disabled
    )
fi
MESON_ARGS+=("${EXTRA_ARGS[@]}")

msg "Configuring ($BUILD)"
if [ -f "$BUILD/build.ninja" ]; then
    # --clearcache: meson caches configure-time probes (e.g. a stale
    # "qplatformnativeinterface.h: NO" from before qt6-base-private-dev was installed).
    meson setup --reconfigure --clearcache "${MESON_ARGS[@]}" "$BUILD" "$SRC"
else
    meson setup "${MESON_ARGS[@]}" "$BUILD" "$SRC"
fi

# --- build + install --------------------------------------------------------
msg "Building with $JOBS jobs (this takes a while on the first run)"
ninja -C "$BUILD" -j "$JOBS"

msg "Installing to $PREFIX"
meson install -C "$BUILD" --no-rebuild --quiet

# Sanity check: the patched GES must be what we just installed.
GES_LIB="$(ls "$PREFIX/$LIBDIR"/libges-1.0.so.0.* 2>/dev/null | head -1 || true)"
[ -n "$GES_LIB" ] || die "libges-1.0 was not installed - check the meson output above"
if LC_ALL=C grep -aq "GES_GL_MODE" "$GES_LIB"; then
    info "patched GES installed: $GES_LIB"
else
    die "$GES_LIB does not contain the GL-mode patch"
fi

# Sanity check: qml6glsink must have been built with Wayland support, otherwise
# the video preview is black on QT_QPA_PLATFORM=wayland.
QML6_LIB="$PREFIX/$LIBDIR/gstreamer-1.0/libgstqml6.so"
[ -f "$QML6_LIB" ] || die "$QML6_LIB was not installed (qt6 plugin missing?)"
if nm -D --undefined-only "$QML6_LIB" | grep -q gst_gl_display_wayland_new_with_display; then
    info "qml6glsink has Wayland support: $QML6_LIB"
else
    die "$QML6_LIB lacks Wayland support - install qt6-wayland-dev and qt6-base-private-dev and rebuild"
fi

msg "Done: GStreamer $GST_VERSION in $PREFIX"
cat <<EOF

Build the app against it:
    GCS_GST_PREFIX="$PREFIX" ./build.sh
Run it:
    GCS_GST_PREFIX="$PREFIX" ./run_new_gstreamer.sh
EOF
