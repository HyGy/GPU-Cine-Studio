import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import VideoEditor 1.0
import "editing"

Item {
    id: editingWorkspace
    focus: true

    property string editingItemId: ""
    property string timelineConfigPath: "timeline_config.json"
    property string selectedClipId: ""
    property alias timelinePanel: timelinePanel
    property alias timelineEngine: timelineEngine
    // qml6glsink spike only (feature/qml6-gl-video-sink branch) - lets the
    // test API script drive clipVideoEngine.loadVideo() directly instead
    // of needing a real click through AT-SPI.
    property alias sourceMonitor: sourceMonitor
    // For main.qml's runAction() (Play/Pause shortcut).
    property alias projectMonitor: projectMonitor

    // Flag to hide drag proxy when over timeline drop area
    property bool timelineDropActive: false

    // Keyboard shortcuts are not handled here any more: they all come from
    // the registry (Backend.shortcuts) and are dispatched focus-independently
    // by main.qml's runAction() - see plan_shortcuts.md.

    // Ends in-place text editing: keyboard focus back to this workspace
    // (a focus-out commits the field). Enter/Esc of the in-place fields and
    // a click outside the field use it.
    function releaseTextFocus() { Backend.shortcuts.releaseTextFocus() }

    // Length of one project frame in ms. project/fps may be "auto", a plain
    // number ("29.97") or a fraction ("30000/1001").
    function projectFrameMs() {
        var parts = String(Backend.getSetting("project/fps", "30")).split("/")
        var fps = parseFloat(parts[0]) / (parts.length > 1 ? parseFloat(parts[1]) : 1)
        if (!(fps > 0)) fps = 30
        return 1000.0 / fps
    }

    // Re-read the monitor's canvas-frame outline after Project Settings' OK.
    function refreshCanvasFrameSetting() {
        if (projectMonitor) projectMonitor.refreshCanvasFrameSetting()
    }

    Component.onCompleted: {
        forceActiveFocus()
    }

    // Timeline alapállapotba állítása (betöltés előtt hívandó)
    function resetTimeline() {
        // Undoing across a project switch would restore the PREVIOUS
        // project's clips into the new one - clear before anything else.
        if (timelinePanel.clearUndoHistory) timelinePanel.clearUndoHistory()

        // Timeline engine leállítása (stop() már tartalmazza a seek(0)-t)
        if (timelineEngine) {
            timelineEngine.stop()
        }

        // Klipek törlése
        timelinePanel.clipsModel.clear()

        // Kijelölés törlése
        selectedClipId = ""
        timelinePanel.resetActiveTrack()

        // Master volume is project state; a reset returns to unity.
        timelinePanel.masterVolume = 1.0
        timelinePanel.rippleAllTracks = false

        // Az üres klip-listát is el kell juttatni a GES motorhoz, különben
        // az előző projekt klipjei a timeline motorban/preview-ban
        // megmaradnak addig, amíg valamilyen más szerkesztés (drag, split,
        // stb.) újra meg nem hívja updateTimelineEngine()-t.
        updateTimelineEngine()
    }

    // HH:MM:SS:FF at the project frame rate (projectFrameMs(): 25, 29.97 =
    // 30000/1001, 23.976, ...). Seconds are real (wall-clock) seconds, FF is
    // the frame within that second - for a fractional rate a second holds 29
    // or 30 (23 or 24) frames. The small epsilon absorbs the integer-ms
    // truncation of positions that sit exactly on a frame start.
    function formatTimecode(ms) {
        var fps = 1000.0 / projectFrameMs()
        var totalFrames = Math.max(0, Math.floor(ms * fps / 1000 + 0.05))
        var totalSeconds = Math.floor(totalFrames / fps + 1e-9)
        var frames = Math.max(0, totalFrames - Math.ceil(totalSeconds * fps - 1e-6))
        var seconds = totalSeconds % 60
        var totalMinutes = Math.floor(totalSeconds / 60)
        var minutes = totalMinutes % 60
        var hours = Math.floor(totalMinutes / 60)

        return (hours < 10 ? "0" : "") + hours + ":" +
               (minutes < 10 ? "0" : "") + minutes + ":" +
               (seconds < 10 ? "0" : "") + seconds + ":" +
               (frames < 10 ? "0" : "") + frames
    }

    // Mirrors the track rows' hide/mute flags into the GES engine.
    // Sent wholesale (not per-track) so a freshly loaded project can
    // never inherit the previous project's hidden/muted tracks.
    function pushTrackStatesToEngine() {
        if (!timelineEngine || !timelineEngine.setTrackStates) return
        timelineEngine.setTrackStates(timelinePanel.trackStatesForEngine())
        timelineEngine.setMasterVolume(timelinePanel.masterVolume)
    }

    // Clears every clip's "media missing" marker. A clip flagged missing on
    // a previous run may have been relinked or its drive reconnected since,
    // and TimelineEngine only signals clipMediaMissing for clips that are
    // ACTUALLY missing this time, so a clip that's fine now would otherwise
    // never get its marker cleared.
    function clearMediaMissingMarkers() {
        for (var ci = 0; ci < timelinePanel.clipsModel.count; ci++) {
            if (timelinePanel.clipsModel.get(ci).mediaMissing) {
                timelinePanel.clipsModel.setProperty(ci, "mediaMissing", false)
            }
        }
    }

    // The clip list handed to TimelineEngine.setClips().
    function buildClipsList() {
        var clipsList = []
        for (var i = 0; i < timelinePanel.clipsModel.count; i++) {
            var clip = timelinePanel.clipsModel.get(i)
            clipsList.push({
                clipId: clip.clipId,
                trackId: clip.trackId,
                itemName: clip.itemName,
                itemPath: clip.itemPath,
                startTime: clip.startTime,
                durationSeconds: clip.durationSeconds,
                xPos: clip.xPos,
                sourceOffset: clip.sourceOffset || 0,
                hasVideo: clip.hasVideo || false,
                hasAudio: clip.hasAudio || false,
                hasTransition: clip.hasTransition || false,
                transitionDuration: clip.transitionDuration || 0,
                transitionType: clip.transitionType || "",
                effects: clip.effects || "",
                clipKind: clip.clipKind || "",
                titleParams: clip.titleParams || ""
            })
        }
        return clipsList
    }

    function updateTimelineEngine() {
        console.log("updateTimelineEngine: Building clips list...")
        clearMediaMissingMarkers()
        var clipsList = buildClipsList()
        // Per-track hide/mute must reach the engine BEFORE setClips():
        // setClips() re-asserts the engine's remembered state onto the
        // (possibly rebuilt) layers as part of its own commit, so pushing
        // first means a load/undo/redo needs no extra commit of its own.
        pushTrackStatesToEngine()
        console.log("updateTimelineEngine: Calling timelineEngine.setClips with", clipsList.length, "clips")
        timelineEngine.setClips(clipsList)
        console.log("updateTimelineEngine: setClips returned")
    }

    // Missing-media Retry / Relink: forget the engine's remembered
    // missing/unreadable results and rebuild the timeline from the current
    // clip list (same sequence as MediaStallDialog.onRetryRequested). Clips
    // whose media is still missing get their marker again via
    // clipMediaMissing.
    function retryMedia() {
        clearMediaMissingMarkers()
        Backend.refreshProxyInstallations()
        Backend.cancelPendingProxyInstallationChanged()   // the rebuild below covers it
        pushTrackStatesToEngine()
        timelineEngine.retryUnavailableMedia(buildClipsList())
    }

    // Every non-title timeline clip's source path with how often it is used.
    function timelineMediaPaths() {
        var out = []
        for (var i = 0; i < timelinePanel.clipsModel.count; i++) {
            var c = timelinePanel.clipsModel.get(i)
            out.push({ itemPath: c.itemPath || "", clipKind: c.clipKind || "" })
        }
        return out
    }

    function getProjectJSON() {
        var clips = []
        for (var i = 0; i < timelinePanel.clipsModel.count; i++) {
            var clip = timelinePanel.clipsModel.get(i)
            clips.push({
                clipId: clip.clipId,
                trackId: clip.trackId,
                itemName: clip.itemName,
                itemPath: clip.itemPath,
                startTime: clip.startTime,
                durationSeconds: clip.durationSeconds,
                xPos: clip.xPos,
                sourceOffset: clip.sourceOffset || 0,
                hasVideo: clip.hasVideo || false,
                hasAudio: clip.hasAudio || false,
                hasTransition: clip.hasTransition || false, // Mentésnél is tároljuk
                transitionDuration: clip.transitionDuration || 0,
                transitionType: clip.transitionType || "",
                transitionCutOffset: clip.transitionCutOffset !== undefined ? clip.transitionCutOffset : (clip.transitionDuration || 0) / 2.0,
                transitionOriginalBId: clip.transitionOriginalBId || "",
                transitionOriginalStartB: clip.transitionOriginalStartB || 0,
                transitionAudioTrimA: clip.transitionAudioTrimA || 0,
                linkGroupId: clip.linkGroupId || "",
                linkedClipId: clip.linkedClipId || "",
                isLinked: clip.isLinked || false,
                sourceItemId: clip.sourceItemId || "",
                waveformPath: clip.waveformPath || "",
                effects: clip.effects || "",
                clipKind: clip.clipKind || "",
                titleParams: clip.titleParams || ""
            })
        }

        var tracks = []
        for (var i = 0; i < timelinePanel.tracksModel.count; i++) {
            var track = timelinePanel.tracksModel.get(i)
            tracks.push({
                trackId: track.trackId,
                type: track.type,
                name: track.name,
                disabled: track.disabled,
                hidden: track.hidden,
                muted: track.muted || false,
                volume: (track.volume !== undefined ? track.volume : 1.0),
                solo: (track.solo === true),
                pan: (track.pan !== undefined ? track.pan : 0.0),
                locked: track.locked
            })
        }

        var timelineState = {
            tracks: tracks,
            clips: clips,
            pixelsPerSecond: timelinePanel.pixelsPerSecond,
            totalSeconds: timelinePanel.totalSeconds,
            masterVolume: timelinePanel.masterVolume,
            rippleAllTracks: timelinePanel.rippleAllTracks
        }

        return JSON.stringify(timelineState, null, 2)
    }

    // Property to store loading dialog reference
    property var currentLoadingDialog: null

    function loadProjectJSON(jsonString, loadingDialog) {
        currentLoadingDialog = loadingDialog || null

        try {
            var timelineData = JSON.parse(jsonString)

            if (currentLoadingDialog) {
                currentLoadingDialog.setStep("Resetting timeline...")
            }

            // Alapállapotba állítás betöltés előtt
            resetTimeline()

            // Master volume (default 1.0 for old files without it). Set AFTER
            // resetTimeline(), which returns it to unity.
            timelinePanel.masterVolume = (timelineData.masterVolume !== undefined ? timelineData.masterVolume : 1.0)
            timelinePanel.rippleAllTracks = (timelineData.rippleAllTracks === true)

            // Track-lista visszaállítása - korábban ez sosem történt meg,
            // a tracksModel mindig a hard-coded V2/V1/A1/A2 alapértéknél
            // maradt. Ha a mentett projekt más track-azonosítókat
            // használt (pl. V3/A3-at hozzáadtak), azok klipjei a
            // getTrackYPosition() ismeretlen trackId-re való 0 fallback-je
            // miatt a legfelső sávra rajzolódtak volna.
            if (timelineData.tracks && timelineData.tracks.length > 0) {
                timelinePanel.tracksModel.clear()
                for (var t = 0; t < timelineData.tracks.length; t++) {
                    var track = timelineData.tracks[t]
                    timelinePanel.tracksModel.append({
                        trackId: track.trackId,
                        type: track.type,
                        name: track.name || "",
                        disabled: track.disabled || false,
                        hidden: track.hidden || false,
                        muted: track.muted || false,
                        volume: (track.volume !== undefined ? track.volume : 1.0),
                        solo: (track.solo === true),
                        pan: (track.pan !== undefined ? track.pan : 0.0),
                        locked: track.locked || false
                    })
                }
            }

            // Active track (view state, not saved): default for the loaded track list.
            timelinePanel.resetActiveTrack()

            if (timelineData.clips) {
                for (var i = 0; i < timelineData.clips.length; i++) {
                    var clip = timelineData.clips[i]

                    if (currentLoadingDialog) {
                        currentLoadingDialog.setStep("Adding clip " + (i + 1) + "/" + timelineData.clips.length + ": " + clip.itemName)
                    }

                    timelinePanel.clipsModel.append({
                        clipId: clip.clipId,
                        trackId: clip.trackId,
                        itemName: clip.itemName,
                        itemPath: clip.itemPath,
                        startTime: clip.startTime,
                        durationSeconds: clip.durationSeconds,
                        xPos: clip.xPos,
                        sourceOffset: clip.sourceOffset || 0,
                        hasVideo: clip.hasVideo,
                        hasAudio: clip.hasAudio,
                        hasTransition: clip.hasTransition || false,
                        transitionDuration: clip.transitionDuration || 0,
                        transitionType: clip.transitionType || "",
                        transitionCutOffset: clip.transitionCutOffset !== undefined ? clip.transitionCutOffset : (clip.transitionDuration || 0) / 2.0,
                        transitionOriginalBId: clip.transitionOriginalBId || "",
                        transitionOriginalStartB: clip.transitionOriginalStartB || 0,
                        transitionAudioTrimA: clip.transitionAudioTrimA || 0,
                        linkGroupId: clip.linkGroupId || "",
                        linkedClipId: clip.linkedClipId || "",
                        isLinked: clip.isLinked || false,
                        sourceItemId: clip.sourceItemId || "",
                        // Re-queried live rather than trusting the saved
                        // value verbatim: a clip saved before its waveform
                        // finished generating (or before a cache folder was
                        // manually restored after the fact) serializes an
                        // empty waveformPath that would otherwise stay
                        // empty forever - onWaveformReady only updates it
                        // when CacheManager generates something fresh IN
                        // THIS session, which never fires for an item
                        // that's already "ready" on disk at load time.
                        waveformPath: (clip.sourceItemId && Backend.cacheManager)
                            ? (Backend.cacheManager.getWaveformPath(clip.sourceItemId) || clip.waveformPath || "")
                            : (clip.waveformPath || ""),
                        effects: clip.effects || "",
                        clipKind: clip.clipKind || "",
                        titleParams: clip.titleParams || ""
                    })
                }
            }

            // The clip/transition index (TimelinePanel.rebuildClipIndex())
            // only updates on checkAllClipNeighbors() - without this call,
            // every delegate just created by the append loop above would
            // read a stale (pre-load, likely empty) index from its own
            // Component.onCompleted and show zero overlap for any
            // transition the loaded project actually has, until some
            // later edit happened to trigger a rebuild.
            timelinePanel.checkAllClipNeighbors()

            if (timelineData.pixelsPerSecond !== undefined) {
                timelinePanel.pixelsPerSecond = timelineData.pixelsPerSecond
            }
            // totalSeconds is now a derived readonly property (TimelinePanel.qml) -
            // computed from contentEndSeconds, which checkAllClipNeighbors()
            // above already refreshed from the just-loaded clips. The
            // project JSON still carries totalSeconds (getProjectJSON())
            // for file-format compatibility, but it's advisory only now.

            if (currentLoadingDialog) {
                currentLoadingDialog.setStep("Building timeline engine...")
            }

            // ProjectMonitor's "Active proxy" combo only refreshes itself
            // on Component.onCompleted (fires once, at app/component
            // creation - never again for a SECOND project loaded into the
            // same running session) and on live proxyReady/
            // proxyInstallationChanged signals (which never fire for
            // proxies that were already "ready" before this project
            // context existed - e.g. a manually-restored .cache folder,
            // or any project whose proxies were generated in an earlier
            // session). Without this, the combo silently shows stale
            // "Original (no proxy)" even though Settings' own copy of the
            // same list (populated the same way, but re-run every dialog-
            // open) correctly lists the available resolution.
            if (projectMonitor) projectMonitor.refreshActiveProxyModel()

            // The full build below resolves every asset fresh, so it
            // already reflects every proxy install/uninstall made up to
            // this moment (main.qml's loadProject() runs
            // refreshProxyInstallations() just before this; if its install
            // pass is still running, the engine parks the list below until
            // it ended). The pending (or, for a running pass, eventual)
            // coalesced proxyInstallationChanged would only trigger a
            // second, identical rebuild ~2 s later, so cancel it - and
            // invalidate the asset cache ourselves to keep what that
            // signal used to guarantee (no stale asset left over from a
            // previously open project). Installs after this point
            // schedule a new timer as usual.
            Backend.cancelPendingProxyInstallationChanged()
            timelineEngine.invalidateAssetCache()

            console.log("loadProjectJSON: Calling updateTimelineEngine...")
            updateTimelineEngine()
            console.log("loadProjectJSON: updateTimelineEngine returned, waiting for timelineReady signal")
        } catch(e) {
            console.error("Failed to load timeline JSON:", e)
            if (currentLoadingDialog) {
                currentLoadingDialog.addLog("Error: " + e.toString())
                currentLoadingDialog.close()
                currentLoadingDialog = null
            }
        }
    }

    MediaStallDialog {
        id: mediaStallDialog
        objectName: "mediaStallDialog"
        engine: timelineEngine
        // Transient for the loading dialog (if open) so the window manager
        // keeps this one above it.
        transientParent: editingWorkspace.currentLoadingDialog
        onRetryRequested: {
            // Cancelled loading may have left proxies uninstalled (their
            // media was never resolved): pick them up again; the engine
            // parks the clip list below until that pass has finished.
            Backend.refreshProxyInstallations()
            Backend.cancelPendingProxyInstallationChanged()   // the build below covers it
            editingWorkspace.updateTimelineEngine()
        }
    }

    TimelineEngine {
        id: timelineEngine
        onError: function(message) { console.error("Timeline error:", message) }
        // Safety net for a preview proxy the pipeline cannot play (or a
        // rebuild that never prerolls): the Backend reverts to the original
        // and triggers a rebuild - see BackendManager::handleProxyPlaybackFailure().
        onProxyPlaybackFailed: function(failingPath) { Backend.handleProxyPlaybackFailure(failingPath) }
        onProxyRebuildStuck: function() { Backend.handleProxyRebuildStuck() }
        Component.onCompleted: {
            setDecoderPreference(Backend.preferredDecoder)
            setProjectDir(Backend.getSetting("project/location", ""))
        }

        onClipMediaMissing: function(clipId) {
            for (var i = 0; i < timelinePanel.clipsModel.count; i++) {
                if (timelinePanel.clipsModel.get(i).clipId === clipId) {
                    timelinePanel.clipsModel.setProperty(i, "mediaMissing", true)
                    break
                }
            }
        }

        onClipDurationClamped: function(clipId, newDurationSeconds) {
            // The engine had to shorten this clip because its requested
            // duration ran past the source asset's real length - without
            // this, clipsModel (and therefore the timeline's drawn clip
            // width/drag range) would keep the longer, requested value
            // that never actually plays.
            for (var i = 0; i < timelinePanel.clipsModel.count; i++) {
                if (timelinePanel.clipsModel.get(i).clipId === clipId) {
                    console.log("Clip", clipId, "duration clamped to", newDurationSeconds, "s by engine")
                    timelinePanel.clipsModel.setProperty(i, "durationSeconds", newDurationSeconds)
                    break
                }
            }
            // The clip/transition/overlap index is keyed off durationSeconds
            // too (clipIndexByTrack entries carry it) - without a rebuild,
            // overlap/wall queries for this clip would use the old,
            // pre-clamp duration until some unrelated edit happened to
            // trigger one.
            Qt.callLater(timelinePanel.checkAllClipNeighbors)
        }

        onTimelineReady: {
            console.log("Timeline ready signal received")
            if (editingWorkspace.currentLoadingDialog) {
                editingWorkspace.currentLoadingDialog.setStep("Timeline ready!")
                editingWorkspace.currentLoadingDialog.finish()
                editingWorkspace.currentLoadingDialog = null
            }
        }

        onDecoderPreferenceApplied: {
            console.log("Decoder preference applied - repopulating timeline after pipeline rebuild")
            updateTimelineEngine()
        }
    }

    Connections {
        target: Backend
        function onPreferredDecoderChanged() {
            timelineEngine.setDecoderPreference(Backend.preferredDecoder)
        }
        // proxy_build_plan.md Part J.4.4: ges_asset_set_proxy() alone
        // changes nothing on screen - TimelineEngine's own asset cache and
        // its no-op/incremental fast paths would all otherwise conclude
        // "nothing changed" against the same clip list. reloadAssets()
        // forces the next setClips() call past all of that.
        function onProxyInstallationChanged() {
            timelineEngine.reloadAssets()
        }
        function onProxyRevertedToOriginal(sourcePath, reason) {
            console.warn("Proxy reverted:", reason)
        }
    }

    // "editing" (default) or "effects" - driven externally by main.qml's
    // Binding on currentWorkspace. Both layouts below are built at once
    // (visible/enabled toggled, not Loader-swapped) so the three shared
    // panels declared further down - ProjectBinPanel, ProjectMonitor,
    // TimelinePanel - can be reparented between them by a plain `parent:`
    // binding instead of being duplicated. Duplicating them would mean
    // duplicate undo stacks, duplicate GES-backed TimelinePanel state, and
    // (worse) a second native video child window fighting the first one
    // for the same GStreamer overlay handle - see VideoOutput.cpp's
    // parentChanged handling below for the one thing that reparenting
    // does NOT handle for free.
    property string layoutMode: "editing"

    Item {
        anchors.fill: parent

        // ----- EDITING LAYOUT: bin+monitors over timeline+audio mixer -----
        SplitView {
            id: editingLayout
            anchors.fill: parent
            orientation: Qt.Vertical
            visible: editingWorkspace.layoutMode === "editing"
            enabled: visible

            SplitView {
                id: edTopRow
                SplitView.minimumHeight: 300
                SplitView.preferredHeight: 500
                orientation: Qt.Horizontal

                Item {
                    id: edBinSlot
                    SplitView.minimumWidth: 250
                    SplitView.preferredWidth: 320
                }

                Rectangle {
                    SplitView.minimumWidth: 400
                    SplitView.fillWidth: true
                    color: "#1d1d1d"

                    SplitView {
                        id: edMonitorSplit
                        anchors.fill: parent
                        orientation: Qt.Horizontal

                        // Clip monitor's share of the width; kept when the
                        // window is resized and updated when a drag ends.
                        property real clipFraction: 0.5
                        onResizingChanged: {
                            if (!resizing && width > 0)
                                clipFraction = sourceMonitor.width / width
                        }

                        SourceMonitor {
                            id: sourceMonitor
                            timelinePanel: timelinePanel
                            timelineEngine: timelineEngine
                            formatTimecode: editingWorkspace.formatTimecode
                            SplitView.minimumWidth: 200
                            SplitView.preferredWidth: Math.round(edMonitorSplit.clipFraction * edMonitorSplit.width)
                        }
                        Item {
                            id: edMonitorSlot
                            SplitView.minimumWidth: 200
                            SplitView.fillWidth: true
                        }
                    }
                }
            }

            SplitView {
                id: edBottomRow
                SplitView.minimumHeight: 200
                SplitView.preferredHeight: 300
                orientation: Qt.Horizontal

                Item {
                    id: edTimelineSlot
                    SplitView.minimumWidth: 400
                    SplitView.fillWidth: true
                }

                Rectangle {
                    SplitView.minimumWidth: 150
                    SplitView.preferredWidth: 270
                    color: palette.window
                    border.color: "#1d1d1d"
                    border.width: 1
                    // Tabbed area, tab bar at the bottom: Audio Mixer | Transition.
                    // Last tab is app-wide (QSettings), like monitor/clipInfoCollapsed.
                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: 5; spacing: 0
                        StackLayout {
                            Layout.fillWidth: true; Layout.fillHeight: true
                            currentIndex: rightTabs.currentIndex
                            AudioMixerPanel { timelinePanel: timelinePanel; workspace: editingWorkspace }
                            TransitionPanel { timelinePanel: timelinePanel; workspace: editingWorkspace }
                        }
                        TabBar {
                            id: rightTabs
                            objectName: "rightTabs"
                            Layout.fillWidth: true
                            background: Rectangle { color: "#1a1c1f" }
                            currentIndex: {
                                var v = parseInt(Backend.getSetting("editing/rightTab", 0))
                                return v === 1 ? 1 : 0
                            }
                            onCurrentIndexChanged: Backend.setSetting("editing/rightTab", currentIndex)
                            // A clicked transition brings its settings up.
                            Connections {
                                target: timelinePanel
                                function onSelectedTransitionIdChanged() {
                                    if (timelinePanel.selectedTransitionId !== "") rightTabs.currentIndex = 1
                                }
                            }
                            component BottomTab : TabButton {
                                id: tb
                                implicitHeight: 28
                                contentItem: Text {
                                    text: tb.text
                                    font.pixelSize: 12
                                    font.bold: tb.checked
                                    color: tb.checked ? "white" : "#8a8f96"
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                background: Rectangle {
                                    color: tb.checked ? palette.window : "#1a1c1f"
                                    Rectangle {   // accent line on the edge facing the content
                                        width: parent.width; height: 2
                                        anchors.top: parent.top
                                        color: "#b055ff"
                                        visible: tb.checked
                                    }
                                }
                            }
                            BottomTab { text: "Audio Mixer" }
                            BottomTab { text: "Transition" }
                        }
                    }
                }
            }
        }

        // ----- EFFECTS LAYOUT: browser+preview+inspector over bin+timeline -----
        SplitView {
            id: effectsLayout
            anchors.fill: parent
            orientation: Qt.Vertical
            visible: editingWorkspace.layoutMode === "effects"
            enabled: visible

            SplitView {
                SplitView.minimumHeight: 300
                SplitView.preferredHeight: 500
                orientation: Qt.Horizontal

                EffectBrowserPanel {
                    id: effectBrowserPanel
                    SplitView.minimumWidth: 220
                    SplitView.preferredWidth: 280
                    selectedClipId: editingWorkspace.selectedClipId
                    timelinePanel: timelinePanel
                    workspaceRoot: editingWorkspace
                }

                Item {
                    id: fxMonitorSlot
                    SplitView.minimumWidth: 400
                    SplitView.fillWidth: true
                }

                // Title clips get their own inspector, shown ONLY while
                // one is selected - selection-driven, same pattern as
                // EffectInspectorPanel's own selectedClipId binding.
                // SplitView skips invisible children entirely, so for
                // every ordinary clip this column simply isn't there.
                // The effect stack below stays visible alongside it on
                // purpose: a title is a normal video clip as far as GES
                // is concerned, so video effects (fade, transform, ...)
                // apply to it just like any other.
                TitleInspectorPanel {
                    id: titleInspectorPanel
                    SplitView.minimumWidth: 260
                    SplitView.preferredWidth: 340
                    // Shown for a selected title CLIP or a selected
                    // title BIN item - the panel decides which of the
                    // two it is editing (see its clipMode/binMode).
                    visible: titleInspectorPanel.hasTitle
                    selectedClipId: editingWorkspace.selectedClipId
                    timelinePanel: timelinePanel
                    timelineEngine: timelineEngine
                }

                EffectInspectorPanel {
                    id: effectInspectorPanel
                    // Widened per explicit user request ("majdnem a
                    // duplája is elférne") - only preferredWidth, not
                    // minimumWidth: raising the minimum would raise the
                    // whole row's hard floor (sum of all three panels'
                    // minimums) and make SplitView overflow on smaller
                    // windows instead of gracefully compressing: the
                    // fxMonitorSlot in the middle is the fillWidth item,
                    // so it absorbs this panel's extra preferred width
                    // with no risk, and the user can still drag the
                    // splitter handle back down.
                    SplitView.minimumWidth: 260
                    SplitView.preferredWidth: 580
                    selectedClipId: editingWorkspace.selectedClipId
                    timelinePanel: timelinePanel
                    timelineEngine: timelineEngine
                }
            }

            SplitView {
                SplitView.minimumHeight: 200
                SplitView.preferredHeight: 300
                orientation: Qt.Horizontal

                // No bin slot here on purpose - the Project Bin isn't
                // needed in the Effects layout (titles are created in the
                // Logging/Editing bin; this layout only edits whatever
                // clip is already selected on the timeline), so
                // fxTimelineSlot just takes the whole row.
                Item {
                    id: fxTimelineSlot
                    SplitView.minimumWidth: 400
                    SplitView.fillWidth: true
                }
            }
        }
    }

    // ----- SHARED PANELS - declared once, reparented by layoutMode -----
    ProjectBinPanel {
        id: projectBinPanel
        workspaceRoot: editingWorkspace
        clipVideoEngine: sourceMonitor.videoEngine
        onItemPicked: sourceMonitor.showBinInfo()
        editingItemId: editingWorkspace.editingItemId
        onEditingItemIdChanged: editingWorkspace.editingItemId = editingItemId
        // Always the editing-layout slot - effectsLayout has no bin slot
        // at all (see its own comment), so this stays parked here,
        // invisible, whenever layoutMode is "effects".
        parent: edBinSlot
        anchors.fill: parent
    }

    // Editing layout only: resize the panes so the picture shown in the
    // Project Monitor is pictureW x pictureH logical px (aspect must match
    // the canvas). The monitor's chrome (everything around the video item)
    // is taken from live geometry. Moves the Clip/Project Monitor divider
    // (shrinking the Project Bin down to its minimum if needed) and the
    // top/bottom divider; if the target does not fit it is scaled down
    // (aspect kept) to the largest size that does, never breaking minimums.
    // Returns the picture size {w, h} that was aimed at.
    function fitProjectMonitorTo(pictureW, pictureH) {
        if (layoutMode !== "editing" || pictureW <= 0 || pictureH <= 0) return null
        var slotW = edMonitorSlot.width, slotH = edMonitorSlot.height
        var chromeW = slotW - projectMonitor.videoAreaWidth
        var chromeH = slotH - projectMonitor.videoAreaHeight
        var hTop = edTopRow.width - edBinSlot.width - edMonitorSplit.width        // handle thickness
        var hIn = edMonitorSplit.width - sourceMonitor.width - slotW              // handle thickness
        var hV = editingLayout.height - edTopRow.height - edBottomRow.height
        var binMin = edBinSlot.SplitView.minimumWidth
        var clipMin = sourceMonitor.SplitView.minimumWidth
        // Largest slot the window can give.
        var maxSlotW = edTopRow.width - binMin - hTop - clipMin - hIn
        var maxRowH = editingLayout.height - edBottomRow.SplitView.minimumHeight - hV
        var maxSlotH = slotH + (maxRowH - edTopRow.height)
        var s = Math.min(1, (maxSlotW - chromeW) / pictureW, (maxSlotH - chromeH) / pictureH)
        if (s <= 0) return null
        var pw = s < 1 ? Math.floor(pictureW * s) : pictureW
        var ph = s < 1 ? Math.floor(pictureH * s) : pictureH
        var needW = pw + chromeW
        // Vertical: top row height.
        var rowH = Math.max(edTopRow.SplitView.minimumHeight,
                            Math.min(maxRowH, edTopRow.height + (ph + chromeH - slotH)))
        // Horizontal: keep the bin width if the clip monitor stays >= its
        // minimum, else take the missing width from the bin.
        var bin = edBinSlot.width
        var splitW = edTopRow.width - bin - hTop
        var clipW = splitW - hIn - needW
        if (clipW < clipMin) {
            bin = Math.max(binMin, bin - (clipMin - clipW))
            splitW = edTopRow.width - bin - hTop
            clipW = Math.max(clipMin, splitW - hIn - needW)
        }
        edBinSlot.SplitView.preferredWidth = bin
        edMonitorSplit.clipFraction = clipW / splitW
        // A manual handle drag may have replaced the item's preferredWidth
        // binding with a plain value; re-establish it so the ratio rules.
        sourceMonitor.SplitView.preferredWidth = Qt.binding(function() {
            return Math.round(edMonitorSplit.clipFraction * edMonitorSplit.width)
        })
        edTopRow.SplitView.preferredHeight = rowH
        return { w: pw, h: ph }
    }

    ProjectMonitor {
        id: projectMonitor
        timelineEngine: timelineEngine
        formatTimecode: editingWorkspace.formatTimecode
        updateTimelineEngine: editingWorkspace.updateTimelineEngine
        workspace: editingWorkspace
        parent: editingWorkspace.layoutMode === "effects" ? fxMonitorSlot : edMonitorSlot
        anchors.fill: parent
    }

    TimelinePanel {
        id: timelinePanel
        timelineEngine: timelineEngine
        updateTimelineEngine: editingWorkspace.updateTimelineEngine
        formatTimecode: editingWorkspace.formatTimecode
        selectedClipId: editingWorkspace.selectedClipId
        workspace: editingWorkspace
        onSelectedClipIdChanged: editingWorkspace.selectedClipId = selectedClipId
        parent: editingWorkspace.layoutMode === "effects" ? fxTimelineSlot : edTimelineSlot
        anchors.fill: parent
    }
}
