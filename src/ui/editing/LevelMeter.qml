import QtQuick
import QtQuick.Layouts

// Stereo level meter. Vertical bars, -60..0 dB, linear in dB, with a small
// scale on the left. Values arrive from the engine's "level" element every
// 50 ms; no animations (see plan C1.4).
Item {
    id: meter
    property real peakL: -90
    property real peakR: -90
    property real holdL: -90
    property real holdR: -90

    function decayToSilence() {
        peakL = -90; peakR = -90; holdL = -90; holdR = -90
    }

    implicitWidth: 42

    Row {
        anchors.fill: parent
        spacing: 3

        // dB scale (left of the bars)
        Item {
            width: 22
            height: parent.height
            Repeater {
                model: [0, -6, -12, -18, -24, -30, -36, -42, -48]
                delegate: Item {
                    width: 22
                    height: 1
                    y: (1 - (modelData + 60) / 60) * (meter.height - 2)
                    Rectangle {
                        width: 4; height: 1; color: "#b0b0b0"
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: modelData
                        color: "#b0b0b0"
                        font.pixelSize: 9
                        x: 6
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }

        // The two bars
        Row {
            spacing: 2
            height: parent.height

            LevelBar { height: parent.height; db: meter.peakL; hold: meter.holdL }
            LevelBar { height: parent.height; db: meter.peakR; hold: meter.holdR }
        }
    }
}
