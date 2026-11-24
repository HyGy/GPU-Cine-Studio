import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import VideoEditor 1.0
// qml6glsink spike (feature/qml6-gl-video-sink branch only) - renders
// straight into the QML scene graph instead of a native child X11 window.
// Requires GCS_TEST_API or just GCS_VIDEO_SINK=qml6glsink set when
// launching the app (see VideoEngine.cpp setupPipeline()).
import org.freedesktop.gstreamer.Qt6GLVideoItem 1.0
import "../components"

// Clip Monitor (Source Monitor)
Rectangle {
    id: sourceMonitor

    color: palette.window

    // Expose the video engine
    property alias videoEngine: clipVideoEngine

    // Leaving the workspace must not leave the clip playing (the Logging
    // workspace has its own, separate engine).
    onVisibleChanged: if (!visible) clipVideoEngine.pause()

    // Video engine for clip monitor
    VideoEngine {
        id: clipVideoEngine
        onError: function(message) {
            console.error("Clip video error:", message)
        }
        Component.onCompleted: {
            setDecoderPreference(Backend.preferredDecoder)
        }
    }

    // Connect decoder preference changes to clip VideoEngine
    Connections {
        target: Backend
        function onPreferredDecoderChanged() {
            clipVideoEngine.setDecoderPreference(Backend.preferredDecoder)
        }
    }

    // ------------------------------------------------------------------
    // Clip Information: which thing the panel describes
    //
    // The most recent selection wins. A timeline clip selection (also a
    // re-click of the already selected clip, see clipSelectionTouched)
    // sets infoMode "timeline", a bin pick sets "bin". With no timeline
    // selection the panel falls back to the last bin item.
    // ------------------------------------------------------------------
    property var timelinePanel: null
    property var timelineEngine: null
    property var formatTimecode: null
    property string infoMode: "bin"
    // Collapsed: only the header bar stays; app-wide (QSettings, like
    // monitor/showCanvasFrame), not per project.
    property bool infoCollapsed: {
        var v = Backend.getSetting("monitor/clipInfoCollapsed", false)
        return v === true || String(v) === "true"
    }
    // Height of the expanded box (px), app-wide like the collapsed flag.
    property int infoHeight: {
        var v = parseInt(Backend.getSetting("monitor/clipInfoHeight", 150))
        return v > 0 ? v : 150
    }
    readonly property int barH: 8
    readonly property int infoMinH: 60
    readonly property int videoMinH: 110
    // Largest box height that leaves the video area its minimum
    // (header 25 + controls 40 + bar + video min + 8 px of net spacing).
    readonly property real infoMaxH: Math.max(infoMinH, monCol.height - (25 + 40 + barH + videoMinH + 8))
    readonly property int infoShownH: Math.round(Math.max(infoMinH, Math.min(infoHeight, infoMaxH)))
    function setInfoCollapsed(c) {
        infoCollapsed = c
        Backend.setSetting("monitor/clipInfoCollapsed", c)
    }
    // One-line description shown in the collapsed header.
    readonly property string infoSummary: {
        var _ = binRev
        if (showingTimeline) return info.summary
        var id = Backend.selectedProjectBinItemId
        if (id === "") return ""
        var f = fileRow(clipVideoEngine.currentFile).v
        return [f, binValue(id, ProjectBinModel.ResolutionRole), binValue(id, ProjectBinModel.DurationRole)].join(" \u00b7 ")
    }
    // Description of the selected timeline clip (see recomputeInfo()), or
    // null. Only maintained while infoMode is "timeline"; rebuilt (coalesced)
    // from the model's change signals, never from the playhead.
    property var info: null
    property int binRev: 0
    readonly property int infoFont: 10

    readonly property bool showingTimeline: infoMode === "timeline" && info !== null
    readonly property bool noSelection: !showingTimeline && Backend.selectedProjectBinItemId === ""
    readonly property int extraSelected: (timelinePanel && timelinePanel.selectedClipIds)
        ? Math.max(0, timelinePanel.selectedClipIds.length - 1) : 0
    readonly property string infoTitle: showingTimeline
        ? "Clip Information - Timeline (" + info.track + ")" : "Clip Information - Project Bin"
    readonly property var sections: showingTimeline ? info.sections : binSections
    readonly property var binSections: {
        var _ = binRev
        if (showingTimeline) return []
        return [{ title: "", rows: binRows(Backend.selectedProjectBinItemId) }]
    }

    readonly property var effectLabels: ({
        colorbalance: "Color Balance", gamma: "Gamma", lut3d: "3D LUT", imageoverlay: "Image Overlay",
        colorkey: "Chroma Key", transform: "Position/Zoom", fade: "Fade", brightness: "Brightness",
        contrast: "Contrast", volume: "Volume", curves: "Curves"
    })

    function showBinInfo() {
        infoMode = "bin"
        info = null
    }

    function scheduleRecompute() {
        if (infoMode === "timeline" && !infoTimer.running) infoTimer.start()
    }
    Timer { id: infoTimer; interval: 50; onTriggered: sourceMonitor.recomputeInfo() }

    Connections {
        target: sourceMonitor.timelinePanel
        ignoreUnknownSignals: true
        function onSelectedClipIdChanged() {
            if (sourceMonitor.timelinePanel.selectedClipId !== "") sourceMonitor.infoMode = "timeline"
            sourceMonitor.recomputeInfo()
        }
        function onClipSelectionTouched() {
            if (sourceMonitor.timelinePanel.selectedClipId === "") return
            sourceMonitor.infoMode = "timeline"
            sourceMonitor.recomputeInfo()
        }
        function onEffectsRevisionChanged() { sourceMonitor.scheduleRecompute() }
        function onTitleParamsRevisionChanged() { sourceMonitor.scheduleRecompute() }
    }
    Connections {
        target: sourceMonitor.timelinePanel ? sourceMonitor.timelinePanel.clipsModel : null
        ignoreUnknownSignals: true
        function onDataChanged() { sourceMonitor.scheduleRecompute() }
        function onRowsInserted() { sourceMonitor.scheduleRecompute() }
        function onRowsRemoved() { sourceMonitor.scheduleRecompute() }
        function onRowsMoved() { sourceMonitor.scheduleRecompute() }
        function onModelReset() { sourceMonitor.scheduleRecompute() }
    }
    Connections {
        target: Backend
        function onSelectedProjectBinItemIdChanged(itemId) { if (itemId !== "") sourceMonitor.showBinInfo() }
        function onProxyInstallationChanged() { sourceMonitor.scheduleRecompute() }
    }
    Connections {
        target: Backend.cacheManager
        ignoreUnknownSignals: true
        function onProxyReady() { sourceMonitor.scheduleRecompute() }
    }
    Connections {
        target: Backend.projectBinModel
        ignoreUnknownSignals: true
        function onDataChanged() { sourceMonitor.binRev++; sourceMonitor.scheduleRecompute() }
        function onModelReset() { sourceMonitor.binRev++; sourceMonitor.scheduleRecompute() }
    }
    Connections {
        target: sourceMonitor.timelineEngine
        ignoreUnknownSignals: true
        function onReloadingAssetsChanged() { sourceMonitor.scheduleRecompute() }
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    function binValue(itemId, role) {
        if (!itemId) return "-"
        var idx = Backend.projectBinModel.indexFromItemId(itemId)
        if (!idx.valid) return "-"
        var value = Backend.projectBinModel.data(idx, role)
        return value || "-"
    }

    // "HH:MM:SS.cc" (MetadataExtractor::formatDuration) -> seconds, -1 if unknown.
    function parseDurationSec(s) {
        var m = /^(\d+):(\d+):(\d+)(?:[.,](\d+))?$/.exec(String(s))
        if (!m) return -1
        var frac = m[4] ? parseFloat("0." + m[4]) : 0
        return parseInt(m[1]) * 3600 + parseInt(m[2]) * 60 + parseInt(m[3]) + frac
    }

    // The project's (30-frame based) timecode, as the monitor and timeline
    // show it; +0.5 ms so a value sitting exactly on a frame boundary is not
    // floored into the previous frame by floating point noise.
    function tc(sec) {
        if (!formatTimecode) return sec.toFixed(2) + " s"
        return formatTimecode(Math.max(0, sec) * 1000 + 0.5)
    }
    function tcSec(sec) { return tc(sec) + " (" + sec.toFixed(1) + " s)" }

    function localPath(p) {
        var s = String(p || "")
        if (s.indexOf("file://") === 0) {
            s = s.substring(7)
            try { s = decodeURIComponent(s) } catch (e) {}
        }
        return s
    }
    function fileRow(p) {
        var f = localPath(p)
        if (!f) return { l: "File:", v: "-", elide: true }
        var i = f.lastIndexOf("/")
        return { l: "File:", v: f.substring(i + 1), sub: i >= 0 ? f.substring(0, i) : "", elide: true }
    }

    // Bin mode: exactly the rows the panel always showed.
    function binRows(itemId) {
        var R = ProjectBinModel
        return [
            fileRow(clipVideoEngine.currentFile),
            { l: "Duration:", v: binValue(itemId, R.DurationRole) },
            { l: "Resolution:", v: binValue(itemId, R.ResolutionRole) },
            { l: "Frame Rate:", v: binValue(itemId, R.FrameRateRole) },
            { l: "Aspect Ratio:", v: binValue(itemId, R.AspectRatioRole) },
            { l: "Video Codec:", v: binValue(itemId, R.VideoCodecRole) },
            { l: "Audio Codec:", v: binValue(itemId, R.AudioCodecRole) },
            { l: "Bitrate:", v: binValue(itemId, R.BitrateRole) },
            { l: "Encoder:", v: binValue(itemId, R.EncoderRole) },
            { l: "Creation Time:", v: binValue(itemId, R.CreationTimeRole) }
        ]
    }

    // Which variant preview uses for this item: the project-wide active
    // proxy setting plus this item's own status for it (the same inputs
    // BackendManager::computeProxyStep() uses to decide what to install).
    function proxyText(itemId) {
        var en = String(Backend.getSetting("project/proxyEnabled", false)) === "true"
        var res = String(Backend.getSetting("project/proxyActiveResolution", "Original (no proxy)"))
        var fmt = String(Backend.getSetting("project/proxyFormat", "h264_intra"))
        if (!en || res === "" || res === "Original (no proxy)") return "Original"
        var cm = Backend.cacheManager
        var st = cm ? cm.getProxyStatus(itemId, res, fmt) : "none"
        if (st === "ready") return res + " (in use)"
        if (st === "generating" || st === "pending") return "Original (" + res + " " + st + ")"
        return "not available (Original used)"
    }

    function transitionLabel(nick) {
        var list = timelinePanel.availableTransitionTypes || []
        for (var i = 0; i < list.length; i++) if (list[i].nick === nick) return list[i].label
        return nick || "Dissolve"
    }

    // Builds `info` for the selected timeline clip (or null).
    function recomputeInfo() {
        var tp = timelinePanel
        if (infoMode !== "timeline" || !tp || tp.selectedClipId === "") { info = null; return }
        var m = tp.clipsModel
        var row = tp.findClipRowById(tp.selectedClipId)
        if (row < 0) { info = null; return }
        var c = m.get(row)
        var cid = c.clipId
        var pm = Backend.projectBinModel
        var isTitle = (c.clipKind || "") === "title"
        var srcId = c.sourceItemId || ""
        var key = srcId !== "" ? srcId : (c.itemPath || "")
        var st = c.startTime, dur = c.durationSeconds, off = c.sourceOffset || 0
        var binIdx = srcId !== "" ? pm.indexFromItemId(srcId) : null
        var binOk = !!binIdx && binIdx.valid
        var itemType = binOk ? pm.data(binIdx, ProjectBinModel.TypeRole) : ""
        var isImage = itemType === "image"
        var audioOnly = !c.hasVideo && c.hasAudio && !isTitle
        var total = (binOk && !isTitle && !isImage)
            ? parseDurationSec(pm.data(binIdx, ProjectBinModel.DurationRole)) : -1
        var linkedId = c.linkedClipId || ""

        // one pass: link partner, transitions, other uses of the same source
        var partnerTrack = "", tIn = null, tOut = null, cands = []
        for (var i = 0; i < m.count; i++) {
            var o = m.get(i)
            var oid = o.clipId
            if (!oid) continue
            if (linkedId !== "" && oid === linkedId) partnerTrack = o.trackId
            if (o.hasTransition && o.transitionOriginalBId === cid && o.transitionDuration > 0)
                tIn = { type: o.transitionType, d: o.transitionDuration }
            if (total > 0 && (o.clipKind || "") !== "title") {
                var ok = (o.sourceItemId || "") !== "" ? o.sourceItemId : (o.itemPath || "")
                if (ok === key) {
                    var os = o.sourceOffset || 0
                    cands.push({ id: oid, link: o.linkedClipId || "", hv: !!o.hasVideo,
                                 s: os, e: os + o.durationSeconds, ts: o.startTime })
                }
            }
        }
        if (c.hasTransition && c.transitionDuration > 0) tOut = { type: c.transitionType, d: c.transitionDuration }

        // usage of the source: this clip + others, linked A/V pairs counted once
        var usage = [], others = []
        if (total > 0) {
            usage.push({ s: off, e: Math.min(total, off + dur), self: true })
            for (var k = 0; k < cands.length; k++) {
                var q = cands[k]
                if (q.id === cid || q.id === linkedId) continue
                if (!q.hv && q.link !== "") {
                    var partnerIsVideo = false
                    for (var j = 0; j < cands.length; j++)
                        if (cands[j].id === q.link && cands[j].hv) { partnerIsVideo = true; break }
                    if (partnerIsVideo) continue
                }
                usage.push({ s: q.s, e: Math.min(total, q.e), self: false })
                others.push(q)
            }
        }
        var usageTip = ""
        if (total > 0) {
            usageTip = "Source length " + tc(total) + "\nThis clip: " + tc(off) + " - " + tc(off + dur)
            if (others.length === 0) usageTip += "\nNo other use of this source on the timeline"
            else {
                usageTip += "\nOther uses (" + others.length + "):"
                for (var u = 0; u < others.length && u < 12; u++)
                    usageTip += "\n  " + tc(others[u].s) + " - " + tc(others[u].e) + "  (at " + tc(others[u].ts) + ")"
                if (others.length > 12) usageTip += "\n  ... " + (others.length - 12) + " more"
            }
        }

        // ---- effects
        var fxs = []
        try { var raw = c.effects || ""; if (raw !== "" && raw !== "[]") fxs = JSON.parse(raw) } catch (e) {}
        var fxNames = []
        for (var f = 0; f < fxs.length; f++)
            fxNames.push((effectLabels[fxs[f].type] || fxs[f].type) + (fxs[f].enabled === false ? " (off)" : ""))
        var fxText = fxs.length === 0 ? "None" : (fxs.length + ": " + fxNames.join(", "))

        // ---- rows
        var R = ProjectBinModel
        var sections = []
        if (isTitle) {
            var txt = ""
            try { var tpar = JSON.parse(c.titleParams || "{}"); txt = String(tpar.text || "") } catch (e2) {}
            txt = txt.replace(/\s*\n\s*/g, " / ")
            if (txt.length > 60) txt = txt.substring(0, 57) + "..."
            sections.push({ title: "Title clip", rows: txt !== "" ? [{ l: "Text:", v: txt }] : [] })
        } else {
            var rows = [fileRow(c.itemPath)]
            if (!isImage) rows.push({ l: "Duration:", v: binValue(srcId, R.DurationRole) })
            else rows.push({ l: "Duration:", v: "Still image" })
            if (!audioOnly) {
                rows.push({ l: "Resolution:", v: binValue(srcId, R.ResolutionRole) })
                if (!isImage) rows.push({ l: "Frame Rate:", v: binValue(srcId, R.FrameRateRole) })
                rows.push({ l: "Aspect Ratio:", v: binValue(srcId, R.AspectRatioRole) })
                if (!isImage) rows.push({ l: "Video Codec:", v: binValue(srcId, R.VideoCodecRole) })
            }
            if (!isImage) rows.push({ l: "Audio Codec:", v: binValue(srcId, R.AudioCodecRole) })
            rows.push({ l: "Bitrate:", v: binValue(srcId, R.BitrateRole) })
            rows.push({ l: "Encoder:", v: binValue(srcId, R.EncoderRole) })
            rows.push({ l: "Creation Time:", v: binValue(srcId, R.CreationTimeRole) })
            if (!audioOnly && !isImage && binOk) rows.push({ l: "Proxy:", v: proxyText(srcId) })
            sections.push({ title: "Source", rows: rows })
        }

        var trows = []
        var trackText = c.trackId + (linkedId !== "" && partnerTrack !== "" ? "  (linked to " + partnerTrack + ")" : "")
        trows.push({ l: "Track:", v: trackText })
        trows.push({ l: "Position:", v: tc(st) + " - " + tc(st + dur) })
        trows.push({ l: "Length:", v: tcSec(dur) })
        if (!isTitle) {
            if (isImage) trows.push({ l: "Used part:", v: "Still image (no length limit)" })
            else if (total > 0) {
                trows.push({ l: "Used part:", v: tc(off) + " - " + tc(off + dur) + " of " + tc(total), bar: true })
                var after = Math.max(0, total - (off + dur))
                trows.push({ l: "Handles:", v: tcSec(off) + " before, " + tcSec(after) + " after" })
            } else trows.push({ l: "Used part:", v: tc(off) + " - " + tc(off + dur) + " of -" })
        }
        trows.push({ l: "Effects:", v: fxText })
        var trText = []
        if (tIn) trText.push("In: " + transitionLabel(tIn.type) + ", " + tIn.d.toFixed(1) + " s")
        if (tOut) trText.push("Out: " + transitionLabel(tOut.type) + ", " + tOut.d.toFixed(1) + " s")
        if (trText.length) trows.push({ l: "Transition:", v: trText.join("; ") })
        if (c.mediaMissing) trows.push({ l: "Warning:", v: "Source media file is missing", warn: true })
        sections.push({ title: "On timeline", rows: trows })

        function shortTc(v) { return tc(v).replace(/^00:00:/, "").replace(/^00:/, "") }
        var base = isTitle ? "Title" : localPath(c.itemPath).split("/").pop()
        var summary = base + " \u00b7 " + tc(st) + "-" + tc(st + dur)
        if (!isTitle && !isImage) summary += " \u00b7 used " + shortTc(off) + "-" + shortTc(off + dur)
        info = { summary: summary, track: c.trackId, start: st, end: st + dur, off: off, total: total,
                 usage: usage, usageTip: usageTip, sections: sections }
    }

    ColumnLayout {
        id: monCol
        anchors.fill: parent
        anchors.margins: 5
        spacing: 5

        // Header
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 25
            color: palette.button

            Text {
                anchors.centerIn: parent
                text: "Clip Monitor"
                color: "white"
                font.pixelSize: 12
            }
        }

        // Video display area
        Rectangle {
            id: videoArea
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "black"

            // qml6glsink spike: GstGLQt6VideoItem renders directly into
            // the QML scene graph - no native child window, no
            // GstVideoOverlay window-handle plumbing. Launch the app with
            // GCS_VIDEO_SINK=qml6glsink for this to actually take effect
            // (VideoEngine.cpp's setupPipeline() gates on that env var;
            // without it this item just sits here unused and VideoEngine
            // falls back to its normal xvimagesink/ximagesink path, which
            // has no QML item to render into and shows nothing here).
            GstGLQt6VideoItem {
                id: clipGLVideoItem
                anchors.fill: parent
                visible: clipVideoEngine.glVideoSink
                // itemInitialized only goes true once this item has a live
                // GL context (strictly later than Component.onCompleted) -
                // qml6glsink's NULL->READY transition fails outright if
                // wired up before that.
                onItemInitializedChanged: {
                    if (itemInitialized) clipVideoEngine.setGLVideoItem(clipGLVideoItem)
                }
                Component.onCompleted: {
                    if (itemInitialized) clipVideoEngine.setGLVideoItem(clipGLVideoItem)
                }
            }

            VideoUnavailableOverlay {
                glItem: clipGLVideoItem
                monitored: clipVideoEngine.glVideoSink
            }

            Text {
                anchors.centerIn: parent
                text: clipVideoEngine.currentFile ? "" : "No clip loaded"
                color: "#888888"
                z: 1
            }
        }

        // Playback controls for clip monitor
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            color: palette.window

            Row {
                anchors.centerIn: parent
                spacing: 10

                Button {
                    text: "⏮"
                    width: 35
                    height: 35
                    font.pixelSize: 14
                    enabled: clipVideoEngine.currentFile
                    onClicked: clipVideoEngine.seek(0)
                }

                Button {
                    text: clipVideoEngine.playing ? "⏸" : "▶"
                    width: 35
                    height: 35
                    font.pixelSize: 14
                    enabled: clipVideoEngine.currentFile || Backend.selectedProjectBinItemId !== ""
                    onClicked: {
                        if (clipVideoEngine.playing) {
                            clipVideoEngine.pause()
                        } else if (clipVideoEngine.currentFile) {
                            clipVideoEngine.play()
                        } else if (Backend.selectedProjectBinItemId !== "") {
                            // Nothing loaded yet - a bin item is only
                            // selected (single click), not loaded
                            // (that's double-click's job). Pressing
                            // Play should load AND start it in one step.
                            var idx = Backend.projectBinModel.indexFromItemId(Backend.selectedProjectBinItemId)
                            if (idx.valid) {
                                var path = Backend.projectBinModel.data(idx, ProjectBinModel.PathRole)
                                if (path) clipVideoEngine.loadVideo(path)
                            }
                        }
                    }
                }

                Button {
                    text: "⏹"
                    width: 35
                    height: 35
                    font.pixelSize: 14
                    enabled: clipVideoEngine.currentFile
                    onClicked: clipVideoEngine.stop()
                }
            }
        }

        // Splitter bar above the info box (ExtJS "mini" collapse): drag to
        // resize the box, tab in the middle collapses/expands it. Items
        // never take keyboard focus.
        Rectangle {
            id: infoBar
            Layout.fillWidth: true
            Layout.preferredHeight: sourceMonitor.barH
            Layout.topMargin: -5
            z: 2
            color: barDrag.containsMouse || barDrag.pressed ? "#4a5056" : "#383d42"
            border.color: "#1d1d1d"
            border.width: 1

            MouseArea {
                id: barDrag
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.SizeVerCursor
                preventStealing: true
                property real pressY: 0
                property real grabOff: 0
                property bool moved: false
                function curY(mouse) { return mapToItem(sourceMonitor, mouse.x, mouse.y).y }
                onPressed: function(mouse) {
                    pressY = curY(mouse)
                    grabOff = pressY - infoBar.mapToItem(sourceMonitor, 0, 0).y
                    moved = false
                }
                onPositionChanged: function(mouse) {
                    if (!pressed) return
                    var y = curY(mouse)
                    if (!moved && Math.abs(y - pressY) < 3) return
                    // from the collapsed state only an upward drag opens the box
                    if (!moved && sourceMonitor.infoCollapsed && y > pressY) return
                    moved = true
                    // box height from the pointer: bar top = pointer - grab offset,
                    // the box starts 5 px below it and ends at the column bottom
                    var colBottom = monCol.y + monCol.height
                    var h = Math.round(Math.max(sourceMonitor.infoMinH,
                                Math.min(sourceMonitor.infoMaxH, colBottom - (y - grabOff) - 5)))
                    if (sourceMonitor.infoCollapsed) sourceMonitor.infoCollapsed = false
                    sourceMonitor.infoHeight = h
                }
                onReleased: {
                    if (moved) {
                        Backend.setSetting("monitor/clipInfoHeight", sourceMonitor.infoHeight)
                        Backend.setSetting("monitor/clipInfoCollapsed", sourceMonitor.infoCollapsed)
                    }
                }
            }

            Rectangle {
                id: infoTab
                anchors.centerIn: parent
                width: 40
                height: sourceMonitor.barH
                radius: 2
                color: tabMouse.containsMouse ? "#6b7380" : "#555b62"
                Text {
                    anchors.centerIn: parent
                    text: sourceMonitor.infoCollapsed ? "\u25b2" : "\u25bc"
                    color: tabMouse.containsMouse ? "white" : "#c8ccd0"
                    font.pixelSize: 6
                }
                MouseArea {
                    id: tabMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    Accessible.role: Accessible.Button
                    Accessible.name: sourceMonitor.infoCollapsed ? "Expand Clip Information" : "Collapse Clip Information"
                    Accessible.onPressAction: sourceMonitor.setInfoCollapsed(!sourceMonitor.infoCollapsed)
                    onClicked: sourceMonitor.setInfoCollapsed(!sourceMonitor.infoCollapsed)
                }
            }
        }

        // Collapsed: one-line title + summary under the bar.
        Rectangle {
            visible: sourceMonitor.infoCollapsed
            Layout.fillWidth: true
            Layout.preferredHeight: 20
            color: palette.base
            border.color: palette.button
            border.width: 1
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                spacing: 8
                Text {
                    Layout.maximumWidth: sourceMonitor.width * 0.5
                    text: sourceMonitor.infoTitle
                    color: "#4a9eff"; font.pixelSize: 11; font.bold: true
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    text: sourceMonitor.infoSummary
                    color: "#aaaaaa"; font.pixelSize: 10
                    elide: Text.ElideRight
                }
            }
        }

        // Clip Information Panel - describes the most recently selected
        // thing: a timeline clip (infoMode "timeline") or a project bin item
        // ("bin"). See recomputeInfo() / binRows() above.
        Rectangle {
            Layout.fillWidth: true
            visible: !sourceMonitor.infoCollapsed
            Layout.preferredHeight: sourceMonitor.infoShownH
            Layout.minimumHeight: sourceMonitor.infoMinH
            // the bar sits in the old 5 px gap; the box starts under it
            Layout.topMargin: -sourceMonitor.barH
            color: palette.base
            border.color: palette.button
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 4

                RowLayout {
                    id: infoHeader
                    Layout.fillWidth: true
                    spacing: 6
                    Text {
                        Layout.fillWidth: true
                        text: sourceMonitor.infoTitle
                        color: "#4a9eff"
                        font.pixelSize: 11
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    Text {
                        visible: sourceMonitor.showingTimeline && sourceMonitor.extraSelected > 0
                        text: "+" + sourceMonitor.extraSelected + " more selected"
                        color: "#f0b030"
                        font.pixelSize: 10
                    }
                }

                ScrollView {
                    id: infoScroll
                    visible: !sourceMonitor.infoCollapsed
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    // The bar overlays the content: reserve its width so it
                    // never covers text.
                    readonly property real contentW: availableWidth - 14
                    contentWidth: contentW
                    ScrollBar.vertical: ScrollBar {
                        id: infoVBar
                        policy: ScrollBar.AlwaysOn
                        parent: infoScroll
                        x: infoScroll.width - width
                        y: 0
                        width: 12
                        height: infoScroll.height
                        contentItem: Rectangle {
                            implicitWidth: 12
                            radius: 4
                            color: infoVBar.pressed ? "#9aa0a6" : "#6b7075"
                        }
                        background: Rectangle { color: "#1c1f22" }
                    }

                    // Source and timeline blocks side by side when the
                    // monitor is wide enough, stacked otherwise.
                    GridLayout {
                        width: infoScroll.contentW
                        columns: infoScroll.contentW >= 560 ? 2 : 1
                        columnSpacing: 20
                        rowSpacing: 3

                        Text {
                            visible: sourceMonitor.noSelection
                            text: "No clip selected"
                            color: "#888888"; font.pixelSize: sourceMonitor.infoFont
                        }

                        Repeater {
                            // stacked: the timeline block (the specific info) goes first
                            model: sourceMonitor.noSelection ? [] : (infoScroll.contentW >= 560 ? sourceMonitor.sections : sourceMonitor.sections.slice().reverse())
                            delegate: ColumnLayout {
                                id: secDelegate
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.preferredWidth: 1
                                Layout.alignment: Qt.AlignTop
                                spacing: 3

                                Text {
                                    visible: !!secDelegate.modelData.title
                                    text: secDelegate.modelData.title || ""
                                    color: "#7aa7d9"; font.pixelSize: sourceMonitor.infoFont; font.bold: true
                                }

                                Repeater {
                                    model: secDelegate.modelData.rows
                                    delegate: ColumnLayout {
                                        id: rowDelegate
                                        required property var modelData
                                        Layout.fillWidth: true
                                        spacing: 2

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 10
                                            Text {
                                                Layout.preferredWidth: 88
                                                Layout.alignment: Qt.AlignTop
                                                text: rowDelegate.modelData.l
                                                color: "#aaaaaa"; font.pixelSize: sourceMonitor.infoFont
                                            }
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 0
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: rowDelegate.modelData.v
                                                    color: rowDelegate.modelData.warn ? "#ff6060" : "white"
                                                    font.pixelSize: sourceMonitor.infoFont; font.bold: true
                                                    elide: rowDelegate.modelData.elide ? Text.ElideMiddle : Text.ElideNone
                                                    wrapMode: rowDelegate.modelData.elide ? Text.NoWrap : Text.Wrap
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    visible: !!rowDelegate.modelData.sub
                                                    text: rowDelegate.modelData.sub || ""
                                                    color: "#888888"; font.pixelSize: sourceMonitor.infoFont + 1
                                                    wrapMode: Text.WrapAnywhere
                                                }
                                            }
                                        }

                                        // Usage bar: the whole source; this clip's used range
                                        // highlighted, other uses of the source fainter, a 1 px
                                        // marker for the playhead. Display only.
                                        Item {
                                            id: usageBar
                                            visible: !!rowDelegate.modelData.bar
                                            Layout.fillWidth: true
                                            Layout.leftMargin: 98
                                            Layout.preferredHeight: 9
                                            readonly property var inf: sourceMonitor.info
                                            readonly property real tpos: sourceMonitor.timelineEngine
                                                ? sourceMonitor.timelineEngine.position / 1000.0 : -1

                                            Rectangle { anchors.fill: parent; color: "#2a2a2a"; border.color: "#444444"; border.width: 1 }
                                            Repeater {
                                                model: usageBar.visible && usageBar.inf ? usageBar.inf.usage : []
                                                delegate: Rectangle {
                                                    required property var modelData
                                                    readonly property real tot: usageBar.inf ? usageBar.inf.total : 1
                                                    x: Math.max(0, Math.min(usageBar.width - 2, modelData.s / tot * usageBar.width))
                                                    width: Math.max(2, Math.min(usageBar.width - x, (modelData.e - modelData.s) / tot * usageBar.width))
                                                    height: parent.height
                                                    color: modelData.self ? "#4a9eff" : "#4a9eff"
                                                    opacity: modelData.self ? 1.0 : 0.3
                                                    z: modelData.self ? 1 : 0
                                                }
                                            }
                                            Rectangle {
                                                // playhead inside this clip -> source position
                                                readonly property bool inside: usageBar.inf !== null && usageBar.inf.total > 0
                                                    && usageBar.tpos >= usageBar.inf.start && usageBar.tpos < usageBar.inf.end
                                                visible: usageBar.visible && inside
                                                width: 1; height: parent.height + 4; y: -2; z: 2
                                                color: "white"
                                                x: inside ? Math.max(0, Math.min(usageBar.width - 1,
                                                    (usageBar.inf.off + usageBar.tpos - usageBar.inf.start) / usageBar.inf.total * usageBar.width)) : 0
                                            }
                                            HoverHandler { id: usageHover }
                                            ToolTip.visible: usageHover.hovered && usageBar.inf !== null
                                            ToolTip.delay: 300
                                            ToolTip.text: usageBar.inf ? usageBar.inf.usageTip : ""
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
