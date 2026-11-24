import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import VideoEditor 1.0

Row {
    id: toolbar

    property var timeline
    property var tracks
    property int currentTrackIndex: -1
    property real mouseTimeSeconds: 0.0
    property int frameRate: 25

    function formatTimecode(seconds) {
        var totalFrames = Math.floor(seconds * frameRate)
        var frames = totalFrames % frameRate
        var totalSecs = Math.floor(seconds)
        var secs = totalSecs % 60
        var mins = Math.floor(totalSecs / 60) % 60
        var hours = Math.floor(totalSecs / 3600)
        return String(hours).padStart(2, '0') + ":" +
               String(mins).padStart(2, '0') + ":" +
               String(secs).padStart(2, '0') + ":" +
               String(frames).padStart(2, '0')
    }

    // Key hint from the shortcut registry (Settings -> Keyboard): " (S)",
    // or "" when the action is unbound. Reading revision makes the tooltip
    // bindings follow a rebind.
    function keyHint(id, suffix) {
        var t = Backend.shortcuts.revision >= 0 ? Backend.shortcuts.displayText(id) : ""
        return t ? " (" + t + (suffix || "") + ")" : ""
    }

    spacing: 5

    // Add Track
    Button {
        focusPolicy: Qt.NoFocus
        text: "+ Track"
        height: 25
        onClicked: addTrackDialog.open()
    }

    Dialog {
        id: addTrackDialog
        title: "Add Track"
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        anchors.centerIn: Overlay.overlay
        width: 260

        ColumnLayout {
            spacing: 8
            width: parent.width

            Label { text: "Type:"; color: "white" }
            ComboBox {
                id: trackTypeCombo
                model: ["Video", "Audio", "AV"]
                Layout.fillWidth: true
            }

            Label { text: "Name (optional):"; color: "white" }
            TextField {
                id: trackNameField
                placeholderText: "Track name"
                Layout.fillWidth: true
            }
        }

        onAccepted: {
            if (timeline) timeline.beginUndoableEdit()
            var typeStr = trackTypeCombo.currentText
            var newName = trackNameField.text || ""

            if (typeStr === "Video" || typeStr === "AV") {
                // Find max video number
                var mv = 0
                for (var i = 0; i < tracks.count; i++) {
                    if (tracks.get(i).type === "video") {
                        var vn = parseInt(tracks.get(i).trackId.substring(1))
                        if (!isNaN(vn) && vn > mv) mv = vn
                    }
                }
                var videoId = "V" + (mv + 1)
                tracks.insert(0, {trackId: videoId, type: "video", name: newName, disabled: false, hidden: false, muted: false, volume: 1.0, solo: false, pan: 0.0, locked: false})
            }

            if (typeStr === "Audio" || typeStr === "AV") {
                // Find max audio number
                var ma = 0
                for (var j = 0; j < tracks.count; j++) {
                    if (tracks.get(j).type === "audio") {
                        var an = parseInt(tracks.get(j).trackId.substring(1))
                        if (!isNaN(an) && an > ma) ma = an
                    }
                }
                var audioId = "A" + (ma + 1)
                tracks.append({trackId: audioId, type: "audio", name: newName, disabled: false, hidden: false, muted: false, volume: 1.0, solo: false, pan: 0.0, locked: false})
            }

            Backend.logOperation("track_add", { type: typeStr, name: newName })
            if (timeline) timeline.commitUndoableEdit("Add track")

            trackNameField.text = ""
            trackTypeCombo.currentIndex = 0
        }

        onRejected: {
            trackNameField.text = ""
            trackTypeCombo.currentIndex = 0
        }
    }

    // Delete Track
    Button {
        focusPolicy: Qt.NoFocus
        text: "- Del"
        height: 25
        enabled: currentTrackIndex >= 0
        onClicked: {
            deleteTrackWindow.visible = true
            deleteTrackWindow.raise()
            deleteTrackWindow.requestActivate()
        }
    }

    // A real top-level Window, not a Quick-scene Dialog - a Dialog/Popup
    // centered anywhere in the main window can end up rendering behind
    // the Project/Source Monitor's native video child window (GStreamer's
    // video-overlay embedding always composites above the whole Quick
    // scene in the window manager's stacking order), and panel layout
    // can shift with window size, so there's no position that's
    // guaranteed safe for a Popup living in the same Quick scene as the
    // video area. Same fix/reasoning as TimelinePanel.qml's
    // splitBlockedWindow.
    Window {
        id: deleteTrackWindow
        title: "Delete track"
        modality: Qt.ApplicationModal
        flags: Qt.Dialog
        width: 360
        height: 160
        visible: false
        color: palette.window

        property var mainWin: toolbar.Window.window
        transientParent: mainWin
        x: mainWin ? mainWin.x + (mainWin.width - width) / 2 : 100
        y: mainWin ? mainWin.y + (mainWin.height - height) / 2 : 100

        function confirmDelete() {
            if (currentTrackIndex < 0 || currentTrackIndex >= tracks.count) {
                deleteTrackWindow.visible = false
                return
            }
            if (timeline) timeline.beginUndoableEdit()
            var removedTrackId = tracks.get(currentTrackIndex).trackId
            Backend.logOperation("track_delete", { trackId: removedTrackId })

            // Clips on the deleted track would otherwise stay in
            // clipsModel, render stacked on the top track (any unknown
            // trackId resolves to y=0), and keep playing in GES - removing
            // the track itself never used to touch its clips at all.
            if (timeline && timeline.clipsModel) {
                for (var i = timeline.clipsModel.count - 1; i >= 0; i--) {
                    if (timeline.clipsModel.get(i).trackId === removedTrackId) {
                        timeline.clipsModel.remove(i)
                    }
                }
            }

            tracks.remove(currentTrackIndex)
            currentTrackIndex = -1

            if (timeline && timeline.updateTimelineEngine) {
                timeline.updateTimelineEngine()
            }

            // The clip/transition/overlap index (TimelinePanel.rebuildClipIndex())
            // is only rebuilt by checkAllClipNeighbors() - without this, the
            // index still holds entries for the clips just removed above,
            // leaving stale wall/overlap data for the surviving clips until
            // some unrelated edit happened to trigger a rebuild.
            if (timeline && timeline.checkAllClipNeighbors) {
                timeline.checkAllClipNeighbors()
            }

            if (timeline) timeline.commitUndoableEdit("Delete track")
            deleteTrackWindow.visible = false
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 12

            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: palette.windowText
                text: currentTrackIndex >= 0 && currentTrackIndex < tracks.count
                      ? "Delete track \"" + tracks.get(currentTrackIndex).trackId
                        + "\" and all its clips?"
                      : ""
            }

            Row {
                Layout.alignment: Qt.AlignRight
                spacing: 8

                Button {
                    focusPolicy: Qt.NoFocus
                    text: "No"
                    onClicked: deleteTrackWindow.visible = false
                }
                Button {
                    focusPolicy: Qt.NoFocus
                    text: "Yes"
                    onClicked: deleteTrackWindow.confirmDelete()
                }
            }
        }
    }

    // Split Mode Toggle (All Tracks vs Selected Clip)
    Button {
        focusPolicy: Qt.NoFocus
        text: timeline.splitAllTracksMode ? "Split All" : "Split One"
        height: 25
        width: 75
        checkable: true
        checked: timeline.splitAllTracksMode
        onClicked: timeline.splitAllTracksMode = !timeline.splitAllTracksMode
        ToolTip.visible: hovered
        ToolTip.text: (timeline.splitAllTracksMode ? "Split all tracks at playhead" : "Split only selected clip at playhead") + toolbar.keyHint("toggle_split_mode", " toggles")
        background: Rectangle {
            color: parent.checked ? "#ff9e4a" : "#555"
            radius: 2
        }
        contentItem: Text {
            text: parent.text
            color: "white"
            font.pixelSize: 10
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    // Split at Playhead
    Button {
        focusPolicy: Qt.NoFocus
        text: "]["
        height: 25
        width: 30
        onClicked: timeline.splitAtPlayhead()
        ToolTip.visible: hovered
        ToolTip.text: "Split clip(s) at playhead" + toolbar.keyHint("split")
    }

    // "+ Title" direct-to-timeline button removed per explicit user
    // request - title creation is bin-based only now (Logging workspace
    // Project Bin "+ Title", drag the result onto a track). The engine
    // side (TimelinePanel.addTitleClip()/isTrackFreeForTitle()) is left
    // in place - it's harmless dead-ish code for now, not wired to any
    // UI, but removing it wasn't asked for and risks breaking something
    // the drag-drop-from-bin path might still lean on internally.

    // Delete Clip
    Button {
        focusPolicy: Qt.NoFocus
        text: "\u{1F5D1}"
        height: 25
        width: 30
        enabled: timeline.selectedClipId !== ""
        onClicked: timeline.deleteSelectedClip()
    }

    // Ripple Edit Toggle
    Button {
        focusPolicy: Qt.NoFocus
        text: "Ripple: " + (timeline.rippleEditEnabled ? "ON" : "OFF")
        height: 25
        width: 80
        checkable: true
        checked: timeline.rippleEditEnabled
        onClicked: timeline.rippleEditEnabled = !timeline.rippleEditEnabled
        ToolTip.visible: hovered
        ToolTip.text: "Ripple edit on/off" + toolbar.keyHint("toggle_ripple")
        background: Rectangle { color: parent.checked ? "#4a9eff" : "#555"; radius: 2 }
        contentItem: Text {
            text: parent.text
            color: "white"
            font.pixelSize: 10
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    // All-tracks ripple (only meaningful while Ripple is on)
    Button {
        focusPolicy: Qt.NoFocus
        text: "All tracks"
        height: 25
        width: 70
        checkable: true
        checked: timeline.rippleAllTracks
        opacity: timeline.rippleEditEnabled ? 1.0 : 0.5
        onClicked: timeline.rippleAllTracks = !timeline.rippleAllTracks
        ToolTip.visible: hovered
        ToolTip.text: "Ripple shifts ALL tracks (keeps music/narration aligned)" + toolbar.keyHint("toggle_ripple_all_tracks")
        background: Rectangle { color: parent.checked ? "#4a9eff" : "#555"; radius: 2 }
        contentItem: Text {
            text: parent.text
            color: "white"
            font.pixelSize: 10
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    Item { width: 20; height: 1 }

    // Zoom: Fit to Window
    Button {
        focusPolicy: Qt.NoFocus
        height: 25
        width: 28
        ToolTip.visible: hovered
        ToolTip.text: "Fit to window" + toolbar.keyHint("zoom_fit")
        onClicked: timeline.zoomToFit()
        background: Rectangle { color: parent.hovered ? "#666" : "#555"; radius: 2 }
        contentItem: Text {
            text: "\u2922"
            color: "white"
            font.pixelSize: 14
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    // Zoom Out
    Button {
        focusPolicy: Qt.NoFocus
        height: 25
        width: 28
        ToolTip.visible: hovered
        ToolTip.text: "Zoom out" + toolbar.keyHint("zoom_out")
        onClicked: timeline.zoomOut()
        background: Rectangle { color: parent.hovered ? "#666" : "#555"; radius: 2 }
        contentItem: Text {
            text: "\u2212"
            color: "white"
            font.pixelSize: 16
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    // Zoom Slider
    Slider {
        id: zoomSlider
        height: 25
        width: 120
        from: 0
        to: 1
        value: (timeline.pixelsPerSecond - timeline.minPixelsPerSecond) / (timeline.maxPixelsPerSecond - timeline.minPixelsPerSecond)
        onMoved: timeline.setZoomLevel(value)
        background: Rectangle {
            x: zoomSlider.leftPadding
            y: zoomSlider.topPadding + zoomSlider.availableHeight / 2 - 2
            width: zoomSlider.availableWidth
            height: 4
            radius: 2
            color: "#555"
            Rectangle {
                width: zoomSlider.visualPosition * parent.width
                height: parent.height
                color: "#4a9eff"
                radius: 2
            }
        }
        handle: Rectangle {
            x: zoomSlider.leftPadding + zoomSlider.visualPosition * (zoomSlider.availableWidth - width)
            y: zoomSlider.topPadding + zoomSlider.availableHeight / 2 - height / 2
            width: 14
            height: 14
            radius: 7
            color: zoomSlider.pressed ? "#fff" : "#ddd"
        }
    }

    // Zoom In
    Button {
        focusPolicy: Qt.NoFocus
        height: 25
        width: 28
        ToolTip.visible: hovered
        ToolTip.text: "Zoom in" + toolbar.keyHint("zoom_in")
        onClicked: timeline.zoomIn()
        background: Rectangle { color: parent.hovered ? "#666" : "#555"; radius: 2 }
        contentItem: Text {
            text: "+"
            color: "white"
            font.pixelSize: 16
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    Item { width: 20; height: 1 }

    // === DEV-ONLY: Stage 3b scaling measurement buttons ===
    // Only visible when timeline.devToolsEnabled is hand-flipped to true
    // (TimelinePanel.qml) - never shipped on.
    Button {
        focusPolicy: Qt.NoFocus
        visible: timeline && timeline.devToolsEnabled
        text: "+500"
        height: 25
        onClicked: timeline.devGenerateClips(500)
    }
    Button {
        focusPolicy: Qt.NoFocus
        visible: timeline && timeline.devToolsEnabled
        text: "+2000"
        height: 25
        onClicked: timeline.devGenerateClips(2000)
    }
    Button {
        focusPolicy: Qt.NoFocus
        visible: timeline && timeline.devToolsEnabled
        text: "Clear syn"
        height: 25
        onClicked: timeline.devRemoveSyntheticClips()
    }
    Button {
        focusPolicy: Qt.NoFocus
        visible: timeline && timeline.devToolsEnabled
        text: "Report"
        height: 25
        onClicked: { timeline.devReportDelegates(); timeline.devTimeZoom() }
    }

    Item { width: 20; height: 1; visible: timeline && timeline.devToolsEnabled }

    // Mouse position timecode display
    Rectangle {
        height: 25
        width: 100
        color: "#333"
        radius: 3
        border.color: "#555"
        border.width: 1

        Text {
            anchors.centerIn: parent
            text: formatTimecode(mouseTimeSeconds)
            color: "#0f0"
            font.pixelSize: 12
            font.family: "monospace"
            font.bold: true
        }
    }
}
