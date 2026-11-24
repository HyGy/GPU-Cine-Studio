import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Transition tab of the Editing workspace's right-hand area: edits the
// transition selected on the timeline (TimelinePanel.selectedTransitionId).
// Everything goes through TimelinePanel's id-based entry points
// (setTransitionTypeById / setTransitionDurationById / removeTransitionById),
// so each change is one undoable edit exactly like the drag-resize handles.
// The text fields are TextFields, so ShortcutManager's text-editing guard
// keeps global shortcuts quiet while typing; Enter/Esc hand focus back.
Item {
    id: panel
    property var timelinePanel: null
    property var workspace: null

    readonly property string transId: timelinePanel ? timelinePanel.selectedTransitionId : ""
    // null = nothing selected / selected transition no longer exists.
    readonly property var info: {
        if (!timelinePanel || transId === "") return null
        var _ = timelinePanel.transitionRevision
        return timelinePanel.transitionInfo(transId)
    }
    readonly property real fps: { var _ = info; return timelinePanel ? timelinePanel.projectFps() : 30 }
    readonly property bool busy: secField.activeFocus || frameField.activeFocus

    function returnFocus() { if (panel.workspace) panel.workspace.releaseTextFocus() }

    // Title: the actual type's label (Iris Wipe, ...); audio is always Crossfade.
    function kindName() {
        if (!info) return ""
        if (!info.isVideo) return "Crossfade"
        var list = timelinePanel.availableTransitionTypes
        var want = info.type === "dissolve" ? "crossfade" : info.type
        for (var i = 0; i < list.length; i++)
            if (list[i].nick === want) return list[i].label
        return want
    }
    // TimelineEngine defers a clip-list rebuild while the pipeline is PLAYING
    // (teardown during playback crashes GES), so a type/duration change made
    // during playback would not show until the user stops. Pause first; the
    // deferred list is applied as soon as the pause settles.
    function pauseIfPlaying() {
        var e = timelinePanel ? timelinePanel.timelineEngine : null
        if (e && e.playing) e.pause()
    }

    function syncType() {
        var list = timelinePanel ? timelinePanel.availableTransitionTypes : []
        var idx = -1
        if (info) {
            // "dissolve" (the default video type name) is GES's "crossfade".
            var want = info.type === "dissolve" ? "crossfade" : info.type
            for (var i = 0; i < list.length; i++)
                if (list[i].nick === want) { idx = i; break }
        }
        typeCombo.currentIndex = idx
    }
    function syncFields() {
        if (!info) { secField.text = ""; frameField.text = ""; return }
        secField.text = info.duration.toFixed(2)
        frameField.text = String(Math.round(info.duration * fps))
    }
    function commitSeconds(sec) {
        if (!info || isNaN(sec) || !(sec > 0)) { syncFields(); return }
        if (info && Math.abs(timelinePanel.snapTransitionDuration(transId, sec) - info.duration) > 1e-6)
            pauseIfPlaying()
        timelinePanel.setTransitionDurationById(transId, sec)
        syncFields()
    }

    onInfoChanged: {
        syncType()
        if (!busy) syncFields()
        // The transition is gone (removed, undone, clip deleted): drop the
        // selection once the dust of a multi-step model edit has settled.
        if (transId !== "" && info === null) goneTimer.restart()
    }
    onTransIdChanged: { syncType(); syncFields() }
    Component.onCompleted: { syncType(); syncFields() }

    Timer {
        id: goneTimer
        interval: 0
        onTriggered: {
            if (panel.timelinePanel && panel.transId !== ""
                    && panel.timelinePanel.transitionInfo(panel.transId) === null)
                panel.timelinePanel.clearTransitionSelection()
        }
    }

    Rectangle { anchors.fill: parent; color: "#101214" }

    // ---- nothing selected ----
    Label {
        anchors.fill: parent
        anchors.margins: 12
        visible: panel.info === null
        text: "Click a transition on the timeline to edit it."
        color: "#999999"
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    // ---- selected transition ----
    Flickable {
        id: flick
        anchors.fill: parent
        anchors.margins: 8
        visible: panel.info !== null
        clip: true
        contentWidth: width
        contentHeight: form.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { }

        ColumnLayout {
            id: form
            width: flick.width
            spacing: 8

            Label {
                objectName: "transitionTitle"
                text: panel.kindName()
                color: "white"
                font.bold: true
                font.pixelSize: 14
            }
            Label {
                Layout.fillWidth: true
                text: panel.info ? ("Track " + panel.info.trackId) : ""
                color: "#cccccc"
                font.pixelSize: 12
            }
            Label {
                Layout.fillWidth: true
                text: panel.info ? (panel.info.clipAName + "  →  " + panel.info.clipBName) : ""
                color: "#cccccc"
                font.pixelSize: 12
                elide: Text.ElideMiddle
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: "#2a2d31" }

            Label { text: "Type"; color: "#cccccc" }
            ComboBox {
                id: typeCombo
                objectName: "transitionTypeCombo"
                Layout.fillWidth: true
                enabled: panel.info !== null && panel.info.isVideo
                model: panel.timelinePanel ? panel.timelinePanel.availableTransitionTypes : []
                textRole: "label"
                displayText: (panel.info && !panel.info.isVideo) ? "Crossfade"
                             : (currentIndex < 0 && panel.info ? panel.info.type : currentText)
                onActivated: function(i) {
                    var nick = panel.timelinePanel.availableTransitionTypes[i].nick
                    panel.pauseIfPlaying()
                    panel.timelinePanel.setTransitionTypeById(panel.transId, nick)
                    panel.syncType()
                    panel.returnFocus()
                }
            }
            Label {
                Layout.fillWidth: true
                visible: panel.info !== null && !panel.info.isVideo
                text: "Audio transitions are always a linear crossfade."
                color: "#999999"
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }

            Label { text: "Duration"; color: "#cccccc" }
            RowLayout {
                spacing: 8
                TextField {
                    id: secField
                    objectName: "transitionDurSeconds"
                    Layout.preferredWidth: 70
                    selectByMouse: true
                    horizontalAlignment: Text.AlignRight
                    validator: RegularExpressionValidator { regularExpression: /^[0-9]{0,4}([.,][0-9]{0,2})?$/ }
                    onTextEdited: {
                        var v = parseFloat(text.replace(",", "."))
                        if (!isNaN(v)) frameField.text = String(Math.round(v * panel.fps))
                    }
                    onAccepted: { panel.commitSeconds(parseFloat(text.replace(",", "."))); panel.returnFocus() }
                    onActiveFocusChanged: {
                        if (activeFocus) selectAll()
                        else panel.commitSeconds(parseFloat(text.replace(",", ".")))
                    }
                    Keys.onEscapePressed: { panel.syncFields(); panel.returnFocus() }
                }
                Label { text: "s"; color: "#cccccc" }
                TextField {
                    id: frameField
                    objectName: "transitionDurFrames"
                    Layout.preferredWidth: 60
                    selectByMouse: true
                    horizontalAlignment: Text.AlignRight
                    validator: IntValidator { bottom: 0; top: 99999 }
                    onTextEdited: {
                        var f = parseInt(text)
                        if (!isNaN(f)) secField.text = (f / panel.fps).toFixed(2)
                    }
                    onAccepted: { panel.commitSeconds(parseInt(text) / panel.fps); panel.returnFocus() }
                    onActiveFocusChanged: {
                        if (activeFocus) selectAll()
                        else panel.commitSeconds(parseInt(text) / panel.fps)
                    }
                    Keys.onEscapePressed: { panel.syncFields(); panel.returnFocus() }
                }
                Label { text: "f"; color: "#cccccc" }
            }
            Label {
                Layout.fillWidth: true
                visible: panel.info !== null && panel.info.range !== null
                text: panel.info && panel.info.range
                      ? ("Allowed: " + panel.info.range.min.toFixed(2) + " - " + panel.info.range.max.toFixed(2) + " s")
                      : ""
                color: "#999999"
                font.pixelSize: 11
            }

            Button {
                objectName: "transitionRemoveButton"
                Layout.topMargin: 6
                text: "Remove transition"
                onClicked: {
                    var id = panel.transId
                    panel.timelinePanel.removeTransitionById(id)
                    panel.timelinePanel.clearTransitionSelection()
                    panel.returnFocus()
                }
            }
        }
    }
}
