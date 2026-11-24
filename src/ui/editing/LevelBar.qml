import QtQuick

// One vertical level bar: dark background, green/yellow/red zones (linear in
// dB over -60..0), and a white hold line.
Item {
    id: bar
    property real db: -90
    property real hold: -90
    width: 7

    readonly property real barH: height
    readonly property real fill: Math.max(0, Math.min(1, (bar.db + 60) / 60)) * barH
    readonly property real gGreen: Math.min(fill, 0.8 * barH)
    readonly property real gYellow: Math.max(0, Math.min(fill, 0.95 * barH) - 0.8 * barH)
    readonly property real gRed: Math.max(0, fill - 0.95 * barH)

    Rectangle { anchors.fill: parent; color: "#15181c"; border.color: "#000000" }
    Rectangle { color: "#12b312"; width: parent.width; height: bar.gGreen;  y: bar.barH - bar.gGreen }
    Rectangle { color: "#d8c21a"; width: parent.width; height: bar.gYellow; y: bar.barH - 0.8 * bar.barH - bar.gYellow }
    Rectangle { color: "#d82a1a"; width: parent.width; height: bar.gRed;    y: bar.barH - 0.95 * bar.barH - bar.gRed }
    Rectangle {
        visible: bar.hold > -60
        color: "#f0f0f0"
        width: parent.width
        height: 2
        y: bar.barH - Math.max(0, Math.min(1, (bar.hold + 60) / 60)) * bar.barH - 1
    }
}
