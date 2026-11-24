import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// "Clip fitting" controls shared by Project Settings (project default) and
// the transform effect's "Fit to frame" row: a Scaling combo, an optional
// one-line explanation of the selected mode and a 3x3 anchor selector.
// Pure view: it only edits its own scaling / anchorH / anchorV properties.
// The maths lives in TimelinePanel.computeFitRect().
Item {
    id: root

    property string scaling: "fill"
    property string anchorH: "center"
    property string anchorV: "center"
    property bool showExplanation: true
    property color textColor: "#eff0f1"
    property color dimColor: "#9a9ca0"
    property color panelColor: "#232629"
    property color borderColor: "#5d6066"
    property color accentColor: "#3daee9"

    readonly property var modes: [
        { id: "fill",    name: "Fill (crop overflow)",
          info: "Scales the image up until it covers the whole frame; whatever sticks out is cropped." },
        { id: "fit",     name: "Fit (show whole image)",
          info: "Scales the image until all of it is visible; the rest of the frame stays empty (black bars)." },
        { id: "width",   name: "Fit width",
          info: "Scales the image to the full frame width; the height follows the aspect ratio and may be cropped or leave bars." },
        { id: "height",  name: "Fit height",
          info: "Scales the image to the full frame height; the width follows the aspect ratio and may be cropped or leave bars." },
        { id: "none",    name: "No scaling (100%)",
          info: "Keeps the source pixel size, positioned by the anchor; larger sources are cropped, smaller ones leave bars." },
        { id: "stretch", name: "Stretch (distort)",
          info: "Stretches the image to exactly the frame size, ignoring its aspect ratio." }
    ]
    readonly property var hIds: ["left", "center", "right"]
    readonly property var vIds: ["top", "center", "bottom"]

    function modeIndex(id) {
        for (var i = 0; i < modes.length; i++) if (modes[i].id === id) return i
        return 1 // unknown -> "fit"
    }

    implicitWidth: layout.implicitWidth
    implicitHeight: layout.implicitHeight

    RowLayout {
        id: layout
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 12

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            spacing: 4

            ComboBox {
                id: scalingCombo
                objectName: "fitScalingCombo"
                Layout.fillWidth: true
                Layout.preferredHeight: 26
                model: root.modes.map(function(m) { return m.name })
                currentIndex: root.modeIndex(root.scaling)
                onActivated: root.scaling = root.modes[currentIndex].id
                contentItem: Text {
                    text: scalingCombo.displayText
                    color: root.textColor
                    font.pixelSize: 11
                    verticalAlignment: Text.AlignVCenter
                    leftPadding: 8
                    elide: Text.ElideRight
                }
                background: Rectangle { color: root.panelColor; border.color: root.borderColor; radius: 2 }
            }
            Label {
                objectName: "fitScalingInfo"
                visible: root.showExplanation
                Layout.fillWidth: true
                text: root.modes[root.modeIndex(root.scaling)].info
                color: root.dimColor
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }
        }

        ColumnLayout {
            Layout.alignment: Qt.AlignTop
            spacing: 2
            Label { text: "Anchor"; color: root.dimColor; font.pixelSize: 10; Layout.alignment: Qt.AlignHCenter }
            Grid {
                columns: 3
                spacing: 2
                Repeater {
                    model: 9
                    delegate: Rectangle {
                        required property int index
                        readonly property string v: root.vIds[Math.floor(index / 3)]
                        readonly property string h: root.hIds[index % 3]
                        readonly property bool on: v === root.anchorV && h === root.anchorH
                        objectName: "fitAnchor_" + v + "_" + h
                        width: 20; height: 20; radius: 2
                        color: on ? root.accentColor : root.panelColor
                        border.color: on ? root.accentColor : root.borderColor
                        Accessible.role: Accessible.Button
                        Accessible.name: "Anchor " + v + " " + h
                        MouseArea {
                            anchors.fill: parent
                            onClicked: { root.anchorH = parent.h; root.anchorV = parent.v }
                        }
                    }
                }
            }
        }
    }
}
