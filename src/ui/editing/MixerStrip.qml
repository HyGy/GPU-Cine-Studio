import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// One mixer channel strip (Kdenlive-style): name box, M/S buttons, pan row,
// stereo meter + fader, editable dB field. Used for tracks and Master.
Item {
    id: root
    width: 84

    property string title: ""
    property bool isMaster: false
    property real gain: 1.0            // linear, committed value
    property bool muted: false
    property bool solo: false
    property real pan: 0.0             // -1..1
    property bool panEnabled: false
    property real peakL: -90
    property real peakR: -90
    property real holdL: -90
    property real holdR: -90
    property color titleColor: "white"
    // Handle height, duplicated in the tick formula below: reading
    // fader.handle.height from a Repeater delegate triggers a QML binding
    // loop (lazily created Control child + re-polish during layout).
    readonly property real handleH: 30

    signal gainLive(real gain)
    signal gainCommitted(real gain)
    signal muteToggled()
    signal soloToggled()
    signal panLive(real pan)
    signal panCommitted(real pan)
    signal interactionFinished()

    // Fader scale labels are dropped when they would overlap (short fader):
    // keeps the first label, then only those >= 11 px below the last shown.
    function scaleLabelShown(db, areaH) {
        var order = [12, 6, 0, -6, -12, -24, -36, -48]
        var ppd = Math.max(1, areaH - handleH) / 72
        var last = -1000
        for (var i = 0; i < order.length; i++) {
            var y = (12 - order[i]) * ppd
            var show = (y - last >= 11)
            if (show) last = y
            if (order[i] === db) return show
        }
        return false
    }
    function dbToGain(db) { return (db <= -60) ? 0 : Math.pow(10, db / 20) }
    function gainToDb(g) { return (g <= 0.001) ? -60 : Math.max(-60, Math.min(12, 20 * Math.log(g) / Math.LN10)) }
    function dispText() {
        var g = fader.pressed ? dbToGain(fader.value) : root.gain
        if (g <= 0.001) return "-inf"
        return Number(root.gainToDb(g)).toLocaleString(Qt.locale(), 'f', 2)
    }

    ColumnLayout {
        anchors.fill: parent
        // 2 px inset per side: neighbouring strips get a visible 4 px gap
        // instead of touching borders and run-together "R"/"L" pan labels.
        anchors.leftMargin: 2
        anchors.rightMargin: 2
        spacing: 3

        // 1. Name box
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 26
            color: "#1b1e22"
            border.color: "#3a3f44"
            border.width: 1
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 3; color: "#e8e8e8" }
            Text {
                anchors.fill: parent
                anchors.margins: 3
                text: root.title
                color: root.titleColor
                font.pixelSize: 11
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
        }

        // 2. M / S buttons
        RowLayout {
            Layout.fillWidth: true
            spacing: 3
            Button {
                objectName: "mixerMute_" + root.title
                Layout.fillWidth: true
                Layout.preferredHeight: 22
                text: "M"
                focusPolicy: Qt.NoFocus
                ToolTip.visible: hovered
                ToolTip.text: "Mute"
                onClicked: root.muteToggled()
                background: Rectangle {
                    radius: 2
                    color: root.muted ? "#c0392b" : "#2a2e33"
                    border.color: "#3a3f44"
                }
                contentItem: Text {
                    text: parent.text
                    color: root.muted ? "white" : "#cfcfcf"
                    font.bold: root.muted
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
            Button {
                Layout.fillWidth: true
                Layout.preferredHeight: 22
                visible: !root.isMaster
                text: "S"
                focusPolicy: Qt.NoFocus
                ToolTip.visible: hovered
                ToolTip.text: "Solo"
                onClicked: root.soloToggled()
                background: Rectangle {
                    radius: 2
                    color: root.solo ? "#d4a017" : "#2a2e33"
                    border.color: "#3a3f44"
                }
                contentItem: Text {
                    text: parent.text
                    color: root.solo ? "black" : "#cfcfcf"
                    font.bold: root.solo
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }

        // 3. Pan row. The Master strip has no pan but keeps the (invisible,
        // inert) row so its meter/fader line up with the track strips.
        ColumnLayout {
            Layout.fillWidth: true
            visible: root.panEnabled || root.isMaster
            opacity: root.panEnabled ? 1 : 0
            enabled: root.panEnabled
            spacing: 2
            Slider {
                id: panSlider
                Layout.fillWidth: true
                Layout.preferredHeight: 18
                from: -100; to: 100; stepSize: 1
                focusPolicy: Qt.NoFocus
                // Bipolar look: fill runs from the centre mark to the handle
                // (the default style fills from the left edge, which reads as
                // a 0..100 level).
                readonly property real hw: 10
                background: Rectangle {
                    x: panSlider.leftPadding
                    y: panSlider.topPadding + panSlider.availableHeight / 2 - height / 2
                    width: panSlider.availableWidth
                    height: 4
                    radius: 2
                    color: "#2a2e33"
                    Rectangle {
                        readonly property real cx: panSlider.visualPosition * (panSlider.availableWidth - panSlider.hw) + panSlider.hw / 2
                        x: Math.min(cx, parent.width / 2)
                        width: Math.abs(cx - parent.width / 2)
                        height: parent.height
                        radius: 2
                        color: "#3daee9"
                    }
                    Rectangle {
                        x: parent.width / 2 - 0.5
                        y: -3
                        width: 1
                        height: parent.height + 6
                        color: "#8a8a8a"
                    }
                }
                handle: Rectangle {
                    x: panSlider.leftPadding + panSlider.visualPosition * (panSlider.availableWidth - width)
                    y: panSlider.topPadding + panSlider.availableHeight / 2 - height / 2
                    width: panSlider.hw
                    height: 14
                    radius: 2
                    color: "#d9d9d9"
                    border.color: "#8a8a8a"
                }
                Binding { target: panSlider; property: "value"; value: root.pan * 100; when: !panSlider.pressed; restoreMode: Binding.RestoreNone }
                onMoved: root.panLive(value / 100)
                onPressedChanged: {
                    if (!pressed) { root.panCommitted(value / 100); root.interactionFinished() }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 2
                Text { text: "L"; color: "#b0b0b0"; font.pixelSize: 9 }
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 18
                    color: "#1b1e22"; border.color: "#3a3f44"; radius: 2
                    Text {
                        anchors.centerIn: parent
                        text: Math.round(root.pan * 100)
                        color: "white"; font.pixelSize: 10
                    }
                    MouseArea {
                        anchors.fill: parent
                        onDoubleClicked: { root.panCommitted(0); root.interactionFinished() }
                    }
                }
                Text { text: "R"; color: "#b0b0b0"; font.pixelSize: 9 }
            }
        }

        // 4. Main area: stereo meter + fader (with scale)
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 2

            LevelMeter {
                Layout.preferredWidth: 36
                Layout.fillHeight: true
                peakL: root.peakL
                peakR: root.peakR
                holdL: root.holdL
                holdR: root.holdR
            }

            Item {
                id: faderArea
                Layout.fillWidth: true
                Layout.fillHeight: true

                Slider {
                    id: fader
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 22
                    orientation: Qt.Vertical
                    from: -60; to: 12; stepSize: 0.5
                    focusPolicy: Qt.NoFocus
                    background: Rectangle {
                        x: (parent.width - 4) / 2
                        width: 4
                        height: parent.height
                        color: "#2a2e33"
                    }
                    handle: Rectangle {
                        width: 18
                        height: root.handleH
                        // The style normally supplies these two bindings; a
                        // custom handle must position itself.
                        x: (fader.availableWidth - width) / 2
                        y: fader.topPadding + fader.visualPosition * (fader.availableHeight - height)
                        color: "#d9d9d9"
                        border.color: "#8a8a8a"
                        border.width: 1
                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width - 4
                            height: 2
                            color: "#333333"
                        }
                    }
                    Binding {
                        target: fader
                        property: "value"
                        value: root.gainToDb(root.gain)
                        when: !fader.pressed
                        restoreMode: Binding.RestoreNone
                    }
                    onMoved: root.gainLive(root.dbToGain(value))
                    onPressedChanged: {
                        if (!pressed) { root.gainCommitted(root.dbToGain(value)); root.interactionFinished() }
                    }
                }

                // Scale beside the fader, aligned to the handle centre.
                Repeater {
                    model: [12, 6, 0, -6, -12, -24, -36, -48]
                    delegate: Item {
                        x: 0
                        width: parent.width - fader.width - 2
                        height: 1
                        y: fader.topPadding + root.handleH / 2
                           + (1 - (modelData - fader.from) / (fader.to - fader.from))
                             * (parent.height - fader.topPadding - fader.bottomPadding - root.handleH)
                        Rectangle { width: 5; height: 1; color: "#b0b0b0"; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: modelData; color: "#b0b0b0"; font.pixelSize: 9; x: 7; anchors.verticalCenter: parent.verticalCenter
                               visible: root.scaleLabelShown(modelData, faderArea.height) }
                    }
                }

                // Double click anywhere on the scale area resets to 0 dB.
                MouseArea {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: parent.width - fader.width - 2
                    onDoubleClicked: { root.gainCommitted(1.0); root.interactionFinished() }
                }
            }
        }

        // 5. Editable dB field
        RowLayout {
            Layout.fillWidth: true
            spacing: 2
            TextField {
                id: dbField
                Layout.fillWidth: true
                Layout.preferredHeight: 24
                horizontalAlignment: TextInput.AlignRight
                selectByMouse: true
                color: "white"
                font.pixelSize: 11
                background: Rectangle { color: "#1b1e22"; border.color: "#3a3f44"; radius: 2 }
                Binding {
                    target: dbField
                    property: "text"
                    value: root.dispText()
                    when: !dbField.activeFocus
                    restoreMode: Binding.RestoreNone
                }
                onEditingFinished: {
                    var t = text.trim().replace(",", ".")
                    var g
                    if (t === "-inf" || t === "-∞") g = 0
                    else {
                        var v = parseFloat(t)
                        if (!isFinite(v)) { text = root.dispText(); root.interactionFinished(); return }
                        v = Math.max(-60, Math.min(12, v))
                        g = (v <= -60) ? 0 : Math.pow(10, v / 20)
                    }
                    root.gainCommitted(g)
                    root.interactionFinished()
                }
                Keys.onEscapePressed: { text = root.dispText(); root.interactionFinished() }
            }
            Text { text: "dB"; color: "#b0b0b0"; font.pixelSize: 10 }
        }
    }
}
