#!/bin/bash
# Build a .deb package for GPU Cine Studio via CPack (see the
# CPACK_* settings at the bottom of CMakeLists.txt for package
# metadata/dependencies).
#
# Usage: ./build_deb.sh [VERSION]
# Example: ./build_deb.sh 20261024

set -e

cd "$(dirname "$0")"

VERSION=${1:-}
CMAKE_VERSION_ARG=""
if [ -n "$VERSION" ]; then
    CMAKE_VERSION_ARG="-DBUILD_VERSION=$VERSION"
    echo "=== Building GPU Cine Studio .deb (version: $VERSION) ==="
else
    echo "=== Building GPU Cine Studio .deb (auto-generated version) ==="
fi

mkdir -p build
cd build
cmake -DCMAKE_BUILD_TYPE=Release $CMAKE_VERSION_ARG ..
make -j"$(nproc)"
cpack -G DEB

echo ""
echo "=== Done ==="
ls -1 ./*.deb
echo ""
echo "Install with: sudo apt install ./build/$(ls -1 *.deb | tail -1)"
