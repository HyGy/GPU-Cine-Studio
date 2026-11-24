import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import VideoEditor 1.0

Window {
    id: aboutWindow
    title: "About GPU Cine Studio"
    width: 600
    height: 450
    visible: false
    
    // Modális ablak, középre igazítva
    modality: Qt.ApplicationModal
    flags: Qt.Dialog | Qt.WindowStaysOnTopHint

    // Középre igazítás indításkor
    Component.onCompleted: {
        x = (Screen.width - width) / 2
        y = (Screen.height - height) / 2
    }

    // Stílus változók (Breeze Dark)
    readonly property color colorBackground: "#31363b"
    readonly property color colorPanel: "#232629"
    readonly property color colorText: "#eff0f1"
    readonly property color colorHighlight: "#3daee9"
    readonly property color colorBorder: "#5d6066"
    readonly property color colorSubText: "#aaaaaa"

    color: colorBackground

    // Egyedi Tab Gomb stílus
    component StyledTabButton : TabButton {
        id: control
        contentItem: Text {
            text: control.text
            font.pixelSize: 13
            color: control.checked ? colorText : colorSubText
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        background: Rectangle {
            color: "transparent"
            Rectangle {
                width: parent.width
                height: 2
                anchors.bottom: parent.bottom
                color: colorHighlight
                visible: control.checked
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // 1. TABS
        TabBar {
            id: tabBar
            Layout.fillWidth: true
            background: Rectangle { color: colorPanel }
            
            StyledTabButton { text: "About" }
            StyledTabButton { text: "Components" }
            StyledTabButton { text: "Legal & Codecs" }
        }

        // 2. CONTENT
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: colorBackground
            
            StackLayout {
                anchors.fill: parent
                anchors.margins: 20
                currentIndex: tabBar.currentIndex

                // --- TAB 1: ABOUT ---
                ColumnLayout {
                    spacing: 15
                    
                    // Logo Image
                    Image {
                        Layout.alignment: Qt.AlignHCenter
                        source: "qrc:/icons/app_icon.svg"
                        sourceSize.width: 96
                        sourceSize.height: 96
                        width: 96
                        height: 96
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                    }

                    Text {
                        text: "GPU Cine Studio"
                        font.pixelSize: 24
                        font.bold: true
                        color: colorText
                        Layout.alignment: Qt.AlignHCenter
                    }

                    Text {
                        text: "Version 1.0.0 (Alpha)"
                        font.pixelSize: 12
                        color: colorSubText
                        Layout.alignment: Qt.AlignHCenter
                    }

                    Rectangle { Layout.fillWidth: true; height: 1; color: colorBorder; Layout.margins: 10 }

                    Text {
                        text: "A high-performance, hardware-accelerated video editor designed for modern workflows. Built with Qt 6 and GStreamer."
                        color: colorText
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignHCenter
                        Layout.fillWidth: true
                        Layout.maximumWidth: 400
                        Layout.alignment: Qt.AlignHCenter
                    }

                    Text {
                        text: "Video output: " + Backend.videoOutputMethod
                        font.pixelSize: 11
                        color: colorSubText
                        Layout.alignment: Qt.AlignHCenter
                    }

                    Text {
                        visible: Backend.videoOutputFallback
                        text: "⚠ qml6glsink is unavailable in this GStreamer build - using the native-window fallback."
                        font.pixelSize: 11
                        color: "#e0a030"
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignHCenter
                        Layout.fillWidth: true
                        Layout.maximumWidth: 400
                        Layout.alignment: Qt.AlignHCenter
                    }

                    Item { Layout.fillHeight: true } // Spacer

                    Text {
                        text: "© 2025-2026 hygy - free software under the GNU GPL v3 or later.\nThis program comes with ABSOLUTELY NO WARRANTY."
                        font.pixelSize: 11
                        color: colorSubText
                        horizontalAlignment: Text.AlignHCenter
                        Layout.alignment: Qt.AlignHCenter
                    }
                }

                // --- TAB 2: COMPONENTS ---
                ListView {
                    clip: true
                    // Qt/GStreamer versions are read live from the running
                    // process (Backend.qtVersion/gstreamerVersion) rather
                    // than hand-maintained strings here, which drifted out
                    // of date at the last several version bumps.
                    model: ListModel {
                        id: componentsModel
                        ListElement { name: "GPU Cine Studio"; ver: ""; lic: "GPL v3 or later" }
                        ListElement { name: "Qt Framework"; ver: ""; lic: "LGPL v3" }
                        ListElement { name: "GStreamer"; ver: ""; lic: "LGPL v2.1+" }
                        ListElement { name: "GES (patched)"; ver: ""; lic: "LGPL v2.1+" }
                        ListElement { name: "Breeze Icons"; ver: "5.100"; lic: "LGPL v3" }
                    }
                    Component.onCompleted: {
                        componentsModel.setProperty(0, "ver", Backend.appVersion)
                        componentsModel.setProperty(1, "ver", Backend.qtVersion)
                        componentsModel.setProperty(2, "ver", Backend.gstreamerVersion)
                        componentsModel.setProperty(3, "ver", Backend.gstreamerVersion)
                    }

                    footer: ColumnLayout {
                        width: parent ? parent.width : 0
                        spacing: 4

                        Item { Layout.preferredHeight: 10 }

                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "Video output: " + Backend.videoOutputMethod
                            font.pixelSize: 11
                            color: colorSubText
                        }

                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.fillWidth: true
                            Layout.maximumWidth: 400
                            visible: Backend.videoOutputFallback
                            text: "⚠ qml6glsink is unavailable in this GStreamer build - using the native-window fallback."
                            font.pixelSize: 11
                            color: "#e0a030"
                            wrapMode: Text.WordWrap
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }

                    delegate: Rectangle {
                        width: parent.width
                        height: 40
                        color: "transparent"
                        
                        RowLayout {
                            anchors.fill: parent
                            spacing: 10
                            
                            Text { 
                                text: "• " + model.name
                                color: colorText
                                font.bold: true
                                Layout.preferredWidth: 150
                            }
                            
                            Text { 
                                text: model.ver
                                color: colorSubText
                                Layout.preferredWidth: 80
                            }
                            
                            Item { Layout.fillWidth: true }
                            
                            Text { 
                                text: model.lic
                                color: colorHighlight
                                font.pixelSize: 11
                            }
                        }
                        
                        Rectangle { 
                            width: parent.width; height: 1; color: "#3d4248"
                            anchors.bottom: parent.bottom 
                        }
                    }
                }

                // --- TAB 3: LEGAL & CODECS ---
                ScrollView {
                    id: legalScrollView
                    clip: true
                    contentWidth: availableWidth 
                    
                    ColumnLayout {
                        width: legalScrollView.availableWidth
                        spacing: 12

                        Text {
                            text: "License"
                            font.pixelSize: 16
                            font.bold: true
                            color: colorHighlight
                        }

                        Text {
                            text: "GPU Cine Studio is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version (GPL-3.0-or-later). It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the LICENSE file shipped with the source code, or https://www.gnu.org/licenses/gpl-3.0.html.\n\n" +
                                  "The app runs on a patched GStreamer Editing Services library (LGPL-2.1-or-later); the patch is published in the source repository under patches/."
                            color: colorText
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }

                        Rectangle { Layout.fillWidth: true; height: 1; color: colorBorder }

                        Text {
                            text: "Codec & Licensing Strategy"
                            font.pixelSize: 16
                            font.bold: true
                            color: colorHighlight
                        }

                        Text {
                            text: "GPU Cine Studio is built directly on GStreamer/GStreamer Editing Services (GES) - there is no external FFmpeg process. The app itself contains no codec implementations; it only calls GStreamer plugins, preferring hardware-accelerated ones when available."
                            color: colorText
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }

                        Rectangle { Layout.fillWidth: true; height: 1; color: colorBorder }

                        // 1. Playback
                        Text { text: "1. Playback (Decoding)"; color: colorText; font.bold: true }
                        Text {
                            text: "• All decoding goes through GStreamer's decodebin, selecting whatever plugins are installed on your system - the application does not bundle or choose codecs itself.\n" +
                                  "• Hardware Acceleration: preferred by default (NVIDIA NVDEC / Intel VA-API). This is covered by the license included with your GPU driver.\n" +
                                  "• Software decoding (H.264/H.265/AAC): provided by your distribution's GStreamer codec packages (gst-libav, OpenH264, ...), not by this application."
                            color: colorSubText
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                            leftPadding: 10
                        }

                        // 2. Export
                        Text { text: "2. Rendering (Encoding)"; color: colorText; font.bold: true }
                        Text {
                            text: "• Rendering goes directly through GES's encoding profile API (GstEncodingProfile), driving GStreamer encoder plugins in-process - no external FFmpeg call.\n" +
                                  "• Hardware encoders preferred: NVENC (nvh264enc/nvh265enc) or VA-API (vah264enc/vah265enc), covered by your GPU driver's license.\n" +
                                  "• MP4 audio (AAC) and the software H.264/H.265 fallback (x264enc/x265enc/openh264enc) come from your distribution's packages too - same \"your own system, your own license\" model as decoding. MKV/WebM renders use Opus audio, which is bundled."
                            color: colorSubText
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                            leftPadding: 10
                        }

                        Rectangle { Layout.fillWidth: true; height: 1; color: colorBorder }

                        // 3. AppImage packaging
                        Text { text: "3. AppImage Packaging"; color: colorText; font.bold: true }
                        Text {
                            text: "• The AppImage bundles its own GStreamer build (including the patched GES) but deliberately EXCLUDES patent-encumbered software codec plugins (libav/FFmpeg, x264, x265, OpenH264, fdk-aac, faad) - bundling and redistributing those ourselves would require our own patent licensing.\n" +
                                  "• Instead it loads exactly these codec plugins from your distribution's own GStreamer packages (a fixed whitelist; the rest of the host's GStreamer is never mixed in). The codecs are then provided by your distribution, exactly as for any other GStreamer application on your system.\n" +
                                  "• GPU-vendor plugins (NVENC/NVDEC, VA-API) remain bundled - the codec work is done by the GPU and its driver.\n" +
                                  "• File > Settings > Codecs shows what is available and the install command for your distribution (e.g. gstreamer1.0-libav + gstreamer1.0-plugins-ugly on Ubuntu/Debian)."
                            color: colorSubText
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                            leftPadding: 10
                        }

                        Rectangle { Layout.fillWidth: true; height: 1; color: colorBorder }

                        Text {
                            text: "This project is a hobby project provided as-is, without warranty. It is your responsibility to ensure any codecs active on your system are properly licensed for your use case."
                            color: colorSubText
                            font.italic: true
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }
                    }
                }
            }
        }

        // 3. FOOTER
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 50
            color: colorPanel
            
            RowLayout {
                anchors.centerIn: parent
                
                Button {
                    text: "Close"
                    onClicked: aboutWindow.close()
                    background: Rectangle {
                        color: parent.down ? "#2a9ad0" : colorHighlight
                        radius: 4
                    }
                    contentItem: Text { 
                        text: parent.text
                        color: "white"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }
}
