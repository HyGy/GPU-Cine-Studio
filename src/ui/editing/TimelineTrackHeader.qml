import QtQuick
import QtQuick.Controls
import VideoEditor 1.0

Rectangle {
    id: trackHeader

    // Parent references
    property var tracks
    property var contentList
    property var timeline

    width: 150
    height: 60
    color: headerColor
    border.color: palette.base
    border.width: 1

    readonly property bool isVideoTrack: model.type === "video"
    // Active track (TimelinePanel.activeTrackId): lighter header + accent bar.
    readonly property bool isActiveTrack: !!timeline && timeline.activeTrackId === model.trackId
    readonly property color headerColor: isActiveTrack ? Qt.lighter(palette.button, 1.35) : palette.button
    // Video rows carry "hidden" (eye), audio rows carry "muted" (speaker).
    // These are two independent flags on two independent track rows, which
    // is exactly what makes a linked A/V pair decouple: hiding V1 does not
    // touch A1's "muted", and muting A1 does not touch V1's "hidden".
    readonly property bool trackOff: isVideoTrack ? (model.hidden === true)
                                                  : (model.muted === true)

    Accessible.role: Accessible.Pane
    Accessible.name: "Track header " + model.trackId

    MouseArea {
        anchors.fill: parent
        onClicked: {
            if (contentList) contentList.currentIndex = index
            if (timeline) timeline.setActiveTrack(model.trackId)
        }
    }

    Column {
        anchors.fill: parent

        Rectangle {
            width: parent.width
            height: 30
            color: trackHeader.headerColor

            Text {
                x: 5
                anchors.verticalCenter: parent.verticalCenter
                text: model.trackId
                color: model.type === "video" ? "#4a9eff" : "#ff9e4a"
                font.bold: true
            }

            // Hide (video) / mute (audio) toggle.
            Item {
                id: toggleButton
                width: 24
                height: 24
                anchors.right: parent.right
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter

                Accessible.role: Accessible.CheckBox
                Accessible.name: (trackHeader.isVideoTrack ? "Hide video track "
                                                           : "Mute audio track ") + model.trackId
                Accessible.checked: trackHeader.trackOff

                Rectangle {
                    anchors.fill: parent
                    radius: 3
                    color: toggleMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
                }

                Text {
                    id: toggleGlyph
                    anchors.centerIn: parent
                    // Eye for video rows, speaker for audio rows. The
                    // "off" state is drawn as the same glyph dimmed with a
                    // slash through it (below) rather than a different
                    // glyph, so the two states line up pixel-for-pixel and
                    // the row doesn't visually jump when toggled.
                    text: trackHeader.isVideoTrack ? "\u{1F441}" : "\u{1F50A}"
                    font.pixelSize: 13
                    opacity: trackHeader.trackOff ? 0.45 : 1.0
                }

                // Diagonal "disabled" slash, shown only when off.
                Rectangle {
                    visible: trackHeader.trackOff
                    anchors.centerIn: parent
                    width: 22
                    height: 2
                    radius: 1
                    rotation: -45
                    color: "#ff5555"
                }

                MouseArea {
                    id: toggleMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        if (!timeline) return
                        if (trackHeader.isVideoTrack)
                            timeline.setTrackHidden(index, !trackHeader.trackOff)
                        else
                            timeline.setTrackMuted(index, !trackHeader.trackOff)
                    }
                }

                ToolTip.visible: toggleMouse.containsMouse
                ToolTip.delay: 600
                ToolTip.text: trackHeader.isVideoTrack
                    ? (trackHeader.trackOff ? "Show this video track"
                                            : "Hide this video track (its linked audio keeps playing)")
                    : (trackHeader.trackOff ? "Unmute this audio track"
                                            : "Mute this audio track (its linked video stays visible)")
            }
        }

        Rectangle {
            width: parent.width
            height: 30
            color: palette.window

            TextInput {
                anchors.fill: parent
                anchors.margins: 3
                text: model.name || model.trackId
                color: "#ccc"
                selectByMouse: true
                onActiveFocusChanged: if (activeFocus && timeline) timeline.setActiveTrack(model.trackId)
                // Enter commits (editingFinished) and ends editing; Esc
                // restores the shown name and ends editing.
                onAccepted: Backend.shortcuts.releaseTextFocus()
                Keys.onEscapePressed: {
                    text = model.name || model.trackId
                    Backend.shortcuts.releaseTextFocus()
                }
                onEditingFinished: {
                    if (!tracks) return
                    // Focus loss with no change. The field shows the track id
                    // when the track has no name - leaving it unchanged must
                    // not "rename" the track to its own id.
                    if (text === (model.name || "") || (!model.name && text === model.trackId)) return
                    if (timeline) timeline.beginUndoableEdit()
                    tracks.setProperty(index, "name", text)
                    if (timeline) timeline.commitUndoableEdit("Rename track")
                }
            }
        }
    }

    // Active-track marker: accent bar on the left edge.
    Rectangle {
        visible: trackHeader.isActiveTrack
        x: 0
        y: 0
        width: 4
        height: parent.height
        color: "#3daee9"
    }
}
