#!/bin/bash
# Quick build script.
#
#   ./build.sh                                  # build against ./gstreamer/install when it exists
#                                               # (scripts/build-gstreamer.sh builds it), else
#                                               # against the GStreamer pkg-config finds
#   GCS_GST_PREFIX=/other/prefix ./build.sh     # build against another private GStreamer prefix
#   GCS_GST_PREFIX= ./build.sh                  # (set but empty) force the pkg-config GStreamer
#   GCS_BUILD_DIR=/tmp/gcs-build ./build.sh     # other build directory (default: ./build)

set -e

cd "$(dirname "$0")"
BUILD_DIR="${GCS_BUILD_DIR:-build}"

# Unset -> default to the project-local prefix if it was built.
if [ -z "${GCS_GST_PREFIX+set}" ] && [ -d gstreamer/install ]; then
    GCS_GST_PREFIX="$PWD/gstreamer/install"
fi

CMAKE_ARGS=()
if [ -n "${GCS_GST_PREFIX:-}" ]; then
    echo "Building against GStreamer prefix: $GCS_GST_PREFIX"
    if [ ! -d "$GCS_GST_PREFIX" ]; then
        echo "FAIL: GCS_GST_PREFIX=$GCS_GST_PREFIX does not exist (scripts/build-gstreamer.sh builds it)." >&2
        exit 1
    fi
    CMAKE_ARGS+=("-DGCS_GST_PREFIX=$(cd "$GCS_GST_PREFIX" && pwd)")
elif [ -n "${GCS_GST_PREFIX+set}" ]; then
    CMAKE_ARGS+=("-DGCS_GST_PREFIX=")   # clear a prefix cached by an earlier configure
fi

cmake -S . -B "$BUILD_DIR" "${CMAKE_ARGS[@]}"
cmake --build "$BUILD_DIR" -j"$(nproc)"

echo ""
echo "Build complete! Run with: ./run_new_gstreamer.sh  (binary: $BUILD_DIR/gpu-cine-studio)"
