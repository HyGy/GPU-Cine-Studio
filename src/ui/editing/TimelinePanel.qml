import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtQml.Models
import VideoEditor 1.0

Rectangle {
    id: timelineContainer

    SplitView.minimumWidth: 400
    SplitView.fillWidth: true
    color: palette.window
    border.color: "#1d1d1d"
    border.width: 1

    // === PUBLIC PROPERTIES ===
    property var timelineEngine: null
    property var updateTimelineEngine: null
    property var formatTimecode: null
    // PRIMARY / last-clicked clip - drives the Effect Stack inspector,
    // split, delete, right-click context menu. Multi-select (below)
    // only widens which clips an effect-application/move targets; the
    // inspector deliberately keeps showing just one clip's stack, not
    // some N-clip union/intersection view.
    property string selectedClipId: ""
    // Full selection, primary included. Always REASSIGNED wholesale
    // (never mutated in place, e.g. never `.push()`) - QML's property
    // dependency tracking only notices whole-property writes, not
    // in-place array mutation, and several bindings elsewhere key off
    // this directly.
    property var selectedClipIds: []
    // Last plain- or Ctrl-clicked clip; a Shift+click range is always
    // computed from this clip to the one just clicked and does NOT
    // move it - so repeated Shift+clicks grow/shrink one live range
    // from the same origin instead of compounding.
    property string selectionAnchorClipId: ""
    property var workspace: null

    // Keeps the two in sync for every PRE-EXISTING direct
    // `selectedClipId = x` write elsewhere in this file (right-click,
    // split, undo-prune, etc.) without having to find and update each
    // call site - collapsing the wider selection down to just the new
    // primary is the correct behaviour for all of them. selectOnly()/
    // toggleSelection()/selectRange() above manage selectedClipIds
    // directly and this handler is a harmless no-op for their writes
    // (selectedClipId already matches by the time they assign it).
    onSelectedClipIdChanged: {
        if (selectedClipId !== "" && selectedClipIds.indexOf(selectedClipId) < 0)
            selectedClipIds = [selectedClipId]
    }

    property alias tracksModel: tracksModel
    property alias clipsModel: clipsModel
    property alias clipContextMenu: clipContextMenu

    // === ZOOM PROPERTIES ===
    property real pixelsPerSecond: 50
    property real minPixelsPerSecond: 5
    property real maxPixelsPerSecond: 200
    // Master gain (linear). Preview-only: the engine's "audio-filter" bin
    // applies it; the render folds it into each clip's trackVolume.
    property real masterVolume: 1.0
    // True end of the last clip (start+duration, max across all clips) -
    // updated by rebuildClipIndex() on every edit, so it's always current
    // without a separate scan. totalSeconds derives from it below.
    property real contentEndSeconds: 0
    // Was a plain property, hardcoded to 120 and only ever written once,
    // on project load - a project built IN-SESSION (never saved/reloaded)
    // could never scroll or render past 120s no matter how long it
    // actually was (getTimelineDurationForRender() in main.qml silently
    // truncated renders there too - see its own fix). Now derived from
    // the actual content, with 60s of working headroom past the last
    // clip, floored at 120s so an empty/short project still has a
    // reasonable minimum ruler/scroll range.
    readonly property int totalSeconds: Math.max(120, Math.ceil(contentEndSeconds) + 60)

    // === DEV-ONLY: synthetic clip generator for Stage 3b scaling measurement ===
    // NEVER enabled in a shipped build. Flip devToolsEnabled to true by
    // hand when measuring, then use the Dev buttons in TimelineToolbar.
    // devGenerateClips() deliberately does NOT call updateTimelineEngine():
    // the point is to measure QML delegate/binding cost, and asking GES to
    // actually build hundreds of real clips would take a long time and
    // measure the wrong thing.
    property bool devToolsEnabled: false
    property real devLastRefilterMs: 0
    property int devCreateCount: 0
    property int devDestroyCount: 0

    function devGenerateClips(count) {
        // Reuse an existing clip's source so itemName/path look realistic.
        var proto = null
        for (var p = 0; p < clipsModel.count; p++) {
            var pc = clipsModel.get(p)
            if (pc.itemPath) { proto = pc; break }
        }
        var path = proto ? proto.itemPath : ""
        var name = proto ? proto.itemName : "synthetic"
        var srcId = proto ? proto.sourceItemId : ""
        var wf = proto ? proto.waveformPath : ""

        var t0 = Date.now()
        var dur = 3.0
        var gap = 0.5
        var vTracks = []
        for (var ti = 0; ti < tracksModel.count; ti++) {
            if (tracksModel.get(ti).type === "video") vTracks.push(tracksModel.get(ti).trackId)
        }
        if (vTracks.length === 0) return
        var cursor = {}
        for (var vi = 0; vi < vTracks.length; vi++) cursor[vTracks[vi]] = contentEndSeconds + 5

        for (var i = 0; i < count; i++) {
            var tid = vTracks[i % vTracks.length]
            var st = cursor[tid]
            cursor[tid] = st + dur + gap
            clipsModel.append({
                clipId: "syn_" + Date.now() + "_" + i,
                trackId: tid,
                itemName: name + " " + i,
                itemPath: path,
                startTime: st,
                durationSeconds: dur,
                hasVideo: true, hasAudio: false,
                sourceOffset: 0,
                hasTransition: false, transitionDuration: 0, transitionType: "",
                transitionOriginalBId: "", transitionOriginalStartB: 0,
                linkGroupId: "", linkedClipId: "", isLinked: false,
                sourceItemId: srcId, waveformPath: wf
            })
        }
        var tAppend = Date.now() - t0
        var t1 = Date.now()
        checkAllClipNeighbors()
        console.log("[dev] generated", count, "clips: append", tAppend, "ms, index+refilter",
                    (Date.now() - t1), "ms, total model count", clipsModel.count)
    }

    function devRemoveSyntheticClips() {
        for (var i = clipsModel.count - 1; i >= 0; i--) {
            if (clipsModel.get(i).clipId.indexOf("syn_") === 0) clipsModel.remove(i)
        }
        checkAllClipNeighbors()
        console.log("[dev] synthetic clips removed, model count", clipsModel.count)
    }

    function devReportDelegates() {
        console.log("[dev] model rows:", clipsModel.count,
                    "| created:", devCreateCount, "destroyed:", devDestroyCount,
                    "| live:", devCreateCount - devDestroyCount,
                    "| lastRefilter:", devLastRefilterMs.toFixed(2), "ms")
    }

    function devTimeZoom() {
        var t = Date.now()
        zoomIn()
        console.log("[dev] zoomIn step:", Date.now() - t, "ms")
    }

    // === STAGE 3b: WINDOWED (VIRTUALIZED) CLIP RENDERING ===
    // Clip and transition delegates are instantiated only for rows whose
    // time span intersects the visible viewport plus one viewport of
    // overscan on each side. Implemented with a QML DelegateModel per
    // Repeater, each carrying a non-default "win" group with
    // includeByDefault: false and filterOnGroup: "win" - so a row has a
    // delegate if and only if refilterWindow() has put it in "win".
    //
    // Deliberately NOT a C++ QSortFilterProxyModel: that would replace
    // clipsModel's identity for every existing consumer
    // (EditingWorkspace.updateTimelineEngine()/getProjectJSON(),
    // main.qml's render-duration helper, every findClipRow()) - that's
    // Stage 4/5 territory. A DelegateModel is purely a view-side adapter;
    // clipsModel and every model-based code path are untouched.
    //
    // windowFilterEnabled is the master switch. Stage 3b-1 keeps it
    // false, so refilterWindow() puts EVERY row in "win" - isolating
    // "does DelegateModel work at all" from "is the predicate right".
    property bool windowFilterEnabled: true
    property real windowMinSeconds: 0
    property real windowMaxSeconds: 0
    // The window that was last actually APPLIED to the groups - used by
    // scheduleRefilter() to decide whether the 40ms debounce is safe or
    // whether this scroll jumped clean out of the overscan and needs an
    // immediate pass.
    property real appliedWindowMinSeconds: -1e9
    property real appliedWindowMaxSeconds: 1e9
    // Row-aligned [{id, s, e}] - built in the same single pass as
    // clipIndexByTrack (rebuildClipIndex()), so the window predicate
    // never needs its own scan of clipsModel.
    property var clipSpanByRow: []
    // Re-entrancy guard: refilterWindow() can create/destroy delegates,
    // whose Component.onCompleted (updateOverlapAmount()) and
    // onDestruction (unregisterClipItem()) run synchronously. Nothing in
    // those paths calls back into refilterWindow() today, but a nested
    // pass would operate on half-applied group state.
    property bool refilterInProgress: false

    // While true, refilterWindow() may ADD rows to "win" but never
    // remove any. The clips model is only written on RELEASE, so during
    // a drag the dragged clip's own model position stays where it was at
    // press time - an edge-scroll drag (edgeScrollTimer, 16ms, unbounded)
    // walks the viewport away from it, and a removing refilter would
    // destroy the very delegate whose MouseArea holds the mouse grab.
    // Neither onReleased nor onCanceled fires then, leaving
    // activeDragItem pointing at a destroyed object and scrollDirection
    // stuck non-zero - an unreleasable drag with runaway auto-scroll.
    // Deriving this from state the code already maintains (rather than a
    // pinnedClipIds set with its own pin/unpin bookkeeping) means it
    // cannot leak: there is no decrement to forget. It also covers the
    // trim handles, which press their OWN MouseAreas and never reach
    // TimelineClip's body onPressed.
    property string trimActiveClipId: ""
    readonly property bool windowAdditiveOnly: activeDragItem !== null || trimActiveClipId !== ""
    // Deferred, never synchronous: onReleased clears activeDragItem on
    // its FIRST line but then calls rebindPosition() on itself ~150 lines
    // later - a synchronous refilter here would destroy clipItem from
    // inside its own handler. Debounced (not Now) so it also lands after
    // onReleased's own Qt.callLater(checkAllClipNeighbors).
    onWindowAdditiveOnlyChanged: if (!windowAdditiveOnly) Qt.callLater(scheduleRefilter)

    // Viewport -> window bounds in SECONDS, with one full viewport of
    // overscan on each side. Overscan is what makes the 40ms debounce in
    // scheduleRefilter() safe: a scroll smaller than one viewport can
    // always wait, because everything it will reveal is already
    // instantiated.
    function recomputeWindow() {
        var pps = pixelsPerSecond
        var vw = tracksContentFlickable.width
        if (pps <= 0 || vw <= 0) return
        var vx = tracksContentFlickable.contentX
        windowMinSeconds = (vx - vw) / pps
        windowMaxSeconds = (vx + 2 * vw) / pps
    }

    function windowWantsRow(sp) {
        if (!windowFilterEnabled) return true
        if (!sp) return true
        // Interval intersection. Model [s,e] is a safe superset of a
        // clip's drawn extent: calculateVisualX() only shifts a B-side
        // clip's left edge RIGHT (inward), and an ACTIVE transition
        // overlay spans [e - transDur, e], also inside. The only thing
        // that pokes outside is the INACTIVE "+" button slot
        // (TimelineTransition.qml: e*pps - 12, width 24), i.e. 12 pixels
        // past e - swamped by a whole viewport of overscan.
        return (sp.e >= windowMinSeconds) && (sp.s <= windowMaxSeconds)
    }

    // Absolute membership write for one contiguous run of rows. Both
    // DelegateModels are driven from the SAME desired-state array - a
    // transition delegate's drawn extent is inside its clip's span, so
    // there is no reason for them to have different windows, and keeping
    // them in lockstep means transitionItemsByOwner and clipItemsById
    // always have matching holes.
    //
    // setGroups() (as opposed to addGroups/removeGroups) writes ABSOLUTE
    // membership, which makes this pass stateless and idempotent: it is
    // correct no matter what the previous membership was, so it needs no
    // row-aligned cache that could desynchronize when clipsModel.remove()
    // shifts every later row's items-group index down by one (which it
    // does, in deleteSelectedClip()).
    function applyWinRun(from, count, wanted) {
        if (count <= 0) return
        var g = wanted ? ["items", "win"] : ["items"]
        clipDM.items.setGroups(from, count, g)
        transDM.items.setGroups(from, count, g)
    }

    function refilterWindow() {
        if (refilterInProgress) return

        var n = clipsModel.count
        var spans = clipSpanByRow
        if (!spans || spans.length !== n) {
            // Model changed without a rebuildClipIndex() in between -
            // the spans array is row-aligned, so a stale length means
            // stale indices. Rebuild rather than guess. Done BEFORE the
            // in-progress guard below is set: rebuildClipIndex() writes
            // contentEndSeconds -> totalSeconds -> contentWidth, which
            // can make the Flickable clamp contentX (StopAtBounds) and
            // synchronously trigger a nested refilterWindow() via
            // onContentXChanged/scheduleRefilter(). Letting that nested
            // call run to completion here - rather than toggling the
            // guard off/on around rebuildClipIndex(), which let it
            // observe a half-set guard state - is what actually
            // prevents a half-applied pass.
            rebuildClipIndex()
            n = clipsModel.count
            spans = clipSpanByRow
        }

        // clipsModel.count updates synchronously, but clipDM/transDM's
        // own group bookkeeping reacts to the model's insert/remove
        // signal on its own schedule - a bulk append (+500) can have
        // this pass observe n already caught up while the DelegateModels
        // haven't. setGroups() below would then index out of range
        // (Qt warning, no-op) and, worse, still let the non-additive
        // branch claim appliedWindow as fully applied even though
        // nothing was actually written for the new rows - leaving them
        // invisible until an unrelated scroll/zoom. Defer one tick
        // instead of guessing.
        if (clipDM.items.count !== n || transDM.items.count !== n) {
            windowRefilterTimer.restart()
            return
        }

        if (refilterInProgress) return
        refilterInProgress = true

        var t0 = devToolsEnabled ? Date.now() : 0

        var additiveOnly = windowAdditiveOnly
        var runStart = -1
        var runWanted = false

        for (var i = 0; i < n; i++) {
            var wanted = windowWantsRow(spans[i])
            if (runStart < 0) { runStart = i; runWanted = wanted; continue }
            if (wanted !== runWanted) {
                if (runWanted || !additiveOnly) applyWinRun(runStart, i - runStart, runWanted)
                runStart = i
                runWanted = wanted
            }
        }
        if (runStart >= 0 && (runWanted || !additiveOnly)) {
            applyWinRun(runStart, n - runStart, runWanted)
        }

        // A pass that was allowed to REMOVE can claim the window as
        // exactly applied. An additive-only pass can never claim removal
        // happened, but it DID just add every row this window wants - so
        // it's safe (and necessary for performance) to grow the applied
        // frontier to at least cover it, just never shrink it: without
        // this, appliedWindow* stays frozen at its pre-drag value for the
        // whole drag, so scheduleRefilter()'s bypass check re-fires on
        // literally every 16ms edgeScrollTimer tick (a full O(n) pass
        // each time, with the 40ms debounce never getting a chance to
        // coalesce anything) instead of settling back into the debounced
        // path after the first tick extends coverage.
        if (additiveOnly) {
            appliedWindowMinSeconds = Math.min(appliedWindowMinSeconds, windowMinSeconds)
            appliedWindowMaxSeconds = Math.max(appliedWindowMaxSeconds, windowMaxSeconds)
        } else {
            appliedWindowMinSeconds = windowMinSeconds
            appliedWindowMaxSeconds = windowMaxSeconds
        }

        if (devToolsEnabled) devLastRefilterMs = Date.now() - t0
        refilterInProgress = false
    }

    function refilterWindowNow() {
        windowRefilterTimer.stop()
        recomputeWindow()
        refilterWindow()
    }

    // Debounced entry point with a bypass. Normal scrolling coalesces
    // into one pass per 40ms; a jump that lands outside the currently
    // applied window (scrollbar drag, zoomToFit, a seek-driven jump)
    // cannot wait, because the rows it needs have no delegate at all -
    // waiting would show a blank timeline for a frame or four.
    function scheduleRefilter() {
        if (!windowFilterEnabled) { windowRefilterTimer.restart(); return }
        var pps = pixelsPerSecond
        var vw = tracksContentFlickable.width
        if (pps > 0 && vw > 0) {
            var vx = tracksContentFlickable.contentX
            var vLo = vx / pps
            var vHi = (vx + vw) / pps
            if (vLo < appliedWindowMinSeconds || vHi > appliedWindowMaxSeconds) {
                refilterWindowNow()
                return
            }
        }
        windowRefilterTimer.restart()
    }

    Timer {
        id: windowRefilterTimer
        interval: 40
        repeat: false
        onTriggered: timelineContainer.refilterWindowNow()
    }

    // Zoom changes seconds-per-pixel, so the window's bounds in SECONDS
    // change even at a fixed contentX. Goes through scheduleRefilter()
    // (not a direct refilterWindowNow()) so a genuine zoom-out that
    // escapes the applied window still gets an immediate pass (no
    // blank-frame risk - scheduleRefilter()'s bypass check recomputes
    // vLo/vHi from the CURRENT pixelsPerSecond), but a burst of rapid
    // wheel-driven zoom steps that keeps landing inside the already-
    // applied window coalesces into the normal 40ms debounce instead of
    // one full O(n) refilter pass - with its own batch of real
    // QQuickItem creation/destruction via the DelegateModel "win" group
    // - per wheel tick. Was an unconditional refilterWindowNow() until a
    // SIGSEGV (QV4::Object::insertMember/StoreElement, 2026-10-12) was
    // caught under gdb reproducing from rapid zoom in/out alone, no
    // scrolling - see TODO.txt. Not a confirmed root-cause fix, just a
    // reduction in how often that churn can happen back-to-back.
    onPixelsPerSecondChanged: scheduleRefilter()

    // === LAYOUT PROPERTIES ===
    readonly property int trackHeight: 61

    // === EDITING PROPERTIES ===
    // App-wide setting (Settings > Editing); read live so a change in the
    // dialog applies to the next transition without a restart.
    function defaultTransitionDurationNow() {
        var v = parseFloat(Backend.getSetting("editing/defaultTransitionDuration", 2.0))
        return (isNaN(v) || v <= 0) ? 2.0 : v
    }
    property real defaultTransitionDuration: defaultTransitionDurationNow()
    function projectFps() {
        var parts = String(Backend.getSetting("project/fps", "30")).split("/")
        var f = parseFloat(parts[0]) / (parts.length > 1 ? parseFloat(parts[1]) : 1)
        return f > 0 ? f : 30
    }
    property bool rippleEditEnabled: true
    property bool splitAllTracksMode: false  // false = csak kijelölt klip, true = minden track
    // Ripple on: close the gap on ALL unlocked tracks by the same amount
    // (music/narration stays aligned with the picture) instead of only the
    // edited track(s) + linked partners. Project state (EditingWorkspace
    // saves/loads it), default off; not part of undo.
    property bool rippleAllTracks: false

    // Selected transition (owner clip id = the outgoing clip A that owns it),
    // "" = none. Edited in EditingWorkspace's Transition tab. Independent of
    // the clip selection; any clip selection change deselects it.
    property string selectedTransitionId: ""
    function selectTransition(ownerClipId) { selectedTransitionId = ownerClipId }
    function clearTransitionSelection() { selectedTransitionId = "" }
    onClipSelectionTouched: clearTransitionSelection()
    // Bumped on any clipsModel change; Transition tab bindings depend on it.
    property int transitionRevision: 0
    Connections {
        target: clipsModel
        function onDataChanged() { timelineContainer.transitionRevision++ }
        function onRowsInserted() { timelineContainer.transitionRevision++ }
        function onRowsRemoved() { timelineContainer.transitionRevision++ }
        function onRowsMoved() { timelineContainer.transitionRevision++ }
        function onModelReset() { timelineContainer.transitionRevision++ }
    }
    // Everything the Transition tab shows for the transition owned by
    // ownerClipId, or null when there is none (removed, undone, clip gone).
    function transitionInfo(ownerClipId) {
        var ctx = transitionContext(ownerClipId)
        if (!ctx) return null
        var a = clipsModel.get(ctx.rowA)
        var b = clipsModel.get(ctx.rowB)
        return {
            trackId: a.trackId,
            isVideo: a.trackId.startsWith("V"),
            type: a.transitionType || "crossfade",
            duration: ctx.duration,
            range: transitionDurationRange(ownerClipId),
            clipAName: a.itemName || "?",
            clipBName: b.itemName || "?"
        }
    }

    // Shared right-click context menu for ALL clips, replacing one
    // QtQuick Controls Menu instance PER clip delegate (a Menu is a Popup
    // with its own content ListView and, on most platforms, a backing
    // window - by far the heaviest single child TimelineClip.qml had,
    // created for every clip whether or not the user ever right-clicks).
    property string menuClipId: ""
    Menu {
        id: clipContextMenu
        MenuItem {
            text: "Split"
            // Right-click already sets selectedClipId = menuClipId (see
            // TimelineClip.qml's body MouseArea onClicked for the
            // RightButton branch) - splitAtPlayhead() reads that, and
            // (same as the toolbar Split button) only acts if the
            // playhead actually falls within this clip's range.
            onTriggered: timelineContainer.splitAtPlayhead()
        }
        MenuItem {
            text: "Unlink Audio/Video"
            enabled: timelineContainer.isClipLinked(timelineContainer.menuClipId)
            onTriggered: timelineContainer.unlinkClips(timelineContainer.menuClipId)
        }
        MenuItem {
            text: "Delete"
            // Right-click already sets selectedClipId = menuClipId (see
            // TimelineClip.qml's body MouseArea onClicked for the
            // RightButton branch) - deleteSelectedClip() reads that.
            onTriggered: timelineContainer.deleteSelectedClip()
        }
    }

    // === DRAG STATE ===
    property var activeDragItem: null
    property int scrollDirection: 0
    property int scrollSpeed: 20
    property real mouseTimeSeconds: 0.0

    // === SIGNALS ===
    signal requestNeighborCheck()
    // A clip was (re)selected by the user or by an editing action, even if
    // selectedClipId kept its value - the Clip Information panel uses it to
    // switch back to describing the timeline clip.
    signal clipSelectionTouched()
    // Új signal hibaüzenetekhez
    signal showMessage(string msg)

    // === CLIP INDEX (O(1)/O(log n) szomszéd- és overlap-lekérdezésekhez) ===
    // A régi kód minden szerkesztésnél O(n) modell-scant futtatott MINDEN
    // klip/transition delegate-ben (pl. calculateOverlapAmount(),
    // clipTransitionZone(), checkForNeighbor()) - ez n klipnél O(n^2)
    // ListModel.get() hívás egyetlen szerkesztésnél, és drag közben is
    // (lásd TimelineClip.updateDragPosition() korábbi hasTransitionGroup
    // számítása). Ez az index EGYSZER, egy O(n log n) átmenet alatt
    // épül fel checkAllClipNeighbors()-ben, a delegate-ek pedig már csak
    // ebből olvasnak O(1)/O(log n) alatt.
    property var clipIndexByTrack: ({})      // trackId -> [{clipId,startTime,durationSeconds,hasTransition,transitionDuration,transitionCutOffset}], startTime szerint rendezve
    property var overlapByClipId: ({})       // clipId(B) -> bejövő overlap mértéke (geometriai - calculateOverlapAmount() eredeti szemantikája)
    property var incomingTransDurById: ({})  // clipId(B) -> bejövő transition hossz (ID-alapú, transitionOriginalBId linkeléssel - clipTransitionZone() eredeti szemantikája)
    // clipId(B) -> A oldal transitionCutOffset-je (hol van a TÉNYLEGES
    // vágáspont az overlap elejétől, nem a feltételezett felezőpont) -
    // lásd KdenliveImporter.cpp emitEditingJson()'s transitionCutOffset:
    // Kdenlive-ból importált aszimmetrikus mixcut esetén ez eltér
    // transitionDuration/2-től, TimelineClip.qml ezt olvassa a B klip
    // vizuális pozíciójának/szélességének kiszámításához.
    property var incomingCutOffsetById: ({})

    function rebuildClipIndex() {
        var byTrack = {}
        var incoming = {}
        var incomingCutOffset = {}
        var maxEnd = 0
        var spans = new Array(clipsModel.count)

        for (var i = 0; i < clipsModel.count; i++) {
            var c = clipsModel.get(i)
            if (!byTrack[c.trackId]) byTrack[c.trackId] = []
            byTrack[c.trackId].push({
                clipId: c.clipId,
                startTime: c.startTime,
                durationSeconds: c.durationSeconds,
                hasTransition: c.hasTransition,
                transitionDuration: c.transitionDuration,
                transitionCutOffset: c.transitionCutOffset
            })
            if (c.hasTransition && c.transitionOriginalBId) {
                incoming[c.transitionOriginalBId] = c.transitionDuration
                incomingCutOffset[c.transitionOriginalBId] =
                    c.transitionCutOffset !== undefined ? c.transitionCutOffset : c.transitionDuration / 2.0
            }
            var end = c.startTime + c.durationSeconds
            if (end > maxEnd) maxEnd = end
            // Row-aligned span for the Stage-3b window predicate. Row
            // order here is clipsModel row order (insertion order), NOT
            // time order - that's fine, the predicate is a plain interval
            // test per row, not a search.
            spans[i] = { id: c.clipId, s: c.startTime, e: end }
        }
        contentEndSeconds = maxEnd
        clipSpanByRow = spans

        var overlap = {}
        for (var trackId in byTrack) {
            if (!byTrack.hasOwnProperty(trackId)) continue
            var arr = byTrack[trackId]
            arr.sort(function(a, b) { return a.startTime - b.startTime })
            for (var k = 0; k < arr.length; k++) {
                var a = arr[k]
                if (!a.hasTransition) continue
                var aEnd = a.startTime + a.durationSeconds
                // A régi calculateOverlapAmount() geometriai feltétele
                // (other.startTime < model.startTime && otherEnd >
                // model.startTime) ekvivalens azzal, hogy a sorban
                // KÖVETKEZŐ klip kezdete A vége elé esik.
                if (k + 1 < arr.length) {
                    var b = arr[k + 1]
                    if (b.startTime < aEnd) {
                        overlap[b.clipId] = a.transitionDuration
                    }
                }
            }
        }

        clipIndexByTrack = byTrack
        overlapByClipId = overlap
        incomingTransDurById = incoming
        incomingCutOffsetById = incomingCutOffset
    }

    // Shared O(log n + k) wall lookup via clipIndexByTrack, replacing the
    // O(n) per-call scans that used to live in TimelineClip.getTrackWalls()/
    // getTrackWallsExcludeGroup() and TimelineDropArea.findTrackWalls() -
    // all three now call this. excludeIds: clipIds to skip (the dragged
    // clip/its linked partner, or a whole transition group). Returns pixel
    // units, matching those functions' existing contract. k is bounded by
    // how many consecutive entries must be skipped (excluded, or - in a
    // non-overlapping track, which is the only state the rest of this app
    // ever produces outside the bounded transition-crossfade overlap -
    // essentially never more than a couple).
    function getTrackWallsIndexed(trackId, centerSeconds, excludeIds) {
        var arr = clipIndexByTrack[trackId]
        if (!arr || arr.length === 0) {
            return { l: 0, r: 99999999 }
        }

        function isExcluded(clipId) {
            if (!excludeIds) return false
            for (var e = 0; e < excludeIds.length; e++) {
                if (excludeIds[e] === clipId) return true
            }
            return false
        }

        var lo = 0, hi = arr.length
        while (lo < hi) {
            var mid = (lo + hi) >> 1
            if (arr[mid].startTime < centerSeconds) lo = mid + 1
            else hi = mid
        }

        var leftWall = 0
        for (var i = lo - 1; i >= 0; i--) {
            var o = arr[i]
            if (isExcluded(o.clipId)) continue
            var oCenter = o.startTime + o.durationSeconds / 2
            if (centerSeconds >= oCenter) {
                leftWall = o.startTime + o.durationSeconds
                break
            }
            // Else: this predecessor's own center is still ahead of
            // centerSeconds, so per the original (pre-index) semantics it
            // would bucket toward rightWall, not leftWall - keep scanning
            // further back for the true left bound rather than stopping
            // here. Only reachable with unusually large/overlapping clips;
            // kept for safety even though the rest of the app already
            // enforces non-overlap outside the bounded transition zone.
        }

        var rightWall = 99999999
        for (var j = lo; j < arr.length; j++) {
            var o2 = arr[j]
            if (isExcluded(o2.clipId)) continue
            var o2Center = o2.startTime + o2.durationSeconds / 2
            if (centerSeconds < o2Center) {
                rightWall = o2.startTime
                break
            }
        }

        return { l: leftWall * pixelsPerSecond, r: rightWall * pixelsPerSecond }
    }

    // Direct, authoritative interval-overlap check - independent safety
    // net for TimelineDropArea.qml's findValidDropPosition(). That
    // function picks a neighbor's "wall" via a CENTER-based bucket
    // (which side of a neighboring clip's own center the drop's own
    // center falls on) - for a dragged item much WIDER than the gap
    // it's being dropped into (a title's fixed default duration into a
    // short gap between two existing clips, confirmed by a real user
    // report), that bucketing can pick the wrong neighbor as the
    // reference wall, under-reporting how far away the true obstacle
    // is and letting the drop land overlapping it despite being
    // reported "valid". This function doesn't replace that logic (kept
    // for its drag-feel/snapping behavior) - it's a final correctness
    // check run on the ALREADY-CLAMPED result, so it can only turn a
    // wrongly-accepted drop into a rejected one, never the reverse.
    function hasOverlapInRange(trackId, startSeconds, endSeconds, excludeIds) {
        var arr = clipIndexByTrack[trackId]
        if (!arr) {
            return false
        }
        for (var i = 0; i < arr.length; i++) {
            var c = arr[i]
            if (excludeIds && excludeIds.indexOf(c.clipId) >= 0) continue
            if (c.startTime < endSeconds && (c.startTime + c.durationSeconds) > startSeconds) {
                return true
            }
        }
        return false
    }

    // === CLIP/TRANSITION DELEGATE REGISTRY ===
    // TimelineClip's findLinkedVisualItem()/findClipVisualItem()/
    // findTransitionOverlay() used to linearly scan contentContainer's
    // QML children (container.children) to find a delegate by clipId -
    // O(n) per lookup, called repeatedly while building a drag's
    // transition group. Delegates register themselves here instead.
    // clipId is NOT a stable key across a clip's lifetime (split()
    // reassigns it on the same ListModel row/delegate instance without
    // destroying it), so registration happens on every clipId change,
    // not just once at creation - see TimelineClip.qml's syncRegistration().
    // These two registries are ES6 Maps, NOT plain objects used as dictionaries:
    // Qt 6.4.2's QV4 engine segfaults in QV4::Object::insertMember when keys
    // are added to a plain object after earlier keys of it were removed with
    // `delete obj[key]` (reproduced with a standalone QML file, no app code;
    // here it hit after a few undo/split/restore cycles that tore the
    // delegates down and re-created them). A Map keeps its entries in its
    // own table, not in the object's member storage, so set()/delete() are safe.
    property var clipItemsById: new Map()          // clipId -> TimelineClip instance
    property var transitionItemsByOwner: new Map() // ownerClipId -> TimelineTransition instance

    function registerClipItem(clipId, item) {
        if (clipId) clipItemsById.set(clipId, item)
    }
    function unregisterClipItem(clipId, item) {
        if (clipId && clipItemsById.get(clipId) === item) clipItemsById.delete(clipId)
    }
    function registerTransitionItem(ownerClipId, item) {
        if (ownerClipId) transitionItemsByOwner.set(ownerClipId, item)
    }
    function unregisterTransitionItem(ownerClipId, item) {
        if (ownerClipId && transitionItemsByOwner.get(ownerClipId) === item) transitionItemsByOwner.delete(ownerClipId)
    }

    // === TIMERS ===
    Timer {
        interval: 500
        running: true
        repeat: false
        onTriggered: timelineContainer.checkAllClipNeighbors()
    }

    Timer {
        id: edgeScrollTimer
        interval: 16
        running: scrollDirection !== 0
        repeat: true
        onTriggered: {
            var currentX = tracksContentFlickable.contentX
            var nextX = currentX + (scrollDirection * scrollSpeed)
            var maxScroll = tracksContentFlickable.contentWidth - tracksContentFlickable.width
            nextX = Math.max(0, Math.min(nextX, maxScroll))

            if (currentX !== nextX) {
                tracksContentFlickable.contentX = nextX
                // The additive-only hold (windowAdditiveOnly) is what
                // actually prevents the dragged clip from being evicted
                // mid-drag; this guard is the cheap second line of
                // defence - a destroyed QObject reads as falsy in QML, so
                // without it a stale activeDragItem would mean a
                // TypeError every 16ms forever plus runaway auto-scroll.
                if (activeDragItem && activeDragItem.updateDragPosition) activeDragItem.updateDragPosition()
            }
        }
    }

    // === TRANSITION LOGIC (ÚJ) ===

    // Felépíti a transition csoportot - visszaadja az összes clipId-t ami transition-ban van a megadott klippel
    function buildTransitionGroup(startClipId) {
        var group = []
        var visited = {}
        var toProcess = [startClipId]

        while (toProcess.length > 0) {
            var currentId = toProcess.shift()

            // Ha már feldolgoztuk, skip
            if (visited[currentId]) continue
            visited[currentId] = true

            // Megkeressük a klipet
            var currentClip = null
            for (var i = 0; i < clipsModel.count; i++) {
                var c = clipsModel.get(i)
                if (c.clipId === currentId) {
                    currentClip = c
                    break
                }
            }

            if (!currentClip) continue

            // Hozzáadjuk a csoporthoz
            group.push(currentId)

            // Ha a current klipnek van linked párja, azt is hozzáadjuk
            if (currentClip.isLinked && currentClip.linkedClipId && !visited[currentClip.linkedClipId]) {
                toProcess.push(currentClip.linkedClipId)
            }

            // ELŐRE: Ha van transition, akkor B klipet is hozzáadjuk (és annak linked párját)
            if (currentClip.hasTransition && currentClip.transitionOriginalBId && !visited[currentClip.transitionOriginalBId]) {
                toProcess.push(currentClip.transitionOriginalBId)

                // Ha a B klipnek van linked párja, azt is hozzáadjuk
                for (var k = 0; k < clipsModel.count; k++) {
                    var bClip = clipsModel.get(k)
                    if (bClip.clipId === currentClip.transitionOriginalBId) {
                        if (bClip.isLinked && bClip.linkedClipId && !visited[bClip.linkedClipId]) {
                            toProcess.push(bClip.linkedClipId)
                        }
                        break
                    }
                }
            }

            // HÁTRA: Keressük meg, hogy van-e olyan klip ami transition-ban van ezzel (A klip)
            for (var j = 0; j < clipsModel.count; j++) {
                var other = clipsModel.get(j)
                if (other.hasTransition && other.transitionOriginalBId === currentId && !visited[other.clipId]) {
                    toProcess.push(other.clipId)

                    // Ha az A klipnek van linked párja, azt is hozzáadjuk
                    if (other.isLinked && other.linkedClipId && !visited[other.linkedClipId]) {
                        toProcess.push(other.linkedClipId)
                    }
                }
            }
        }

        return group
    }

    // Transition típusok konfigurációja
    readonly property var videoTransitions: [
        "dissolve",         // Crossfade/dissolve (default)
        "bar-wipe-lr",     // Bar wipe left to right
        "bar-wipe-tb",     // Bar wipe top to bottom
        "box-wipe-tl",     // Box wipe from top-left
        "box-wipe-tr",     // Box wipe from top-right
        "box-wipe-br",     // Box wipe from bottom-right
        "box-wipe-bl",     // Box wipe from bottom-left
        "four-box-wipe-ci", // Four box clockwise in
        "four-box-wipe-co", // Four box clockwise out
        "barndoor-v",      // Vertical barndoor
        "barndoor-h",      // Horizontal barndoor
        "misc-diagonal-tl", // Diagonal from top-left
        "misc-diagonal-tr", // Diagonal from top-right
        "clock-cw12",      // Clock wipe from 12 o'clock
        "clock-cw3",       // Clock wipe from 3 o'clock
        "clock-cw6",       // Clock wipe from 6 o'clock
        "clock-cw9"        // Clock wipe from 9 o'clock
    ]

    readonly property var audioTransitions: [
        "crossfade"        // Audio crossfade (default)
    ]

    // Default párosítás (fix, beégetve)
    readonly property string defaultVideoTransition: "dissolve"
    readonly property string defaultAudioTransition: "crossfade"

    // Id-alapú belépési pontok a TimelineTransition delegate "+"/"×"
    // gombjaihoz. A delegate korábban a saját `index`-ét adta át
    // applyTransition()/removeTransition()-nek - ez a clipsModel-beli SOR
    // indexe csak addig, amíg a delegate-ek 1:1-ben megfelelnek a modell
    // soroknak. Egy jövőbeli szűrt/virtualizált nézet alatt (Stage 3b)
    // `index` a SZŰRT csoporton belüli pozíció lenne, nem a forrás-sor -
    // ez a "+"/"×" gombot egy TETSZŐLEGES ROSSZ klipre alkalmazná/törölné.
    // Id-vel azonosítva ez a hiba strukturálisan kizárt.
    function applyTransitionById(clipId) {
        var row = findClipRowById(clipId)
        if (row >= 0) applyTransition(row)
    }
    function removeTransitionById(clipId) {
        var row = findClipRowById(clipId)
        if (row >= 0) removeTransition(row)
    }
    // Changes an EXISTING transition's wipe shape in place (duration/cut
    // point untouched) - distinct from applyTransition()'s "create a new
    // transition" and removeTransition()'s "delete it". Video-only by
    // design: GES wipe types other than crossfade have no meaning on an
    // audio-only transition clip (see GesTransitions::applyTransitionTypes()'s
    // GES_TRACK_TYPE_VIDEO guard) - TimelineTransition.qml's picker is
    // only shown on video tracks in the first place, but this function
    // stays defensive rather than trusting the caller.
    function setTransitionTypeById(clipId, type) {
        var row = findClipRowById(clipId)
        if (row < 0) return
        var cd = clipsModel.get(row)
        if (!cd.hasTransition || !cd.trackId.startsWith("V")) return
        beginUndoableEdit()
        clipsModel.setProperty(row, "transitionType", type)
        if (updateTimelineEngine) updateTimelineEngine()
        Backend.logOperation("transition_type_change", { clipId: clipId, trackId: cd.trackId, type: type })
        commitUndoableEdit("Change transition type")
    }
    // Shared by TimelineTransition.qml's type picker and (for the
    // common ones) its own label text - the full set this app can
    // actually realize, via GesTransitions::applyTransitionTypes()'s
    // "vtype" property write (TimelineEngine.cpp/RenderEngine.cpp), plus
    // the mapping table a Kdenlive luma-wipe import resolves onto
    // (KdenliveImporter.cpp's kLumaMappings). "crossfade" (labelled
    // Dissolve) is always first - it's GES's own default/no-wipe type.
    readonly property var availableTransitionTypes: [
        { nick: "crossfade", label: "Dissolve" },
        { nick: "bar-wipe-lr", label: "Bar Wipe (H)" },
        { nick: "bar-wipe-tb", label: "Bar Wipe (V)" },
        { nick: "box-wipe-br", label: "Box Wipe (BR)" },
        { nick: "box-wipe-bl", label: "Box Wipe (BL)" },
        { nick: "box-wipe-rc", label: "Box Wipe (Center)" },
        { nick: "iris-rect", label: "Iris Wipe" },
        { nick: "four-box-wipe-ci", label: "Double Iris" },
        { nick: "barndoor-v", label: "Barn Door (H)" },
        { nick: "barndoor-h", label: "Barn Door (V)" },
        { nick: "barndoor-dbl", label: "Barn Door (Diag \\)" },
        { nick: "barndoor-dtl", label: "Barn Door (Diag /)" },
        { nick: "diagonal-tl", label: "Diagonal Wipe (TL)" },
        { nick: "diagonal-tr", label: "Diagonal Wipe (TR)" },
        { nick: "barnvee-u", label: "Barn Vee" },
        { nick: "clock-cw12", label: "Clock Wipe" }
    ]
    function findClipRowById(clipId) {
        for (var i = 0; i < clipsModel.count; i++) {
            if (clipsModel.get(i).clipId === clipId) return i
        }
        return -1
    }

    // Resolves a clip row's linked AUDIO row, or -1.
    // A clip dropped on a video track is always split into a video row
    // (hasVideo:true/hasAudio:false) plus a SEPARATE linked audio row
    // (hasVideo:false/hasAudio:true) - see TimelineDropArea.qml. So a
    // row's own hasAudio flag says nothing about whether that clip has
    // audio in the project; the only authoritative test is whether its
    // linkedClipId resolves to a real audio row.
    function linkedAudioRowOf(c) {
        if (!c || !c.isLinked || !c.linkedClipId) return -1
        var r = findClipRowById(c.linkedClipId)
        if (r < 0) return -1
        return clipsModel.get(r).hasAudio === true ? r : -1
    }

    // === TRANSITIONS (Kdenlive-style: nothing on the timeline moves) ===
    // A transition is an overlap of A (left) and B (right) around a CUT
    // POINT C. Applying it extends A's tail to the right and B's head to
    // the left into unused source material ("handles"); removing it trims
    // both back to C; a duration change keeps C. transitionCutOffset is
    // the cut's offset from the overlap start (Kdenlive's mixcut, see
    // KdenliveImporter.cpp), so overlap = [C - cut, C - cut + d]. Clips
    // never move, so no ripple is involved. Projects made with the older
    // "B moves left by d" model hold exactly the same geometry (an
    // overlap + cut), so they load, play and edit the same way.
    //
    // Geometry of an A/B pair "as if cut at C" (the transition-free state):
    // A ends at C, B starts at C with sourceOffset bSo0. lim.right/left:
    // how far A may extend right / B may extend left - limited by media
    // handles and by the transitions on A's other side / B's other side
    // (GES does not allow three clips to overlap).
    function sourceLengthOf(c) {
        if ((c.clipKind || "") === "title") return Infinity
        var L = timelineEngine ? timelineEngine.sourceDurationSeconds(c.itemPath || "") : -1
        if (L === Infinity || L > 0) return L
        if (c.sourceItemId) {
            var md = Backend.projectBinModel.getItemMetadata(c.sourceItemId)
            var s = md && md.duration ? durationToSeconds(md.duration) : 0
            if (s > 0) return s
        }
        return -1
    }
    function transitionPairGeometry(a, b, C) {
        var frame = 1.0 / projectFps()
        var g = { C: C, aDur0: C - a.startTime,
                  bSo0: (b.sourceOffset || 0) + (C - b.startTime),
                  bEnd: b.startTime + b.durationSeconds,
                  bStill: (b.clipKind || "") === "title" || sourceLengthOf(b) === Infinity }
        var La = sourceLengthOf(a)
        var hA = La === Infinity ? Infinity
               : (La > 0 ? Math.max(0, La - frame - ((a.sourceOffset || 0) + g.aDur0)) : 0)
        var hB = g.bStill ? Infinity : Math.max(0, g.bSo0)
        var inA = 0     // overlap of the transition INTO A (other side)
        for (var i = 0; i < clipsModel.count; i++) {
            var o = clipsModel.get(i)
            if (o.hasTransition && o.transitionOriginalBId === a.clipId && o.clipId !== a.clipId)
                inA = o.transitionDuration || 0
        }
        var outB = (b.hasTransition && b.transitionOriginalBId) ? (b.transitionDuration || 0) : 0
        var rA = C - (a.startTime + inA)
        var rB = (g.bEnd - outB) - C
        g.right = Math.max(0, Math.min(hA, rB))
        g.left = Math.max(0, Math.min(hB, rA))
        return g
    }
    // Cut offset for duration d within the limits, as close to pref as possible.
    function chooseTransitionCut(d, pref, right, left) {
        return Math.max(Math.max(0, d - right), Math.min(left, pref))
    }
    function placeTransitionOverlap(rowA, rowB, g, d, cut) {
        clipsModel.setProperty(rowA, "durationSeconds", g.aDur0 + (d - cut))
        clipsModel.setProperty(rowB, "startTime", g.C - cut)
        clipsModel.setProperty(rowB, "durationSeconds", g.bEnd - (g.C - cut))
        if (!g.bStill) clipsModel.setProperty(rowB, "sourceOffset", Math.max(0, g.bSo0 - cut))
    }
    function snapDownToFrame(t) {
        var fps = projectFps()
        return Math.floor(t * fps + 1e-6) / fps
    }

    // Short non-modal message at the bottom of the timeline (transition
    // shortened / refused, all-tracks ripple blocked). lastNotice is also
    // read by the automation tests.
    property string lastNotice: ""
    function showTimelineNotice(msg) {
        console.log("Timeline notice:", msg)
        lastNotice = msg
        timelineNotice.text = msg
        timelineNotice.opacity = 1
        timelineNoticeTimer.restart()
    }

    // Resolves the linked A/B pair that should crossfade together with
    // the video pair: both linked, partners found, and (for a NEW
    // transition) the partner cut lines up with the main cut.
    function alignedLinkedPair(a, b, C) {
        if (!(a.isLinked && a.linkedClipId && b.isLinked && b.linkedClipId)) return null
        var rAL = findClipRowById(a.linkedClipId)
        var rBL = findClipRowById(b.linkedClipId)
        if (rAL < 0 || rBL < 0) return null
        var al = clipsModel.get(rAL), bl = clipsModel.get(rBL)
        if (al.trackId !== bl.trackId || al.hasTransition) return null
        var eps = 1e-4
        if (Math.abs(al.startTime - a.startTime) > eps || Math.abs(al.startTime + al.durationSeconds - C) > eps
                || Math.abs(bl.startTime - b.startTime) > eps
                || Math.abs(bl.startTime + bl.durationSeconds - (b.startTime + b.durationSeconds)) > eps)
            return null
        return { rowAL: rAL, rowBL: rBL }
    }

    // Ellenőrzi és alkalmazza az átmenetet
    function applyTransition(clipIndex) {
        var clipA = clipsModel.get(clipIndex)
        if (clipA.hasTransition) return
        var tolerance = 0.1

        // Track típus meghatározása (video vagy audio)
        var isVideoTrack = clipA.trackId.startsWith("V")
        var currentTransitionType = isVideoTrack ? defaultVideoTransition : defaultAudioTransition
        var linkedTransitionType = isVideoTrack ? defaultAudioTransition : defaultVideoTransition

        // 1. Szomszéd keresése (Clip B)
        var clipBIndex = -1
        var clipB = null
        var endTimeA = clipA.startTime + clipA.durationSeconds
        for (var i = 0; i < clipsModel.count; i++) {
            var other = clipsModel.get(i)
            if (other.trackId === clipA.trackId && Math.abs(other.startTime - endTimeA) < tolerance && other.clipId !== clipA.clipId) {
                clipB = other
                clipBIndex = i
                break
            }
        }
        if (clipBIndex === -1 || !clipB) {
            console.log("Nem található szomszédos klip az átmenethez.")
            return
        }

        // 2. Duration and cut. Re-adding a transition that was removed
        // between this SAME A/B pair restores its duration and cut point
        // (removeTransition() leaves both on A). Otherwise: the Settings
        // default, centered on the cut.
        var C = endTimeA
        var d0 = defaultTransitionDurationNow()
        var pref = d0 / 2.0
        if (clipA.transitionOriginalBId === clipB.clipId && clipA.transitionDuration > 0) {
            d0 = clipA.transitionDuration
            var rc = clipA.transitionCutOffset
            pref = (rc !== undefined && rc >= 0 && rc <= d0) ? rc : d0 / 2.0
        }

        var g = transitionPairGeometry(clipA, clipB, C)
        var right = g.right, left = g.left
        var linked = alignedLinkedPair(clipA, clipB, C)
        var gL = null
        if (linked) {
            gL = transitionPairGeometry(clipsModel.get(linked.rowAL), clipsModel.get(linked.rowBL), C)
            right = Math.min(right, gL.right)
            left = Math.min(left, gL.left)
        }
        var maxD = right + left
        var frame = 1.0 / projectFps()
        if (maxD < frame - 1e-9) {
            showTimelineNotice("Cannot add transition: not enough unused media at the cut (handles).")
            return
        }
        var d = d0
        if (d0 > maxD + 1e-9) {
            d = Math.max(frame, snapDownToFrame(maxD))
            pref = pref * d / d0
            showTimelineNotice("Transition shortened to " + d.toFixed(2) + " s (not enough unused media at the cut).")
        }
        var cut = chooseTransitionCut(d, pref, right, left)

        // 3. Overlap from handles - nothing moves.
        beginUndoableEdit()
        clipsModel.setProperty(clipIndex, "transitionOriginalBId", clipB.clipId)
        clipsModel.setProperty(clipIndex, "transitionOriginalStartB", C)
        clipsModel.setProperty(clipIndex, "hasTransition", true)
        clipsModel.setProperty(clipIndex, "transitionDuration", d)
        clipsModel.setProperty(clipIndex, "transitionType", currentTransitionType)
        clipsModel.setProperty(clipIndex, "transitionCutOffset", cut)
        // A one-sided audio (A has audio, B none / partners not aligned)
        // simply stays cut at C: only the video extends.
        clipsModel.setProperty(clipIndex, "transitionAudioTrimA", 0)
        placeTransitionOverlap(clipIndex, clipBIndex, g, d, cut)

        if (linked) {
            var blId = clipsModel.get(linked.rowBL).clipId
            clipsModel.setProperty(linked.rowAL, "transitionOriginalBId", blId)
            clipsModel.setProperty(linked.rowAL, "transitionOriginalStartB", C)
            clipsModel.setProperty(linked.rowAL, "hasTransition", true)
            clipsModel.setProperty(linked.rowAL, "transitionDuration", d)
            clipsModel.setProperty(linked.rowAL, "transitionType", linkedTransitionType)
            clipsModel.setProperty(linked.rowAL, "transitionCutOffset", cut)
            clipsModel.setProperty(linked.rowAL, "transitionAudioTrimA", 0)
            placeTransitionOverlap(linked.rowAL, linked.rowBL, gL, d, cut)
        }

        if (updateTimelineEngine) updateTimelineEngine()
        checkAllClipNeighbors()
        Backend.logOperation("transition_apply", {
            clipA: clipA.clipId, trackA: clipA.trackId,
            clipB: clipB.clipId, trackB: clipB.trackId,
            duration: d, cutOffset: cut, cutPoint: C, linked: linked !== null
        })
        commitUndoableEdit("Apply transition")
    }

    function removeTransition(clipIndex) {
        var clipA = clipsModel.get(clipIndex)
        if (!clipA.hasTransition) return
        beginUndoableEdit()
        var originalBId = clipA.transitionOriginalBId
        var d = clipA.transitionDuration || 0
        var clipBIndex = findClipRowById(originalBId)

        if (clipBIndex !== -1 && d > 0) {
            var clipB = clipsModel.get(clipBIndex)
            // Linked pair carrying the same transition (resolved BEFORE
            // anything is trimmed).
            var rowAL = -1, rowBL = -1
            if (clipA.isLinked && clipA.linkedClipId && clipB.isLinked && clipB.linkedClipId) {
                var rAL = findClipRowById(clipA.linkedClipId)
                var rBL = findClipRowById(clipB.linkedClipId)
                if (rAL >= 0 && rBL >= 0 && clipsModel.get(rAL).hasTransition
                        && clipsModel.get(rAL).transitionOriginalBId === clipB.linkedClipId) {
                    rowAL = rAL; rowBL = rBL
                }
            }
            // Trim both back to the cut point - nothing moves.
            var cut = clipA.transitionCutOffset !== undefined ? clipA.transitionCutOffset : d / 2.0
            placeTransitionOverlap(clipIndex, clipBIndex,
                                   transitionPairGeometry(clipA, clipB, clipB.startTime + cut), 0, 0)
            if (rowAL >= 0) {
                var al = clipsModel.get(rowAL), bl = clipsModel.get(rowBL)
                var dl = al.transitionDuration || d
                var cutL = al.transitionCutOffset !== undefined ? al.transitionCutOffset : dl / 2.0
                placeTransitionOverlap(rowAL, rowBL, transitionPairGeometry(al, bl, bl.startTime + cutL), 0, 0)
                // Duration/cut stay on the row (re-add memory).
                clipsModel.setProperty(rowAL, "hasTransition", false)
                clipsModel.setProperty(rowAL, "transitionType", "")
                clipsModel.setProperty(rowAL, "transitionAudioTrimA", 0)
            }
        }

        // An old-model one-sided audio trim (A's audio was shortened by
        // d/2, i.e. it already ends at the cut) needs no restore any more:
        // A's video is trimmed back to that same cut.
        clipsModel.setProperty(clipIndex, "transitionAudioTrimA", 0)

        // Flag törlése. transitionDuration/transitionCutOffset/
        // transitionOriginalBId deliberately stay: every reader gates on
        // hasTransition, and applyTransition() uses them to restore the
        // same transition on a re-add.
        clipsModel.setProperty(clipIndex, "hasTransition", false)
        clipsModel.setProperty(clipIndex, "transitionType", "")

        if (updateTimelineEngine) updateTimelineEngine()
        checkAllClipNeighbors()
        Backend.logOperation("transition_remove", {
            clipA: clipA.clipId, trackA: clipA.trackId, originalBId: originalBId
        })
        commitUndoableEdit("Remove transition")
    }

    // --- Transition duration change -----------------------------------
    // Resolves everything setTransitionDurationById() / the drag UI need
    // for the transition owned by A (ownerClipId): rows of A and B, the
    // linked pair (only when the transition exists on both linked tracks,
    // exactly like applyTransition()), the cut-point geometry and the
    // allowed duration range (media handles + neighboring transitions).
    function transitionContext(ownerClipId) {
        var rowA = findClipRowById(ownerClipId)
        if (rowA < 0) return null
        var a = clipsModel.get(rowA)
        if (!a.hasTransition || !(a.transitionDuration > 0)) return null
        var rowB = findClipRowById(a.transitionOriginalBId)
        if (rowB < 0) return null
        var b = clipsModel.get(rowB)
        var d = a.transitionDuration
        var cut = a.transitionCutOffset !== undefined ? a.transitionCutOffset : d / 2.0
        var ctx = { rowA: rowA, rowB: rowB, rowAL: -1, rowBL: -1, duration: d, cut: cut }
        ctx.geo = transitionPairGeometry(a, b, b.startTime + cut)
        var right = ctx.geo.right, left = ctx.geo.left
        if (a.isLinked && a.linkedClipId && b.isLinked && b.linkedClipId) {
            var rAL = findClipRowById(a.linkedClipId)
            var rBL = findClipRowById(b.linkedClipId)
            if (rAL >= 0 && rBL >= 0 && clipsModel.get(rAL).hasTransition
                    && clipsModel.get(rAL).transitionOriginalBId === b.linkedClipId) {
                ctx.rowAL = rAL
                ctx.rowBL = rBL
                var al = clipsModel.get(rAL), bl = clipsModel.get(rBL)
                var dl = al.transitionDuration || d
                ctx.cutL = al.transitionCutOffset !== undefined ? al.transitionCutOffset : dl / 2.0
                ctx.durationL = dl
                ctx.geoL = transitionPairGeometry(al, bl, bl.startTime + ctx.cutL)
                right = Math.min(right, ctx.geoL.right)
                left = Math.min(left, ctx.geoL.left)
            }
        }
        ctx.right = right
        ctx.left = left
        ctx.maxDuration = Math.max(0, right + left)
        return ctx
    }
    // Allowed [min, max] in seconds (min = one project frame, max rounded
    // down to a whole frame) for the UI; null when there is no transition.
    function transitionDurationRange(ownerClipId) {
        var ctx = transitionContext(ownerClipId)
        if (!ctx) return null
        var fps = projectFps()
        return { min: 1.0 / fps, max: Math.max(1.0 / fps, Math.floor(ctx.maxDuration * fps + 1e-6) / fps) }
    }
    function snapTransitionDuration(ownerClipId, d) {
        var r = transitionDurationRange(ownerClipId)
        if (!r) return d
        var fps = projectFps()
        var snapped = Math.round(d * fps) / fps
        return Math.max(r.min, Math.min(r.max, snapped))
    }

    // Changes an existing transition from d to d'. The cut point stays
    // where it is; the cut offset scales with the duration (clamped to
    // the available handles), A's tail and B's head follow. Nothing else
    // moves. Returns true when something changed. One undoable edit.
    function setTransitionDurationById(ownerClipId, newDuration) {
        var ctx = transitionContext(ownerClipId)
        if (!ctx) return false
        var d = ctx.duration
        var nd = snapTransitionDuration(ownerClipId, newDuration)
        if (!(nd > 0) || Math.abs(nd - d) < 1e-6) return false
        var a = clipsModel.get(ctx.rowA)
        var aId = a.clipId
        var bId = clipsModel.get(ctx.rowB).clipId
        var cut = chooseTransitionCut(nd, ctx.cut * nd / d, ctx.right, ctx.left)

        beginUndoableEdit()
        clipsModel.setProperty(ctx.rowA, "transitionDuration", nd)
        clipsModel.setProperty(ctx.rowA, "transitionCutOffset", cut)
        placeTransitionOverlap(ctx.rowA, ctx.rowB, ctx.geo, nd, cut)
        if (ctx.rowAL >= 0) {
            var cutL = chooseTransitionCut(nd, ctx.cutL * nd / ctx.durationL, ctx.right, ctx.left)
            clipsModel.setProperty(ctx.rowAL, "transitionDuration", nd)
            clipsModel.setProperty(ctx.rowAL, "transitionCutOffset", cutL)
            placeTransitionOverlap(ctx.rowAL, ctx.rowBL, ctx.geoL, nd, cutL)
        }

        if (updateTimelineEngine) updateTimelineEngine()
        checkAllClipNeighbors()
        Backend.logOperation("transition_duration", {
            clipA: aId, clipB: bId, oldDuration: d, newDuration: nd, cutOffset: cut
        })
        commitUndoableEdit("Change transition duration")
        return true
    }

    // ... (Maradék kód változatlan: Utility functions, Clip functions, Zoom functions, Models, UI Layout) ...
    // === UTILITY FUNCTIONS ===
    function durationToSeconds(durationStr) {
        if (!durationStr || durationStr === "") return 5
        var parts = durationStr.split(":")
        if (parts.length < 3) return 5
        return (parseInt(parts[0])||0)*3600 + (parseInt(parts[1])||0)*60 + (parseFloat(parts[2])||0)
    }

    // === TRACK INDEX (O(1) track lookups, mirrors the Stage-1 clip index) ===
    // getTrackIndexFromId()/getTrackType()/getTrackYPosition() used to
    // linearly scan tracksModel on every call - called from inside the
    // drag hot loop (updateTransitionGroupPosition() alone calls
    // tracks.get()-based scans multiple times per mouse-move). tracksModel
    // only has a handful of rows today, but it's user-extensible (+Track),
    // and the scan cost was paid every frame regardless.
    property var trackIndexById: ({})   // trackId -> row index in tracksModel
    property var trackTypeById: ({})    // trackId -> "video"/"audio"
    // Bumped on every rebuild. TimelineClip.y/TimelineTransition.y read
    // this (see those files) purely to force their y binding to
    // re-evaluate when a track is added/removed/reordered - getTrackYPosition()
    // reads tracksModel via trackIndexById, which on its own does NOT
    // retrigger a QML binding that calls it (the same non-reactivity trap
    // already documented for clipTransitionZone()/ListModel.get()).
    property int trackGeometryRevision: 0

    function rebuildTrackIndex() {
        var idx = {}
        var types = {}
        for (var i = 0; i < tracksModel.count; i++) {
            var t = tracksModel.get(i)
            idx[t.trackId] = i
            types[t.trackId] = t.type
        }
        trackIndexById = idx
        trackTypeById = types
        trackGeometryRevision++
        // Deferred: bulk rewrites (load, undo of a track change) clear()
        // and re-append rows one by one; judge the finished model only.
        Qt.callLater(ensureActiveTrack)
    }

    Connections {
        target: tracksModel
        function onCountChanged() { timelineContainer.rebuildTrackIndex() }
    }

    // Belt-and-braces: every edit path already routes through
    // checkAllClipNeighbors(), but an append/remove that somehow doesn't
    // would otherwise leave the new row permanently invisible under
    // Stage 3b's window filter. Debounced, so a bulk append (e.g.
    // loadProjectJSON()'s clip loop) collapses to a single pass.
    Connections {
        target: clipsModel
        function onCountChanged() { timelineContainer.scheduleRefilter() }
    }

    Component.onCompleted: {
        rebuildTrackIndex()
        // With includeByDefault: false on the "win" group, nothing has a
        // delegate until the first refilter.
        refilterWindowNow()
    }

    // === TRACK FUNCTIONS ===
    function getTrackIndexFromY(localY) {
        return Math.floor(localY / trackHeight)
    }

    function getTrackIdFromIndex(idx) {
        if (idx >= 0 && idx < tracksModel.count) return tracksModel.get(idx).trackId
        return null
    }

    function getTrackIndexFromId(trackId) {
        var idx = trackIndexById[trackId]
        return (idx === undefined) ? -1 : idx
    }

    function getTrackIdFromY(localY) {
        return getTrackIdFromIndex(getTrackIndexFromY(localY))
    }

    function getTrackType(trackId) {
        var t = trackTypeById[trackId]
        return (t === undefined) ? null : t
    }

    function getTrackYPosition(trackId) {
        var idx = trackIndexById[trackId]
        return (idx === undefined) ? 0 : idx * trackHeight
    }

    // === CLIP FUNCTIONS ===
    function canPlaceClipAtTime(trackId, startTime, durationSeconds, excludeClipId) {
        var newEnd = startTime + durationSeconds
        for (var i = 0; i < clipsModel.count; i++) {
            var clip = clipsModel.get(i)
            if (excludeClipId && clip.clipId === excludeClipId) continue
            if (clip.trackId !== trackId) continue
            if ((startTime + 0.01) < (clip.startTime + clip.durationSeconds) && (newEnd - 0.01) > clip.startTime) return false
        }
        return true
    }

    function checkAllClipNeighbors() {
        rebuildClipIndex()
        // Deferred, NOT synchronous. This function is called from inside
        // live signal handlers - TimelineTransition's "+" and "x" button
        // onClicked (via applyTransitionById/removeTransitionById), and in
        // a loop from deleteSelectedClip() - and a synchronous refilter
        // could destroy the very delegate whose handler we are executing
        // inside (classic Qt self-destruction crash). Qt.callLater dedupes
        // identical function references, so deleteSelectedClip()'s
        // repeated removeTransition() calls collapse into one pass, and it
        // still runs before the next render, so a freshly dropped/split
        // clip appears without a visible delay.
        Qt.callLater(refilterWindowNow)
        requestNeighborCheck()
    }

    // === TRACK MAPPING FUNCTIONS ===
    function getCorrespondingAudioTrack(videoTrackId) {
        var trackNum = videoTrackId.replace("V", "")
        var audioTrackId = "A" + trackNum
        for (var i = 0; i < tracksModel.count; i++) {
            if (tracksModel.get(i).trackId === audioTrackId) return audioTrackId
        }
        for (var j = 0; j < tracksModel.count; j++) {
            if (tracksModel.get(j).type === "audio") return tracksModel.get(j).trackId
        }
        return null
    }

    // === LINK MANAGEMENT FUNCTIONS ===
    function linkClips(clipId1, clipId2) {
        beginUndoableEdit()
        var linkGroupId = "link_" + Date.now()
        for (var i = 0; i < clipsModel.count; i++) {
            var clip = clipsModel.get(i)
            if (clip.clipId === clipId1) {
                clipsModel.setProperty(i, "linkGroupId", linkGroupId)
                clipsModel.setProperty(i, "linkedClipId", clipId2)
                clipsModel.setProperty(i, "isLinked", true)
            }
            if (clip.clipId === clipId2) {
                clipsModel.setProperty(i, "linkGroupId", linkGroupId)
                clipsModel.setProperty(i, "linkedClipId", clipId1)
                clipsModel.setProperty(i, "isLinked", true)
            }
        }
        commitUndoableEdit("Link clips")
    }

    function unlinkClips(clipId) {
        beginUndoableEdit()
        var linkedId = null
        for (var i = 0; i < clipsModel.count; i++) {
            var clip = clipsModel.get(i)
            if (clip.clipId === clipId) {
                linkedId = clip.linkedClipId
                clipsModel.setProperty(i, "linkGroupId", "")
                clipsModel.setProperty(i, "linkedClipId", "")
                clipsModel.setProperty(i, "isLinked", false)
            }
        }
        if (linkedId) {
            for (var j = 0; j < clipsModel.count; j++) {
                if (clipsModel.get(j).clipId === linkedId) {
                    clipsModel.setProperty(j, "linkGroupId", "")
                    clipsModel.setProperty(j, "linkedClipId", "")
                    clipsModel.setProperty(j, "isLinked", false)
                    break
                }
            }
        }
        commitUndoableEdit("Unlink clips")
    }

    function getLinkedClipId(clipId) {
        for (var i = 0; i < clipsModel.count; i++) {
            var clip = clipsModel.get(i)
            if (clip.clipId === clipId && clip.isLinked) {
                return clip.linkedClipId
            }
        }
        return null
    }

    function isClipLinked(clipId) {
        for (var i = 0; i < clipsModel.count; i++) {
            if (clipsModel.get(i).clipId === clipId) {
                return clipsModel.get(i).isLinked === true
            }
        }
        return false
    }

    function isClipSelected(clipId) {
        if (selectedClipId === clipId) return true
        var selectedLinkedId = getLinkedClipId(selectedClipId)
        return selectedLinkedId === clipId
    }

    // === MULTI-SELECT ===
    // selectedClipId stays "primary" throughout (drives the inspector);
    // these only manage the wider selectedClipIds set used for effect
    // application and multi-clip move.
    function isClipInSelection(clipId) {
        return selectedClipIds.indexOf(clipId) >= 0
    }

    function selectOnly(clipId) {
        selectedClipId = clipId
        selectedClipIds = clipId === "" ? [] : [clipId]
        selectionAnchorClipId = clipId
        if (clipId !== "") clipSelectionTouched()
    }

    function toggleSelection(clipId) {
        var ids = selectedClipIds.slice()
        var i = ids.indexOf(clipId)
        if (i >= 0) {
            ids.splice(i, 1)
            if (selectedClipId === clipId) selectedClipId = ids.length ? ids[ids.length - 1] : ""
        } else {
            ids.push(clipId)
            selectedClipId = clipId   // last-clicked becomes primary
        }
        selectedClipIds = ids
        selectionAnchorClipId = clipId
        if (selectedClipId !== "") clipSelectionTouched()
    }

    // Shift+click: rectangular region from selectionAnchorClipId to
    // clipId - time span [min(start), max(end)] of both clips, across
    // every track whose tracksModel row index lies between the two
    // clips' track rows (inclusive). Degenerates to "everything between
    // them on this track" when both are on the same track, which is
    // what makes it feel predictable rather than arbitrary - picking
    // only the two clips' own tracks (ignoring ones visually between
    // them) would leave users wondering why an obviously-between clip
    // on a middle track was skipped.
    //
    // additive=true (Ctrl+Shift+click) unions the range into the
    // current selection; otherwise the range REPLACES it outright -
    // repeated Shift+clicks grow/shrink one range from the same
    // anchor instead of accreting clips from earlier, unrelated
    // Shift-clicks.
    function selectRange(clipId, additive) {
        var tRow = findClipRowById(clipId)
        if (tRow < 0) return
        var aRow = selectionAnchorClipId ? findClipRowById(selectionAnchorClipId) : -1
        if (aRow < 0) { selectOnly(clipId); return }

        var a = clipsModel.get(aRow)
        var b = clipsModel.get(tRow)
        var t0 = Math.min(a.startTime, b.startTime)
        var t1 = Math.max(a.startTime + a.durationSeconds, b.startTime + b.durationSeconds)
        var iA = getTrackIndexFromId(a.trackId)
        var iB = getTrackIndexFromId(b.trackId)
        if (iA < 0 || iB < 0) { selectOnly(clipId); return }
        var lo = Math.min(iA, iB), hi = Math.max(iA, iB)

        var EPS = 0.001
        var out = additive ? selectedClipIds.slice() : []
        for (var ti = lo; ti <= hi; ti++) {
            var tid = getTrackIdFromIndex(ti)
            if (!tid) continue
            var arr = clipIndexByTrack[tid] || []   // sorted ascending by startTime
            for (var k = 0; k < arr.length; k++) {
                var c = arr[k]
                if (c.startTime >= t1 - EPS) break   // sorted - nothing further qualifies
                if (c.startTime + c.durationSeconds <= t0 + EPS) continue
                if (out.indexOf(c.clipId) === -1) out.push(c.clipId)
            }
        }
        selectedClipIds = out
        selectedClipId = clipId
        clipSelectionTouched()
        // selectionAnchorClipId deliberately untouched - see comment above.
    }

    // === UNDO/REDO (snapshot-based) ===
    // Snapshot, not command/inverse: the model's invariants are cross-row
    // (transitionOriginalBId/StartB/AudioTrimA on A describe B;
    // relinkIncomingTransitionRef() rewrites third-party rows; ripple
    // shifts an unbounded set of rows), so a wrong inverse is the
    // dominant risk here - a snapshot has no inverse to get wrong. Cost
    // is one O(n) JSON.stringify per COMMITTED edit, which is noise next
    // to the setClips()/GES rebuild those same edits already pay for.
    readonly property int undoStackLimit: 50
    property var undoStack: []          // [{state, label, ts}] - oldest first
    property var redoStack: []
    // Array.push() does not notify bindings - main.qml's toolbar buttons
    // depend on these ints instead, assigned explicitly after every
    // stack mutation.
    property int undoCount: 0
    property int redoCount: 0

    property string undoPendingBefore: ""   // BEFORE-state of the open scope
    property int undoDepth: 0               // nesting (e.g. delete -> removeTransition)
    property bool undoRestoreInProgress: false

    // A restore clear()s clipsModel, which destroys the delegate whose
    // MouseArea holds the mouse grab mid-gesture - the exact hazard
    // windowAdditiveOnly exists for. Ctrl+Z is reachable with the mouse
    // button held down. No guard against in-flight setClips() is needed:
    // TimelineEngine already defers and supersedes clip lists itself.
    readonly property bool undoBusy: windowAdditiveOnly || undoRestoreInProgress
    readonly property bool canUndo: undoCount > 0 && !undoBusy
    readonly property bool canRedo: redoCount > 0 && !undoBusy

    function clipsArray() {
        var out = []
        for (var i = 0; i < clipsModel.count; i++) {
            var c = clipsModel.get(i)
            out.push({
                clipId: c.clipId, trackId: c.trackId,
                itemName: c.itemName, itemPath: c.itemPath,
                startTime: c.startTime, durationSeconds: c.durationSeconds,
                sourceOffset: c.sourceOffset || 0,
                hasVideo: c.hasVideo || false, hasAudio: c.hasAudio || false,
                hasTransition: c.hasTransition || false,
                transitionDuration: c.transitionDuration || 0,
                transitionType: c.transitionType || "",
                transitionCutOffset: c.transitionCutOffset !== undefined ? c.transitionCutOffset : (c.transitionDuration || 0) / 2.0,
                transitionOriginalBId: c.transitionOriginalBId || "",
                transitionOriginalStartB: c.transitionOriginalStartB || 0,
                transitionAudioTrimA: c.transitionAudioTrimA || 0,
                linkGroupId: c.linkGroupId || "", linkedClipId: c.linkedClipId || "",
                isLinked: c.isLinked || false,
                sourceItemId: c.sourceItemId || "", waveformPath: c.waveformPath || "",
                effects: c.effects || "",
                clipKind: c.clipKind || "", titleParams: c.titleParams || ""
            })
        }
        return out
    }

    // Per-clip effects stack accessors. Stored as a JSON array string on
    // the clip row (not a nested ListModel role - QML ListModel can't hold
    // arrays of objects as a role value). Each entry: {id, type, enabled,
    // params: {...}}.
    //
    // effectsRevision exists purely so QML bindings that depend on effects
    // content can force a re-evaluation. clipEffects()/setClipEffects()
    // read/write through ListModel.get()/setProperty(), which does NOT
    // participate in QML's automatic property-dependency tracking the way
    // a delegate's `model.effects` role binding would - a binding like
    // `model: timelinePanel.currentEffects()` would silently never
    // re-evaluate after the first call otherwise. Bump this, and have the
    // dependent binding read it (even via an unused comma-expression), to
    // force a refresh.
    property int effectsRevision: 0

    function clipEffects(clipId) {
        var row = findClipRowById(clipId)
        if (row < 0) return []
        var raw = clipsModel.get(row).effects || ""
        if (raw === "" || raw === "[]") return []
        try { return JSON.parse(raw) } catch (e) { console.error("clipEffects: corrupt effects JSON for", clipId, e); return [] }
    }

    // Used by EffectKeyframeEditor.qml to map its own time axis (clip
    // MEDIA time, the same base ClipEffects.cpp's animated-param
    // keyframes use) to/from the clip's position on the timeline, and
    // to know the clip's media window for its curve plot. Returns null
    // if the clip no longer exists (e.g. deleted while its inspector
    // row was still open).
    function clipTiming(clipId) {
        var row = findClipRowById(clipId)
        if (row < 0) return null
        var c = clipsModel.get(row)
        return { startTime: c.startTime, durationSeconds: c.durationSeconds, sourceOffset: c.sourceOffset || 0 }
    }

    // pushToEngine=true (default) also calls updateTimelineEngine() so GES
    // picks up the change immediately - callers doing a batch of changes
    // (e.g. drag-reorder of several entries) can pass false and update once.
    function setClipEffects(clipId, effectsArray, pushToEngine) {
        var row = findClipRowById(clipId)
        if (row < 0) return
        clipsModel.setProperty(row, "effects", JSON.stringify(effectsArray || []))
        effectsRevision++
        if (pushToEngine !== false && updateTimelineEngine) updateTimelineEngine()
    }

    // ---- Clip transform rescale on a project-size change ----------------
    // A "transform" effect holds fposx/fposy/fwidth/fheight in ABSOLUTE
    // canvas pixels (static numbers, or {"kf":[{t,v},...]} animations).
    // This is the ONE place that knows how those values follow a canvas
    // change from oldW x oldH to newW x newH ("cover, centred, no
    // distortion"):
    //   s = max(newW/oldW, newH/oldH)
    //   w' = w*s, h' = h*s,
    //   x' = x*s + (newW - oldW*s)/2,  y' = y*s + (newH - oldH*s)/2
    // Other effect types and non-pixel params (alpha, rotation, ...) are
    // never touched. A transform whose four static values are all 0 is the
    // untouched "Position and Zoom" placeholder and is skipped.
    function transformIsPlaceholder(params) {
        var names = ["fposx", "fposy", "fwidth", "fheight"]
        for (var i = 0; i < names.length; i++) {
            var v = params[names[i]]
            if (v === undefined) continue
            if (typeof v === "object") return false   // animated
            if (Number(v) !== 0) return false
        }
        return true
    }

    // Number of clips that carry at least one real (non-placeholder) transform.
    function countTransformClips() {
        var n = 0
        for (var i = 0; i < clipsModel.count; i++) {
            var id = clipsModel.get(i).clipId
            var fx = clipEffects(id)
            for (var j = 0; j < fx.length; j++) {
                if (fx[j].type === "transform" && fx[j].params && !transformIsPlaceholder(fx[j].params)) { n++; break }
            }
        }
        return n
    }

    function rescaleTransformValue(name, v, oldW, oldH, newW, newH) {
        var s = Math.max(newW / oldW, newH / oldH)
        if (name === "fposx") return v * s + (newW - oldW * s) / 2
        if (name === "fposy") return v * s + (newH - oldH * s) / 2
        return v * s // fwidth / fheight
    }

    // One undo step. Does NOT push to the engine: the caller follows with a
    // single updateTimelineEngine() (together with the canvas change that
    // triggered this) so there is exactly one rebuild. Returns the number of
    // clips changed. (Undo restores the transforms only - the project
    // profile itself is not part of the undo snapshot.)
    function rescaleClipTransforms(oldW, oldH, newW, newH) {
        if (!(oldW > 0 && oldH > 0 && newW > 0 && newH > 0)) return 0
        var names = ["fposx", "fposy", "fwidth", "fheight"]
        var changed = 0
        beginUndoableEdit()
        for (var i = 0; i < clipsModel.count; i++) {
            var id = clipsModel.get(i).clipId
            var fx = clipEffects(id)
            var dirty = false
            for (var j = 0; j < fx.length; j++) {
                if (fx[j].type !== "transform" || !fx[j].params) continue
                var params = fx[j].params
                if (transformIsPlaceholder(params)) continue
                for (var k = 0; k < names.length; k++) {
                    var nm = names[k]
                    var pv = params[nm]
                    if (pv === undefined || pv === null) continue
                    if (typeof pv === "object") {
                        if (!pv.kf) continue
                        for (var q = 0; q < pv.kf.length; q++)
                            pv.kf[q].v = rescaleTransformValue(nm, Number(pv.kf[q].v), oldW, oldH, newW, newH)
                    } else {
                        params[nm] = rescaleTransformValue(nm, Number(pv), oldW, oldH, newW, newH)
                    }
                    dirty = true
                }
            }
            if (dirty) { setClipEffects(id, fx, false); changed++ }
        }
        commitUndoableEdit("Rescale clip transforms")
        console.log("rescaleClipTransforms:", oldW + "x" + oldH, "->", newW + "x" + newH, "-", changed, "clips")
        return changed
    }

    // ---- Clip fitting (project default + inspector "Fit to frame") ------
    // Fits a source of w x h (square pixels) into the W x H canvas and
    // returns the absolute-pixel transform rect {fposx,fposy,fwidth,fheight}:
    //   scaling: fill s=max(W/w,H/h) | fit s=min(W/w,H/h) | width s=W/w |
    //            height s=H/h | none s=1 | stretch (fwidth=W, fheight=H)
    //   fwidth=w*s, fheight=h*s; anchor H: left 0 | center (W-fwidth)/2 |
    //   right W-fwidth; anchor V likewise. Values rounded to 0.01 px.
    // The ONE place that knows this maths (drop default + inspector Apply).
    function computeFitRect(w, h, W, H, scaling, ah, av) {
        var fw, fh
        if (scaling === "stretch") { fw = W; fh = H }
        else {
            var s
            if (scaling === "fill") s = Math.max(W / w, H / h)
            else if (scaling === "width") s = W / w
            else if (scaling === "height") s = H / h
            else if (scaling === "none") s = 1
            else s = Math.min(W / w, H / h)   // "fit" and anything unknown
            fw = w * s; fh = h * s
        }
        var x = ah === "left" ? 0 : (ah === "right" ? W - fw : (W - fw) / 2)
        var y = av === "top" ? 0 : (av === "bottom" ? H - fh : (H - fh) / 2)
        function r2(v) { return Math.round(v * 100) / 100 }
        return { fposx: r2(x), fposy: r2(y), fwidth: r2(fw), fheight: r2(fh) }
    }

    // Project default as stored: missing keys mean "fit"/centre (projects
    // that pre-date the feature keep their old behaviour; new projects and
    // Kdenlive imports write "fill" explicitly).
    function fitDefaults() {
        return { scaling: String(Backend.getSetting("project/fitScaling", "fit")),
                 ah: String(Backend.getSetting("project/fitAnchorH", "center")),
                 av: String(Backend.getSetting("project/fitAnchorV", "center")) }
    }

    // {w,h} of the project canvas, or null while it is "auto"/unknown.
    function projectCanvasSize() {
        var W = parseInt(Backend.getSetting("project/width", "auto"))
        var H = parseInt(Backend.getSetting("project/height", "auto"))
        return (W > 0 && H > 0) ? { w: W, h: H } : null
    }

    // {w,h} of a bin item from its metadata ("3840x2160"), or null if the
    // metadata is not there (yet).
    function binItemSize(sourceItemId) {
        if (!sourceItemId) return null
        var meta = Backend.projectBinModel.getItemMetadata(sourceItemId)
        var m = meta && meta.resolution ? /^\s*(\d+)\s*x\s*(\d+)/.exec(String(meta.resolution)) : null
        if (!m) return null
        var w = parseInt(m[1]), h = parseInt(m[2])
        return (w > 0 && h > 0) ? { w: w, h: h } : null
    }

    // {w,h} of the clip's source media (bin metadata), or null if unknown.
    function clipSourceSize(clipId) {
        var row = findClipRowById(clipId)
        if (row < 0) return null
        return binItemSize(clipsModel.get(row).sourceItemId || "")
    }

    // The transform effect entry a NEWLY placed clip gets from the project
    // default, or null when none is needed: canvas/source size unknown
    // (never guess), or the result equals what GES does on its own
    // (aspect-preserving fit, centred) - e.g. source == canvas.
    function defaultFitEffectFor(sourceItemId) {
        var cv = projectCanvasSize(), src = binItemSize(sourceItemId)
        if (!cv || !src) return null
        var d = fitDefaults()
        var r = computeFitRect(src.w, src.h, cv.w, cv.h, d.scaling, d.ah, d.av)
        var g = computeFitRect(src.w, src.h, cv.w, cv.h, "fit", "center", "center")
        if (Math.abs(r.fposx - g.fposx) < 0.5 && Math.abs(r.fposy - g.fposy) < 0.5
                && Math.abs(r.fwidth - g.fwidth) < 0.5 && Math.abs(r.fheight - g.fheight) < 0.5)
            return null
        return { id: "fx_" + Date.now() + "_" + Math.floor(Math.random() * 10000),
                 type: "transform", enabled: true, params: r }
    }

    // ---------------------------------------------------------------
    // TITLE (text) CLIPS
    //
    // Same string-blob-on-the-row convention as `effects` above, with
    // its own revision counter for the same reason (ListModel.get()
    // does not participate in QML dependency tracking).
    // ---------------------------------------------------------------
    property int titleParamsRevision: 0

    function isTitleClip(clipId) {
        var row = findClipRowById(clipId)
        if (row < 0) return false
        return (clipsModel.get(row).clipKind || "") === "title"
    }

    function clipTitleParams(clipId) {
        var row = findClipRowById(clipId)
        if (row < 0) return null
        var raw = clipsModel.get(row).titleParams || ""
        if (raw === "") return null
        try { return JSON.parse(raw) }
        catch (e) { console.error("clipTitleParams: corrupt JSON for", clipId, e); return null }
    }

    function setClipTitleParams(clipId, params, pushToEngine) {
        var row = findClipRowById(clipId)
        if (row < 0) return
        clipsModel.setProperty(row, "titleParams", JSON.stringify(params || {}))
        // Keep the timeline label in sync with the text - display only.
        if (params && params.text !== undefined) {
            var label = String(params.text).replace(/\n/g, " ").substring(0, 24)
            clipsModel.setProperty(row, "itemName", label === "" ? "Title" : label)
        }
        titleParamsRevision++
        if (pushToEngine !== false && updateTimelineEngine) updateTimelineEngine()
    }

    // Default duration of a newly added title, in seconds.
    readonly property real defaultTitleDuration: 5.0

    // Picks the video track a new title should land on. Titles must NOT
    // overlap another clip on the SAME layer: GES's "auto-transition"
    // (enabled on this app's timeline) silently inserts a crossfade
    // GESTransitionClip for any same-layer overlap - VERIFIED LIVE in a
    // standalone GES probe - which both fades the title in/out and
    // confuses this panel's own transition bookkeeping
    // (clipTransitionZone() and friends). So the title needs a video
    // track of its own for the time range it covers.
    //
    // It must ALSO end up ABOVE the video it is captioning, and in this
    // app higher track number == higher GES layer priority == composited
    // on top (TimelineEngine::ensureLayers() sorts V* descending and
    // assigns priority 0 to the highest number; tracksModel stores the
    // same order, topmost-first). So the scan goes top-down and STOPS at
    // the first occupied track: a free track found BELOW an occupied one
    // would put the title underneath that clip, where it is invisible -
    // VERIFIED LIVE (test project: video on V2, empty V1 -> the title
    // landed on V1 and nothing showed in the Project Monitor).
    // Returns "" when there is no free track above everything at that
    // range; the caller then tells the user to add a video track.
    // Validates a caller-chosen track (not an auto-picked one - placing a
    // title is a user decision about WHICH layer it should overlay, and
    // guessing "the topmost track" is wrong whenever that track is the
    // one already showing video, since a lower track would render the
    // title UNDER it, not over it). Returns true only if trackId is an
    // unlocked video track with nothing already occupying [start, start+duration).
    function isTrackFreeForTitle(trackId, start, duration) {
        var end = start + duration
        var track = null
        for (var i = 0; i < tracksModel.count; i++) {
            var t = tracksModel.get(i)
            if (t.trackId === trackId) { track = t; break }
        }
        if (!track || track.type !== "video" || track.locked) return false
        for (var j = 0; j < clipsModel.count; j++) {
            var c = clipsModel.get(j)
            if (c.trackId !== trackId) continue
            if (c.startTime < end && (c.startTime + c.durationSeconds) > start) return false
        }
        return true
    }

    // Appends a title clip at `startSeconds` (defaults to the playhead)
    // on `trackId` - the user's own currently-selected track (see the
    // toolbar's "+ Title" button, which resolves this from
    // currentTrackIndex before calling in). Returns the new clipId, or
    // "" if trackId isn't a free, unlocked video track at that time.
    function addTitleClip(trackId, startSeconds, text) {
        var start = (startSeconds === undefined || startSeconds === null)
                    ? (timelineEngine ? timelineEngine.position / 1000.0 : 0)
                    : startSeconds
        if (start < 0) start = 0
        var dur = defaultTitleDuration
        if (!trackId || !isTrackFreeForTitle(trackId, start, dur)) {
            console.warn("addTitleClip: track", trackId, "is not a free video track at", start)
            return ""
        }
        var body = (text === undefined || text === null || text === "") ? "Title" : text
        var clipId = "title_" + Date.now() + "_" + Math.floor(Math.random() * 10000)

        beginUndoableEdit()
        clipsModel.append({
            clipId: clipId,
            trackId: trackId,
            itemName: body.substring(0, 24),
            itemPath: "",
            startTime: start,
            durationSeconds: dur,
            hasVideo: true,
            hasAudio: false,
            sourceOffset: 0,
            hasTransition: false,
            transitionDuration: 0,
            transitionType: "",
            transitionCutOffset: 0,
            transitionOriginalBId: "",
            transitionOriginalStartB: 0,
            transitionAudioTrimA: 0,
            linkGroupId: "", linkedClipId: "", isLinked: false,
            sourceItemId: "", waveformPath: "",
            effects: "",
            clipKind: "title",
            titleParams: Backend.defaultTitleParams(body),
            mediaMissing: false
        })
        selectOnly(clipId)
        if (updateTimelineEngine) updateTimelineEngine()
        Qt.callLater(checkAllClipNeighbors)
        Backend.logOperation("title_add", { clipId: clipId, trackId: trackId, startTime: start })
        commitUndoableEdit("Add title")
        return clipId
    }

    // Builds one fresh effect-stack entry from an EffectBrowserPanel
    // preset. A fresh id is generated per CALL (not reused across
    // clips in applyPresetToClips() below) - ids are addressed per-
    // clip (EffectInspectorPanel/EffectKeyframeEditor look an effect
    // up by id WITHIN one clip's own stack), but giving two different
    // clips' stacks an effect with the identical id is a pointless
    // latent trap to avoid for free.
    function makeEffectEntry(preset) {
        var params = {}
        for (var k in preset.params) params[k] = preset.params[k]
        return { id: "fx_" + Date.now() + "_" + Math.floor(Math.random() * 10000),
                 type: preset.type, enabled: true, params: params }
    }

    // "video" or "audio" (same vocabulary as getTrackType()) - "" if
    // the clip no longer exists. Used to keep an effect preset off a
    // track type it can't actually run on (ClipEffects.cpp's video
    // top-effects/GstFramePositioner properties simply don't exist on
    // an audio track's GESAudioUriSource, and vice versa for "volume" -
    // this isn't a UI nicety, a mismatched apply would fail inside GES).
    function clipMediaType(clipId) {
        var row = findClipRowById(clipId)
        if (row < 0) return ""
        return getTrackType(clipsModel.get(row).trackId)
    }

    // Whether at least one of clipIds matches preset.mediaType - used
    // to enable/disable the "+" button without needing to actually
    // attempt (and filter) an apply first.
    function hasCompatibleTarget(clipIds, mediaType) {
        if (!clipIds) return false
        for (var i = 0; i < clipIds.length; i++) {
            if (clipMediaType(clipIds[i]) === mediaType) return true
        }
        return false
    }

    // Drop target is AUTHORITATIVE: the user physically pointed at a
    // clip, so that always wins over an unrelated earlier selection.
    // Dropping onto a clip that's part of the CURRENT selection honours
    // the whole selection (the user's actual request: drag onto one of
    // several selected clips -> applies to all of them); dropping onto
    // anything else applies to just that one clip and retargets the
    // selection to it, so the selection border always matches what
    // just received the effect - never silently diverging from it.
    function applyPresetToClipsFromDrop(preset, dropClipId) {
        // The DropArea itself already refuses to show a "valid drop"
        // highlight for a mismatched clip (see TimelineClip.qml) - this
        // is a second, authoritative check at the actual commit point,
        // not just a UI hint.
        if (preset.mediaType && clipMediaType(dropClipId) !== preset.mediaType) return
        var targets
        if (isClipInSelection(dropClipId)) {
            targets = selectedClipIds.slice()
        } else {
            targets = [dropClipId]
            selectOnly(dropClipId)
        }
        applyPresetToClips(preset, targets)
    }

    // Single entry point for every way an effect preset can be applied
    // to one or more clips (row click, the per-row "+" button, and a
    // drag-and-drop onto a clip) - so those three gestures can never
    // silently diverge in what "add this effect" actually does.
    // clipIds may be a single-element array (the common case) or
    // several, committed as ONE undo step either way.
    function applyPresetToClips(preset, clipIds) {
        if (!clipIds || clipIds.length === 0) return
        // Silently drop any clip whose track type doesn't match the
        // preset (e.g. dragging "Position and Zoom" - video-only - onto
        // an audio clip, or one that's merely part of a mixed-type
        // multi-selection) - see clipMediaType()'s comment for why this
        // is a hard requirement, not a style choice.
        var targets = preset.mediaType
            ? clipIds.filter(function(id) { return clipMediaType(id) === preset.mediaType })
            : clipIds.slice()
        if (targets.length === 0) return

        beginUndoableEdit()
        for (var i = 0; i < targets.length; i++) {
            var effects = clipEffects(targets[i])
            effects.push(makeEffectEntry(preset))
            // Push to GES only once, after the last clip in the batch -
            // same pushToEngine=false idiom setClipEffects() already
            // supports for exactly this reason.
            setClipEffects(targets[i], effects, i === targets.length - 1)
        }
        commitUndoableEdit(targets.length > 1
            ? "Add " + preset.name + " to " + targets.length + " clips"
            : "Add " + preset.name)
    }

    function tracksArray() {
        var out = []
        for (var i = 0; i < tracksModel.count; i++) {
            var t = tracksModel.get(i)
            out.push({ trackId: t.trackId, type: t.type, name: t.name || "",
                       disabled: t.disabled || false, hidden: t.hidden || false,
                       muted: t.muted || false, volume: (t.volume !== undefined ? t.volume : 1.0),
                       solo: (t.solo === true), pan: (t.pan !== undefined ? t.pan : 0.0), locked: t.locked || false })
        }
        return out
    }

    function serializeTimelineState() {
        return JSON.stringify({ tracks: tracksArray(), clips: clipsArray() })
    }

    // --- Per-track hide (video) / mute (audio) ------------------------
    //
    // Two deliberately SEPARATE flags on two separate rows. A linked A/V
    // pair is a video-only clip row on V<n> plus an audio-only clip row
    // on A<n>, and each row lives on its own GES layer, so hiding V1
    // leaves A1 playing and muting A1 leaves V1 on screen. Nothing here
    // consults getPairTrackId()/getCorrespondingAudioTrack() on purpose -
    // that pairing is for drag/drop routing, not for playback state.
    //
    // Both go through the engine's live layer-activation path (no
    // setClips() rebuild), so they can be toggled during playback.
    function setTrackHidden(trackIndex, hidden) {
        if (trackIndex < 0 || trackIndex >= tracksModel.count) return
        var t = tracksModel.get(trackIndex)
        if (t.type !== "video") return
        if ((t.hidden === true) === hidden) return
        beginUndoableEdit()
        tracksModel.setProperty(trackIndex, "hidden", hidden)
        if (timelineEngine) timelineEngine.setTrackVideoHidden(t.trackId, hidden)
        commitUndoableEdit((hidden ? "Hide track " : "Show track ") + t.trackId)
    }

    function anyAudioSolo() {
        for (var i = 0; i < tracksModel.count; i++) {
            var t = tracksModel.get(i)
            if (t.type === "audio" && t.solo === true) return true
        }
        return false
    }
    // What the engine and the render must treat as muted.
    function effectiveAudioMuted(trackIndex) {
        // Delegates can re-evaluate this while the model is being cleared
        // (project load / undo), when the old index no longer exists.
        if (trackIndex === undefined || trackIndex < 0 || trackIndex >= tracksModel.count) return false
        var t = tracksModel.get(trackIndex)
        if (!t || t.type !== "audio") return false
        if (t.muted === true) return true
        return anyAudioSolo() && t.solo !== true
    }
    // One list for TimelineEngine.setTrackStates(): hide/mute(effective)/volume.
    function trackStatesForEngine() {
        var states = []
        for (var i = 0; i < tracksModel.count; i++) {
            var t = tracksModel.get(i)
            states.push({
                trackId: t.trackId,
                hidden: t.type === "video" && t.hidden === true,
                muted: effectiveAudioMuted(i),
                volume: (t.type === "audio" && t.volume !== undefined) ? t.volume : 1.0,
                pan: (t.type === "audio" && t.pan !== undefined) ? t.pan : 0.0
            })
        }
        return states
    }
    function setTrackSolo(trackIndex, solo) {
        if (trackIndex < 0 || trackIndex >= tracksModel.count) return
        var t = tracksModel.get(trackIndex)
        if (t.type !== "audio") return
        if ((t.solo === true) === solo) return
        beginUndoableEdit()
        tracksModel.setProperty(trackIndex, "solo", solo)
        if (timelineEngine) timelineEngine.setTrackStates(trackStatesForEngine())
        commitUndoableEdit((solo ? "Solo track " : "Unsolo track ") + t.trackId)
    }

    function setTrackMuted(trackIndex, muted) {
        if (trackIndex < 0 || trackIndex >= tracksModel.count) return
        var t = tracksModel.get(trackIndex)
        if (t.type !== "audio") return
        if ((t.muted === true) === muted) return
        beginUndoableEdit()
        tracksModel.setProperty(trackIndex, "muted", muted)
        if (timelineEngine) timelineEngine.setTrackStates(trackStatesForEngine())
        commitUndoableEdit((muted ? "Mute track " : "Unmute track ") + t.trackId)
    }

    function setMasterVolume(volume) {
        masterVolume = Math.max(0, Math.min(4, volume))
        if (timelineEngine) timelineEngine.setMasterVolume(masterVolume)
    }

    function trackVolumeOf(trackId) {
        var i = trackIndexById[trackId]
        if (i === undefined || i < 0 || i >= tracksModel.count) return 1.0
        var v = tracksModel.get(i).volume
        return (v === undefined) ? 1.0 : v
    }

    function trackPanOf(trackId) {
        var i = trackIndexById[trackId]
        if (i === undefined || i < 0 || i >= tracksModel.count) return 0.0
        var p = tracksModel.get(i).pan
        return (p === undefined) ? 0.0 : p
    }

    // live=true: while the pan slider is dragged - engine only, no undo
    // entry. live=false: final value - stored in the model, undoable.
    function setTrackPan(trackIndex, pan, live) {
        if (trackIndex < 0 || trackIndex >= tracksModel.count) return
        var t = tracksModel.get(trackIndex)
        if (t.type !== "audio") return
        pan = Math.max(-1, Math.min(1, pan))
        if (live) {
            if (timelineEngine) timelineEngine.setTrackPan(t.trackId, pan)
            return
        }
        if (Math.abs((t.pan === undefined ? 0.0 : t.pan) - pan) < 0.0005) {
            if (timelineEngine) timelineEngine.setTrackPan(t.trackId, pan)
            return
        }
        beginUndoableEdit()
        tracksModel.setProperty(trackIndex, "pan", pan)
        if (timelineEngine) timelineEngine.setTrackPan(t.trackId, pan)
        commitUndoableEdit("Pan of track " + t.trackId)
    }

    // live=true: called continuously while the fader is dragged - engine only,
    // no undo entry. live=false: final value - stored in the model, undoable.
    function setTrackVolume(trackIndex, volume, live) {
        if (trackIndex < 0 || trackIndex >= tracksModel.count) return
        var t = tracksModel.get(trackIndex)
        if (t.type !== "audio") return
        volume = Math.max(0, Math.min(4, volume))
        if (live) {
            if (timelineEngine) timelineEngine.setTrackVolume(t.trackId, volume)
            return
        }
        if (Math.abs((t.volume === undefined ? 1.0 : t.volume) - volume) < 0.0005) {
            if (timelineEngine) timelineEngine.setTrackVolume(t.trackId, volume)
            return
        }
        beginUndoableEdit()
        tracksModel.setProperty(trackIndex, "volume", volume)
        if (timelineEngine) timelineEngine.setTrackVolume(t.trackId, volume)
        commitUndoableEdit("Volume of track " + t.trackId)
    }

    // True when this track's clips must be left out of a RENDER. Hide/
    // mute are NOT preview-only here: they behave as in Kdenlive/Premiere
    // and exclude the track from the exported file too (see
    // main.qml's getTimelineClipsForRender()).
    function isTrackSilenced(trackId) {
        var i = trackIndexById[trackId]
        if (i === undefined || i < 0 || i >= tracksModel.count) return false
        var t = tracksModel.get(i)
        return t.type === "video" ? (t.hidden === true) : effectiveAudioMuted(i)
    }

    function beginUndoableEdit() {
        if (undoDepth === 0) undoPendingBefore = serializeTimelineState()
        undoDepth++
        return undoDepth === 1
    }

    // Entry point for MOUSE GESTURES only (clip drag, trim handles). A
    // gesture start can never be legitimately nested inside another edit,
    // so a non-zero depth here is always leaked state from a gesture
    // whose release/cancel handler never ran (e.g. a modal Window
    // stealing the grab). Self-heal rather than silently swallowing every
    // later edit for the rest of the session.
    function beginUndoableGesture() {
        if (undoDepth !== 0) {
            console.warn("undo: stale edit scope (depth", undoDepth, ") - resetting")
            undoDepth = 0
            undoPendingBefore = ""
        }
        return beginUndoableEdit()
    }

    function commitUndoableEdit(label) {
        if (undoDepth <= 0) { console.warn("undo: commit without begin:", label); return }
        undoDepth--
        if (undoDepth > 0) return              // inner scope (delete -> removeTransition)
        if (undoPendingBefore === "") return
        undoStack.push({ state: undoPendingBefore, label: label || "Edit", ts: Date.now() })
        if (undoStack.length > undoStackLimit) undoStack.shift()
        undoPendingBefore = ""
        // Any new edit invalidates redo - centralized here so none of the
        // instrumented call sites has to remember it.
        redoStack = []
        undoCount = undoStack.length
        redoCount = 0
    }

    function abortUndoableEdit() {
        if (undoDepth <= 0) return
        undoDepth--
        if (undoDepth === 0) undoPendingBefore = ""
    }

    function undo() {
        if (!canUndo) return
        var entry = undoStack[undoStack.length - 1]
        var afterState = serializeTimelineState()
        if (!restoreTimelineState(entry.state)) return   // leave the stack intact
        undoStack.pop()
        redoStack.push({ state: afterState, label: entry.label, ts: Date.now() })
        if (redoStack.length > undoStackLimit) redoStack.shift()
        undoCount = undoStack.length
        redoCount = redoStack.length
        Backend.logOperation("undo", { label: entry.label, undoLeft: undoCount, redoLeft: redoCount })
    }

    function redo() {
        if (!canRedo) return
        var entry = redoStack[redoStack.length - 1]
        var afterState = serializeTimelineState()
        if (!restoreTimelineState(entry.state)) return
        redoStack.pop()
        undoStack.push({ state: afterState, label: entry.label, ts: Date.now() })
        if (undoStack.length > undoStackLimit) undoStack.shift()
        undoCount = undoStack.length
        redoCount = redoStack.length
        Backend.logOperation("redo", { label: entry.label, undoLeft: undoCount, redoLeft: redoCount })
    }

    // Called from EditingWorkspace.resetTimeline() - covers both New
    // Project and project load (loadProjectJSON -> resetTimeline).
    // Undoing across a project switch would restore the previous
    // project's clips into the new one.
    function clearUndoHistory() {
        undoStack = []
        redoStack = []
        undoCount = 0
        redoCount = 0
        undoPendingBefore = ""
        undoDepth = 0
    }

    // Save As only. Each clip row carries an ABSOLUTE waveformPath
    // (CacheManager::getWaveformPath() = cacheDir + "/" + relPath), and
    // EditingWorkspace.getProjectJSON() serializes it verbatim - so after
    // the project's folder changes, those paths still point into the OLD
    // project's .cache. Rewrites the prefix in place.
    //
    // Also rewrites the undo/redo SNAPSHOT strings rather than clearing the
    // stacks: clipsArray() includes waveformPath, so an undo taken after a
    // Save As would otherwise reintroduce an old-cache path. A prefix
    // substitution preserves stack depth, order and labels exactly - this
    // is the same document, only its storage moved.
    function rebaseWaveformPaths(oldCacheDir, newCacheDir) {
        if (!oldCacheDir || !newCacheDir || oldCacheDir === newCacheDir) return

        var n = 0
        for (var i = 0; i < clipsModel.count; i++) {
            var wf = clipsModel.get(i).waveformPath || ""
            if (wf.indexOf(oldCacheDir) === 0) {
                clipsModel.setProperty(i, "waveformPath",
                                       newCacheDir + wf.substring(oldCacheDir.length))
                n++
            }
        }

        function rebaseStack(stack) {
            for (var k = 0; k < stack.length; k++) {
                stack[k].state = stack[k].state.split(oldCacheDir).join(newCacheDir)
            }
        }
        rebaseStack(undoStack)
        rebaseStack(redoStack)
        if (undoPendingBefore !== "") {
            undoPendingBefore = undoPendingBefore.split(oldCacheDir).join(newCacheDir)
        }

        console.log("rebaseWaveformPaths:", n, "clip(s) rebased to", newCacheDir)
    }

    // Missing-media relink: `oldToNew` is a JS Map of plain local old path ->
    // plain local new path. Re-points every clip row (itemPath of any
    // spelling - plain or file:// URL - that normalises to a key) and
    // rewrites the undo/redo SNAPSHOT strings the same way
    // rebaseWaveformPaths() does, so an undo/redo never brings an old path
    // back. This is not an undo step itself. Returns the number of clips
    // changed.
    function relinkSourcePaths(oldToNew) {
        if (!oldToNew || oldToNew.size === 0) return 0
        var n = 0
        // Every spelling of an old path that may appear (rows or snapshots) ->
        // the new plain path.
        var spellings = new Map()
        oldToNew.forEach(function(newPath, oldPath) {
            spellings.set(oldPath, newPath)
            spellings.set("file://" + oldPath, newPath)
            spellings.set(encodeURI("file://" + oldPath), newPath)
        })
        for (var i = 0; i < clipsModel.count; i++) {
            var raw = clipsModel.get(i).itemPath || ""
            if (raw === "") continue
            var plain = Backend.mediaAvailability.localPath(raw)
            if (oldToNew.has(plain)) {
                spellings.set(raw, oldToNew.get(plain))
                clipsModel.setProperty(i, "itemPath", oldToNew.get(plain))
                n++
            }
        }
        // One regex over the exact quoted JSON tokens (quotes included, so
        // /a/x.mp4 never rewrites inside "/a/x.mp4.bak").
        var tokens = []
        var tokenMap = new Map()
        spellings.forEach(function(newPath, oldSpelling) {
            var tok = JSON.stringify(oldSpelling)
            tokens.push(tok.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
            tokenMap.set(tok, JSON.stringify(newPath))
        })
        var re = new RegExp(tokens.join("|"), "g")
        function rewrite(str) {
            return str.replace(re, function(m) { return tokenMap.get(m) })
        }
        for (var k = 0; k < undoStack.length; k++) undoStack[k].state = rewrite(undoStack[k].state)
        for (var r = 0; r < redoStack.length; r++) redoStack[r].state = rewrite(redoStack[r].state)
        if (undoPendingBefore !== "") undoPendingBefore = rewrite(undoPendingBefore)
        console.log("relinkSourcePaths:", n, "clip(s) relinked")
        return n
    }

    // Restore for undo/redo only - deliberately NOT loadProjectJSON()'s
    // path (that one also stops playback/seeks to 0, drives a loading
    // dialog, and restores view state like zoom - all wrong for undo).
    // Reuses only the {tracks, clips} serialization SHAPE.
    function restoreTimelineState(snapshotString) {
        var data
        try { data = JSON.parse(snapshotString) }
        catch (e) { console.error("undo: corrupt snapshot -", e); return false }
        if (!data || !data.clips || !data.tracks) { console.error("undo: snapshot missing arrays"); return false }

        undoRestoreInProgress = true
        try {
            // TRACKS - only touch the model when it actually differs, so
            // the overwhelming majority of edits (clip-only) keep every
            // track-header delegate alive (rename TextInput binding,
            // tracksContentList.currentIndex, etc).
            if (JSON.stringify(tracksArray()) !== JSON.stringify(data.tracks)) {
                tracksModel.clear()
                for (var t = 0; t < data.tracks.length; t++) {
                    var tr = data.tracks[t]
                    tracksModel.append({
                        trackId: tr.trackId, type: tr.type, name: tr.name || "",
                        disabled: tr.disabled || false, hidden: tr.hidden || false,
                        muted: tr.muted || false, volume: (tr.volume !== undefined ? tr.volume : 1.0),
                        solo: (tr.solo === true), pan: (tr.pan !== undefined ? tr.pan : 0.0), locked: tr.locked || false
                    })
                }
                // tracksModel.onCountChanged -> rebuildTrackIndex() does
                // NOT fire when the row count happens to be unchanged
                // (e.g. undoing a delete-track+add-track pair) - call it
                // unconditionally here.
                rebuildTrackIndex()
            }

            // CLIPS - always wholesale. clear() destroys every
            // TimelineClip/TimelineTransition delegate, the appends
            // create fresh rows; DelegateModel's "win" group then needs
            // the refilter below to give them delegates again.
            clipsModel.clear()
            for (var i = 0; i < data.clips.length; i++) {
                var c = data.clips[i]
                clipsModel.append({
                    clipId: c.clipId, trackId: c.trackId,
                    itemName: c.itemName, itemPath: c.itemPath,
                    startTime: c.startTime, durationSeconds: c.durationSeconds,
                    sourceOffset: c.sourceOffset || 0,
                    hasVideo: c.hasVideo || false, hasAudio: c.hasAudio || false,
                    hasTransition: c.hasTransition || false,
                    transitionDuration: c.transitionDuration || 0,
                    transitionType: c.transitionType || "",
                    transitionCutOffset: c.transitionCutOffset !== undefined ? c.transitionCutOffset : (c.transitionDuration || 0) / 2.0,
                    transitionOriginalBId: c.transitionOriginalBId || "",
                    transitionOriginalStartB: c.transitionOriginalStartB || 0,
                    transitionAudioTrimA: c.transitionAudioTrimA || 0,
                    linkGroupId: c.linkGroupId || "", linkedClipId: c.linkedClipId || "",
                    isLinked: c.isLinked || false,
                    sourceItemId: c.sourceItemId || "", waveformPath: c.waveformPath || "",
                    effects: c.effects || "",
                    clipKind: c.clipKind || "", titleParams: c.titleParams || ""
                })
            }

            // SELECTION is view state, NOT snapshotted - but it can now
            // point at a clipId that no longer exists (undoing a split
            // reinstates the pre-split id and drops both fragment ids).
            if (selectedClipId !== "" && findClipRowById(selectedClipId) < 0) selectedClipId = ""
            var prunedSelection = []
            for (var psi = 0; psi < selectedClipIds.length; psi++) {
                if (findClipRowById(selectedClipIds[psi]) >= 0) prunedSelection.push(selectedClipIds[psi])
            }
            selectedClipIds = prunedSelection
            if (selectionAnchorClipId !== "" && findClipRowById(selectionAnchorClipId) < 0) selectionAnchorClipId = ""

            // Index + window refilter - same sequence loadProjectJSON()
            // relies on: rebuild the per-track index, let the window
            // refilter create delegates for the new rows, then have each
            // delegate re-derive its overlap/trim-handle state.
            checkAllClipNeighbors()

            // Push to GES. Safe to call with a commit/async op in flight -
            // setClips() snapshots and replays only the newest list.
            if (updateTimelineEngine) updateTimelineEngine()
        } finally {
            undoRestoreInProgress = false
        }
        return true
    }

    function deleteSelectedClip() {
        if (selectedClipId === "") return
        Backend.logOperation("clip_delete_pressed", { clipId: selectedClipId })
        deleteClipById(selectedClipId, true)
    }

    // Body of deleteSelectedClip(), for any clip id (Q/W delete a split
    // fragment that is not the selection). Removes the clip and its
    // linked partner, closes the gap when ripple is on, clears the
    // selection. Returns false (nothing changed, no undo scope opened)
    // if the clip does not exist. pushToEngine === false skips the final
    // engine rebuild (caller does it; removeTransition() still pushes).
    function deleteClipById(clipId, pushToEngine) {
        return deleteClipsById([clipId], pushToEngine)
    }

    // Batch form (Q/W remove one fragment per cut track in ONE pass):
    // all transitions are undone first, then all clips removed, then ONE
    // ripple pass closes every gap. Sequential single deletes could not do
    // that once the ripple follows linked partners: the first delete would
    // already move audio on a track whose own gap the second delete then
    // measures from the shifted state.
    function deleteClipsById(clipIds, pushToEngine) {
        var any = false
        for (var q = 0; q < clipIds.length; q++) {
            if (findClipRowById(clipIds[q]) >= 0) { any = true; break }
        }
        if (!any) return false
        beginUndoableEdit()

        // If a clip being deleted (or its linked partner) is on either
        // side of a transition, remove the transition FIRST - which trims
        // both clips back to the cut point (nothing moves) - instead of
        // deleting it in place. Without this, the surviving neighbor would
        // keep its handle-extended overlap reaching into the gap, and the
        // gap-closing ripple below would re-create an unintended overlap
        // (GES auto-transition = phantom crossfade) with whatever comes
        // after.
        for (var q2 = 0; q2 < clipIds.length; q2++) {
            var startIndex = findClipRowById(clipIds[q2])
            if (startIndex < 0) continue
            var startClip = clipsModel.get(startIndex)
            var idsToDetach = [startClip.clipId]
            if (startClip.isLinked && startClip.linkedClipId) idsToDetach.push(startClip.linkedClipId)

            for (var d = 0; d < idsToDetach.length; d++) {
                var detachId = idsToDetach[d]
                // This clip IS the transition's A side
                for (var a = 0; a < clipsModel.count; a++) {
                    var ac = clipsModel.get(a)
                    if (ac.clipId === detachId && ac.hasTransition) {
                        removeTransition(a)
                        break
                    }
                }
                // This clip is the transition's B side (referenced by some A)
                for (var b = 0; b < clipsModel.count; b++) {
                    var bc = clipsModel.get(b)
                    if (bc.hasTransition && bc.transitionOriginalBId === detachId) {
                        removeTransition(b)
                        break
                    }
                }
            }
        }

        // Re-resolve everything by id - removeTransition() above re-trimmed
        // clips (start/duration of the B side changed). Capture
        // each removed clip's (now transition-free, natural) track/position
        // before removing it - needed below to close the gap it leaves.
        var rippleTargets = []
        for (var q3 = 0; q3 < clipIds.length; q3++) {
            var clipIndex = findClipRowById(clipIds[q3])
            if (clipIndex < 0) continue   // already removed as a partner
            var clipToDelete = clipsModel.get(clipIndex)
            var linkedClipId = clipToDelete.isLinked ? clipToDelete.linkedClipId : null
            rippleTargets.push({ trackId: clipToDelete.trackId, startTime: clipToDelete.startTime,
                                 duration: clipToDelete.durationSeconds })
            Backend.logOperation("clip_delete_commit", {
                clipId: clipToDelete.clipId, trackId: clipToDelete.trackId,
                startTime: clipToDelete.startTime, linkedClipId: linkedClipId || ""
            })
            if (linkedClipId) {
                var j = findClipRowById(linkedClipId)
                if (j >= 0) {
                    var linkedClip = clipsModel.get(j)
                    rippleTargets.push({ trackId: linkedClip.trackId, startTime: linkedClip.startTime,
                                         duration: linkedClip.durationSeconds })
                    clipsModel.remove(j)
                }
            }
            clipsModel.remove(findClipRowById(clipIds[q3]))
        }
        selectOnly("")

        if (rippleEditEnabled && rippleAllTracks && rippleTargets.length > 0) {
            var blocked = rippleCloseGapAllTracks(rippleTargets[0])
            if (blocked !== "") {
                showTimelineNotice("All-tracks ripple blocked: " + blocked + " Nothing was changed.")
                Backend.logOperation("ripple_all_tracks_blocked", { reason: blocked })
                // Roll the WHOLE edit back (incl. the transitions removed
                // above). Only the outermost scope owns the snapshot: a
                // nested caller (trimToPlayhead) gets "blocked" and rolls
                // back its own, larger edit (the split) itself.
                if (undoDepth === 1) {
                    var snap = undoPendingBefore
                    abortUndoableEdit()
                    restoreTimelineState(snap)
                    return false
                }
                abortUndoableEdit()
                return "blocked"
            }
        } else if (rippleEditEnabled) {
            // Each target closes the ACTUAL gap on its own track - the
            // distance to the next clip there - rather than the deleted
            // clip's duration (those differ whenever something shifted
            // clips around, e.g. a now-undone transition). Every following
            // clip on a target track moves by the sum of the gaps before
            // it; the LINKED PARTNER of each moved clip that is not itself
            // on a target track moves by the same amount (deleting a
            // video-only clip used to leave the following clips' audio
            // behind - A/V desync). Each clip is shifted exactly once.
            var deltaById = new Map()
            for (var k = 0; k < rippleTargets.length; k++) {
                var t = rippleTargets[k]
                var nextStart = -1
                for (var m = 0; m < clipsModel.count; m++) {
                    var mc = clipsModel.get(m)
                    if (mc.trackId === t.trackId && mc.startTime > t.startTime) {
                        if (nextStart < 0 || mc.startTime < nextStart) nextStart = mc.startTime
                    }
                }
                if (nextStart < 0) continue   // nothing follows on this track
                var gap = nextStart - t.startTime
                for (var f = 0; f < clipsModel.count; f++) {
                    var fc = clipsModel.get(f)
                    if (fc.trackId === t.trackId && fc.startTime > t.startTime)
                        deltaById.set(fc.clipId, (deltaById.has(fc.clipId) ? deltaById.get(fc.clipId) : 0) - gap)
                }
            }
            var partnerDelta = new Map()
            for (var r = 0; r < clipsModel.count; r++) {
                var rc = clipsModel.get(r)
                if (!deltaById.has(rc.clipId) || !rc.isLinked || !rc.linkedClipId) continue
                if (!deltaById.has(rc.linkedClipId) && !partnerDelta.has(rc.linkedClipId))
                    partnerDelta.set(rc.linkedClipId, deltaById.get(rc.clipId))
            }
            for (var w = 0; w < clipsModel.count; w++) {
                var wc = clipsModel.get(w)
                var dl = deltaById.has(wc.clipId) ? deltaById.get(wc.clipId)
                       : (partnerDelta.has(wc.clipId) ? partnerDelta.get(wc.clipId) : 0)
                if (dl !== 0) clipsModel.setProperty(w, "startTime", wc.startTime + dl)
            }
        }

        if (pushToEngine !== false && updateTimelineEngine) updateTimelineEngine()
        Qt.callLater(checkAllClipNeighbors)
        commitUndoableEdit("Delete clip")
        return true
    }

    // All-tracks ripple for a delete whose primary removed clip was at
    // t.startTime on t.trackId. The gap is the distance to the next clip
    // on that track (or the removed clip's own length when nothing follows
    // there); every clip on every UNLOCKED track starting at or after the
    // end of that gap moves left by it, once. Clips that end before the
    // edit point, or start at/before it and run past it (a music bed),
    // stay. Returns ""
    // after applying it, or a reason (and changes nothing) when it would
    // break something: a clip starting inside the removed range, a moved
    // clip landing on a clip that stays, or a linked pair split by a lock.
    function rippleCloseGapAllTracks(t) {
        var eps = 1e-4
        var E = t.startTime
        var nextStart = -1
        for (var i = 0; i < clipsModel.count; i++) {
            var c0 = clipsModel.get(i)
            if (c0.trackId === t.trackId && c0.startTime > E + 1e-9 && (nextStart < 0 || c0.startTime < nextStart))
                nextStart = c0.startTime
        }
        var g = nextStart >= 0 ? nextStart - E : (t.duration || 0)
        if (!(g > 1e-9)) return ""
        var move = new Map()
        for (var j = 0; j < clipsModel.count; j++) {
            var c = clipsModel.get(j)
            if (c.startTime < E + eps && c.startTime + c.durationSeconds > E + eps)
                continue                                        // spans (or starts at) the edit point: stays
            if (c.startTime < E - eps) continue                 // entirely before: stays
            if (isTrackLocked(c.trackId)) continue              // locked: never moves
            if (c.startTime < E + g - eps)
                return "\"" + c.itemName + "\" on " + c.trackId + " starts inside the removed range."
            move.set(c.clipId, true)
        }
        for (var k = 0; k < clipsModel.count; k++) {
            var m = clipsModel.get(k)
            if (!move.has(m.clipId) || !m.isLinked || !m.linkedClipId) continue
            if (findClipRowById(m.linkedClipId) >= 0 && !move.has(m.linkedClipId))
                return "\"" + m.itemName + "\" would lose sync with its linked clip (locked track?)."
        }
        for (var a = 0; a < clipsModel.count; a++) {
            var mc = clipsModel.get(a)
            if (!move.has(mc.clipId)) continue
            var ns = mc.startTime - g, ne = ns + mc.durationSeconds
            for (var b = 0; b < clipsModel.count; b++) {
                var x = clipsModel.get(b)
                if (x.trackId !== mc.trackId || move.has(x.clipId)) continue
                if (ns < x.startTime + x.durationSeconds - eps && ne > x.startTime + eps)
                    return "\"" + mc.itemName + "\" on " + mc.trackId + " would overlap \"" + x.itemName + "\"."
            }
        }
        for (var w = 0; w < clipsModel.count; w++) {
            var wc = clipsModel.get(w)
            if (move.has(wc.clipId)) clipsModel.setProperty(w, "startTime", wc.startTime - g)
        }
        return ""
    }

    // Returns the [start, end] time range (seconds) of clip c's crossfade
    // overlap with a neighboring clip, or null if it isn't part of one.
    // Covers both directions: c fading OUT into the next clip (c itself
    // has hasTransition), and c fading IN from the previous clip (some
    // other clip on the same track has hasTransition pointing at c via
    // transitionOriginalBId).
    function clipTransitionZone(c) {
        if (c.hasTransition && c.transitionDuration > 0) {
            var zEnd = c.startTime + c.durationSeconds
            return { start: zEnd - c.transitionDuration, end: zEnd }
        }
        var incomingDur = incomingTransDurById[c.clipId]
        if (incomingDur && incomingDur > 0) {
            return { start: c.startTime, end: c.startTime + incomingDur }
        }
        return null
    }

    // Some other clip may fade OUT into the clip identified by oldId
    // (recorded via that other clip's transitionOriginalBId pointing at
    // oldId). Splitting always keeps the original startTime on the LEFT
    // fragment (the original row gets renamed to newId, a new row is
    // appended for the right fragment) - so if oldId is still the target
    // of an incoming transition, redirect that reference to newId,
    // otherwise incomingTransDurById/clipTransitionZone silently go
    // stale for the renamed clip (dissolve indicator + trim-handle
    // suppression disappear even though GES's own overlap is untouched).
    function relinkIncomingTransitionRef(oldId, newId) {
        if (oldId === newId) return
        for (var m = 0; m < clipsModel.count; m++) {
            var rc = clipsModel.get(m)
            if (rc.hasTransition && rc.transitionOriginalBId === oldId) {
                clipsModel.setProperty(m, "transitionOriginalBId", newId)
            }
        }
    }

    // Finds the video clip (if any) the playhead currently sits inside,
    // for showing "how far into this clip" alongside the absolute
    // timecode (ProjectMonitor.qml). Prefers video tracks since that's
    // what's actually visible in the monitor; if several video tracks
    // overlap at this position, returns the first match in model order
    // (no defined priority - good enough for the common single-video
    // case, picture-in-picture just shows one of them).
    function clipAtPlayhead(playheadSeconds) {
        for (var i = 0; i < clipsModel.count; i++) {
            var c = clipsModel.get(i)
            if (!c.trackId || c.trackId.charAt(0) !== "V") continue
            if (playheadSeconds >= c.startTime && playheadSeconds < c.startTime + c.durationSeconds) {
                return { startTime: c.startTime, durationSeconds: c.durationSeconds }
            }
        }
        return null
    }

    // === CUT TARGETS AT THE PLAYHEAD (shared by S, Q, W and D) ===
    // The playhead position is an integer number of ms (TimelineEngine
    // position is qint64 ms), while clip edges are float seconds that need
    // not fall on a whole ms (imported/dragged clips). A playhead that is
    // less than 1 ms from a clip edge is therefore treated as being AT that
    // edge: no split there (it would only create a sub-ms sliver), and the
    // clip starting within that 1 ms counts as the clip under the playhead.
    // Edges created by a split are whole ms (position / 1000), so for them
    // this is identical to the plain strict comparison.
    readonly property real cutEdgeEpsSec: 0.001

    function isTrackLocked(trackId) {
        var i = getTrackIndexFromId(trackId)
        return i >= 0 && tracksModel.get(i).locked === true
    }

    // Playhead strictly inside clip c (not at/within 1 ms of either edge).
    function playheadInsideClip(c, t) {
        var eps = cutEdgeEpsSec - 1e-9
        return (t - c.startTime) >= eps && (c.startTime + c.durationSeconds - t) >= eps
    }

    // Row of the clip under the playhead on trackId, or -1. strict=false:
    // start <= t < end (a clip starting less than cutEdgeEpsSec after t
    // counts as under it); strict=true: playhead strictly inside
    // (playheadInsideClip). Two clips can overlap on one track only inside
    // a transition; the earlier-starting one is returned.
    function clipRowUnderPlayheadOnTrack(trackId, t, strict) {
        var eps = cutEdgeEpsSec - 1e-9
        var best = -1
        for (var i = 0; i < clipsModel.count; i++) {
            var c = clipsModel.get(i)
            if (c.trackId !== trackId) continue
            var under = strict ? playheadInsideClip(c, t)
                               : ((c.startTime - t) < eps && (c.startTime + c.durationSeconds - t) >= eps)
            if (!under) continue
            if (best < 0 || c.startTime < clipsModel.get(best).startTime) best = i
        }
        return best
    }

    // The clip at `row` plus its linked partner (if the playhead is inside
    // the partner too), as split's [{index, data}] list. With skipLocked,
    // a pair touching a locked track yields [] (never cut one half only).
    function clipPairTargets(row, t, skipLocked) {
        var c = clipsModel.get(row)
        if (skipLocked && isTrackLocked(c.trackId)) return []
        var res = [{ index: row, data: c }]
        if (c.isLinked && c.linkedClipId) {
            var lr = findClipRowById(c.linkedClipId)
            if (lr >= 0) {
                var l = clipsModel.get(lr)
                if (playheadInsideClip(l, t)) {
                    if (skipLocked && isTrackLocked(l.trackId)) return []
                    res.push({ index: lr, data: l })
                }
            }
        }
        return res
    }

    // Which clips S / Q / W act on at playhead time t (seconds).
    //  - Split One: the clip the playhead is strictly inside on the ACTIVE
    //    track (+ its linked partner). Nothing if the active track is
    //    locked or has no such clip.
    //  - Split All: every clip the playhead is inside, on every track.
    // skipLocked (Q/W) additionally drops clips on locked tracks, and a
    // linked pair whose partner is on a locked track.
    // Returns {targets: [{index, data}], primaryId} - primaryId is the clip
    // whose remaining fragment Q/W select afterwards.
    function resolveCutTargets(t, skipLocked) {
        var out = { targets: [], primaryId: "" }
        if (splitAllTracksMode) {
            for (var i = 0; i < clipsModel.count; i++) {
                var c = clipsModel.get(i)
                if (!playheadInsideClip(c, t)) continue
                if (skipLocked && isTrackLocked(c.trackId)) continue
                out.targets.push({ index: i, data: c })
            }
            // Primary = the selection (or its partner) if it is cut, else
            // the active track's clip if it is cut, else the first target.
            var selRow = selectedClipId ? findClipRowById(selectedClipId) : -1
            var selPartner = selRow >= 0 ? (clipsModel.get(selRow).linkedClipId || "") : ""
            var actRow = clipRowUnderPlayheadOnTrack(activeTrackId, t, true)
            var prefer = [selectedClipId, selPartner, actRow >= 0 ? clipsModel.get(actRow).clipId : ""]
            for (var p = 0; p < prefer.length && out.primaryId === ""; p++) {
                if (!prefer[p]) continue
                for (var k = 0; k < out.targets.length; k++) {
                    if (out.targets[k].data.clipId === prefer[p]) { out.primaryId = prefer[p]; break }
                }
            }
            if (out.primaryId === "" && out.targets.length > 0) out.primaryId = out.targets[0].data.clipId
            return out
        }
        if (isTrackLocked(activeTrackId)) return out
        var row = clipRowUnderPlayheadOnTrack(activeTrackId, t, true)
        if (row < 0) return out
        out.primaryId = clipsModel.get(row).clipId
        out.targets = clipPairTargets(row, t, skipLocked)
        return out
    }

    // === ACTIVE TRACK ===
    // Exactly one track is "active" (marker on its header). It decides
    // what S (Split One), Q and W cut. View state: not in undo snapshots,
    // not saved. Separate from tracksContentList.currentIndex, the
    // header-click "current track" the toolbar's "- Del" removes.
    property string activeTrackId: "V1"

    function defaultActiveTrackId() {
        if (getTrackIndexFromId("V1") >= 0) return "V1"
        return tracksModel.count > 0 ? tracksModel.get(0).trackId : ""
    }

    // Called (deferred) from rebuildTrackIndex(): a deleted/unknown active
    // track falls back to the default.
    function ensureActiveTrack() {
        if (activeTrackId === "" || getTrackIndexFromId(activeTrackId) < 0)
            activeTrackId = defaultActiveTrackId()
    }

    function resetActiveTrack() {
        activeTrackId = ""
        ensureActiveTrack()
    }

    function setActiveTrack(trackId) {
        if (getTrackIndexFromId(trackId) < 0) return
        activeTrackId = trackId
    }

    // Scrolls the track rows (content and headers together) so row idx is
    // fully visible.
    function ensureTrackRowVisible(idx) {
        if (idx < 0) return
        var viewH = tracksContentFlickable.height - horizontalScrollBar.height
        if (viewH <= 0) return
        var y0 = idx * trackHeight
        var y1 = y0 + trackHeight - 1
        var cy = tracksContentFlickable.contentY
        if (y0 < cy) cy = y0
        else if (y1 > cy + viewH) cy = y1 - viewH
        cy = Math.max(0, Math.min(cy, tracksContentFlickable.contentHeight - viewH))
        if (cy !== tracksContentFlickable.contentY) tracksContentFlickable.contentY = cy
        if (tracksHeadersList.contentY !== cy) tracksHeadersList.contentY = cy
    }

    // Up / Down: active track one row up (-1) / down (+1) in the displayed
    // order, stopping at the ends. Also selects the clip under the playhead
    // on the new track (as a click would), if there is one.
    function moveActiveTrack(dir) {
        var idx = getTrackIndexFromId(activeTrackId)
        if (idx < 0) { ensureActiveTrack(); idx = getTrackIndexFromId(activeTrackId) }
        var n = Math.max(0, Math.min(tracksModel.count - 1, idx + dir))
        if (n === idx || n < 0) return
        activeTrackId = tracksModel.get(n).trackId
        ensureTrackRowVisible(n)
        if (timelineEngine) {
            var row = clipRowUnderPlayheadOnTrack(activeTrackId, timelineEngine.position / 1000.0, false)
            if (row >= 0) selectOnly(clipsModel.get(row).clipId)
        }
    }

    // D: select the clip under the playhead on the active track (same
    // selection call as a plain mouse click). No clip: nothing happens.
    function selectClipAtPlayhead() {
        if (!timelineEngine) return
        var t = timelineEngine.position / 1000.0
        var row = clipRowUnderPlayheadOnTrack(activeTrackId, t, false)
        if (row < 0) return
        var id = clipsModel.get(row).clipId
        Backend.logOperation("clip_select_at_playhead", { playheadSeconds: t, trackId: activeTrackId, clipId: id })
        selectOnly(id)
    }

    function splitAtPlayhead() {
        if (!timelineEngine) return
        var playheadSeconds = timelineEngine.position / 1000.0

        // 1. Megkeressük a split-elhető klipeket
        var res = resolveCutTargets(playheadSeconds, false)
        if (res.targets.length === 0) {
            console.log("Nothing to split at playhead")
            return
        }
        splitClipTargets(res.targets, playheadSeconds, true)
    }

    // Effects JSON of one fragment of a cut clip. Every effect (static
    // params and keyframes) is copied verbatim: keyframe times are in clip
    // MEDIA time (see clipTiming()), so they stay on the same source frames
    // whatever the fragment's sourceOffset is, and effect ids only need to
    // be unique within one clip (ClipEffects::findEffectById is per clip).
    // The one exception is "fade" (Fade from/to Black): its params are
    // durations anchored at the clip's own start/end, so the fade-in stays
    // on the left fragment only and the fade-out on the right one only
    // (otherwise the cut itself would fade to/from black). An entry whose
    // two durations are both gone is dropped. rightSide selects the fragment.
    function splitEffectsJson(raw, rightSide) {
        if (!raw || raw === "[]") return raw || ""
        var arr
        try { arr = JSON.parse(raw) } catch (e) { return raw }
        var changed = false
        var out = []
        for (var i = 0; i < arr.length; i++) {
            var fx = arr[i]
            if (fx && fx.type === "fade" && fx.params) {
                changed = true
                if (rightSide) delete fx.params["in"]; else delete fx.params["out"]
                if (!(Number(fx.params["in"]) > 0) && !(Number(fx.params["out"]) > 0)) continue
            }
            out.push(fx)
        }
        return changed ? JSON.stringify(out) : raw
    }

    // Splits every clip in clipsToSplit ([{index, data}], e.g. from
    // resolveCutTargets()) at playheadSeconds. Returns null if blocked
    // (playhead in a transition zone - nothing changed, no undo entry),
    // else [{origId, leftId, rightId}] for every row that was cut.
    // pushToEngine === false skips the engine rebuild (caller does it).
    // keepFades=true (Q/W trim) copies the effects verbatim to the right
    // fragment and leaves the left one untouched; the default (S split)
    // moves a "fade" effect's fade-in to the left fragment and its
    // fade-out to the right one, see splitEffectsJson().
    function splitClipTargets(clipsToSplit, playheadSeconds, pushToEngine, keepFades) {
        var fragments = []

        Backend.logOperation("clip_split_pressed", {
            playheadSeconds: playheadSeconds, clipCount: clipsToSplit.length,
            splitAllTracksMode: splitAllTracksMode, selectedClipId: selectedClipId
        })

        // Splitting inside a transition's crossfade zone is ambiguous
        // (there's no single correct way to "cut a dissolve in half") and
        // the old behavior silently left a corrupt state: the split clip's
        // hasTransition flag got cleared, but the actual GES-side overlap
        // (which is what really drives the auto-transition crossfade, not
        // our hasTransition bookkeeping) was untouched - so the dissolve
        // kept rendering while the UI lost track of it and clip positions
        // went wrong. Block the split entirely instead and tell the user
        // to remove the transition first.
        for (var zi = 0; zi < clipsToSplit.length; zi++) {
            var zone = clipTransitionZone(clipsToSplit[zi].data)
            if (zone && playheadSeconds > zone.start && playheadSeconds < zone.end) {
                splitBlockedWindow.present()
                return null
            }
        }

        // 2. Csoportosítjuk linkelt párokba és feldolgozzuk
        beginUndoableEdit()
        var processedClipIds = {}  // Nyilvántartjuk, hogy melyik klipet már feldolgoztuk

        for (var j = 0; j < clipsToSplit.length; j++) {
            var cd = clipsToSplit[j].data
            // clipsModel.get() returns a live reference, not a snapshot -
            // cd.clipId would read back whatever setProperty() below just
            // wrote (the NEW leftClipId), not the true pre-split id, if
            // read after those calls. Capture it now, before anything
            // mutates this row, so the debug log below records the real
            // original->new mapping.
            var origCdClipId = cd.clipId

            // Ha már feldolgoztuk (mert a linked párja miatt már splitteltük), akkor skip
            if (processedClipIds[cd.clipId]) continue

            // EXACTLY the same live-reference trap as origCdClipId above,
            // and the reason the first attempt at preserving the dissolve
            // across a split silently did nothing: the left fragment's
            // hasTransition gets explicitly cleared further down, BEFORE
            // the append() literal for the right fragment is evaluated -
            // so reading cd.hasTransition inside that literal always read
            // back the already-cleared `false`, and every "preserve"
            // ternary collapsed to the cleared arm. Snapshot the whole
            // outgoing-transition tuple here, before any setProperty()
            // touches this row, and build the right fragment from these
            // locals only.
            var origHasTransition = (cd.hasTransition === true)
            var origTransitionDuration = cd.transitionDuration || 0
            var origTransitionType = cd.transitionType || ""
            var origTransitionCutOffset = cd.transitionCutOffset !== undefined ? cd.transitionCutOffset : origTransitionDuration / 2.0
            var origTransitionOriginalBId = cd.transitionOriginalBId || ""
            var origTransitionOriginalStartB = cd.transitionOriginalStartB || 0
            var origTransitionAudioTrimA = cd.transitionAudioTrimA || 0
            // Same live-reference trap: the effects string must be read
            // before the first setProperty() on this row.
            var origEffectsStr = cd.effects || ""

            var firstPartDuration = playheadSeconds - cd.startTime
            var secondPartDuration = (cd.startTime + cd.durationSeconds) - playheadSeconds

            // Új clipId-k generálása
            var timestamp = Date.now() + j
            var leftClipId = "clip_" + timestamp + "_left"
            var rightClipId = "clip_" + timestamp + "_right"

            // Ha linkelt klip van, megkeressük
            var linkedClipModelIndex = -1  // clipsModel-ben való index
            var linkedClipData = null
            if (cd.isLinked && cd.linkedClipId) {
                for (var k = 0; k < clipsToSplit.length; k++) {
                    if (clipsToSplit[k].data.clipId === cd.linkedClipId) {
                        linkedClipModelIndex = clipsToSplit[k].index  // JAVÍTVA: model index!
                        linkedClipData = clipsToSplit[k].data
                        break
                    }
                }
            }
            // Same reasoning as origCdClipId above - capture before any
            // setProperty() mutates this row.
            var origLinkedClipId = linkedClipData ? linkedClipData.clipId : ""
            var origLinkedHasTransition = linkedClipData ? (linkedClipData.hasTransition === true) : false
            var origLinkedTransitionDuration = linkedClipData ? (linkedClipData.transitionDuration || 0) : 0
            var origLinkedTransitionType = linkedClipData ? (linkedClipData.transitionType || "") : ""
            var origLinkedTransitionCutOffset = linkedClipData
                ? (linkedClipData.transitionCutOffset !== undefined ? linkedClipData.transitionCutOffset : origLinkedTransitionDuration / 2.0)
                : 0
            var origLinkedTransitionOriginalBId = linkedClipData ? (linkedClipData.transitionOriginalBId || "") : ""
            var origLinkedTransitionOriginalStartB = linkedClipData ? (linkedClipData.transitionOriginalStartB || 0) : 0
            var origLinkedTransitionAudioTrimA = linkedClipData ? (linkedClipData.transitionAudioTrimA || 0) : 0
            var origLinkedEffectsStr = linkedClipData ? (linkedClipData.effects || "") : ""

            // Ha van linkelt pár, együtt split-eljük
            if (linkedClipData) {
                // Új linkedClipId-k generálása
                var linkedLeftClipId = "clip_" + timestamp + "_linked_left"
                var linkedRightClipId = "clip_" + timestamp + "_linked_right"

                // === AKTUÁLIS KLIP (pl. videó) SPLIT ===
                // Bal rész: eredeti klip módosítása
                clipsModel.setProperty(clipsToSplit[j].index, "durationSeconds", firstPartDuration)
                clipsModel.setProperty(clipsToSplit[j].index, "clipId", leftClipId)
                clipsModel.setProperty(clipsToSplit[j].index, "linkedClipId", linkedLeftClipId)
                clipsModel.setProperty(clipsToSplit[j].index, "hasTransition", false)
                if (!keepFades) {
                    var leftFx = splitEffectsJson(origEffectsStr, false)
                    if (leftFx !== origEffectsStr) clipsModel.setProperty(clipsToSplit[j].index, "effects", leftFx)
                }
                relinkIncomingTransitionRef(origCdClipId, leftClipId)

                // Jobb rész: új klip. Az eredeti klip vége (és ezzel az
                // esetleges kimenő dissolve zónája) mindig ebben a
                // részben marad, ezért a hasTransition-t és a kapcsolódó
                // mezőket NEM nullázzuk, hanem átvesszük az eredetiből -
                // lásd relinkIncomingTransitionRef() fenti kommentjét.
                clipsModel.append({
                    clipId: rightClipId,
                    trackId: cd.trackId,
                    itemName: cd.itemName,
                    itemPath: cd.itemPath,
                    startTime: playheadSeconds,
                    durationSeconds: secondPartDuration,
                    hasVideo: cd.hasVideo,
                    hasAudio: cd.hasAudio,
                    sourceOffset: cd.sourceOffset + firstPartDuration,
                    hasTransition: origHasTransition,
                    transitionDuration: origHasTransition ? origTransitionDuration : 0,
                    transitionType: origHasTransition ? origTransitionType : "",
                    transitionCutOffset: origHasTransition ? origTransitionCutOffset : 0,
                    transitionOriginalBId: origHasTransition ? origTransitionOriginalBId : "",
                    transitionOriginalStartB: origHasTransition ? origTransitionOriginalStartB : 0,
                    transitionAudioTrimA: origHasTransition ? origTransitionAudioTrimA : 0,
                    linkGroupId: cd.linkGroupId || "",
                    linkedClipId: linkedRightClipId,
                    isLinked: true,
                    sourceItemId: cd.sourceItemId || "",
                    waveformPath: cd.waveformPath || "",
                    effects: keepFades ? origEffectsStr : splitEffectsJson(origEffectsStr, true),
                    clipKind: cd.clipKind || "", titleParams: cd.titleParams || ""
                })

                // === LINKELT KLIP (pl. audio) SPLIT ===
                // Bal rész: eredeti klip módosítása
                clipsModel.setProperty(linkedClipModelIndex, "durationSeconds", firstPartDuration)
                clipsModel.setProperty(linkedClipModelIndex, "clipId", linkedLeftClipId)
                clipsModel.setProperty(linkedClipModelIndex, "linkedClipId", leftClipId)
                clipsModel.setProperty(linkedClipModelIndex, "hasTransition", false)
                if (!keepFades) {
                    var leftLinkedFx = splitEffectsJson(origLinkedEffectsStr, false)
                    if (leftLinkedFx !== origLinkedEffectsStr) clipsModel.setProperty(linkedClipModelIndex, "effects", leftLinkedFx)
                }
                relinkIncomingTransitionRef(origLinkedClipId, linkedLeftClipId)

                // Jobb rész: új klip (ugyanaz az indoklás, mint fent)
                clipsModel.append({
                    clipId: linkedRightClipId,
                    trackId: linkedClipData.trackId,
                    itemName: linkedClipData.itemName,
                    itemPath: linkedClipData.itemPath,
                    startTime: playheadSeconds,
                    durationSeconds: secondPartDuration,
                    hasVideo: linkedClipData.hasVideo,
                    hasAudio: linkedClipData.hasAudio,
                    sourceOffset: linkedClipData.sourceOffset + firstPartDuration,
                    hasTransition: origLinkedHasTransition,
                    transitionDuration: origLinkedHasTransition ? origLinkedTransitionDuration : 0,
                    transitionType: origLinkedHasTransition ? origLinkedTransitionType : "",
                    transitionCutOffset: origLinkedHasTransition ? origLinkedTransitionCutOffset : 0,
                    transitionOriginalBId: origLinkedHasTransition ? origLinkedTransitionOriginalBId : "",
                    transitionOriginalStartB: origLinkedHasTransition ? origLinkedTransitionOriginalStartB : 0,
                    transitionAudioTrimA: origLinkedHasTransition ? origLinkedTransitionAudioTrimA : 0,
                    linkGroupId: linkedClipData.linkGroupId || "",
                    linkedClipId: rightClipId,
                    isLinked: true,
                    sourceItemId: linkedClipData.sourceItemId || "",
                    waveformPath: linkedClipData.waveformPath || "",
                    effects: keepFades ? origLinkedEffectsStr : splitEffectsJson(origLinkedEffectsStr, true),
                    clipKind: linkedClipData.clipKind || "", titleParams: linkedClipData.titleParams || ""
                })

                // Megjelöljük, hogy mindkét klipet feldolgoztuk
                processedClipIds[cd.clipId] = true
                processedClipIds[linkedClipData.clipId] = true
                fragments.push({ origId: origCdClipId, leftId: leftClipId, rightId: rightClipId })
                fragments.push({ origId: origLinkedClipId, leftId: linkedLeftClipId, rightId: linkedRightClipId })

                Backend.logOperation("clip_split_commit", {
                    originalClipId: origCdClipId, leftClipId: leftClipId, rightClipId: rightClipId,
                    linkedOriginalClipId: origLinkedClipId, linkedLeftClipId: linkedLeftClipId, linkedRightClipId: linkedRightClipId,
                    playheadSeconds: playheadSeconds, trackId: cd.trackId
                })

            } else {
                // Nincs linkelt pár, egyedül split-eljük
                // Bal rész: eredeti klip módosítása
                clipsModel.setProperty(clipsToSplit[j].index, "durationSeconds", firstPartDuration)
                clipsModel.setProperty(clipsToSplit[j].index, "clipId", leftClipId)
                clipsModel.setProperty(clipsToSplit[j].index, "hasTransition", false)
                clipsModel.setProperty(clipsToSplit[j].index, "isLinked", false)
                clipsModel.setProperty(clipsToSplit[j].index, "linkedClipId", "")
                if (!keepFades) {
                    var leftSoloFx = splitEffectsJson(origEffectsStr, false)
                    if (leftSoloFx !== origEffectsStr) clipsModel.setProperty(clipsToSplit[j].index, "effects", leftSoloFx)
                }
                relinkIncomingTransitionRef(origCdClipId, leftClipId)

                // Jobb rész: új klip - a kimenő dissolve zóna (ha volt)
                // mindig ebben a részben marad, lásd fenti indoklás.
                clipsModel.append({
                    clipId: rightClipId,
                    trackId: cd.trackId,
                    itemName: cd.itemName,
                    itemPath: cd.itemPath,
                    startTime: playheadSeconds,
                    durationSeconds: secondPartDuration,
                    hasVideo: cd.hasVideo,
                    hasAudio: cd.hasAudio,
                    sourceOffset: cd.sourceOffset + firstPartDuration,
                    hasTransition: origHasTransition,
                    transitionDuration: origHasTransition ? origTransitionDuration : 0,
                    transitionType: origHasTransition ? origTransitionType : "",
                    transitionCutOffset: origHasTransition ? origTransitionCutOffset : 0,
                    transitionOriginalBId: origHasTransition ? origTransitionOriginalBId : "",
                    transitionOriginalStartB: origHasTransition ? origTransitionOriginalStartB : 0,
                    transitionAudioTrimA: origHasTransition ? origTransitionAudioTrimA : 0,
                    linkGroupId: "",
                    linkedClipId: "",
                    isLinked: false,
                    sourceItemId: cd.sourceItemId || "",
                    waveformPath: cd.waveformPath || "",
                    effects: keepFades ? origEffectsStr : splitEffectsJson(origEffectsStr, true),
                    clipKind: cd.clipKind || "", titleParams: cd.titleParams || ""
                })

                processedClipIds[cd.clipId] = true
                fragments.push({ origId: origCdClipId, leftId: leftClipId, rightId: rightClipId })

                Backend.logOperation("clip_split_commit", {
                    originalClipId: origCdClipId, leftClipId: leftClipId, rightClipId: rightClipId,
                    playheadSeconds: playheadSeconds, trackId: cd.trackId
                })
            }
        }

        effectsRevision++
        if (pushToEngine !== false && updateTimelineEngine) updateTimelineEngine()
        Qt.callLater(checkAllClipNeighbors)
        commitUndoableEdit("Split clip")
        return fragments
    }

    // Q / W: trim the clip start ("top") / end ("tail") to the playhead.
    // Composed of the existing operations inside ONE undo step: split at
    // the playhead (same targets as S, minus locked tracks), then delete
    // the fragment before (Q) or after (W) the playhead exactly as Delete
    // would (ripple closes the gap per track, transitions undone first).
    function trimStartToPlayhead() { trimToPlayhead(true) }
    function trimEndToPlayhead() { trimToPlayhead(false) }

    function trimToPlayhead(keepRight) {
        if (!timelineEngine) return
        var label = keepRight ? "Trim start to playhead" : "Trim end to playhead"
        var t = timelineEngine.position / 1000.0
        var res = resolveCutTargets(t, true)
        if (res.targets.length === 0) {
            console.log(label + ": no clip to trim at playhead")
            return
        }
        var primaryOrigId = res.primaryId
        Backend.logOperation("clip_trim_to_playhead_pressed", {
            side: keepRight ? "start" : "end", playheadSeconds: t, clipCount: res.targets.length,
            activeTrackId: activeTrackId, splitAllTracksMode: splitAllTracksMode, rippleEditEnabled: rippleEditEnabled
        })

        beginUndoableEdit()
        var frags = splitClipTargets(res.targets, t, false, true)
        if (!frags) { abortUndoableEdit(); return }   // blocked (transition zone)

        var keepId = ""
        var removeIds = []
        for (var f = 0; f < frags.length; f++) {
            var fr = frags[f]
            var kept = keepRight ? fr.rightId : fr.leftId
            removeIds.push(keepRight ? fr.leftId : fr.rightId)
            if (fr.origId === primaryOrigId) keepId = kept
        }
        // One batch (one ripple pass). A linked fragment is removed
        // together with its partner; the partner's own id is then skipped.
        // Primary fragment first: the all-tracks ripple measures its gap there.
        for (var pi = 0; pi < frags.length; pi++) {
            if (frags[pi].origId === primaryOrigId) {
                var pid = keepRight ? frags[pi].leftId : frags[pi].rightId
                removeIds.splice(removeIds.indexOf(pid), 1)
                removeIds.unshift(pid)
                break
            }
        }
        if (deleteClipsById(removeIds, false) === "blocked") {
            var snapT = undoPendingBefore
            abortUndoableEdit()
            restoreTimelineState(snapT)
            return
        }

        var seekMs = -1
        if (keepRight && rippleEditEnabled && keepId !== "") {
            // The kept fragment moved left to where the removed part
            // started - follow it so the same frame stays under the playhead.
            var kRow = findClipRowById(keepId)
            if (kRow >= 0) seekMs = Math.round(clipsModel.get(kRow).startTime * 1000)
        }
        // Seek BEFORE the rebuild: setClips() re-samples the position for
        // its own post-commit seek. A seek() issued while the rebuilt
        // pipeline is still prerolling was seen to leave a wrong frame on
        // the monitor (engine-side; not changed here).
        if (seekMs >= 0) timelineEngine.seek(seekMs)
        if (updateTimelineEngine) updateTimelineEngine()
        Qt.callLater(checkAllClipNeighbors)
        selectOnly(keepId)

        commitUndoableEdit(label)
        Backend.logOperation("clip_trim_to_playhead_commit", {
            side: keepRight ? "start" : "end", keptClipId: keepId, removedClipIds: removeIds, seekMs: seekMs
        })
    }

    // Ctrl+Left/Right, PageUp/PageDown: previous / next cut point (every clip start
    // and end on all tracks, plus 0). Points closer than half a project
    // frame count as one; "before"/"after" use the same half-frame
    // tolerance so repeated presses step instead of sticking. Seeks to the
    // point rounded to whole ms (the engine position unit); the resulting
    // playhead is within 0.5 ms of the edge, which cutEdgeEpsSec treats as
    // AT the edge (no sliver split, Q/W no-op).
    function cutPointsMs(halfFrameMs) {
        var pts = [0]
        for (var i = 0; i < clipsModel.count; i++) {
            var c = clipsModel.get(i)
            pts.push(c.startTime * 1000, (c.startTime + c.durationSeconds) * 1000)
        }
        pts.sort(function(a, b) { return a - b })
        var out = []
        for (var k = 0; k < pts.length; k++) {
            if (out.length === 0 || pts[k] - out[out.length - 1] > halfFrameMs) out.push(pts[k])
        }
        return out
    }

    function seekToAdjacentCut(direction) {
        if (!timelineEngine) return
        var frameMs = (workspace && workspace.projectFrameMs) ? workspace.projectFrameMs() : 1000 / 30
        var half = frameMs / 2
        var pos = timelineEngine.position
        var pts = cutPointsMs(half)
        var target = -1
        if (direction > 0) {
            for (var i = 0; i < pts.length; i++) {
                if (pts[i] > pos + half) { target = pts[i]; break }
            }
            if (target < 0) return
        } else {
            target = 0
            for (var j = pts.length - 1; j >= 0; j--) {
                if (pts[j] < pos - half) { target = pts[j]; break }
            }
        }
        timelineEngine.seek(Math.round(target))
    }

    function zoomToFit() {
        // contentEndSeconds (refreshed by rebuildClipIndex() on every
        // edit) is exactly the maxEnd this used to rescan clipsModel for.
        var maxEnd = Math.max(10, contentEndSeconds)
        pixelsPerSecond = Math.max(minPixelsPerSecond, Math.min(maxPixelsPerSecond, (tracksContentFlickable.width - 20) / (maxEnd * 1.1)))
        tracksContentFlickable.contentX = 0
    }

    function zoomIn() {
        var centerTime = (tracksContentFlickable.contentX + tracksContentFlickable.width / 2) / pixelsPerSecond
        pixelsPerSecond = Math.min(maxPixelsPerSecond, pixelsPerSecond * 1.25)
        tracksContentFlickable.contentX = Math.max(0, centerTime * pixelsPerSecond - tracksContentFlickable.width / 2)
    }

    function zoomOut() {
        var centerTime = (tracksContentFlickable.contentX + tracksContentFlickable.width / 2) / pixelsPerSecond
        pixelsPerSecond = Math.max(minPixelsPerSecond, pixelsPerSecond / 1.25)
        tracksContentFlickable.contentX = Math.max(0, centerTime * pixelsPerSecond - tracksContentFlickable.width / 2)
    }

    function setZoomLevel(level) {
        var centerTime = (tracksContentFlickable.contentX + tracksContentFlickable.width / 2) / pixelsPerSecond
        pixelsPerSecond = minPixelsPerSecond + (maxPixelsPerSecond - minPixelsPerSecond) * level
        tracksContentFlickable.contentX = Math.max(0, centerTime * pixelsPerSecond - tracksContentFlickable.width / 2)
    }

    // Keeps the playhead marker (TimelinePanel's own red Rectangle +
    // TimelineRuler's twin, both just x-bound to timelineEngine.position -
    // they follow for free once contentX moves) in view - "park and
    // scroll" semantics, same as Kdenlive/Premiere/Resolve: the playhead
    // free-runs until it reaches a parked screen position near the right
    // edge, then from that point on ONLY THE TIMELINE SCROLLS (the
    // playhead's own screen position stays pinned) for as long as
    // playback keeps it at/past that line - a continuous, speed-matched
    // scroll, not a page-jump. A prior iteration used a dead-zone +
    // bigger-landing-margin design instead; that inherently produces a
    // periodic page-jump (the view sits still, then jumps forward by the
    // landing margin's worth of distance) rather than this continuous
    // per-tick tracking - do not reintroduce a two-margin "trigger vs
    // rest" split on this (right) side.
    //
    // No explicit "am I following?" state needed: with parkedX = vw -
    // parkedMargin (the parked line, in content coords once pinned) and
    // target = px - parkedX recomputed fresh every tick, `target <= vx`
    // is EXACTLY equivalent to "the playhead hasn't reached the parked
    // line yet" - so that one comparison alone serves as entry
    // condition, re-entry condition (on resume/after a scrub), AND the
    // jitter guard below, with no separate boolean to keep in sync.
    //
    // During playback this is called straight from the positionChanged
    // handler below (~100Hz, TimelineEngine.cpp's 10ms position timer),
    // i.e. in the SAME event that moves the playhead markers (they are
    // x-bound to timelineEngine.position). Marker and content therefore
    // always move together and the marker stays exactly on the parked
    // line while following. A separate timer would update the content at
    // different moments than the marker and make the marker jitter against
    // the parked line. The function is a handful of float ops, so running
    // it at the position rate is cheap.
    // Last playhead position (ms) the follow logic has seen; -1 = none yet.
    property real lastFollowedPositionMs: -1
    function updatePlayheadScroll() {
        if (!timelineEngine) return
        // A clip drag/trim already owns contentX via edgeScrollTimer
        // (see windowAdditiveOnly's own definition) - don't fight it.
        if (windowAdditiveOnly) return
        // The user is actively dragging the playhead cursor on the ruler
        // right now - yanking the view out from under that gesture would
        // be actively hostile, not helpful.
        if (timelineRulerStrip.scrubbing) return

        var vw = tracksContentFlickable.width
        var pps = pixelsPerSecond
        if (vw <= 0 || pps <= 0) return

        var px = (timelineEngine.position / 1000) * pps
        var vx = tracksContentFlickable.contentX
        var maxX = Math.max(0, tracksContentFlickable.contentWidth - vw)

        // Parked line: how far from the right edge the playhead sits
        // once following engages - ~20% of the viewport, floored/capped
        // so it stays sane on a very narrow or very wide panel. Leaves a
        // reasonable amount of upcoming content visible as lookahead,
        // same ballpark as Kdenlive/Premiere/Resolve.
        var parkedMargin = Math.max(80, Math.min(vw * 0.2, 240))
        var parkedX = vw - parkedMargin

        // --- Backward recovery (seek/loop/jump going backward) - a
        // one-shot jump back into view. Dead-zone-plus-landing-margin IS
        // the right shape here (unlike the right side): this never
        // repeats every tick during normal forward playback, since
        // reverse playback isn't a thing this app does. ---
        var leftTrigger = Math.min(60, vw * 0.1)
        var leftRest = Math.min(140, vw * 0.25)
        if (px < vx + leftTrigger) {
            var back = Math.max(0, Math.min(px - leftRest, maxX))
            if (Math.abs(back - vx) >= 2) tracksContentFlickable.contentX = back
            return
        }

        // --- Forward: park and scroll, recomputed fresh every tick. ---
        // target <= vx covers THREE cases at once, all correctly handled
        // by just holding contentX still: the playhead hasn't reached
        // the parked line yet (free-running); it has already been
        // reached and position is advancing normally but a tick landed
        // exactly on parkedX; and - the jitter case -
        // timelineEngine.position is dead-reckoned/smoothed (wall clock
        // + pipeline blend, TimelineEngine.cpp) and can wobble backward
        // by a frame or two during otherwise steady forward playback.
        // Under continuous tracking a backward wobble would otherwise
        // move the ENTIRE CLIP CONTENT right by that many pixels while
        // the marker stays pinned - a far more visible lurch than the
        // old marker-only jitter - so this same comparison must run
        // UNGUARDED by any "only correct if the error is big enough"
        // threshold: holding content still for a tick is visually inert,
        // moving it backward is not.
        var target = px - parkedX
        if (target <= vx) return
        tracksContentFlickable.contentX = Math.min(target, maxX)
    }

    // While playing, follow on every position update (see the comment above
    // updatePlayheadScroll()). The branch below it also covers seeks that
    // happen WHILE PAUSED (keyboard nav, "go to start/end", a loop point,
    // a Kdenlive-import jump). Cheap while paused: TimelineEngine's
    // 10ms position timer is stopped then, so positionChanged only fires
    // on an explicit seek() call, not continuously. "Never scroll content
    // backward via the right branch" is also exactly the right paused-
    // seek behavior (stepping back one frame while parked should move
    // the marker, not the content).
    Connections {
        target: timelineEngine
        function onPositionChanged() {
            if (!timelineEngine) return
            if (timelineEngine.playing) {
                // Keep the paused-seek filter below current so pausing isn't seen as a move.
                timelineContainer.lastFollowedPositionMs = timelineEngine.position
                timelineContainer.updatePlayheadScroll()
                return
            }
            // Adding/removing a clip rebuilds and commits the GES timeline,
            // and the engine then re-emits positionChanged with an UNCHANGED
            // playhead position (commit restore seek / ASYNC_DONE re-query,
            // possibly off by a sub-frame). That is not a user seek, so don't
            // yank the view back to the playhead - only follow real moves.
            var pos = timelineEngine.position
            var fpsParts = String(Backend.getSetting("project/fps", "30")).split("/")
            var fps = parseFloat(fpsParts[0]) / (fpsParts.length > 1 ? parseFloat(fpsParts[1]) : 1)
            if (!(fps > 0)) fps = 30
            var tol = Math.max(1, 500 / fps) // half a project frame in ms
            var moved = Math.abs(pos - timelineContainer.lastFollowedPositionMs) >= tol
            timelineContainer.lastFollowedPositionMs = pos
            if (moved) timelineContainer.updatePlayheadScroll()
        }
    }

    ListModel {
        id: tracksModel
        ListElement { trackId: "V2"; type: "video"; name: ""; disabled: false; hidden: false; muted: false; volume: 1.0; solo: false; pan: 0.0; locked: false }
        ListElement { trackId: "V1"; type: "video"; name: ""; disabled: false; hidden: false; muted: false; volume: 1.0; solo: false; pan: 0.0; locked: false }
        ListElement { trackId: "A1"; type: "audio"; name: ""; disabled: false; hidden: false; muted: false; volume: 1.0; solo: false; pan: 0.0; locked: false }
        ListElement { trackId: "A2"; type: "audio"; name: ""; disabled: false; hidden: false; muted: false; volume: 1.0; solo: false; pan: 0.0; locked: false }
    }

    // "Automatic (detect from first video)" project profile stores
    // project/width|height|fps as the literal STRING "auto"
    // (ProjectSettingsDialog.qml) - nothing ever resolved that to a real
    // number before now, so every reader (render settings, preview
    // scale, ...) silently fell back to a hardcoded 1920x1080/30fps
    // guess. This resolves it ONCE, the moment the first video clip
    // actually lands on the timeline, and writes back real numbers - a
    // no-op on every call after that (the "!== auto" guard), so it's
    // safe to call from clipsModel.onCountChanged unconditionally
    // (project load, undo/redo, and the add-then-immediately-remove
    // dummy-element dance below all just no-op through the guards).
    function maybeResolveAutoProfile() {
        if (Backend.getSetting("project/width", "auto") !== "auto") return
        var firstVideo = null
        for (var i = 0; i < clipsModel.count; i++) {
            var c = clipsModel.get(i)
            if (!c.hasVideo) continue
            // A title clip has a bin item (its generator entry) but no
            // real media behind it - it can never answer "what is this
            // project's native resolution?", so skip it rather than let
            // it become `firstVideo` and abort the whole resolve.
            if ((c.clipKind || "") === "title") continue
            if (firstVideo === null || c.startTime < firstVideo.startTime) firstVideo = c
        }
        if (!firstVideo || !firstVideo.sourceItemId) return
        var meta = Backend.projectBinModel.getItemMetadata(firstVideo.sourceItemId)
        if (!meta || !meta.resolution) return
        var resMatch = /^(\d+)x(\d+)/.exec(meta.resolution)
        if (!resMatch) return
        Backend.setSetting("project/width", parseInt(resMatch[1]))
        Backend.setSetting("project/height", parseInt(resMatch[2]))
        var fpsMatch = /([\d.]+)/.exec(meta.frameRate || "")
        if (fpsMatch) Backend.setSetting("project/fps", fpsMatch[1])
    }

    ListModel {
        id: clipsModel
        onCountChanged: maybeResolveAutoProfile()
        // Define all roles by creating a dummy element with all properties
        Component.onCompleted: {
            // Add dummy element to establish roles
            clipsModel.append({
                clipId: "",
                trackId: "",
                itemName: "",
                itemPath: "",
                startTime: 0,
                durationSeconds: 0,
                hasVideo: false,
                hasAudio: false,
                sourceOffset: 0,
                hasTransition: false,
                transitionDuration: 0,
                transitionType: "",
                transitionCutOffset: 0,
                transitionOriginalBId: "",
                transitionOriginalStartB: 0,
                transitionAudioTrimA: 0,
                // Link fields - these are critical!
                linkGroupId: "",
                linkedClipId: "",
                isLinked: false,
                // Source tracking
                sourceItemId: "",
                waveformPath: "",
                // Per-clip effects stack (JSON array string) - "" / "[]" = none
                effects: "",
                // "" / "media" = an ordinary file-backed clip (everything
                // that existed before titles). "title" = a generated text
                // clip with NO itemPath at all - see TitleClips.cpp.
                clipKind: "",
                // Title clip parameters, JSON object string ("" = none).
                // Keys are 1:1 the GES title-source child-property names,
                // same string-blob convention as `effects` above.
                titleParams: "",
                // True if the engine couldn't find this clip's source
                // file on disk the last time it checked (see
                // EditingWorkspace.qml's onClipMediaMissing/
                // updateTimelineEngine) - not persisted, re-derived
                // fresh on every setClips() call.
                mediaMissing: false
            })
            // Remove the dummy element
            clipsModel.remove(0)
        }
    }

    // One DelegateModel per Repeater (see the Stage 3b property block
    // near the top of this file). Both wrap the SAME clipsModel and are
    // kept in lockstep by refilterWindow()/applyWinRun(). The delegate
    // lives HERE, not on the Repeater - that's how DelegateModel works;
    // a Repeater given a DelegateModel takes the delegate from it.
    DelegateModel {
        id: clipDM
        model: clipsModel
        filterOnGroup: "win"
        groups: [ DelegateModelGroup { name: "win"; includeByDefault: false } ]
        delegate: TimelineClip {
            timeline: timelineContainer
            container: contentContainer
            flickable: tracksContentFlickable
            clips: clipsModel
            tracks: tracksModel
        }
    }

    DelegateModel {
        id: transDM
        model: clipsModel
        filterOnGroup: "win"
        groups: [ DelegateModelGroup { name: "win"; includeByDefault: false } ]
        delegate: TimelineTransition {
            timeline: timelineContainer
            clips: clipsModel
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 5
        spacing: 5

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            color: palette.button
            Text { anchors.centerIn: parent; text: "Timeline"; color: "white"; font.bold: true }
        }

        TimelineToolbar {
            Layout.fillWidth: true
            timeline: timelineContainer
            tracks: tracksModel
            currentTrackIndex: tracksContentList.currentIndex
            mouseTimeSeconds: timelineContainer.mouseTimeSeconds
        }

        TimelineRuler {
            id: timelineRulerStrip
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            timeline: timelineContainer
            timelineEngine: timelineContainer.timelineEngine
            contentFlickable: tracksContentFlickable
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: palette.base

            TimelineDropArea {
                x: 0
                y: 0
                width: parent.width
                height: parent.height
                timeline: timelineContainer
                clips: clipsModel
                workspace: timelineContainer.workspace
                flickable: tracksContentFlickable
                headerWidth: 150
                z: 100
            }

            Row {
                anchors.fill: parent
                spacing: 0

                ListView {
                    id: tracksHeadersList
                    width: 150
                    height: parent.height
                    model: tracksModel
                    clip: true
                    spacing: 1
                    interactive: false
                    delegate: TimelineTrackHeader {
                        tracks: tracksModel
                        contentList: tracksContentList
                        timeline: timelineContainer
                    }
                }

                Rectangle {
                    id: trackContentArea
                    width: parent.width - 150
                    height: parent.height
                    color: palette.base
                    clip: true

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                        propagateComposedEvents: true
                        z: 0

                        onPositionChanged: function(mouse) {
                            var timeX = mouse.x + tracksContentFlickable.contentX
                            timelineContainer.mouseTimeSeconds = Math.max(0, timeX / pixelsPerSecond)
                        }

                        onExited: {
                            timelineContainer.mouseTimeSeconds = 0
                        }
                    }

                    // Click on empty timeline space deselects the transition
                    // (clips/transitions/scrollbars accept their own presses
                    // first, so this only sees genuinely empty clicks).
                    TapHandler {
                        acceptedButtons: Qt.LeftButton
                        onTapped: timelineContainer.clearTransitionSelection()
                    }

                    WheelHandler {
                        onWheel: function(event) {
                            var delta = event.angleDelta.y || event.angleDelta.x
                            if (event.modifiers & Qt.ControlModifier) {
                                if (delta > 0) zoomIn()
                                else zoomOut()
                            } else {
                                tracksContentFlickable.contentX = Math.max(0, Math.min(
                                    tracksContentFlickable.contentX - delta * 2,
                                    tracksContentFlickable.contentWidth - tracksContentFlickable.width
                                ))
                            }
                        }
                    }

                    Flickable {
                        id: tracksContentFlickable
                        anchors.fill: parent
                        contentWidth: pixelsPerSecond * totalSeconds
                        contentHeight: tracksContentList.contentHeight
                        boundsBehavior: Flickable.StopAtBounds
                        clip: true
                        interactive: false

                        // Stage 3b window triggers. Pure READERS - these
                        // never write contentX, so they do not disturb the
                        // bidirectional contentX sync with TimelineRuler's
                        // rulerFlickable (both sides of that sync are
                        // already inequality-guarded).
                        onContentXChanged: timelineContainer.scheduleRefilter()
                        onWidthChanged: timelineContainer.scheduleRefilter()

                        Rectangle {
                            x: timelineEngine ? (timelineEngine.position / 1000) * pixelsPerSecond - 1 : -1
                            width: 2
                            height: parent.height
                            color: "#ff4444"
                            z: 50
                        }

                        ListView {
                            id: tracksContentList
                            width: pixelsPerSecond * totalSeconds
                            height: parent.height
                            model: tracksModel
                            clip: false
                            spacing: 1
                            interactive: false
                            z: 1
                            delegate: Rectangle {
                                width: tracksContentList.width
                                height: 60
                                color: tracksContentList.currentIndex === index ? palette.button : palette.alternateBase
                                border.color: palette.base
                                border.width: 1
                            }
                        }

                        Rectangle {
                            id: contentContainer
                            width: pixelsPerSecond * totalSeconds
                            height: tracksModel.count * trackHeight
                            z: 10
                            color: "transparent"

                            Repeater { model: clipDM }
                            Repeater { model: transDM }
                        }
                    }

                    ScrollBar {
                        id: horizontalScrollBar
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.rightMargin: verticalScrollBar.width
                        height: 12
                        orientation: Qt.Horizontal
                        policy: ScrollBar.AlwaysOn
                        size: tracksContentFlickable.width / tracksContentFlickable.contentWidth
                        position: tracksContentFlickable.contentX / tracksContentFlickable.contentWidth
                        onPositionChanged: { if (pressed) tracksContentFlickable.contentX = position * tracksContentFlickable.contentWidth }
                    }

                    ScrollBar {
                        id: verticalScrollBar
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: horizontalScrollBar.height
                        width: 12
                        orientation: Qt.Vertical
                        policy: ScrollBar.AlwaysOn
                        size: tracksContentFlickable.height / tracksContentFlickable.contentHeight
                        position: tracksContentFlickable.contentY / tracksContentFlickable.contentHeight
                        onPositionChanged: { if (pressed) tracksContentFlickable.contentY = position * tracksContentFlickable.contentHeight }
                    }
                }
            }
        }
    }

    // A real top-level Window, not a Quick-scene Dialog/Popup. A Popup
    // centered anywhere in the main window can end up behind the
    // Project/Source Monitor's native video child window (GStreamer's
    // video-overlay embedding always composites above the whole Quick
    // scene in the window manager's stacking order) - and since panel
    // layout can change with window size, there's no single "safe" spot
    // to park a Popup that's guaranteed to never overlap the video area.
    // A genuine top-level window sidesteps the problem entirely: the
    // window manager stacks it above ALL of the app's windows (including
    // native video children) the normal way, the same as any other
    // dialog on the desktop.
    // showTimelineNotice() target: transient, non-modal, bottom center.
    Rectangle {
        id: timelineNoticeBox
        property alias text: timelineNotice.text
        z: 1000
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 24
        width: Math.min(parent.width - 32, timelineNotice.implicitWidth + 24)
        height: timelineNotice.implicitHeight + 12
        radius: 4
        color: "#d0302a24"
        border.color: "#e0a040"
        visible: timelineNotice.opacity > 0
        Label {
            id: timelineNotice
            anchors.centerIn: parent
            width: Math.min(implicitWidth, timelineNoticeBox.parent ? timelineNoticeBox.parent.width - 56 : implicitWidth)
            wrapMode: Text.WordWrap
            color: "white"
            opacity: 0
            Behavior on opacity { NumberAnimation { duration: 300 } }
        }
        Timer {
            id: timelineNoticeTimer
            interval: 5000
            onTriggered: timelineNotice.opacity = 0
        }
    }

    Window {
        id: splitBlockedWindow
        title: "Cannot split here"
        modality: Qt.ApplicationModal
        flags: Qt.Dialog
        width: 380
        height: 170
        visible: false
        color: palette.window

        property var mainWin: timelineContainer.Window.window
        transientParent: mainWin
        x: mainWin ? mainWin.x + (mainWin.width - width) / 2 : 100
        y: mainWin ? mainWin.y + (mainWin.height - height) / 2 : 100

        // Named "present" rather than "show" to avoid shadowing Window's
        // own built-in show()/raise()/requestActivate() invokable methods.
        function present() {
            visible = true
            raise()
            requestActivate()
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 12

            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: palette.windowText
                text: "The playhead is inside a transition's crossfade. Splitting there would leave the transition in a broken state.\n\nMove the playhead outside the transition, or remove the transition first."
            }

            Button {
                text: "OK"
                Layout.alignment: Qt.AlignRight
                onClicked: splitBlockedWindow.visible = false
            }
        }
    }
}
