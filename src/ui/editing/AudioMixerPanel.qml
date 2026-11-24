import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Audio Mixer: one MixerStrip per audio track (scrollable) + a fixed Master
// strip on the right. Track volume/solo/mute come from tracksModel; master
// volume is TimelinePanel::masterVolume; the master level comes from the
// engine's preview audio-filter "level" element.
Item {
    id: mixer
    property var timelinePanel: null
    property var workspace: null

    // Bumped on any track-row change so the "silent because another track is
    // soloed" greyed title re-evaluates for every strip, not just the changed
    // row.
    property int tracksRevision: 0
    property bool masterMuted: false
    property real lastMasterUpdate: 0

    // Emitted by the shared decay timer; every track strip checks its own
    // last update and falls to silence when stale.
    signal decayTick()

    function engine() { return mixer.timelinePanel ? mixer.timelinePanel.timelineEngine : null }
    function returnFocus() { if (mixer.workspace) mixer.workspace.releaseTextFocus() }

    Rectangle { anchors.fill: parent; color: "#101214" }

    Connections {
        target: mixer.timelinePanel ? mixer.timelinePanel.tracksModel : null
        function onDataChanged() { mixer.tracksRevision++ }
        function onCountChanged() { mixer.tracksRevision++ }
    }

    Connections {
        target: mixer.engine()
        function onAudioLevel(trackId, peakL, peakR, holdL, holdR) {
            if (trackId === "master") {
                masterStrip.peakL = peakL
                masterStrip.peakR = peakR
                masterStrip.holdL = holdL
                masterStrip.holdR = holdR
                mixer.lastMasterUpdate = Date.now()
            }
        }
    }

    Timer {
        interval: 150
        repeat: true
        running: true
        onTriggered: {
            if (Date.now() - mixer.lastMasterUpdate > 250) {
                masterStrip.peakL = -90
                masterStrip.peakR = -90
                masterStrip.holdL = -90
                masterStrip.holdR = -90
            }
            mixer.decayTick()
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 3
        spacing: 0

    RowLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: 0

        ListView {
            id: stripList
            Layout.fillWidth: true
            Layout.fillHeight: true
            orientation: ListView.Horizontal
            spacing: 0
            clip: true
            // Left/Right/Home/End must stay inside the strips' dB TextField:
            // without this the horizontal view would move its current index and
            // steal keyboard focus when the text cursor is already at the edge.
            keyNavigationEnabled: false
            // A horizontal ListView ignores the vertical wheel; map it to
            // horizontal scrolling (horizontal wheel/touchpad still works).
            WheelHandler {
                acceptedModifiers: Qt.NoModifier
                onWheel: function(event) {
                    if (event.angleDelta.y === 0) return
                    var maxX = stripList.originX + stripList.contentWidth - stripList.width
                    stripList.contentX = Math.max(stripList.originX, Math.min(maxX, stripList.contentX - event.angleDelta.y))
                }
            }
            model: mixer.timelinePanel ? mixer.timelinePanel.tracksModel : null

            delegate: Item {
                id: trackStrip
                width: model.type === "audio" ? 84 : 0
                height: stripList.height
                visible: model.type === "audio"

                // Per-track meter values (stage C2). The engine posts one
                // "level" message per audio clip every 50 ms; a track with
                // two overlapping clips sends two per interval - the latest
                // wins, which is fine.
                property real levelPeakL: -90
                property real levelPeakR: -90
                property real levelHoldL: -90
                property real levelHoldR: -90
                property real lastLevelUpdate: 0

                // Shared 150 ms panel timer: anything that has not been
                // updated for 250 ms (pause, gap, muted track, end of
                // timeline) falls to silence.
                function decayIfStale() {
                    if (Date.now() - lastLevelUpdate > 250) {
                        levelPeakL = -90; levelPeakR = -90
                        levelHoldL = -90; levelHoldR = -90
                    }
                }

                Connections {
                    target: mixer.engine()
                    function onAudioLevel(trackId, peakL, peakR, holdL, holdR) {
                        if (trackId === model.trackId) {
                            trackStrip.levelPeakL = peakL
                            trackStrip.levelPeakR = peakR
                            trackStrip.levelHoldL = holdL
                            trackStrip.levelHoldR = holdR
                            trackStrip.lastLevelUpdate = Date.now()
                        }
                    }
                }

                Connections {
                    target: mixer
                    function onDecayTick() { trackStrip.decayIfStale() }
                }

                MixerStrip {
                    anchors.fill: parent
                    title: (model.name && model.name !== "") ? (model.trackId + " - " + model.name) : model.trackId
                    titleColor: {
                        var _rev = mixer.tracksRevision   // dependency on any row change
                        return (mixer.timelinePanel
                                && mixer.timelinePanel.effectiveAudioMuted(index)
                                && model.muted !== true) ? "#777777" : "white"
                    }
                    gain: model.volume === undefined ? 1.0 : model.volume
                    muted: model.muted === true
                    solo: model.solo === true
                    panEnabled: true
                    pan: model.pan === undefined ? 0.0 : model.pan
                    peakL: trackStrip.levelPeakL
                    peakR: trackStrip.levelPeakR
                    holdL: trackStrip.levelHoldL
                    holdR: trackStrip.levelHoldR

                    onGainLive: function(g) { if (mixer.timelinePanel) mixer.timelinePanel.setTrackVolume(index, g, true) }
                    onGainCommitted: function(g) { if (mixer.timelinePanel) mixer.timelinePanel.setTrackVolume(index, g, false) }
                    onMuteToggled: if (mixer.timelinePanel) mixer.timelinePanel.setTrackMuted(index, !(model.muted === true))
                    onSoloToggled: if (mixer.timelinePanel) mixer.timelinePanel.setTrackSolo(index, !(model.solo === true))
                    onPanLive: function(p) { if (mixer.timelinePanel) mixer.timelinePanel.setTrackPan(index, p, true) }
                    onPanCommitted: function(p) { if (mixer.timelinePanel) mixer.timelinePanel.setTrackPan(index, p, false) }
                    onInteractionFinished: mixer.returnFocus()
                }
            }
        }

        Rectangle {
            Layout.preferredWidth: 1
            Layout.fillHeight: true
            color: "#3a3f44"
        }

        MixerStrip {
            id: masterStrip
            Layout.preferredWidth: 84
            Layout.fillHeight: true
            title: "Master"
            isMaster: true
            gain: mixer.timelinePanel ? mixer.timelinePanel.masterVolume : 1.0
            muted: mixer.masterMuted

            onGainLive: function(g) {
                if (!mixer.timelinePanel) return
                if (mixer.masterMuted) mixer.timelinePanel.masterVolume = Math.max(0, Math.min(4, g))
                else mixer.timelinePanel.setMasterVolume(g)
            }
            onGainCommitted: function(g) {
                if (!mixer.timelinePanel) return
                if (mixer.masterMuted) mixer.timelinePanel.masterVolume = Math.max(0, Math.min(4, g))
                else mixer.timelinePanel.setMasterVolume(g)
            }
            onMuteToggled: {
                mixer.masterMuted = !mixer.masterMuted
                var e = mixer.engine()
                if (e) e.setMasterVolume(mixer.masterMuted ? 0 : (mixer.timelinePanel ? mixer.timelinePanel.masterVolume : 1.0))
            }
            onInteractionFinished: mixer.returnFocus()
        }
    }

    // Always-visible horizontal scrollbar in its own row below the strips, so
    // it never covers the dB fields. It spans the strip list only (the Master
    // strip's width is left empty on the right).
    ScrollBar {
        id: stripScrollBar
        Layout.fillWidth: true
        Layout.rightMargin: masterStrip.width + 1
        Layout.preferredHeight: 12
        orientation: Qt.Horizontal
        policy: ScrollBar.AlwaysOn
        size: stripList.contentWidth > 0 ? Math.min(1, stripList.width / stripList.contentWidth) : 1
        position: stripList.contentWidth > 0 ? (stripList.contentX - stripList.originX) / stripList.contentWidth : 0
        onPositionChanged: { if (pressed) stripList.contentX = stripList.originX + position * stripList.contentWidth }
        contentItem: Rectangle {
            implicitHeight: 12
            radius: 4
            color: stripScrollBar.pressed ? "#9aa0a6" : "#6b7075"
        }
        background: Rectangle { color: "#1c1f22" }
    }
    }
}
