#!/bin/bash
# Launches build/gpu-cine-studio against a locally-built GStreamer prefix
# (default: gstreamer/install/, built by scripts/build-gstreamer.sh) instead of
# the system GStreamer - without touching the system install.
#
# Usage: ./run_new_gstreamer.sh [extra args passed through to the app]
#
# Environment:
#   GCS_GST_PREFIX  GStreamer prefix   (default: ./gstreamer/install)
#   GCS_BUILD_DIR   app build dir      (default: ./build)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GST_PREFIX="${GCS_GST_PREFIX:-$SCRIPT_DIR/gstreamer/install}"
APP="${GCS_BUILD_DIR:-$SCRIPT_DIR/build}/gpu-cine-studio"

if [ ! -d "$GST_PREFIX" ]; then
    echo "FAIL: $GST_PREFIX not found - build GStreamer first (scripts/build-gstreamer.sh)." >&2
    exit 1
fi

if [ ! -x "$APP" ]; then
    echo "FAIL: $APP not found - build the project first (./build.sh)." >&2
    exit 1
fi

# lib/<multiarch> on Debian/Ubuntu, lib64 or lib elsewhere.
GST_LIBDIR=""
for d in "$GST_PREFIX"/lib/*-linux-gnu "$GST_PREFIX/lib64" "$GST_PREFIX/lib"; do
    if [ -e "$d/libgstreamer-1.0.so.0" ]; then GST_LIBDIR="$d"; break; fi
done
if [ -z "$GST_LIBDIR" ]; then
    echo "FAIL: no libgstreamer-1.0.so.0 under $GST_PREFIX/lib*" >&2
    exit 1
fi

export GST_PLUGIN_SYSTEM_PATH_1_0="$GST_LIBDIR/gstreamer-1.0"
export GST_PLUGIN_PATH=
export LD_LIBRARY_PATH="$GST_LIBDIR"

echo "=== Running against GStreamer: $("$GST_PREFIX/bin/gst-inspect-1.0" --version | head -1) ==="
exec "$APP" "$@"
