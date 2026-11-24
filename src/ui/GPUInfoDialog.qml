import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import VideoEditor 1.0

Window {
    id: gpuInfoWindow
    title: "GPU Information"
    width: 950
    height: 750
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

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Header
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 60
            color: colorPanel

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 15
                spacing: 5

                Text {
                    text: "GPU Information"
                    font.pixelSize: 18
                    font.bold: true
                    color: colorText
                }

                Text {
                    text: "Available GPU devices and hardware codec capabilities"
                    font.pixelSize: 11
                    color: colorSubText
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            height: 2
            color: colorHighlight
        }

        // Content
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: colorBackground

            ScrollView {
                anchors.fill: parent
                anchors.margins: 20
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                ColumnLayout {
                    width: gpuInfoWindow.width - 60
                    spacing: 25

                    // ============ GSTREAMER SECTION ============
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 15

                        // Section Header
                        Rectangle {
                            Layout.fillWidth: true
                            height: 50
                            color: colorPanel
                            border.color: "#27ae60"
                            border.width: 2
                            radius: 5

                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: 15
                                spacing: 10

                                Text {
                                    text: "🎬"
                                    font.pixelSize: 24
                                }

                                Text {
                                    text: "GStreamer Backend"
                                    font.pixelSize: 16
                                    font.bold: true
                                    color: colorText
                                }

                                Item { Layout.fillWidth: true }

                                Text {
                                    text: Backend.gpuDevices.length + " device(s)"
                                    font.pixelSize: 12
                                    color: colorSubText
                                }
                            }
                        }

                        // GStreamer GPU Devices
                        Repeater {
                            model: Backend.gpuDevices

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: deviceColumn.implicitHeight + 30
                                color: colorPanel
                                border.color: colorHighlight
                                border.width: 2
                                radius: 5

                                ColumnLayout {
                                    id: deviceColumn
                                    anchors.fill: parent
                                    anchors.margins: 15
                                    spacing: 12

                                    // Device Header
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 15

                                        Rectangle {
                                            Layout.preferredWidth: 50
                                            Layout.preferredHeight: 50
                                            radius: 25
                                            color: modelData.type === "GPU" ? "#27ae60" : "#95a5a6"

                                            Text {
                                                anchors.centerIn: parent
                                                text: modelData.type === "GPU" ? "🖥️" : "⚙️"
                                                font.pixelSize: 24
                                            }
                                        }

                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 3

                                            Text {
                                                text: modelData.name + " (" + modelData.type + ")"
                                                font.bold: true
                                                font.pixelSize: 16
                                                color: colorText
                                                Layout.fillWidth: true
                                            }

                                            Text {
                                                text: "Vendor: " + modelData.vendor
                                                font.pixelSize: 12
                                                color: colorSubText
                                            }

                                            Text {
                                                text: "Device ID: " + modelData.id
                                                font.pixelSize: 10
                                                color: "#888888"
                                            }
                                        }
                                    }

                                    Rectangle {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 1
                                        color: colorBorder
                                    }

                                    // Encoders Section
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 8

                                        Text {
                                            text: "🎬 Encoders:"
                                            font.bold: true
                                            font.pixelSize: 13
                                            color: colorHighlight
                                        }

                                        Flow {
                                            Layout.fillWidth: true
                                            spacing: 8

                                            Repeater {
                                                model: modelData.encoders

                                                Rectangle {
                                                    width: codecText.width + 20
                                                    height: 28
                                                    color: "#27ae60"
                                                    radius: 4

                                                    Text {
                                                        id: codecText
                                                        anchors.centerIn: parent
                                                        text: modelData
                                                        color: "white"
                                                        font.pixelSize: 12
                                                        font.bold: true
                                                    }
                                                }
                                            }
                                        }

                                        Text {
                                            visible: modelData.encoders.length === 0
                                            text: "No encoders available"
                                            font.italic: true
                                            font.pixelSize: 11
                                            color: "#888888"
                                        }
                                    }

                                    // Decoders Section
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 8

                                        Text {
                                            text: "📹 Decoders:"
                                            font.bold: true
                                            font.pixelSize: 13
                                            color: colorHighlight
                                        }

                                        Flow {
                                            Layout.fillWidth: true
                                            spacing: 8

                                            Repeater {
                                                model: modelData.decoders

                                                Rectangle {
                                                    width: codecTextDec.width + 20
                                                    height: 28
                                                    color: "#2980b9"
                                                    radius: 4

                                                    Text {
                                                        id: codecTextDec
                                                        anchors.centerIn: parent
                                                        text: modelData
                                                        color: "white"
                                                        font.pixelSize: 12
                                                        font.bold: true
                                                    }
                                                }
                                            }
                                        }

                                        Text {
                                            visible: modelData.decoders.length === 0
                                            text: "No decoders available"
                                            font.italic: true
                                            font.pixelSize: 11
                                            color: "#888888"
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ============ FFMPEG SECTION ============
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 15

                        // Section Header
                        Rectangle {
                            Layout.fillWidth: true
                            height: 50
                            color: colorPanel
                            border.color: "#e67e22"
                            border.width: 2
                            radius: 5

                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: 15
                                spacing: 10

                                Text {
                                    text: "🎞️"
                                    font.pixelSize: 24
                                }

                                Text {
                                    text: "FFmpeg Backend"
                                    font.pixelSize: 16
                                    font.bold: true
                                    color: colorText
                                }

                                Item { Layout.fillWidth: true }

                                Text {
                                    text: "Coming soon"
                                    font.pixelSize: 12
                                    color: colorSubText
                                    font.italic: true
                                }
                            }
                        }

                        // Placeholder for FFmpeg
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 100
                            color: colorPanel
                            border.color: "#555555"
                            border.width: 1
                            radius: 5

                            Text {
                                anchors.centerIn: parent
                                text: "FFmpeg backend detection will be implemented soon.\nThis will show NVENC, QSV, AMF, and other FFmpeg encoders."
                                color: colorSubText
                                font.pixelSize: 12
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }

                    Item { Layout.preferredHeight: 20 }
                }
            }
        }

        // Footer
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 60
            color: colorPanel

            RowLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 15

                Text {
                    text: "GStreamer: " + Backend.gpuDevices.length + " device(s) | FFmpeg: Not yet detected"
                    font.pixelSize: 11
                    color: colorSubText
                }

                Item { Layout.fillWidth: true }

                Button {
                    text: "Refresh"
                    onClicked: Backend.detectGPUDevices()
                    background: Rectangle {
                        color: parent.down ? "#4a7ea8" : "#5e92c2"
                        radius: 4
                    }
                    contentItem: Text {
                        text: parent.text
                        color: "white"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Button {
                    text: "Close"
                    onClicked: gpuInfoWindow.close()
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
