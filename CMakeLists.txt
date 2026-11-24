cmake_minimum_required(VERSION 3.16)
# C needed for src/core/gl/gstgllut3d.c - a plain-C GStreamer GstGLFilter
# element (GStreamer's own plugin convention is C; no reason to force it
# through a C++ compiler instead).
project(gpu-cine-studio LANGUAGES CXX C)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Date-based version: YYYYMMDD
# Override with: cmake -DBUILD_VERSION=20251125 ..
if(NOT DEFINED BUILD_VERSION)
    # Automatic version from current date
    string(TIMESTAMP PROJECT_VERSION "%Y%m%d" UTC)
    message(STATUS "Auto-generated version: ${PROJECT_VERSION}")
else()
    set(PROJECT_VERSION "${BUILD_VERSION}")
    message(STATUS "Using fixed version: ${PROJECT_VERSION}")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

# Find required packages
find_package(Qt6 REQUIRED COMPONENTS Core Widgets Qml Quick QuickControls2 Multimedia Network DBus)
# libX11 is loaded at runtime (src/core/X11ThreadInit.cpp), not linked: the app
# must start on pure native-Wayland systems without it.
find_package(PkgConfig REQUIRED)

# Optional private GStreamer prefix (e.g. one built by
# scripts/build-gstreamer.sh). -DGCS_GST_PREFIX=... or the GCS_GST_PREFIX
# environment variable; empty = whatever pkg-config finds (system GStreamer,
# or PKG_CONFIG_PATH if you set it yourself). A non-empty environment variable
# wins over the cached value.
set(GCS_GST_PREFIX "" CACHE PATH "GStreamer install prefix to build against (empty = pkg-config default)")
if(NOT "$ENV{GCS_GST_PREFIX}" STREQUAL "")
    set(GCS_GST_PREFIX "$ENV{GCS_GST_PREFIX}" CACHE PATH "GStreamer install prefix to build against (empty = pkg-config default)" FORCE)
endif()
if(GCS_GST_PREFIX)
    file(GLOB _gcs_gst_pc_dirs LIST_DIRECTORIES true
        "${GCS_GST_PREFIX}/lib/*/pkgconfig" "${GCS_GST_PREFIX}/lib64/pkgconfig" "${GCS_GST_PREFIX}/lib/pkgconfig")
    if(NOT _gcs_gst_pc_dirs)
        message(FATAL_ERROR "GCS_GST_PREFIX=${GCS_GST_PREFIX}: no pkgconfig directory found under it")
    endif()
    string(REPLACE ";" ":" _gcs_gst_pc_path "${_gcs_gst_pc_dirs}")
    set(ENV{PKG_CONFIG_PATH} "${_gcs_gst_pc_path}:$ENV{PKG_CONFIG_PATH}")
endif()
# pkg_check_modules() caches its result - redo the lookup when the prefix
# changes between configure runs.
if(NOT "${GCS_GST_PREFIX}" STREQUAL "${_GCS_GST_PREFIX_USED}")
    unset(__pkg_config_checked_GST CACHE)
    set(_GCS_GST_PREFIX_USED "${GCS_GST_PREFIX}" CACHE INTERNAL "")
endif()

pkg_check_modules(GST REQUIRED
    gstreamer-1.0>=1.20
    gstreamer-video-1.0
    gstreamer-gl-1.0
    gstreamer-app-1.0
    gstreamer-pbutils-1.0
    gst-editing-services-1.0
)
message(STATUS "GStreamer ${GST_gstreamer-1.0_VERSION} headers/libs from: ${GST_LIBRARY_DIRS}")

# Source files
set(SOURCES
    src/main.cpp
    src/core/VideoEngine.cpp
    src/core/TimelineEngine.cpp
    src/core/AssetLoader.cpp
    src/core/Timeline.cpp
    src/core/VideoClip.cpp
    src/core/Exporter.cpp
    src/core/ProjectBinModel.cpp
    src/core/MetadataExtractor.cpp
    src/core/BackendManager.cpp
    src/core/RenderEngine.cpp
    src/core/CacheManager.cpp
    src/core/HangWatchdog.cpp
    src/core/ShortcutManager.cpp
    src/core/ScrubAudio.cpp
    src/core/WaveformGenerator.cpp
    src/core/ProxyGenerator.cpp
    src/core/CodecCheck.cpp
    src/core/ProxyAssets.cpp
    src/core/MediaAvailability.cpp
    src/core/GpuLoadMonitor.cpp
    src/core/ClipEffects.cpp
    src/core/TitleClips.cpp
    src/core/KdenliveImporter.cpp
    src/core/GesTransitions.cpp
    src/core/ProfileStore.cpp
    src/core/ProjectSettings.cpp
    src/core/TestApiServer.cpp
    src/core/Theme.cpp
    src/core/ColorSchemeWatcher.cpp
    src/core/X11ThreadInit.cpp
    src/core/gl/gstgllut3d.c
    src/core/gl/gstglcurves.c
    src/core/gl/gstglbrightcontrast.c
    src/ui/VideoOutput.cpp
)

set(HEADERS
    src/core/VideoEngine.h
    src/core/TimelineEngine.h
    src/core/AssetLoader.h
    src/core/Timeline.h
    src/core/VideoClip.h
    src/core/Exporter.h
    src/core/ProjectBinModel.h
    src/core/MetadataExtractor.h
    src/core/BackendManager.h
    src/core/RenderEngine.h
    src/core/CacheManager.h
    src/core/HangWatchdog.h
    src/core/ShortcutManager.h
    src/core/ScrubAudio.h
    src/core/WaveformGenerator.h
    src/core/ProxyGenerator.h
    src/core/ProxyAssets.h
    src/core/MediaAvailability.h
    src/core/GpuLoadMonitor.h
    src/core/ClipEffects.h
    src/core/TitleClips.h
    src/core/KdenliveImporter.h
    src/core/GesTransitions.h
    src/core/ProfileStore.h
    src/core/ProjectSettings.h
    src/core/TestApiServer.h
    src/core/Theme.h
    src/core/ColorSchemeWatcher.h
    src/core/gl/gstgllut3d.h
    src/core/gl/gstglcurves.h
    src/core/gl/gstglbrightcontrast.h
    src/ui/VideoOutput.h
)

# Qt resources
set(RESOURCES
    src/resources.qrc
)

# Executable
add_executable(${PROJECT_NAME}
    ${SOURCES}
    ${HEADERS}
    ${RESOURCES}
)

# Exposed to QML via BackendManager::appVersion() for the title bar.
target_compile_definitions(${PROJECT_NAME} PRIVATE
    APP_VERSION="${PROJECT_VERSION}"
)

# Include directories
target_include_directories(${PROJECT_NAME} PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${GST_INCLUDE_DIRS}
)

# Link libraries
target_link_libraries(${PROJECT_NAME} PRIVATE
    Qt6::Core
    Qt6::Widgets
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::Network
    Qt6::DBus
    ${CMAKE_DL_LIBS}
    ${GST_LIBRARIES}
)

# Add GStreamer library directories
target_link_directories(${PROJECT_NAME} PRIVATE
    ${GST_LIBRARY_DIRS}
)

# Install target
install(TARGETS ${PROJECT_NAME}
    RUNTIME DESTINATION bin
)

# Install desktop file (Linux)
if(UNIX AND NOT APPLE)
    install(FILES packaging/gpu-cine-studio.desktop
        DESTINATION share/applications
    )
    install(FILES packaging/gpu-cine-studio.png
        DESTINATION share/icons/hicolor/256x256/apps
    )
endif()

# CPack configuration for DEB packages
set(CPACK_PACKAGE_NAME "gpu-cine-studio")
set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
set(CPACK_PACKAGE_CONTACT "your-email@example.com")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "GPU Cine Studio - Hardware-accelerated video editor")
set(CPACK_PACKAGE_DESCRIPTION "A lightweight video editor with NVIDIA/Intel/AMD GPU hardware acceleration support for decoding and encoding.")
set(CPACK_DEBIAN_PACKAGE_DEPENDS "libqt6core6, libqt6widgets6, libqt6qml6, libqt6dbus6, libgstreamer1.0-0, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, gstreamer1.0-plugins-bad, gstreamer1.0-gl, frei0r-plugins")
# frei0r-plugins: provides the actual frei0r .so effect libraries (incl.
# select0r, used by the "colorkey" ClipEffects type via gst-plugins-bad's
# frei0r wrapper, gstreamer1.0-plugins-bad's libgstfrei0r.so - that wrapper
# alone does nothing without this package, since it dynamically discovers
# effects from frei0r's own search path (/usr/lib/frei0r-1 by default) at
# runtime rather than linking them in. See TODO.txt.
set(CPACK_DEBIAN_PACKAGE_SECTION "video")
set(CPACK_GENERATOR "DEB")

include(CPack)
