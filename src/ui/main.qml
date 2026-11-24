import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import QtQml 
import VideoEditor 1.0
import "components"

ApplicationWindow {
    id: root
    visible: true
    visibility: Window.Maximized
    width: 1280
    height: 720
    // projectIdentityRevision is a manual binding trigger: setSetting()
    // emits no change signal, so without it a Save As (or a Project
    // Settings rename) leaves the old project name in the title bar.
    title: "GPU Cine Studio - " + Backend.appVersion + (isProjectOpen && projectIdentityRevision >= 0
           ? " - " + Backend.getSetting("project/name", "Untitled") : "")

    color: "#202326"

    property string currentWorkspace: "Logging"
    property string missingDecoderName: ""
    property int projectIdentityRevision: 0
    // Effects shares EditingWorkspace's instance (same StackLayout index,
    // same timeline/undo stack/project bin) with a different layout - so
    // anything gated on "am I looking at the live timeline" must include
    // both tab names, not just "Editing".
    readonly property bool isTimelineWorkspace: currentWorkspace === "Editing" || currentWorkspace === "Effects"

    // Projekt állapot változó
    property bool isProjectOpen: false

    // Set right where the cache gets (re-)initialized for a project that's
    // being opened/imported (loadProject()/commitKdenliveImport()), before
    // the timeline has actually finished loading. loadingDialog's
    // onVisibleChanged below fires the actual proxy-backfill check once it
    // closes (i.e. once TimelineEngine.timelineReady has fired) - that's
    // the earliest point registration (CacheManager) AND the timeline's
    // clip list are both guaranteed ready to query. Cleared on load
    // failure so a failed open never fires the check on stale/empty state.
    property bool pendingProxyBackfillCheck: false

    // Missing source media (MediaAvailability / MissingMediaDialog). The
    // check starts right after the project bin is loaded and runs in
    // parallel with the timeline build; when the loading dialog closes, the
    // missing-media dialog (if anything is missing) comes first and the
    // proxy-backfill prompt follows once it is closed.
    property bool awaitingMissingAtLoad: false
    property string mediaStatusText: ""
    Timer { id: mediaStatusTimer; interval: 6000; onTriggered: root.mediaStatusText = "" }

    // clips: [{itemPath, clipKind}] - the timeline's clip list.
    function startMediaCheck(clips) {
        var mav = Backend.mediaAvailability
        var map = new Map()
        var items = Backend.projectBinModel.fileItemsForCheck()
        for (var i = 0; i < items.length; i++) {
            var p = items[i].path
            var e = map.get(p)
            if (!e) { e = { path: p, itemIds: [], size: -1, clipCount: 0 }; map.set(p, e) }
            e.itemIds.push(items[i].itemId)
            if (e.size < 0 && items[i].size > 0) e.size = items[i].size
        }
        for (var c = 0; c < clips.length; c++) {
            var raw = clips[c].itemPath
            if (!raw || clips[c].clipKind === "title") continue
            var lp = mav.localPath(String(raw))
            if (lp === "") continue
            var ce = map.get(lp)
            if (!ce) { ce = { path: lp, itemIds: [], size: -1, clipCount: 0 }; map.set(lp, ce) }
            ce.clipCount++
        }
        var entries = []
        map.forEach(function(v) { entries.push(v) })
        mav.check(entries)
    }

    function liveTimelineClips() {
        return editingWorkspaceLoader.item ? editingWorkspaceLoader.item.timelineMediaPaths() : []
    }

    // Called when the loading dialog has closed after an open/import.
    function afterLoadMediaCheck() {
        if (!root.isProjectOpen) return
        if (Backend.mediaAvailability.checking) {
            root.awaitingMissingAtLoad = true
            return
        }
        if (Backend.mediaAvailability.missingCount > 0) {
            missingMediaDialog.present(true)
        } else {
            root.checkMissingTimelineProxies()
        }
    }

    // File menu / Project Bin chip.
    function openMissingMediaDialog() {
        if (!root.isProjectOpen) return
        root.startMediaCheck(root.liveTimelineClips())
        missingMediaDialog.present(false)
    }

    function showMediaStatus(text) {
        root.mediaStatusText = text
        mediaStatusTimer.restart()
    }

    Connections {
        target: Backend.mediaAvailability
        function onCheckFinished() {
            var ids = []
            var m = Backend.mediaAvailability.missing
            for (var i = 0; i < m.length; i++)
                for (var j = 0; j < m[i].itemIds.length; j++) ids.push(m[i].itemIds[j])
            Backend.projectBinModel.setMissingItems(ids)
            if (root.awaitingMissingAtLoad) {
                root.awaitingMissingAtLoad = false
                root.afterLoadMediaCheck()
            }
        }
        function onDialogRequested() { root.openMissingMediaDialog() }
    }

    // Jelzi, hogy a takarítás sikeresen befejeződött, mehet a kilépés
    property bool isSafeToQuit: false

    // --- Autosave / crash recovery (plan_autosave.md) ---
    property string autosaveBaseline: ""      // key of the last saved/loaded state
    property bool autosaveBaselineValid: false
    property string autosaveLastWritten: ""   // key of the last autosave written
    property string autosaveStatusText: ""    // e.g. "Autosaved 14:32:05"
    property bool autosaveEnabled: true
    property int autosaveIntervalSec: 60
    property bool quitConfirmed: false

    Component.onCompleted: {
        Backend.checkStartupWarnings()
        Qt.callLater(root.maybeShowCodecDialog)
        Backend.shortcuts.attachWindow(root)
        var av = Backend.getSetting("autosave/enabled", true)
        root.autosaveEnabled = (av === true || String(av) === "true")
        var ai = parseInt(Backend.getSetting("autosave/intervalSec", 60))
        if (isNaN(ai)) ai = 60
        root.autosaveIntervalSec = Math.max(10, Math.min(3600, ai))
    }

    // ---- Modal "switching proxy" overlay ---------------------------------
    // beginProxySwitch() opens a window-wide modal popup IMMEDIATELY, then
    // (after a short timer so the popup is painted first) runs applyFn - the
    // synchronous setSetting()+Backend.refreshProxyInstallations() work - and
    // keeps the popup up until the rebuilt timeline can show a picture again:
    //   applying    -> applyFn running; if it reports "no rebuild scheduled"
    //                  the popup closes at once (nothing will ever signal)
    //   waitInstall -> waiting for the coalesced Backend.proxyInstallationChanged
    //   rebuilding  -> reloadAssets() running; closes on
    //                  TimelineEngine.previewReady (first preroll after the
    //                  rebuild; reloadingAssets/timelineReady fire earlier)
    // A 60 s safety timer closes it regardless.
    property bool proxySwitchBusy: false
    property string proxySwitchPhase: ""
    property string proxySwitchLabel: ""
    property var proxySwitchApply: null

    function beginProxySwitch(label, applyFn) {
        proxySwitchLabel = label
        proxySwitchApply = applyFn
        proxySwitchPhase = "applying"
        proxySwitchBusy = true
        proxySwitchPopup.open()
        proxySwitchSafety.restart()
        proxySwitchStart.restart()
        console.log("ProxySwitch: overlay opened -", label)
    }

    function finishProxySwitch(why) {
        if (!proxySwitchBusy) return
        proxySwitchStart.stop()
        proxySwitchSafety.stop()
        proxySwitchBusy = false
        proxySwitchPhase = ""
        proxySwitchApply = null
        proxySwitchPopup.close()
        console.log("ProxySwitch: overlay closed -", why)
    }

    Timer {
        id: proxySwitchStart
        interval: 80
        repeat: false
        onTriggered: {
            var scheduled = false
            try {
                console.log("ProxySwitch: applying (install/uninstall)")
                scheduled = root.proxySwitchApply ? root.proxySwitchApply() : false
                console.log("ProxySwitch: apply done, rebuild scheduled =", scheduled)
            } catch (e) {
                console.warn("ProxySwitch: apply failed:", e)
            }
            if (scheduled) root.proxySwitchPhase = "waitInstall"
            else root.finishProxySwitch("nothing changed")
        }
    }

    Timer {
        id: proxySwitchSafety
        interval: 60000
        repeat: false
        onTriggered: {
            console.warn("ProxySwitch: safety timeout after 60 s in phase", root.proxySwitchPhase, "- closing overlay")
            root.finishProxySwitch("safety timeout")
        }
    }

    Connections {
        target: Backend
        function onProxyInstallationChanged() {
            if (root.proxySwitchBusy && root.proxySwitchPhase === "waitInstall") {
                console.log("ProxySwitch: rebuild starting")
                root.proxySwitchPhase = "rebuilding"
            }
        }
        // Installing proxies resolves the media on a loader thread (see
        // BackendManager::refreshProxyInstallations()): live progress for the
        // project loading dialog, and the end of a pass that changed nothing
        // (e.g. every proxy failed to resolve) must not leave the switching
        // overlay waiting for a rebuild that will never come.
        function onProxyInstallProgress(done, total, fileName) {
            if (loadingDialog.visible && total > 0)
                loadingDialog.setStep("Preparing media " + done + "/" + total + (fileName ? " - " + fileName : ""))
        }
        function onProxyInstallPassFinished(rebuildScheduled) {
            if (!rebuildScheduled && root.proxySwitchBusy && root.proxySwitchPhase === "waitInstall")
                root.finishProxySwitch("nothing changed")
        }
    }

    Connections {
        target: editingWorkspaceLoader.item ? editingWorkspaceLoader.item.timelineEngine : null
        function onPreviewReady() {
            if (root.proxySwitchBusy && root.proxySwitchPhase === "rebuilding")
                root.finishProxySwitch("rebuilt timeline ready (previewReady)")
        }
    }

    Popup {
        id: proxySwitchPopup
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        dim: true
        closePolicy: Popup.NoAutoClose
        padding: 24
        enter: Transition {}
        exit: Transition {}
        z: 10000

        Overlay.modal: Rectangle { color: "#99000000" }

        background: Rectangle {
            color: "#2b2f33"
            border.color: "#f0b030"
            border.width: 1
            radius: 6
        }

        contentItem: Row {
            spacing: 16
            BusyIndicator {
                id: proxySwitchSpinner
                running: proxySwitchPopup.visible
                width: 44
                height: 44
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: root.proxySwitchLabel
                color: "#ffffff"
                font.pixelSize: 16
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    // --- BIZTONSÁGOS LEÁLLÍTÁSI LOGIKA ---

    function checkCleanupAndQuit() {
        if (root.isSafeToQuit) return  // Már elindult a kilépés

        if (loggingWorkspaceLoader.status === Loader.Null &&
            editingWorkspaceLoader.status === Loader.Null &&
            renderWorkspaceLoader.status === Loader.Null &&
            Backend.cacheManager.generatingProxyCount === 0) {

            console.log("All engines destroyed safely. Quitting now.")
            root.isSafeToQuit = true
            forceQuitTimeout.stop()
            Backend.forceQuit()
        } else {
            console.log("Waiting for engines to stop...")
        }
    }

    // Safety net: forceQuit() is a raw _exit(0) that bypasses every C++
    // destructor, so checkCleanupAndQuit() above deliberately WAITS for an
    // in-flight proxy generation to actually confirm it stopped (rather
    // than just assuming cancelAllProxyGeneration() worked) before quitting
    // - otherwise the app would always close instantly but leave a
    // truncated proxy file behind, which is the exact bug this is fixing.
    // That wait is normally sub-second, but ProxyGenerator.cpp documents a
    // known, rare case (a pathologically stalled source - a FIFO, a hung
    // network mount) where the worker's own pipeline teardown can block
    // indefinitely even after a successful cancel. Without this timer,
    // that one rare case would turn "app always closes instantly" into
    // "app can hang closed forever" - strictly worse than before this
    // whole shutdown-cancel mechanism existed.
    Timer {
        id: forceQuitTimeout
        interval: 20000
        repeat: false
        onTriggered: {
            if (!root.isSafeToQuit) {
                console.log("Shutdown taking too long (stalled proxy generation?) - forcing quit anyway")
                root.isSafeToQuit = true
                Backend.forceQuit()
            }
        }
    }

    // --- Autosave timers (plan_autosave.md) ---
    // Establishes the "what is on disk" baseline right after a load/new
    // project, from the LIVE state (the loaded JSON differs from the file in
    // tiny ways), as soon as the app is not busy.
    Timer {
        id: autosaveBaselineTimer
        interval: 2000
        repeat: true
        running: root.isProjectOpen && !root.autosaveBaselineValid
        onTriggered: {
            if (root.autosaveBusy()) return
            root.autosaveBaseline = root.projectStateKey(root.getCompleteProjectJSON())
            root.autosaveBaselineValid = true
        }
    }

    Timer {
        id: autosaveTimer
        interval: root.autosaveIntervalSec * 1000
        repeat: true
        running: root.isProjectOpen && root.autosaveEnabled
        onTriggered: root.autosaveTick()
    }

    // Re-evaluates checkCleanupAndQuit() when the in-flight proxy
    // generation(s) actually finish stopping - the three Loaders'
    // onStatusChanged handlers (further below) only cover their own
    // condition, not this one.
    Connections {
        target: Backend.cacheManager
        function onGeneratingProxyCountChanged() { checkCleanupAndQuit() }
    }

    onClosing: function(close) {
        if (root.isSafeToQuit) {
            close.accepted = true
            return
        }

        if (Backend.signalQuitRequested()) {
            // SIGINT/SIGTERM: never ask. Keep the work as a recovery copy.
            if (unsavedDialog.opened) unsavedDialog.close()
            if (root.autosaveEnabled && root.hasUnsavedChanges())
                root.writeRecoveryCopyNow()
        } else if (!root.quitConfirmed && root.hasUnsavedChanges()) {
            close.accepted = false
            root.guardUnsaved("quitting", function() { root.quitConfirmed = true; root.close() })
            return
        }

        console.log("Initiating safe shutdown sequence...")
        close.accepted = false
        root.visible = false

        // Before tearing anything else down - see checkCleanupAndQuit()'s
        // generatingProxyCount wait, and this function's own comment on
        // why forceQuit() can't be trusted to clean this up itself.
        Backend.cacheManager.cancelAllProxyGeneration()
        forceQuitTimeout.start()

        Backend.projectBinModel.clear()

        loggingWorkspaceLoader.active = false
        editingWorkspaceLoader.active = false
        renderWorkspaceLoader.active = false

        checkCleanupAndQuit()
    }

    // While the unsaved-changes dialog is open: Enter = Save, Esc = Cancel
    // (plan_autosave.md 5a.2 e). Window-scoped but gated on visibility, so
    // they only ever fire for that dialog.
    Shortcut {
        sequence: "Return"
        enabled: unsavedDialog.visible
        onActivated: unsavedDialog.doAction("save")
    }
    Shortcut {
        sequence: "Enter"
        enabled: unsavedDialog.visible
        onActivated: unsavedDialog.doAction("save")
    }
    Shortcut {
        sequence: "Escape"
        enabled: unsavedDialog.visible
        onActivated: unsavedDialog.doAction("cancel")
    }

    function getTimelineClipsForRender() {
        if (!editingWorkspaceLoader.item) {
            console.log("EditingWorkspace not loaded")
            return []
        }

        var workspace = editingWorkspaceLoader.item
        if (!workspace.timelinePanel) {
            console.log("Timeline panel not found")
            return []
        }

        var clips = []
        for (var i = 0; i < workspace.timelinePanel.clipsModel.count; i++) {
            var clip = workspace.timelinePanel.clipsModel.get(i)
            // Hidden video tracks / muted audio tracks are excluded from
            // the EXPORT too, not just from the preview - the same thing
            // Kdenlive and Premiere do. A linked A/V pair stays decoupled
            // here as well, because the video half and the audio half are
            // separate rows on separate tracks: hiding V1 drops only V1's
            // video rows, A1's audio rows still render.
            if (workspace.timelinePanel.isTrackSilenced
                    && workspace.timelinePanel.isTrackSilenced(clip.trackId)) {
                continue
            }
            clips.push({
                clipId: clip.clipId,
                trackId: clip.trackId,
                trackVolume: Math.min(10, workspace.timelinePanel.trackVolumeOf(clip.trackId) * workspace.timelinePanel.masterVolume),
                trackPan: workspace.timelinePanel.trackPanOf(clip.trackId),
                itemName: clip.itemName,
                itemPath: clip.itemPath,
                startTime: clip.startTime,
                durationSeconds: clip.durationSeconds,
                xPos: clip.xPos,
                sourceOffset: clip.sourceOffset || 0,
                // RenderEngine::startRender() defaults both of these to
                // true when absent (RenderEngine.cpp ~line 83-84), which
                // made every row - including audio-only rows from a
                // linked A/V pair - render as BOTH video and audio. That
                // doubled audio under an audiomixer (mixing=TRUE) and,
                // near a one-sided-audio dissolve, rendered a mismatched
                // audio length vs. the live preview. These roles are
                // already correct in clipsModel (set per-row in
                // TimelineDropArea.qml) - just weren't being forwarded.
                hasVideo: clip.hasVideo || false,
                hasAudio: clip.hasAudio || false,
                hasTransition: clip.hasTransition || false,
                transitionDuration: clip.transitionDuration || 0,
                transitionType: clip.transitionType || "",
                effects: clip.effects || "",
                // Title clips have no itemPath at all, so without these
                // two the export path can't tell them apart from a
                // file-backed row with a missing file and drops them
                // silently - the title shows in the Project Monitor but
                // not in the rendered file. RenderEngine::startRender()
                // reads exactly these key names (RenderEngine.cpp's
                // clip.clipKind / clip.titleParams).
                clipKind: clip.clipKind || "",
                titleParams: clip.titleParams || ""
            })
        }

        return clips
    }

    // proxy_build_plan.md Part J.2: every DISTINCT video source-file
    // itemId used by a clip currently on the timeline whose proxy at the
    // project's configured target resolution+format isn't ready (and
    // isn't already queued/generating - re-offering in-flight work would
    // be confusing, not helpful). Deliberately narrower than
    // Backend.projectBinModel.videoItemIds() (which the Proxy tab's bulk
    // button uses on purpose, Part D14): proxying footage that's in the
    // bin but never cut onto the timeline wastes GPU minutes and disk.
    // Returns {missingIds: [...], offlineCount: N} - offline (file
    // genuinely missing from disk, not just lacking a proxy) is reported
    // separately rather than silently folded into "missing", since
    // requestProxyGeneration() would just no-op on those anyway.
    function missingTimelineProxyItemIds() {
        if (!Backend.getSetting("project/proxyEnabled", false)) return {missingIds: [], offlineCount: 0, resolution: ""}

        // Prefer the resolution this project is actually PREVIEWING
        // (proxyActiveResolution) over the separate "what a future bulk-
        // generate defaults to" setting (proxyTargetResolution) - they
        // can legitimately differ (e.g. proxies were bulk-generated at
        // one resolution via the Proxy tab, then set active, without
        // ever changing the target default) and checking the wrong one
        // produces a confusing "N files missing" prompt for a resolution
        // the project doesn't even use, while the resolution actually in
        // use is fully generated. Falls back to target only when nothing
        // is active yet (nothing generated/chosen at all).
        var activeRes = Backend.getSetting("project/proxyActiveResolution", "Original (no proxy)")
        var res = (activeRes && activeRes !== "Original (no proxy)")
            ? activeRes : Backend.getSetting("project/proxyTargetResolution", "960x540")
        var fmt = Backend.getSetting("project/proxyFormat", "h264_intra")

        var clips = getTimelineClipsForRender()
        // Only bin items of type "video" ever get a proxy (images, titles,
        // audio never do), but an image clip also reports hasVideo=true.
        var videoIds = {}
        var vids = Backend.projectBinModel.videoItemIds()
        for (var v = 0; v < vids.length; v++) videoIds[vids[v]] = true
        var seen = {}
        var missingIds = []
        var offlineCount = 0
        for (var i = 0; i < clips.length; i++) {
            var clip = clips[i]
            if (!clip.hasVideo || !clip.itemPath) continue
            var itemId = Backend.projectBinModel.itemIdForPath(clip.itemPath)
            if (!itemId || seen[itemId] || !videoIds[itemId]) continue
            seen[itemId] = true

            // Not registered with CacheManager, or source file gone from
            // disk: nothing can be generated - report as offline.
            if (!Backend.cacheManager.sourceAvailable(itemId)) {
                offlineCount++
                console.warn("missingTimelineProxyItemIds: item offline/unregistered:", itemId, clip.itemPath)
                continue
            }

            var status = Backend.cacheManager.getProxyStatus(itemId, res, fmt)
            if (status === "ready" || status === "generating" || status === "pending") continue
            missingIds.push(itemId)
        }
        return {missingIds: missingIds, offlineCount: offlineCount, resolution: res}
    }

    // Shared by the open-time backfill prompt below and the Proxy tab's
    // bulk "Generate Proxy for All Bin Items" button - skips anything
    // already ready at this exact (resolution, format) variant (registry
    // v3, Part J.1), queues the rest. Returns how many were actually queued.
    function requestProxiesFor(ids, resolution, format, device) {
        var n = 0
        for (var i = 0; i < ids.length; i++) {
            if (Backend.cacheManager.getProxyStatus(ids[i], resolution, format) === "ready") continue
            if (Backend.cacheManager.requestProxyGeneration(ids[i], resolution, format, device))
                n++
        }
        return n
    }

    // proxy_build_plan.md Part J.2: called once the loading dialog closes
    // after a project open/Kdenlive import, if proxy editing is enabled
    // and the timeline has clips whose proxy isn't ready yet. Never
    // silent either way - the user is always asked, never auto-generated
    // and never left in an enabled-but-silently-incomplete state.
    function checkMissingTimelineProxies() {
        if (!root.isProjectOpen) return
        var result = missingTimelineProxyItemIds()
        if (result.missingIds.length === 0) return
        proxyBackfillPromptDialog.missingIds = result.missingIds
        proxyBackfillPromptDialog.offlineCount = result.offlineCount
        // Same resolution missingTimelineProxyItemIds() just checked
        // against (active-over-target preference, see its own comment) -
        // "Generate Now" must queue at that SAME resolution, or it would
        // generate at a different (target) resolution than what's
        // actually missing, leaving the real gap unfilled and this
        // prompt firing again next launch.
        proxyBackfillPromptDialog.checkedResolution = result.resolution
        proxyBackfillPromptDialog.open()
    }

    function getTimelineDurationForRender() {
        if (!editingWorkspaceLoader.item) return 0
        var workspace = editingWorkspaceLoader.item
        if (!workspace.timelinePanel) return 0
        // contentEndSeconds (the true end of the last clip), NOT
        // totalSeconds - totalSeconds now includes 60s of scroll/ruler
        // headroom past the last clip (see TimelinePanel.qml), which
        // would render as extra black tail if used here directly.
        return workspace.timelinePanel.contentEndSeconds || 0
    }

    // Same reach-through pattern as getTimelineClipsForRender()/
    // getTimelineDurationForRender() above, but as a PROPERTY, not a
    // function: the toolbar buttons' `enabled` must re-evaluate when the
    // Loader finishes and when the undo/redo stacks change, and a plain
    // function call is not a binding dependency.
    readonly property var timelinePanelRef:
        editingWorkspaceLoader.item ? editingWorkspaceLoader.item.timelinePanel : null

    // ---- Keyboard shortcuts (plan_shortcuts.md) -------------------------
    // Every application shortcut comes from ONE registry, Backend.shortcuts
    // (src/core/ShortcutManager.cpp): its key table is user-editable in
    // Settings -> Keyboard. It dispatches from an event filter on this
    // window, independent of which panel has keyboard focus, and only while
    // no text field is being edited and no popup/menu/dialog is open (no
    // registry key ever fires while typing - Ctrl+Z stays the field's own
    // undo). "editing"-scope actions additionally need the Editing/Effects
    // layout. Every match ends up in runAction() below.
    readonly property bool shortcutEditingScope: root.isProjectOpen && root.isTimelineWorkspace
                                                 && !!editingWorkspaceLoader.item
    Binding {
        target: Backend.shortcuts
        property: "editingScopeActive"
        value: root.shortcutEditingScope
    }
    // Where keyboard focus goes when text editing ends (Enter/Esc/click outside).
    Binding {
        target: Backend.shortcuts
        property: "focusRoot"
        value: root.isTimelineWorkspace ? editingWorkspaceLoader.item
             : (root.currentWorkspace === "Logging" && loggingWorkspaceLoader.item ? loggingWorkspaceLoader.item
                : root.contentItem)
    }
    Connections {
        target: Backend.shortcuts
        function onActivated(id) { root.runAction(id) }
    }

    // " (Ctrl+S)" for a tooltip/menu text, "" when the action is unbound.
    // Reads Backend.shortcuts.revision so callers' bindings follow rebinds.
    function shortcutHint(id) {
        var t = Backend.shortcuts.revision >= 0 ? Backend.shortcuts.displayText(id) : ""
        return t ? " (" + t + ")" : ""
    }
    function shortcutMenuText(label, id) {
        var t = Backend.shortcuts.revision >= 0 ? Backend.shortcuts.displayText(id) : ""
        return t ? label + "\t" + t : label
    }

    // The single entry point of every registry shortcut.
    function runAction(id) {
        switch (id) {
        case "undo":
            if (root.isProjectOpen && root.isTimelineWorkspace && root.timelinePanelRef) root.timelinePanelRef.undo()
            return
        case "redo":
            if (root.isProjectOpen && root.isTimelineWorkspace && root.timelinePanelRef) root.timelinePanelRef.redo()
            return
        case "save":
            saveProject()
            return
        case "save_as":
            if (root.isProjectOpen) saveAsWindow.show()
            return
        case "new_project":
            root.guardUnsaved("creating a new project", function() {
                newProjectWindow.isNewProject = true
                newProjectWindow.show()
            })
            return
        case "quit":
            root.close()
            return
        }

        // "editing" scope: the dispatcher only gets here while the
        // Editing/Effects layout is shown.
        var ws = editingWorkspaceLoader.item
        if (!ws || !ws.timelinePanel) return
        var tp = ws.timelinePanel
        var eng = ws.timelineEngine
        switch (id) {
        case "play_pause": ws.projectMonitor.togglePlayPause(); break
        case "frame_back": if (eng) eng.stepSeek(eng.position - ws.projectFrameMs()); break
        case "frame_fwd": if (eng) eng.stepSeek(eng.position + ws.projectFrameMs()); break
        case "second_back": if (eng) eng.seek(eng.position - 1000); break
        case "second_fwd": if (eng) eng.seek(eng.position + 1000); break
        case "go_start": if (eng) eng.seek(0); break
        case "go_end": if (eng && eng.totalDuration > 0) eng.seek(eng.totalDuration); break
        case "prev_cut": tp.seekToAdjacentCut(-1); break
        case "next_cut": tp.seekToAdjacentCut(1); break
        case "track_up": tp.moveActiveTrack(-1); break
        case "track_down": tp.moveActiveTrack(1); break
        case "select_at_playhead": tp.selectClipAtPlayhead(); break
        case "split": tp.splitAtPlayhead(); break
        case "trim_start": tp.trimStartToPlayhead(); break
        case "trim_end": tp.trimEndToPlayhead(); break
        case "delete_clip": tp.deleteSelectedClip(); break
        case "toggle_ripple": tp.rippleEditEnabled = !tp.rippleEditEnabled; break
        case "toggle_ripple_all_tracks": tp.rippleAllTracks = !tp.rippleAllTracks; break
        case "toggle_split_mode": tp.splitAllTracksMode = !tp.splitAllTracksMode; break
        case "zoom_in": tp.zoomIn(); break
        case "zoom_out": tp.zoomOut(); break
        case "zoom_fit": tp.zoomToFit(); break
        default: console.warn("runAction: unknown action", id)
        }
    }

    // Ends in-place text editing (shared by the fields' Enter/Esc handlers).
    function releaseTextFocus() { Backend.shortcuts.releaseTextFocus() }

    // --- Autosave / crash recovery helpers (plan_autosave.md) ---
    function currentProjectFilePath() {
        var fileName = Backend.getSetting("project/fileName", "")
        var location = Backend.getSetting("project/location", "")
        if (fileName === "" || location === "") return ""
        if (!fileName.endsWith(".gpucs")) fileName += ".gpucs"
        return location + "/" + fileName
    }
    function autosavePathFor(projectPath) { return projectPath + ".autosave" }

    // Comparison key: the project JSON with the fields that change on every
    // call (lastSaved, currentWorkspace) removed, so an untouched project
    // does not look "changed" just because time passed.
    function projectStateKey(jsonText) {
        try {
            var o = JSON.parse(jsonText)
            if (o.projectSettings) {
                delete o.projectSettings.lastSaved
                delete o.projectSettings.currentWorkspace
            }
            if (o.editing) {
                // Derived from the clips (content end + scroll headroom), not a
                // user edit: it changes transiently while a freshly created
                // project's timeline initializes, which otherwise produced a
                // false autosave (plan_autosave.md test 9). The clips
                // themselves are still compared, so real edits are never missed.
                delete o.editing.totalSeconds
            }
            return JSON.stringify(o)
        } catch (e) { return "" }
    }

    function autosaveBusy() {
        if (!isProjectOpen) return true
        if (loadingDialog.visible) return true
        if (!editingWorkspaceLoader.item) return true   // otherwise the timeline would autosave empty
        var eng = editingWorkspaceLoader.item.timelineEngine
        if (eng && (eng.playing || eng.reloadingAssets)) return true
        if (timelinePanelRef && timelinePanelRef.undoDepth > 0) return true   // open edit operation
        if (proxySwitchBusy) return true
        return false
    }

    function autosaveTick() {
        if (!autosaveBaselineValid || autosaveBusy()) return
        var path = currentProjectFilePath()
        if (path === "") return
        var json = getCompleteProjectJSON()
        var key = projectStateKey(json)
        if (key === "") return
        if (key === autosaveBaseline) {
            // Back to the saved state (e.g. via undo): nothing to keep.
            if (autosaveLastWritten !== "") {
                Backend.removeFile(autosavePathFor(path))
                autosaveLastWritten = ""
                autosaveStatusText = ""
            }
            return
        }
        if (key === autosaveLastWritten) return   // already written this exact state
        if (Backend.saveProjectToFile(autosavePathFor(path), json)) {
            autosaveLastWritten = key
            autosaveStatusText = "Autosaved " + Qt.formatTime(new Date(), "HH:mm:ss")
            console.log("Autosave written:", autosavePathFor(path))
        } else {
            autosaveStatusText = "Autosave FAILED"
            console.error("Autosave failed:", autosavePathFor(path))
        }
    }

    // Last-chance recovery write used on signal-initiated quit; unlike
    // autosaveTick() it ignores the busy checks (playing etc.).
    function writeRecoveryCopyNow() {
        if (!editingWorkspaceLoader.item) return
        var path = currentProjectFilePath()
        if (path === "") return
        var recPath = autosavePathFor(path)
        if (Backend.saveProjectToFile(recPath, getCompleteProjectJSON()))
            console.log("Signal quit: recovery copy written:", recPath)
        else
            console.error("Signal quit: recovery copy FAILED:", recPath)
    }

    // True if there are unsaved changes relative to the on-disk project.
    // Independent of whether autosave is enabled.
    function hasUnsavedChanges() {
        if (!isProjectOpen) return false
        if (!autosaveBaselineValid) return false
        if (!editingWorkspaceLoader.item) return false
        var key = projectStateKey(getCompleteProjectJSON())
        return key !== "" && key !== autosaveBaseline
    }

    function guardUnsaved(actionText, actionFn) {
        if (!hasUnsavedChanges()) { actionFn(); return }
        unsavedDialog.actionText = actionText
        unsavedDialog.errorText = ""
        unsavedDialog.pendingAction = actionFn
        unsavedDialog.open()
    }

    function saveProject() {
        if (!isProjectOpen) return false

        var fullPath = currentProjectFilePath()
        if (fullPath === "") {
            console.log("Error: Project file name or location not set.")
            return false
        }

        var completeJSON = root.getCompleteProjectJSON()

        // Keep a .bak of the previous version (non-fatal if it fails).
        if (!Backend.backupProjectFile(fullPath))
            console.warn("Could not write .bak backup for:", fullPath)

        if (Backend.saveProjectToFile(fullPath, completeJSON)) {
            console.log("Project saved successfully to:", fullPath)
            Backend.addToRecentProjects(fullPath, Backend.getSetting("project/name", "Untitled"))
            root.autosaveBaseline = projectStateKey(completeJSON)
            root.autosaveBaselineValid = true
            root.autosaveLastWritten = ""
            root.autosaveStatusText = ""
            Backend.removeFile(autosavePathFor(fullPath))   // manual save makes the recovery copy redundant
            return true
        } else {
            console.log("Error: Failed to save project to:", fullPath)
            return false
        }
    }

    // Save As = "this same editing session, stored somewhere new". The
    // ORIGINAL .gpucs and its .cache/ are never touched: no move, no
    // delete, no write. Deliberately does NOT call resetTimeline() or
    // clear the project bin (unlike the New Project flow below) - the open
    // session's content is exactly what is being saved - and deliberately
    // does NOT clear the undo/redo stacks: the clip set is identical
    // before and after, so every snapshot is still a valid state of this
    // same document (clearUndoHistory() exists for project SWITCHES).
    //
    // Returns "" on success, or an error message for the dialog.
    function saveProjectAs(parentDir, projectName, fileName) {
        if (!isProjectOpen) return "No project is open."

        // Remember the OLD project path before the settings below are
        // rewritten, so its stale recovery copy can be removed on success.
        var oldFullPath = currentProjectFilePath()

        // --- 1. all fallible filesystem work FIRST, before any state
        // mutation (same rule as the New Project OK handler) ---
        if (Backend.projectFolderWouldConflict(parentDir, projectName)) {
            return "\"" + Backend.resolveProjectFolderPath(parentDir, projectName)
                 + "\" already exists. Choose a different project name or location."
        }
        var newDir = Backend.createProjectFolder(parentDir, projectName)
        if (newDir === "") {
            return "Could not create the project folder in \"" + parentDir
                 + "\". Check that the location exists and is writable."
        }

        var oldDir = Backend.getSetting("project/location", "")
        var newFileName = fileName.endsWith(".gpucs") ? fileName : (fileName + ".gpucs")
        var newFullPath = newDir + "/" + newFileName

        // --- 2. warm cache for the copy. Non-fatal on failure: the cache
        // is derived data and validateAllItems() re-queues what's missing.
        // saveRegistry() first so the on-disk registry matches memory
        // (it is otherwise only written every 25% of generation progress).
        if (oldDir !== "" && oldDir !== newDir) {
            Backend.cacheManager.saveRegistry()
            if (!Backend.copyProjectCache(oldDir, newDir)) {
                console.warn("Save As: cache copy incomplete - affected waveforms "
                           + "will be regenerated on demand")
            }
        }

        // --- 3. rebind the session identity. Only these three keys:
        // description/profile/tracks/thumbnails/decoder are NOT a storage
        // concern and must survive untouched. ---
        Backend.setSetting("project/fileName", newFileName)
        Backend.setSetting("project/location", newDir)
        Backend.setSetting("project/name", projectName)
        if (editingWorkspaceLoader.item && editingWorkspaceLoader.item.timelineEngine)
            editingWorkspaceLoader.item.timelineEngine.setProjectDir(newDir)

        // --- 4. point the cache manager at the new folder. isNewProject
        // false: the copied registry SHOULD be loaded and validated (that
        // validation is also what re-queues anything the copy missed, and
        // demotes any item that was mid-generation back to pending). ---
        Backend.initializeCacheForProject(newFullPath, false)

        // --- 5. rebase the ABSOLUTE waveform paths held per clip.
        // CacheManager::getWaveformPath() returns cacheDir + "/" + relPath
        // and EditingWorkspace.getProjectJSON() serializes it verbatim, so
        // without this the new .gpucs would carry absolute references into
        // the OLD project's .cache - a cross-project dependency that
        // breaks as soon as the old project is deleted. ---
        if (root.timelinePanelRef) {
            root.timelinePanelRef.rebaseWaveformPaths(oldDir + "/.cache",
                                                      newDir + "/.cache")
        }

        // --- 6. write it out. saveProject() also handles the ".gpucs"
        // suffix and adds the Recent Projects entry - the OLD entry is
        // left in place on purpose: both files exist and both are
        // openable, so both belong in the MRU list. ---
        var completeJSON = root.getCompleteProjectJSON()
        if (!Backend.saveProjectToFile(newFullPath, completeJSON)) {
            // The session is already rebound at this point, pointing at a
            // valid (if empty) folder - a plain Ctrl+S will retry.
            return "Could not write \"" + newFullPath
                 + "\". Check free disk space and permissions, then use Save."
        }
        Backend.addToRecentProjects(newFullPath, projectName)

        root.projectIdentityRevision++
        Backend.logOperation("project_save_as", {
            from: oldDir, to: newDir, fileName: newFileName, name: projectName
        })
        console.log("Project saved as:", newFullPath)

        root.autosaveBaseline = projectStateKey(completeJSON)
        root.autosaveBaselineValid = true
        root.autosaveLastWritten = ""
        root.autosaveStatusText = ""
        Backend.removeFile(autosavePathFor(newFullPath))
        if (oldFullPath !== "") Backend.removeFile(autosavePathFor(oldFullPath))
        return ""
    }

    function getCompleteProjectJSON() {
        var projectData = {
            version: "1.0",
            projectSettings: {
                fileName: Backend.getSetting("project/fileName", ""),
                location: Backend.getSetting("project/location", ""),
                name: Backend.getSetting("project/name", "Untitled Project"),
                description: Backend.getSetting("project/description", ""),
                profile: {
                    width: Backend.getSetting("project/width", "auto"),
                    height: Backend.getSetting("project/height", "auto"),
                    fps: Backend.getSetting("project/fps", "auto")
                },
                videoTracks: Backend.getSetting("project/videoTracks", 2),
                audioTracks: Backend.getSetting("project/audioTracks", 2),
                thumbnails: {
                    video: Backend.getSetting("project/videoThumbnails", true),
                    audio: Backend.getSetting("project/audioThumbnails", true)
                },
                decoder: Backend.getSetting("project/decoder", "nvdec_h264"),
                proxy: {
                    enabled: Backend.getSetting("project/proxyEnabled", false),
                    targetResolution: Backend.getSetting("project/proxyTargetResolution", "960x540"),
                    activeResolution: Backend.getSetting("project/proxyActiveResolution", "Original (no proxy)"),
                    format: Backend.getSetting("project/proxyFormat", "h264_intra"),
                    pauseDuringPlayback: Backend.getSetting("project/proxyPauseDuringPlayback", false),
                    computeDevice: Backend.getSetting("project/proxyComputeDevice", "")
                },
                clipFitting: {
                    scaling: Backend.getSetting("project/fitScaling", "fit"),
                    anchorH: Backend.getSetting("project/fitAnchorH", "center"),
                    anchorV: Backend.getSetting("project/fitAnchorV", "center")
                },
                lastSaved: new Date().toISOString(),
                currentWorkspace: currentWorkspace
            },
            projectBin: {},
            editing: {},
            audio: {},
            effects: {}
        }

        if (loggingWorkspaceLoader.item) {
            try {
                var loggingJSON = loggingWorkspaceLoader.item.getProjectJSON()
                projectData.projectBin = JSON.parse(loggingJSON)
            } catch(e) {
                console.error("Failed to get LoggingWorkspace data:", e)
            }
        }

        if (editingWorkspaceLoader.item) {
            try {
                var editingJSON = editingWorkspaceLoader.item.getProjectJSON()
                projectData.editing = JSON.parse(editingJSON)
            } catch(e) {
                console.error("Failed to get EditingWorkspace data:", e)
            }
        }

        return JSON.stringify(projectData, null, 2)
    }

    ProjectSettingsDialog {
        transientParent: root
        id: newProjectWindow

        transformCountFn: function() {
            return root.timelinePanelRef ? root.timelinePanelRef.countTransformClips() : 0
        }

        onProxySwitchRequested: function(label) {
            root.beginProxySwitch(label, function() { return Backend.refreshProxyInstallations() })
        }

        onAccepted: {
            // plan_home_end_canvasframe.md: apply the canvas-frame view
            // preference on every path (new project and open-project settings).
            if (editingWorkspaceLoader.item && editingWorkspaceLoader.item.refreshCanvasFrameSetting)
                editingWorkspaceLoader.item.refreshCanvasFrameSetting()

            // Guarded: this dialog is ALSO reused for File > Project
            // Settings... on an already-open project (isNewProject set to
            // false there). Unguarded, Save on an open project would wipe
            // the Project Bin and reset the timeline on every settings
            // tweak - this body is the "create a brand new project" flow,
            // not "I changed a setting".
            if (!newProjectWindow.isNewProject) {
                // The video track's restriction caps (canvas size / fps) are
                // only applied inside TimelineEngine::setClips(), and an
                // unchanged clip list is skipped there - so a profile change
                // on an open project would not reach the preview until the
                // next load. reloadAssets() is the existing "force a full
                // rebuild" path (the proxy feature uses it the same way).
                if (newProjectWindow.profileChanged && root.isProjectOpen
                        && editingWorkspaceLoader.item && editingWorkspaceLoader.item.timelineEngine) {
                    console.log("Project profile changed - rebuilding timeline with the new canvas")
                    var rr = newProjectWindow.rescaleRequest
                    var rescaled = 0
                    if (rr && root.timelinePanelRef)
                        rescaled = root.timelinePanelRef.rescaleClipTransforms(rr.oldW, rr.oldH, rr.newW, rr.newH)
                    newProjectWindow.rescaleRequest = null
                    if (rescaled > 0) {
                        // The changed effects make setClips() take its full
                        // rebuild, which also applies the new canvas caps:
                        // one rebuild for both.
                        editingWorkspaceLoader.item.updateTimelineEngine()
                    } else {
                        editingWorkspaceLoader.item.timelineEngine.reloadAssets()
                    }
                }
                return
            }

            console.log("Creating new project with selected settings...")
            root.autosaveBaselineValid = false
            root.autosaveLastWritten = ""
            root.autosaveStatusText = ""
            Backend.projectBinModel.clear()
            Backend.mediaAvailability.reset()

            if (editingWorkspaceLoader.item) {
                editingWorkspaceLoader.item.resetTimeline()
            }

            root.isProjectOpen = true
            root.currentWorkspace = "Logging"

            var fn = Backend.getSetting("project/fileName", "")
            var loc = Backend.getSetting("project/location", "")
            var pn = Backend.getSetting("project/name", "Untitled")

            if (editingWorkspaceLoader.item && editingWorkspaceLoader.item.timelineEngine)
                editingWorkspaceLoader.item.timelineEngine.setProjectDir(loc)

            if (fn !== "" && loc !== "") {
                var fullPath = loc + "/" + fn
                if (!fullPath.endsWith(".gpucs")) fullPath += ".gpucs"
                Backend.addToRecentProjects(fullPath, pn)

                // Initialize cache for the new project - isNewProject:true
                // so a leftover cache_registry.json from a DIFFERENT,
                // unrelated project that happened to be saved in this same
                // folder isn't inherited (see CacheManager::initialize()).
                Backend.initializeCacheForProject(fullPath, true)
                console.log("Cache initialized for new project at:", loc)

                // Write the .gpucs out immediately. A project's folder
                // now exists from the moment it is CREATED, not from the
                // first Ctrl+S, so the folder should never be a mystery
                // empty directory in the user's Videos folder - it is a
                // real, openable (if empty) project from the start. This
                // also means Save/Open/Recent all work before the user
                // has ever pressed Save.
                root.saveProject()
            }
        }
    }

    FileDialog {
        id: openProjectDialog
        title: "Open Project"
        nameFilters: ["GPU Cine Studio Projects (*.gpucs)"]
        fileMode: FileDialog.OpenFile
        onAccepted: {
            var filePath = selectedFile.toString().replace("file://", "")
            loadProject(filePath)
        }
    }

    About { id: aboutWindow; transientParent: root }
    GPUInfoDialog { id: gpuInfoDialog; transientParent: root }
    LoadingDialog {
        transientParent: root
        id: loadingDialog
        // Fires the open-time proxy-backfill check (proxy_build_plan.md
        // Part J.2) once this modal window actually closes - Qt.callLater
        // so it finishes tearing down first; opening another modal Dialog
        // on top of a still-closing ApplicationModal Window can land it
        // behind the dying window on X11 (open()'s own raise()/
        // requestActivate() calls above exist for the same class of
        // problem). Only after TimelineEngine.timelineReady has actually
        // fired (loadProjectJSON()/finish() are what close this window)
        // is the timeline's clip list guaranteed populated to query.
        onVisibleChanged: {
            if (!visible && root.pendingProxyBackfillCheck) {
                root.pendingProxyBackfillCheck = false
                Qt.callLater(root.afterLoadMediaCheck)
            }
        }
    }
    MissingMediaDialog {
        id: missingMediaDialog
        transientParent: root
        workspace: editingWorkspaceLoader.item
        onStatusMessage: function(text) { root.showMediaStatus(text) }
        // The proxy-backfill prompt comes after this dialog, never together.
        onClosedAfterLoad: Qt.callLater(root.checkMissingTimelineProxies)
    }
    SettingsDialog {
        transientParent: root
        id: settingsWindow
        onAutosaveSettingsChanged: {
            var av = Backend.getSetting("autosave/enabled", true)
            root.autosaveEnabled = (av === true || String(av) === "true")
            var ai = parseInt(Backend.getSetting("autosave/intervalSec", 60))
            if (isNaN(ai)) ai = 60
            root.autosaveIntervalSec = Math.max(10, Math.min(3600, ai))
        }
    }

    // --- Crash recovery prompt (plan_autosave.md 5.3) ---
    Dialog {
        id: recoveryDialog
        title: "Unsaved changes found"
        modal: true
        anchors.centerIn: parent
        closePolicy: Popup.NoAutoClose

        property string projectPath: ""
        property string autosavePath: ""

        ColumnLayout {
            spacing: 12
            Label {
                Layout.preferredWidth: 440
                wrapMode: Text.WordWrap
                color: "#eff0f1"
                text: "A recovery copy of this project exists. It was written after the last save, so the application was probably closed without saving or crashed."
            }
            Label {
                Layout.preferredWidth: 440
                wrapMode: Text.WordWrap
                color: "#a0a4a8"
                font.pixelSize: 12
                text: "Recovery copy: " + Backend.fileModifiedText(recoveryDialog.autosavePath)
            }
            Label {
                Layout.preferredWidth: 440
                wrapMode: Text.WordWrap
                color: "#a0a4a8"
                font.pixelSize: 12
                text: "Project file: " + Backend.fileModifiedText(recoveryDialog.projectPath)
            }
        }
        footer: RowLayout {
            spacing: 10
            Item { Layout.fillWidth: true }
            Button {
                text: "Restore"
                onClicked: {
                    var p = recoveryDialog.projectPath
                    var a = recoveryDialog.autosavePath
                    recoveryDialog.close()
                    root.loadProjectFrom(p, a)
                }
            }
            Button {
                text: "Open last saved"
                onClicked: {
                    var p = recoveryDialog.projectPath
                    recoveryDialog.close()
                    root.loadProjectFrom(p, p)
                }
            }
            Button {
                text: "Cancel"
                onClicked: recoveryDialog.close()
            }
        }
    }

    // --- Unsaved-changes prompt (quit / project switch) (plan_autosave.md 5a) ---
    Dialog {
        id: unsavedDialog
        title: "Unsaved changes"
        modal: true
        anchors.centerIn: parent
        closePolicy: Popup.NoAutoClose

        property var pendingAction: null
        property string actionText: ""
        property string errorText: ""

        ColumnLayout {
            spacing: 12
            Label {
                Layout.preferredWidth: 440
                wrapMode: Text.WordWrap
                color: "#eff0f1"
                text: "The project \"" + Backend.getSetting("project/name", "Untitled") + "\" has changes that were not saved. Save them before " + unsavedDialog.actionText + "?"
            }
            Label {
                visible: text !== ""
                Layout.preferredWidth: 440
                wrapMode: Text.WordWrap
                color: "#f0b030"
                text: unsavedDialog.errorText
            }
        }
        footer: RowLayout {
            spacing: 10
            Item { Layout.fillWidth: true }
            Button { text: "Save"; onClicked: unsavedDialog.doAction("save") }
            Button { text: "Don't save"; onClicked: unsavedDialog.doAction("discard") }
            Button { text: "Cancel"; onClicked: unsavedDialog.doAction("cancel") }
        }

        function doAction(kind) {
            if (kind === "cancel") {
                pendingAction = null
                actionText = ""
                errorText = ""
                close()
                return
            }
            var act = pendingAction
            if (kind === "save") {
                if (!root.saveProject()) {
                    errorText = (actionText === "quitting")
                        ? "Saving failed – the application was not closed."
                        : ("Saving failed – " + actionText + " was not performed.")
                    return
                }
            } else if (kind === "discard") {
                Backend.removeFile(autosavePathFor(root.currentProjectFilePath()))
            }
            pendingAction = null
            errorText = ""
            close()
            if (act) act()
        }
    }

    SaveAsDialog {
        transientParent: root
        id: saveAsWindow
        onAccepted: function(parentDir, projectName, fileName) {
            var err = root.saveProjectAs(parentDir, projectName, fileName)
            if (err !== "") {
                saveAsWindow.showError(err)   // stay open so the user can correct
                return
            }
            saveAsWindow.close()
        }
    }

    ImportKdenliveDialog {
        transientParent: root
        id: importKdenliveWindow
        onAccepted: function(kdenlivePath, parentDir, projectName, fileName, options) {
            var err = root.commitKdenliveImport(kdenlivePath, parentDir, projectName, fileName, options)
            if (err !== "") {
                importKdenliveWindow.showError(err)
                return
            }
            importKdenliveWindow.close()
        }
    }

    // Mirrors the New Project flow (ProjectSettingsDialog.qml's
    // onAccepted at this file's own newProjectWindow handler) and
    // loadProject() below: all fallible filesystem work happens BEFORE
    // any state mutation, so a failure (name conflict, bad folder)
    // leaves the current session untouched and the dialog open to retry.
    function commitKdenliveImport(kdenlivePath, parentDir, projectName, fileName, options) {
        root.autosaveBaselineValid = false
        root.autosaveLastWritten = ""
        root.autosaveStatusText = ""
        var convert = Backend.convertKdenliveProject(kdenlivePath, options || {})
        if (!convert.ok) return convert.error || "Could not read this Kdenlive project."

        if (Backend.projectFolderWouldConflict(parentDir, projectName)) {
            return "\"" + Backend.resolveProjectFolderPath(parentDir, projectName)
                 + "\" already exists. Choose a different project name or location."
        }
        var newDir = Backend.createProjectFolder(parentDir, projectName)
        if (newDir === "") {
            return "Could not create the project folder in \"" + parentDir
                 + "\". Check that the location exists and is writable."
        }

        // --- from here on, commit - no further failure path aborts ---
        Backend.projectBinModel.clear()
        Backend.mediaAvailability.reset()
        if (editingWorkspaceLoader.item) editingWorkspaceLoader.item.resetTimeline()

        var fn = fileName.endsWith(".gpucs") ? fileName : (fileName + ".gpucs")
        Backend.setSetting("project/fileName", fn)
        Backend.setSetting("project/location", newDir)
        Backend.setSetting("project/name", projectName)
        Backend.setSetting("project/description", convert.projectSettings.description)
        Backend.setSetting("project/width", convert.projectSettings.width)
        Backend.setSetting("project/height", convert.projectSettings.height)
        Backend.setSetting("project/fps", convert.projectSettings.fps)
        // Make the imported size/rate show up as a (custom) profile if no
        // existing profile matches it exactly.
        Backend.profileStore.ensureImportedProfile(convert.projectSettings.width,
                                                   convert.projectSettings.height,
                                                   String(convert.projectSettings.fps))
        Backend.setSetting("project/videoTracks", convert.projectSettings.videoTracks)
        Backend.setSetting("project/audioTracks", convert.projectSettings.audioTracks)
        Backend.setSetting("project/videoThumbnails", true)
        Backend.setSetting("project/audioThumbnails", true)
        Backend.setSetting("project/decoder", Backend.preferredDecoder || "nvdec_h264")
        Backend.setSetting("project/kdenliveImportSource", kdenlivePath)
        // Same global-default seeding a brand-new (non-import) project gets
        // via ProjectSettingsDialog.loadSettings() - Kdenlive import skips
        // that dialog entirely, so it has to be done here instead.
        // Newly added clips are cropped to fill the frame by default (existing
        // clips keep the importer's own transforms).
        Backend.setSetting("project/fitScaling", "fill")
        Backend.setSetting("project/fitAnchorH", "center")
        Backend.setSetting("project/fitAnchorV", "center")
        Backend.setSetting("project/proxyEnabled", Backend.getSetting("proxy/defaultEnabled", false))
        Backend.setSetting("project/proxyTargetResolution", Backend.getSetting("proxy/defaultTargetResolution", "960x540"))
        Backend.setSetting("project/proxyActiveResolution", "Original (no proxy)")
        Backend.setSetting("project/proxyFormat", Backend.getSetting("proxy/defaultFormat", "h264_intra"))
        Backend.setSetting("project/proxyPauseDuringPlayback", Backend.getSetting("proxy/defaultPauseDuringPlayback", false))
        Backend.setSetting("project/proxyComputeDevice", Backend.getSetting("proxy/defaultComputeDevice", ""))

        root.isProjectOpen = true
        if (editingWorkspaceLoader.item && editingWorkspaceLoader.item.timelineEngine)
            editingWorkspaceLoader.item.timelineEngine.setProjectDir(newDir)

        var fullPath = newDir + "/" + fn
        // isNewProject:true - a leftover cache_registry.json from a
        // different project in a reused folder must not be inherited.
        Backend.initializeCacheForProject(fullPath, true)
        root.pendingProxyBackfillCheck = true

        loadingDialog.reset()
        loadingDialog.open()
        loadingDialog.setWorkspace("Project Bin")
        Backend.projectBinModel.loadFromJson(convert.projectBinJson)
        root.awaitingMissingAtLoad = false
        root.startMediaCheck(JSON.parse(convert.editingJson).clips || [])
        loadingDialog.setWorkspace("Editing Workspace")
        // loadProjectJSON() closes loadingDialog itself once the engine
        // signals timelineReady - same as the normal Open Project path.
        editingWorkspaceLoader.item.loadProjectJSON(convert.editingJson, loadingDialog)

        Backend.writeKdenliveImportReport(newDir, convert.report)
        Backend.setSetting("project/kdenliveImportReport", newDir + "/.import/kdenlive-import-report.json")

        root.saveProject()
        root.currentWorkspace = "Editing"
        Backend.logOperation("project_import_kdenlive", {
            source: kdenlivePath, dir: newDir,
            clips: convert.counts.clips, unsupported: convert.unsupported.length
        })
        return ""
    }

    function loadProject(filePath) {
        var autosavePath = autosavePathFor(filePath)
        if (!Backend.fileExists(autosavePath)) { loadProjectFrom(filePath, filePath); return }

        // Is the recovery copy valid JSON with the expected shape?
        var text = Backend.loadProjectFromFile(autosavePath)
        var valid = false
        try { var o = JSON.parse(text); valid = !!(o && o.projectSettings && o.editing) } catch (e) {}
        if (!valid) {
            console.warn("Autosave file is not valid JSON, ignoring:", autosavePath)
            loadProjectFrom(filePath, filePath)
            return   // do NOT delete the bad file; the next manual save removes it
        }
        // If it matches the project file, there is nothing to ask.
        if (projectStateKey(text) === projectStateKey(Backend.loadProjectFromFile(filePath))) {
            Backend.removeFile(autosavePath)
            loadProjectFrom(filePath, filePath)
            return
        }
        recoveryDialog.projectPath = filePath
        recoveryDialog.autosavePath = autosavePath
        recoveryDialog.open()
    }

    function loadProjectFrom(filePath, contentPath) {
        root.autosaveBaselineValid = false
        root.autosaveLastWritten = ""
        root.autosaveStatusText = ""

        loadingDialog.reset()
        loadingDialog.open()
        loadingDialog.setStep("Reading project file...")

        var jsonContent = Backend.loadProjectFromFile(contentPath)
        if (!jsonContent) {
            loadingDialog.addLog("Error: Failed to load project from: " + filePath)
            loadingDialog.close()
            return
        }

        try {
            var projectData = JSON.parse(jsonContent)
            loadingDialog.setStep("Parsing project data...")

            loadingDialog.setWorkspace("Project Settings")
            if (projectData.projectSettings) {
                var settings = projectData.projectSettings
                Backend.setSetting("project/fileName", settings.fileName || "")
                loadingDialog.setStep("Setting project name: " + (settings.name || "Untitled Project"))
                // Trust where the file ACTUALLY is over what was
                // serialized into it - the user may have moved or renamed
                // the project folder since the last save, and
                // initializeCacheForProject() below derives the cache dir
                // from this same real path.
                var actualDir = filePath.substring(0, filePath.lastIndexOf("/"))
                var resolvedProjectDir = actualDir || (settings.location || "")
                Backend.setSetting("project/location", resolvedProjectDir)
                if (editingWorkspaceLoader.item && editingWorkspaceLoader.item.timelineEngine)
                    editingWorkspaceLoader.item.timelineEngine.setProjectDir(resolvedProjectDir)

                // Must run BEFORE loadFromJson() below, not after - the
                // Project Bin registers each item with CacheManager as it
                // loads (ProjectBinModel::revalidateTree()), and this is
                // what points CacheManager at THIS project's cache dir/
                // registry in the first place. Doing it after (as this
                // code used to) meant every registration from the open
                // path landed in - and was then immediately discarded by -
                // whatever project was open PREVIOUS to this one: its
                // loadRegistry() call clears m_items, and in the window
                // before that call its saveRegistry() calls wrote the new
                // project's items into the OLD project's cache_registry.json.
                // The Kdenlive import path already got this ordering right.
                Backend.initializeCacheForProject(filePath)
                root.pendingProxyBackfillCheck = true
                Backend.setSetting("project/name", settings.name || "Untitled Project")
                Backend.setSetting("project/description", settings.description || "")

                if (settings.profile) {
                    loadingDialog.setStep("Setting profile: " + (settings.profile.width || "auto") + "x" + (settings.profile.height || "auto") + " @ " + (settings.profile.fps || "auto") + " fps")
                    Backend.setSetting("project/width", settings.profile.width || "auto")
                    Backend.setSetting("project/height", settings.profile.height || "auto")
                    Backend.setSetting("project/fps", settings.profile.fps || "auto")
                }

                Backend.setSetting("project/videoTracks", settings.videoTracks || 2)
                Backend.setSetting("project/audioTracks", settings.audioTracks || 2)

                if (settings.thumbnails) {
                    Backend.setSetting("project/videoThumbnails", settings.thumbnails.video !== undefined ? settings.thumbnails.video : true)
                    Backend.setSetting("project/audioThumbnails", settings.thumbnails.audio !== undefined ? settings.thumbnails.audio : true)
                }

                Backend.setSetting("project/decoder", settings.decoder || "nvdec_h264")

                // Older .gpucs files saved before Phase 2 of the proxy
                // feature have no "proxy" key at all - fall back to the
                // same global defaults a brand-new project would get.
                // Projects saved before "Clip fitting" existed have no
                // clipFitting key: fit + centre = the old behaviour.
                var fitSettings = settings.clipFitting || {}
                Backend.setSetting("project/fitScaling", fitSettings.scaling || "fit")
                Backend.setSetting("project/fitAnchorH", fitSettings.anchorH || "center")
                Backend.setSetting("project/fitAnchorV", fitSettings.anchorV || "center")

                var proxySettings = settings.proxy || {}
                Backend.setSetting("project/proxyEnabled",
                    proxySettings.enabled !== undefined ? proxySettings.enabled : Backend.getSetting("proxy/defaultEnabled", false))
                Backend.setSetting("project/proxyTargetResolution",
                    proxySettings.targetResolution || Backend.getSetting("proxy/defaultTargetResolution", "960x540"))
                Backend.setSetting("project/proxyActiveResolution",
                    proxySettings.activeResolution || "Original (no proxy)")
                Backend.setSetting("project/proxyFormat",
                    proxySettings.format || Backend.getSetting("proxy/defaultFormat", "h264_intra"))
                Backend.setSetting("project/proxyPauseDuringPlayback",
                    proxySettings.pauseDuringPlayback !== undefined ? proxySettings.pauseDuringPlayback : Backend.getSetting("proxy/defaultPauseDuringPlayback", false))
                Backend.setSetting("project/proxyComputeDevice",
                    proxySettings.computeDevice !== undefined ? proxySettings.computeDevice : Backend.getSetting("proxy/defaultComputeDevice", ""))
            }

            loadingDialog.setWorkspace("Project Bin")
            if (projectData.projectBin && projectData.projectBin.sourceFiles) {
                var sourceFiles = projectData.projectBin.sourceFiles
                for (var i = 0; i < sourceFiles.length; i++) {
                    var file = sourceFiles[i]
                    loadingDialog.setStep("Loading file: " + (file.name || file.path || "Unknown"))
                }
                var projectBinJson = JSON.stringify(sourceFiles)
                Backend.projectBinModel.loadFromJson(projectBinJson)
                loadingDialog.setStep("Loaded " + sourceFiles.length + " files")
            } else {
                loadingDialog.setStep("No source files to load")
            }
            root.awaitingMissingAtLoad = false
            root.startMediaCheck((projectData.editing && projectData.editing.clips) ? projectData.editing.clips : [])

            // Install this project's proxies now - it needs BOTH this
            // project's own proxy settings (restored above; the pass
            // inside initializeCacheForProject() ran against the PREVIOUS
            // project's/session's values) AND the loaded Project Bin
            // (refreshProxyInstallations() builds its desired set from the
            // bin's video items, so before loadFromJson() it sees nothing
            // on a fresh start). It must also precede loadProjectJSON()
            // below so the timeline is built straight from the proxies
            // instead of from the originals plus a second rebuild. Runs
            // even when the project has no source files, so proxies left
            // installed by a previously open project get uninstalled.
            // The install itself is asynchronous (assets are resolved on the
            // loader thread, this returns at once): the engine parks the clip
            // list below until the pass has finished, and the loading dialog
            // shows "Preparing media n/N" meanwhile.
            Backend.refreshProxyInstallations()

            loadingDialog.setWorkspace("Editing Workspace")
            if (projectData.editing && editingWorkspaceLoader.item) {
                var editingJson = JSON.stringify(projectData.editing)
                var clipCount = projectData.editing.clips ? projectData.editing.clips.length : 0
                loadingDialog.setStep("Loading " + clipCount + " clips to timeline...")
                editingWorkspaceLoader.item.loadProjectJSON(editingJson, loadingDialog)
            } else {
                loadingDialog.setStep("No editing data to load")
                loadingDialog.finish()
            }

            var projName = Backend.getSetting("project/name", filePath.split('/').pop())
            Backend.addToRecentProjects(filePath, projName)

            root.isProjectOpen = true
            root.currentWorkspace = "Editing"

            console.log("Project loaded successfully from:", filePath)

            if (contentPath !== filePath) {
                // Restored state: the on-disk .gpucs is OLDER than this, so
                // this counts as "not saved" until the next manual save.
                root.autosaveBaseline = "<restored>"
                root.autosaveBaselineValid = true
                root.autosaveLastWritten = projectStateKey(jsonContent)
                root.autosaveStatusText = "Restored from autosave – not saved yet"
            }
        } catch(e) {
            console.error("Failed to parse project JSON:", e)
            loadingDialog.addLog("Error: " + e.toString())
            loadingDialog.close()
            root.pendingProxyBackfillCheck = false
        }
    }

    // Shown at startup when an essential codec feature (H.264/H.265 or AAC
    // playback, MP4 render) is missing - typically the AppImage on a host
    // without gst-libav. "Don't show again" remembers the exact set of
    // missing features (Codecs.missingSignature), so it reappears if
    // something else goes missing later. Never shown when everything is OK.
    function maybeShowCodecDialog() {
        if (!Codecs.essentialMissing) return
        if (String(Backend.getSetting("warnings/codecsDismissed", "")) === Codecs.missingSignature) return
        codecMissingDialog.open()
    }

    Dialog {
        id: codecMissingDialog
        objectName: "codecMissingDialog"
        title: "Codecs Missing"
        modal: true
        anchors.centerIn: parent
        width: Math.min(620, root.width - 40)
        ColumnLayout {
            width: parent.width
            spacing: 12
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pixelSize: 13
                text: Codecs.pluginMode === "native"
                      ? "Some codecs are not available in the GStreamer installation this build uses. These features won't work:"
                      : "This AppImage does not bundle the patent-encumbered H.264/H.265/AAC software codecs - it uses the ones your distribution provides, and some are not installed. These features won't work:"
            }
            CodecStatusList {
                Layout.fillWidth: true
                onlyProblems: true
            }
            CheckBox {
                id: codecDontShowCheck
                objectName: "codecDontShowCheck"
                text: "Don't show this again"
            }
        }
        footer: DialogButtonBox {
            Button {
                text: "Close"
                objectName: "codecMissingClose"
                DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
            }
        }
        onAccepted: {
            if (codecDontShowCheck.checked)
                Backend.setSetting("warnings/codecsDismissed", Codecs.missingSignature)
        }
    }

    Dialog {
        id: noGPUDialog
        title: "No GPU Acceleration Available"
        modal: true
        anchors.centerIn: parent
        ColumnLayout {
            spacing: 15
            Label {
                text: "⚠️ Only software (CPU) decoding is available.\nVideo playback performance may be limited."
                font.pixelSize: 13
                Layout.preferredWidth: 400
                wrapMode: Text.WordWrap
            }
            Label {
                text: Codecs.softwareVideoDecoders.length > 0
                      ? "Available software decoders:\n" + Codecs.softwareVideoDecoders.map(function(n) { return "\u2713 " + n }).join("\n")
                      : "No software H.264/H.265 decoder is installed either - see File > Settings > Codecs."
                font.pixelSize: 12
                color: "#888888"
                Layout.preferredWidth: 400
            }
            Label {
                text: "Recommended: Install GPU drivers for better performance."
                font.pixelSize: 11
                font.italic: true
                Layout.preferredWidth: 400
                wrapMode: Text.WordWrap
            }
            CheckBox {
                id: dontShowAgainCheckbox
                text: "Don't show this again"
            }
        }
        standardButtons: Dialog.Ok
        onAccepted: {
            if (dontShowAgainCheckbox.checked) {
                Backend.setSetting("warnings/noGPU", false)
            }
        }
    }

    Dialog {
        id: decoderUnavailableDialog
        title: "Preferred Decoder Missing"
        modal: true
        anchors.centerIn: parent
        ColumnLayout {
            spacing: 15
            Label {
                text: "The previously selected decoder (“" + root.missingDecoderName + "”) is not available on this system anymore."
                wrapMode: Text.WordWrap
                Layout.preferredWidth: 420
            }
            Label {
                text: "The application automatically switched to the best available decoder."
                color: "#888888"
                wrapMode: Text.WordWrap
                Layout.preferredWidth: 420
            }
        }
        standardButtons: Dialog.Ok
    }

    // proxy_build_plan.md Part J.2: shown once, right after a project
    // open/Kdenlive import finishes, when proxy editing is enabled and
    // the timeline has clips whose proxy isn't ready at the configured
    // target resolution/format. Deliberately two named-verb buttons, not
    // Yes/No - "No" to "generate them now, or later?" reads ambiguous.
    Dialog {
        id: proxyBackfillPromptDialog
        title: "Generate Missing Proxies?"
        modal: true
        anchors.centerIn: parent
        closePolicy: Popup.CloseOnEscape

        property var missingIds: []
        property int offlineCount: 0
        property string checkedResolution: ""

        ColumnLayout {
            spacing: 15
            Label {
                Layout.preferredWidth: 440
                wrapMode: Text.WordWrap
                text: "Proxy files are missing for " + proxyBackfillPromptDialog.missingIds.length
                      + " source file(s) used on the timeline, and generating them may take a while."
            }
            Label {
                Layout.preferredWidth: 440
                wrapMode: Text.WordWrap
                color: "#888888"
                text: "Target: " + proxyBackfillPromptDialog.checkedResolution
                      + " · " + Backend.getSetting("project/proxyFormat", "h264_intra")
                      + (proxyBackfillPromptDialog.offlineCount > 0
                         ? " (" + proxyBackfillPromptDialog.offlineCount + " file(s) are missing from disk and were skipped)"
                         : "")
            }
            Label {
                Layout.preferredWidth: 440
                wrapMode: Text.WordWrap
                color: "#888888"
                text: "Choosing Later turns proxy editing off for this project - you can turn it back on in Project Settings."
            }
        }

        footer: DialogButtonBox {
            Button { text: "Generate Now"; DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole }
            Button { text: "Later"; DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
        }

        onAccepted: {
            var res = proxyBackfillPromptDialog.checkedResolution
            var fmt = Backend.getSetting("project/proxyFormat", "h264_intra")
            var dev = Backend.getSetting("project/proxyComputeDevice", "")
            var n = root.requestProxiesFor(missingIds, res, fmt, dev)
            // D11 (proxy_build_plan.md Part J.2.3): also point preview at
            // what was just queued - otherwise the app would spend GPU
            // time generating proxies and still preview from the
            // originals, which is exactly the "enabled but silently
            // incomplete" state this whole prompt exists to avoid. Still
            // resolution-only (not the full "<res>@<format>" variant key)
            // - BackendManager::refreshProxyInstallations() (Part J.4.3)
            // pairs it with the project's current proxyFormat setting as
            // the effective active variant; full per-variant tracking via
            // a dedicated proxyActiveVariant setting remains deferred.
            root.beginProxySwitch("Switching proxy to " + res + "\u2026", function() {
                Backend.setSetting("project/proxyActiveResolution", res)
                return Backend.refreshProxyInstallations()
            })
            root.saveProject()
            Backend.logOperation("proxy_backfill_prompt", {choice: "now", count: n, resolution: res, format: fmt})
        }
        onRejected: {
            root.beginProxySwitch("Switching to original media\u2026", function() {
                Backend.setSetting("project/proxyEnabled", false)
                return Backend.refreshProxyInstallations()
            })
            root.saveProject()
            Backend.logOperation("proxy_backfill_prompt", {choice: "later", count: missingIds.length})
        }
    }

    Connections {
        target: Backend
        function onNoGPUWarning() {
            var showWarning = Backend.getSetting("warnings/noGPU", true)
            if (showWarning) {
                noGPUDialog.open()
            }
        }

        function onSavedDecoderUnavailable(decoderId) {
            root.missingDecoderName = Backend.getDecoderDisplayName(decoderId)
            decoderUnavailableDialog.open()
        }
    }
    
    // Menu Bar
    menuBar: MenuBar {
        id: mainMenuBar
        
        background: Rectangle {
            implicitHeight: 40
            color: palette.window

            // Decoder selection ComboBox
            ComboBox {
                id: decoderComboBox
                anchors.right: workspaceButtonsRow.left
                anchors.rightMargin: 15
                anchors.verticalCenter: parent.verticalCenter
                width: 180
                enabled: isProjectOpen
                opacity: isProjectOpen ? 1.0 : 0.5

                model: Backend.availableDecoders
                currentIndex: {
                    var pref = Backend.preferredDecoder
                    var idx = Backend.availableDecoders.indexOf(pref)
                    return idx >= 0 ? idx : 0
                }

                displayText: Backend.getDecoderDisplayName(currentText)

                delegate: ItemDelegate {
                    width: parent.width
                    text: Backend.getDecoderDisplayName(modelData)
                    highlighted: decoderComboBox.highlightedIndex === index
                }

                ToolTip.visible: hovered
                ToolTip.text: "Hardware decoder: " + Backend.getDecoderDisplayName(currentText)

                onActivated: {
                    Backend.preferredDecoder = currentText
                }

                Component.onCompleted: GpuMonitor.setActiveDecoder(currentText)
            }

            // Live decode load readout for whichever decoder is currently
            // selected above - answers "is it actually using the GPU I
            // picked, and how much" without needing a separate nvidia-smi
            // terminal.
            Text {
                id: gpuLoadLabel
                anchors.right: decoderComboBox.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                visible: isProjectOpen && text.length > 0
                text: GpuMonitor.loadText
                color: palette.windowText
                opacity: 0.75
                font.pixelSize: 11
                font.family: "Monospace"

                Connections {
                    target: Backend
                    function onPreferredDecoderChanged() {
                        GpuMonitor.setActiveDecoder(Backend.preferredDecoder)
                    }
                }
            }

            // Workspace buttons
            Row {
                id: workspaceButtonsRow
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.rightMargin: 10
                anchors.topMargin: 0
                spacing: 2
                height: parent.height + 10 
                
                enabled: isProjectOpen
                opacity: isProjectOpen ? 1.0 : 0.3

                ButtonGroup {
                    id: workspaceGroup
                }
                
                Repeater {
                    model: ["Logging", "Editing", "Audio", "Effects", "Colour", "Render"]
                    
                    Rectangle {
                        width: 75
                        height: 35
                        color: (btn.checked && isProjectOpen) ? "#3daee9" : (ma.containsMouse && isProjectOpen ? "#4a4f55" : "#31363b")
                        radius: 3

                        Accessible.role: Accessible.Button
                        Accessible.name: "Workspace " + modelData

                        Text {
                            anchors.centerIn: parent
                            text: modelData
                            color: "white"
                            font.pixelSize: 13
                        }
                        
                        MouseArea {
                            id: ma
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                if (isProjectOpen) {
                                    btn.checked = true
                                    root.currentWorkspace = modelData
                                }
                            }
                        }
                        
                        Button {
                            id: btn
                            visible: false
                            checkable: true
                            checked: modelData === root.currentWorkspace
                            ButtonGroup.group: workspaceGroup
                        }
                    }
                }
            }
        }

        Menu {
            title: "&File"
            
            MenuItem {
                text: root.shortcutMenuText("New", "new_project")
                onTriggered: root.guardUnsaved("creating a new project", function() {
                    newProjectWindow.isNewProject = true
                    newProjectWindow.show()
                })
            }

            MenuItem {
                text: "Open Project"
                onTriggered: root.guardUnsaved("opening another project", function() { openProjectDialog.open() })
            }

            MenuItem {
                text: "Import Kdenlive Project..."
                onTriggered: root.guardUnsaved("importing a project", function() { importKdenliveWindow.show() })
            }

            // --- JAVÍTVA: Open Recent (Fájl Menü) Qt.callLater használattal ---
            Menu {
                id: recentFileMenu
                title: "Open Recent"
                enabled: Backend.recentProjects.length > 0
                
                Instantiator {
                    model: Backend.recentProjects
                    delegate: MenuItem {
                        text: modelData.name
                        onTriggered: {
                            // Késleltetjük a betöltést, hogy a menü bezáródhasson
                            root.guardUnsaved("opening another project", function() {
                                Qt.callLater(root.loadProject, modelData.path)
                            })
                        }
                    }
                    onObjectAdded: function(index, object) { recentFileMenu.insertItem(index, object) }
                    onObjectRemoved: function(index, object) { recentFileMenu.removeItem(object) }
                }
            }

            MenuSeparator {}
			
			MenuItem {
                text: root.shortcutMenuText("Save", "save")
                enabled: isProjectOpen
                opacity: enabled ? 1.0 : 0.5
                onTriggered: saveProject()
            }

            MenuItem {
                text: root.shortcutMenuText("Save As...", "save_as")
                enabled: isProjectOpen
                opacity: enabled ? 1.0 : 0.5
                onTriggered: saveAsWindow.show()
            }

            MenuSeparator {}

            MenuItem {
                text: "Missing Media..."
                enabled: isProjectOpen && Backend.mediaAvailability.missingCount > 0
                opacity: enabled ? 1.0 : 0.5
                onTriggered: root.openMissingMediaDialog()
            }

            MenuItem {
                text: "Project Settings..."
                enabled: isProjectOpen
                opacity: enabled ? 1.0 : 0.5
                onTriggered: {
                    newProjectWindow.isNewProject = false
                    newProjectWindow.show()
                }
            }

            MenuItem {
                // App-wide preferences (decoder/encoder, debug log) -
                // unlike "Project Settings..." above, these are global
                // and available with no project open.
                text: "Settings..."
                onTriggered: settingsWindow.show()
            }

            MenuSeparator {}

			MenuItem {
                text: root.shortcutMenuText("Quit", "quit") // A \t tabulátort tesz közéjük
                onTriggered: root.close()
            }            
        }
        
        Menu {
            title: "&Help"

            MenuItem {
                text: "GPU Information"
                onTriggered: gpuInfoDialog.show()
            }

            MenuSeparator {}

            MenuItem {
                text: "About"
                onTriggered: aboutWindow.show()
            }
        }
    }

    // Main content area
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Toolbar
        ToolBar {
            Layout.fillWidth: true
            Layout.preferredHeight: 42

            background: Rectangle {
                color: "#202326"
                Rectangle {
                    width: parent.width
                    height: 1
                    anchors.bottom: parent.bottom
                    color: "#5d6066"
                }
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                spacing: 2

                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 24
                    color: "#5d6066"
                }

                // New button
                ToolButton {
                    id: newBtn
                    icon.source: "qrc:/icons/document-new.svg"
                    icon.color: "#eff0f1"
                    icon.width: 20
                    icon.height: 20
                    text: "New"
                    display: AbstractButton.TextBesideIcon
                    ToolTip.visible: hovered
                    ToolTip.text: "New Project" + root.shortcutHint("new_project")
                    onClicked: root.guardUnsaved("creating a new project", function() {
                        newProjectWindow.isNewProject = true
                        newProjectWindow.show()
                    })

                    background: Rectangle {
                        radius: 3
                        color: "transparent"
                        border.color: newBtn.hovered ? "#3daee9" : "transparent"
                        border.width: 1

                        Behavior on border.color {
                            enabled: !newBtn.hovered
                            ColorAnimation { duration: 100 }
                        }
                    }
                }

                // Open button - Split button
                Item {
                    id: openSplitButton
                    Layout.preferredWidth: openMainContent.implicitWidth + separatorLine.width + openDropdownContent.implicitWidth + 8
                    Layout.preferredHeight: 32

                    property bool isHovered: openMainArea.containsMouse || openDropdownArea.containsMouse
                    property bool isPressed: openMainArea.pressed || openDropdownArea.pressed

                    // Közös keret
                    Rectangle {
                        id: openButtonBorder
                        anchors.fill: parent
                        radius: 3
                        color: "transparent"
                        border.color: "transparent"
                        border.width: 1

                        states: [
                            State {
                                name: "hovered"
                                when: openSplitButton.isHovered
                                PropertyChanges { target: openButtonBorder; border.color: "#3daee9" }
                            }
                        ]

                        transitions: [
                            Transition {
                                from: "hovered"
                                to: ""
                                ColorAnimation {
                                    property: "border.color"
                                    duration: 100
                                }
                            }
                        ]
                    }

                    Row {
                        spacing: 0
                        anchors.fill: parent
                        anchors.leftMargin: 4
                        anchors.rightMargin: 4

                        // Open main button content
                        Item {
                            id: openMainContent
                            implicitWidth: openIcon.width + openText.width + 12
                            width: implicitWidth
                            height: parent.height

                            Row {
                                anchors.centerIn: parent
                                spacing: 6

                                Image {
                                    id: openIcon
                                    source: "qrc:/icons/document-open.svg"
                                    sourceSize.width: 20
                                    sourceSize.height: 20
                                    width: 20
                                    height: 20
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Text {
                                    id: openText
                                    text: "Open ..."
                                    color: "#eff0f1"
                                    font.pixelSize: 13
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                id: openMainArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.guardUnsaved("opening another project", function() { openProjectDialog.open() })
                            }

                            ToolTip {
                                visible: openMainArea.containsMouse
                                text: "Open Project"
                            }
                        }

                        // Függőleges elválasztó vonal
                        Rectangle {
                            id: separatorLine
                            width: 1
                            height: parent.height
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            color: "#3daee9"
                            visible: openSplitButton.isHovered
                        }

                        // Dropdown button content
                        Item {
                            id: openDropdownContent
                            implicitWidth: 20
                            width: implicitWidth
                            height: parent.height
                            
                            // Letiltjuk, ha nincs előzmény (megakadályozza az üres menüt)
                            enabled: Backend.recentProjects.length > 0
                            opacity: enabled ? 1.0 : 0.5

                            Text {
                                text: "›"
                                color: "#eff0f1"
                                font.pixelSize: 22
                                font.weight: Font.Light
                                rotation: 90
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.horizontalCenterOffset: 2
                            }

                            MouseArea {
                                id: openDropdownArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: recentToolbarMenu.open()
                            }

                            ToolTip {
                                visible: openDropdownArea.containsMouse && !recentToolbarMenu.visible
                                text: "Recent Projects"
                            }

                            // --- JAVÍTVA: Toolbar Dropdown Qt.callLater használattal ---
                            Menu {
                                id: recentToolbarMenu
                                x: -(openMainContent.implicitWidth + separatorLine.width + 4)
                                y: openSplitButton.height

                                Instantiator {
                                    model: Backend.recentProjects
                                    delegate: MenuItem {
                                        text: modelData.name
                                        onTriggered: {
                                            // Késleltetjük a betöltést itt is
                                            root.guardUnsaved("opening another project", function() {
                                                Qt.callLater(root.loadProject, modelData.path)
                                            })
                                        }
                                    }
                                    onObjectAdded: function(index, object) { recentToolbarMenu.insertItem(index, object) }
                                    onObjectRemoved: function(index, object) { recentToolbarMenu.removeItem(object) }
                                }
                            }
                        }
                    }
                }

                // Save button
                ToolButton {
                    id: saveBtn
                    enabled: isProjectOpen
                    opacity: enabled ? 1.0 : 0.3
                    icon.source: "qrc:/icons/document-save.svg"
                    icon.color: "#eff0f1"
                    icon.width: 20
                    icon.height: 20
                    text: "Save"
                    display: AbstractButton.TextBesideIcon
                    ToolTip.visible: hovered
                    ToolTip.text: "Save Project" + root.shortcutHint("save")
                    onClicked: saveProject()

                    background: Rectangle {
                        radius: 3
                        color: "transparent"
                        border.color: (saveBtn.hovered && saveBtn.enabled) ? "#3daee9" : "transparent"
                        border.width: 1

                        Behavior on border.color {
                            enabled: !saveBtn.hovered
                            ColorAnimation { duration: 100 }
                        }
                    }
                }

                // Autosave status indicator (plan_autosave.md 4.7) - directly
                // beside the Save button, small and grey, so it does not
                // stretch the toolbar.
                Text {
                    id: autosaveStatusLabel
                    visible: root.autosaveStatusText !== ""
                    text: root.autosaveStatusText
                    color: root.autosaveStatusText === "Autosave FAILED" ? "#f0b030" : "#888888"
                    font.pixelSize: 11
                    Layout.alignment: Qt.AlignVCenter
                }

                Text {
                    visible: root.mediaStatusText !== ""
                    text: root.mediaStatusText
                    color: "#6cc06c"
                    font.pixelSize: 11
                    Layout.alignment: Qt.AlignVCenter
                }

                // Separator
                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 24
                    color: "#5d6066"
                }

                // Undo button
                ToolButton {
                    id: undoBtn
                    // Clicking a focusable control steals keyboard focus
                    // from the editing workspace, which is where Delete/S
                    // (deleteSelectedClip/splitAtPlayhead) are bound via
                    // Keys.onPressed - without this, pressing Delete right
                    // after clicking Undo/Redo does nothing (the key event
                    // never reaches that handler) until something else
                    // (e.g. clicking Play) happens to hand focus back.
                    focusPolicy: Qt.NoFocus
                    enabled: isProjectOpen && !!root.timelinePanelRef && root.timelinePanelRef.canUndo
                    opacity: enabled ? 1.0 : 0.3
                    icon.source: "qrc:/icons/edit-undo.svg"
                    icon.color: "#eff0f1"
                    icon.width: 20
                    icon.height: 20
                    text: "Undo"
                    display: AbstractButton.TextBesideIcon
                    ToolTip.visible: hovered
                    ToolTip.text: "Undo" + root.shortcutHint("undo")
                    onClicked: if (root.timelinePanelRef) root.timelinePanelRef.undo()

                    background: Rectangle {
                        radius: 3
                        color: "transparent"
                        border.color: (undoBtn.hovered && undoBtn.enabled) ? "#3daee9" : "transparent"
                        border.width: 1

                        Behavior on border.color {
                            enabled: !undoBtn.hovered
                            ColorAnimation { duration: 100 }
                        }
                    }
                }

                // Redo button
                ToolButton {
                    id: redoBtn
                    // See undoBtn's comment above.
                    focusPolicy: Qt.NoFocus
                    enabled: isProjectOpen && !!root.timelinePanelRef && root.timelinePanelRef.canRedo
                    opacity: enabled ? 1.0 : 0.3
                    icon.source: "qrc:/icons/edit-redo.svg"
                    icon.color: "#eff0f1"
                    icon.width: 20
                    icon.height: 20
                    text: "Redo"
                    display: AbstractButton.TextBesideIcon
                    ToolTip.visible: hovered
                    ToolTip.text: "Redo" + root.shortcutHint("redo")
                    onClicked: if (root.timelinePanelRef) root.timelinePanelRef.redo()

                    background: Rectangle {
                        radius: 3
                        color: "transparent"
                        border.color: (redoBtn.hovered && redoBtn.enabled) ? "#3daee9" : "transparent"
                        border.width: 1

                        Behavior on border.color {
                            enabled: !redoBtn.hovered
                            ColorAnimation { duration: 100 }
                        }
                    }
                }

                // Cut button
                ToolButton {
                    id: cutBtn
                    enabled: isProjectOpen
                    opacity: enabled ? 1.0 : 0.3
                    icon.source: "qrc:/icons/edit-cut.svg"
                    icon.color: "#eff0f1"
                    icon.width: 20
                    icon.height: 20
                    text: "Cut"
                    display: AbstractButton.TextBesideIcon
                    ToolTip.visible: hovered
                    ToolTip.text: "Cut"
                    onClicked: console.log("Cut clicked")

                    background: Rectangle {
                        radius: 3
                        color: "transparent"
                        border.color: (cutBtn.hovered && cutBtn.enabled) ? "#3daee9" : "transparent"
                        border.width: 1

                        Behavior on border.color {
                            enabled: !cutBtn.hovered
                            ColorAnimation { duration: 100 }
                        }
                    }
                }

                // Copy button
                ToolButton {
                    id: copyBtn
                    enabled: isProjectOpen
                    opacity: enabled ? 1.0 : 0.3
                    icon.source: "qrc:/icons/edit-copy.svg"
                    icon.color: "#eff0f1"
                    icon.width: 20
                    icon.height: 20
                    text: "Copy"
                    display: AbstractButton.TextBesideIcon
                    ToolTip.visible: hovered
                    ToolTip.text: "Copy"
                    onClicked: console.log("Copy clicked")

                    background: Rectangle {
                        radius: 3
                        color: "transparent"
                        border.color: (copyBtn.hovered && copyBtn.enabled) ? "#3daee9" : "transparent"
                        border.width: 1

                        Behavior on border.color {
                            enabled: !copyBtn.hovered
                            ColorAnimation { duration: 100 }
                        }
                    }
                }

                // Paste button
                ToolButton {
                    id: pasteBtn
                    enabled: isProjectOpen
                    opacity: enabled ? 1.0 : 0.3
                    icon.source: "qrc:/icons/edit-paste.svg"
                    icon.color: "#eff0f1"
                    icon.width: 20
                    icon.height: 20
                    text: "Paste"
                    display: AbstractButton.TextBesideIcon
                    ToolTip.visible: hovered
                    ToolTip.text: "Paste"
                    onClicked: console.log("Paste clicked")

                    background: Rectangle {
                        radius: 3
                        color: "transparent"
                        border.color: (pasteBtn.hovered && pasteBtn.enabled) ? "#3daee9" : "transparent"
                        border.width: 1

                        Behavior on border.color {
                            enabled: !pasteBtn.hovered
                            ColorAnimation { duration: 100 }
                        }
                    }
                }

                // Spacer
                Item {
                    Layout.fillWidth: true
                }
            }
        }

        // Workspace content
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // Welcome Screen
            Rectangle {
                id: welcomeScreen
                anchors.fill: parent
                color: "#1a1c1e"
                visible: !isProjectOpen
                z: 100

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 30

                    // Logo és Cím
                    ColumnLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 10
                        
                        Image {
                            Layout.alignment: Qt.AlignHCenter
                            source: "qrc:/icons/app_icon.svg"
                            sourceSize.width: 128
                            sourceSize.height: 128
                            smooth: true
                        }

                        Text {
                            text: "GPU Cine Studio"
                            color: "#eff0f1"
                            font.pixelSize: 32
                            font.bold: true
                            Layout.alignment: Qt.AlignHCenter
                        }

                        Text {
                            text: "Hardware Accelerated Video Editor"
                            color: "#888888"
                            font.pixelSize: 16
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }

                    // Gombok
                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 20

                        // New Project Big Button
                        Button {
                            objectName: "newProjectButton"
                            Accessible.name: "New Project"
                            Layout.preferredWidth: 160
                            Layout.preferredHeight: 50

                            background: Rectangle {
                                color: parent.down ? "#3daee9" : "#31363b"
                                border.color: "#3daee9"
                                border.width: 2
                                radius: 4
                            }
                            
                            contentItem: RowLayout {
                                spacing: 10
                                anchors.centerIn: parent
                                Image { 
                                    source: "qrc:/icons/document-new.svg"
                                    sourceSize: Qt.size(24,24)
                                }
                                Text { 
                                    text: "New Project"
                                    color: "white"
                                    font.bold: true
                                    font.pixelSize: 14
                                }
                            }

                            onClicked: root.guardUnsaved("creating a new project", function() {
                                newProjectWindow.isNewProject = true
                                newProjectWindow.show()
                            })
                        }

                        // Open Project Big Button
                        Button {
                            objectName: "openProjectButton"
                            Accessible.name: "Open Project"
                            Layout.preferredWidth: 160
                            Layout.preferredHeight: 50

                            background: Rectangle {
                                color: parent.down ? "#4a4f55" : "#31363b"
                                border.color: "#5d6066"
                                border.width: 1
                                radius: 4
                            }
                            
                            contentItem: RowLayout {
                                spacing: 10
                                anchors.centerIn: parent
                                Image { 
                                    source: "qrc:/icons/document-open.svg"
                                    sourceSize: Qt.size(24,24)
                                }
                                Text { 
                                    text: "Open Project"
                                    color: "white"
                                    font.bold: true
                                    font.pixelSize: 14
                                }
                            }

                            onClicked: root.guardUnsaved("opening another project", function() { openProjectDialog.open() })
                        }
                    }
                    
                    // Recent Projects List
                    ColumnLayout {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: 20
                        spacing: 10
                        visible: Backend.recentProjects.length > 0

                        Text {
                            text: "Recent Projects"
                            color: "#eff0f1"
                            font.bold: true
                            font.pixelSize: 14
                        }

                        ListView {
                            Layout.preferredWidth: 400
                            Layout.preferredHeight: Math.min(200, contentHeight)
                            model: Backend.recentProjects
                            clip: true
                            
                            delegate: Rectangle {
                                width: 400
                                // Was 40 - too short for the two-line
                                // content below (name + path, 10px
                                // margins top/bottom), so the hover
                                // highlight didn't reach under the
                                // path text and visually overlapped
                                // the next row (confirmed via
                                // screenshot - the highlight rectangle
                                // was offset from its own row's text).
                                height: 52
                                color: mouseArea.containsMouse ? "#2a2d30" : "transparent"
                                radius: 4

                                objectName: "recentProject_" + modelData.name
                                Accessible.role: Accessible.ListItem
                                Accessible.name: "Open recent project " + modelData.name
                                
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.margins: 10
                                    spacing: 10
                                    
                                    Image {
                                        source: "qrc:/icons/document-open.svg"
                                        sourceSize: Qt.size(16,16)
                                        opacity: 0.7
                                    }
                                    
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2
                                        
                                        Text {
                                            text: modelData.name
                                            color: "#3daee9"
                                            font.bold: true
                                            font.pixelSize: 13
                                        }
                                        
                                        Text {
                                            text: modelData.path
                                            color: "#888888"
                                            font.pixelSize: 11
                                            elide: Text.ElideMiddle
                                            Layout.fillWidth: true
                                        }
                                    }
                                    
                                    Text {
                                        text: modelData.lastOpened ? modelData.lastOpened.split("T")[0] : ""
                                        color: "#555"
                                        font.pixelSize: 11
                                    }
                                }
                                
                                MouseArea {
                                    id: mouseArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.guardUnsaved("opening another project", function() { loadProject(modelData.path) })
                                }
                            }
                        }
                    }

                    Text {
                        visible: Backend.recentProjects.length === 0
                        text: "No recent projects found."
                        color: "#555"
                        font.italic: true
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: 20
                    }
                }
            }

            // Workspaces Stack
            StackLayout {
                anchors.fill: parent
                visible: isProjectOpen
                
                currentIndex: {
                    switch(root.currentWorkspace) {
                        case "Logging": return 0
                        case "Editing": return 1
                        case "Audio": return 2
                        // Effects reuses EditingWorkspace's own instance
                        // (same timeline, undo stack, project bin, native
                        // video window) under a different layout - see
                        // EditingWorkspace.qml's layoutMode property -
                        // rather than a second, duplicate-state copy.
                        case "Effects": return 1
                        case "Colour": return 3
                        case "Render": return 4
                        default: return 0
                    }
                }

                onCurrentIndexChanged: {
                    if (currentIndex === 0 && loggingWorkspaceLoader.item) {
                        loggingWorkspaceLoader.item.forceActiveFocus()
                    } else if (currentIndex === 1 && editingWorkspaceLoader.item) {
                        editingWorkspaceLoader.item.forceActiveFocus()
                    }
                }

                Loader {
                    id: loggingWorkspaceLoader
                    source: "LoggingWorkspace.qml"
                    asynchronous: true
                    onStatusChanged: checkCleanupAndQuit()
                }

                Loader {
                    id: editingWorkspaceLoader
                    objectName: "editingWorkspaceLoader"
                    source: "EditingWorkspace.qml"
                    asynchronous: true
                    onStatusChanged: checkCleanupAndQuit()
                    onLoaded: {
                        if (root.isTimelineWorkspace) {
                            item.forceActiveFocus()
                        }
                    }
                }

                // Keeps EditingWorkspace's layoutMode in sync even while
                // the Loader is still (asynchronously) resolving `item` -
                // a plain onCurrentWorkspaceChanged handler would miss
                // that case since `item` can be null at the moment the
                // tab is clicked.
                Binding {
                    target: editingWorkspaceLoader.item
                    property: "layoutMode"
                    value: root.currentWorkspace === "Effects" ? "effects" : "editing"
                    when: editingWorkspaceLoader.item !== null
                }

                Item {
                    Text {
                        anchors.centerIn: parent
                        text: "Audio Workspace\n(coming soon)"
                        color: "#888888"
                        font.pixelSize: 20
                        horizontalAlignment: Text.AlignHCenter
                    }
                }

                Item {
                    Text {
                        anchors.centerIn: parent
                        text: "Colour Workspace\n(coming soon)"
                        color: "#888888"
                        font.pixelSize: 20
                        horizontalAlignment: Text.AlignHCenter
                    }
                }

                Loader {
                    id: renderWorkspaceLoader
                    source: "render/RenderWorkspace.qml"
                    asynchronous: true
                    onStatusChanged: checkCleanupAndQuit()
                }
            }
        }
    }
}
