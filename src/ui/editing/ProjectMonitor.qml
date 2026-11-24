import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import VideoEditor 1.0
// qml6glsink spike (feature/qml6-gl-video-sink branch only) - renders
// straight into the QML scene graph instead of a native child X11 window.
// Only takes effect when timelineEngine.glVideoSink is true (gated on
// GCS_VIDEO_SINK=qml6glsink in TimelineEngine.cpp) - see Qml6GLSink.h.
import org.freedesktop.gstreamer.Qt6GLVideoItem 1.0
import "../components"

// Project Monitor (Timeline Preview)
Rectangle {
    id: projectMonitor

    width: parent ? parent.width / 2 - 1 : 400
    height: parent ? parent.height : 600
    color: palette.window

    // Properties
    property var timelineEngine: null
    property var formatTimecode: null
    property var updateTimelineEngine: null
    // The EditingWorkspace root item - used to hand keyboard focus back
    // to it (and thus to the timeline's own shortcuts) after a control
    // inside this panel grabs it (see previewScaleCombo.onActivated).
    property var workspace: null
    // Size of the video item (the monitor's "chrome" is panel size minus this).
    readonly property real videoAreaWidth: timelineGLVideoItem.width
    readonly property real videoAreaHeight: timelineGLVideoItem.height
    // Base size of the "Monitor size" combo, in physical pixels. Width: the
    // active proxy's width; with no proxy active, the smallest available
    // proxy resolution's width; with no proxies at all, 960. So the entries
    // are the same whether or not a proxy is active. Never wider than the
    // canvas; height always follows the canvas aspect.
    readonly property var sizeBase: {
        var te = projectMonitor.timelineEngine
        var cw = te ? te.canvasWidth : 0
        var ch = te ? te.canvasHeight : 0
        if (cw <= 0 || ch <= 0) return null
        var re = /^(\d+)x(\d+)$/
        var m = re.exec(activeProxyCombo.currentText)
        var bw = 0
        var isProxy = false
        if (m) {
            bw = parseInt(m[1]); isProxy = true
        } else {
            var list = activeProxyCombo.model
            for (var i = 0; list && i < list.length; i++) {
                var mm = re.exec(String(list[i]))
                if (mm && (bw === 0 || parseInt(mm[1]) < bw)) bw = parseInt(mm[1])
            }
            isProxy = bw > 0
            if (bw <= 0) bw = 960
        }
        bw = Math.min(bw, cw)
        return { proxy: isProxy, active: !!m, w: bw, h: Math.floor(bw * ch / cw) & ~1 }
    }
    // Entries: percentages of the base (above 100% too - a proxy is always
    // smaller than the display), even-rounded like the rest of the code,
    // plus "Max", which the workspace resolves (largest picture the window
    // allows, all minimums respected).
    readonly property var sizeEntries: {
        var b = projectMonitor.sizeBase
        var out = []
        if (b) {
            var pcts = [50, 75, 100, 125, 150, 175, 200, 250, 300, 400]
            for (var i = 0; i < pcts.length; i++) {
                var w = Math.floor(b.w * pcts[i] / 100) & ~1
                var h = Math.floor(b.h * pcts[i] / 100) & ~1
                out.push({ key: String(pcts[i]), label: pcts[i] + "% (" + w + "\u00d7" + h + ")", w: w, h: h })
            }
        }
        out.push({ key: "max", label: "Max", w: 0, h: 0 })
        return out
    }
    // Key of the entry the user picked last ("" = nothing chosen yet).
    property string chosenKey: ""
    // Resize the editing layout so the picture has the entry's size (in
    // logical px: physical / devicePixelRatio). See
    // EditingWorkspace.fitProjectMonitorTo(). Delivered frames are always
    // canvas (or canvas / preview-scale) sized, so this only moves panes.
    function applySizeEntry(entry) {
        var te = projectMonitor.timelineEngine
        if (!workspace || !te || te.canvasWidth <= 0 || te.canvasHeight <= 0) return
        var dpr = Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
        var w = entry.w, h = entry.h
        if (entry.key === "max") {
            // Far larger than any window: fitProjectMonitorTo() scales the
            // target down (canvas aspect kept) to the largest that fits.
            w = 100000
            h = 100000 * te.canvasHeight / te.canvasWidth
        }
        else {
            // Labels are even-rounded; give the video item the exact canvas
            // aspect height (rounded up) so the picture gets exactly the
            // labelled width.
            h = Math.ceil(w * te.canvasHeight / te.canvasWidth)
        }
        workspace.fitProjectMonitorTo(w / dpr, h / dpr)
    }
    // Outline around the project canvas (GL sink path only). QSettings may
    // hand back the strings "true"/"false", so convert explicitly.
    property bool showCanvasFrame: {
        var v = Backend.getSetting("monitor/showCanvasFrame", false)
        return v === true || String(v) === "true"
    }

    // Function to toggle play/pause (can be called from parent)
    function togglePlayPause() {
        playPauseButton.clicked()
    }

    // Called by EditingWorkspace.loadProjectJSON() after every project
    // load - see the call site's own comment for why activeProxyRow's
    // live signal-driven refresh alone isn't enough.
    function refreshActiveProxyModel() {
        activeProxyRow.refreshModel()
    }

    // Re-reads the monitor/showCanvasFrame setting (app-wide view
    // preference). Called after Project Settings' OK, since the checkbox
    // now lives there (plan_home_end_canvasframe.md).
    function refreshCanvasFrameSetting() {
        var v = Backend.getSetting("monitor/showCanvasFrame", false)
        showCanvasFrame = (v === true || String(v) === "true")
    }

    // The real handler of the "Active proxy" combo (also called directly by
    // the UI tests, which cannot operate the popup under Xephyr). Switching
    // which ALREADY-generated set preview uses never prompts and never
    // cancels anything queued (proxy_build_plan.md J.3.5). Shows the
    // window-wide blocking overlay (main.qml beginProxySwitch) first; the
    // setting write + install/uninstall run after it has been painted.
    function switchActiveProxy(resolution) {
        if (resolution === Backend.getSetting("project/proxyActiveResolution", "Original (no proxy)")) {
            console.log("ProxySwitch: '" + resolution + "' is already active - nothing to do")
            return
        }
        var win = Window.window
        var label = resolution === "Original (no proxy)"
            ? "Switching to original media\u2026" : "Switching proxy to " + resolution + "\u2026"
        win.beginProxySwitch(label, function() {
            Backend.setSetting("project/proxyActiveResolution", resolution)
            return Backend.refreshProxyInstallations()
        })
    }

    ColumnLayout {
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
                text: "Project Monitor"
                color: "white"
                font.pixelSize: 12
                // Not enough room next to the size combo when narrow.
                visible: parent.width >= 440
            }

            // Editing layout only: size the monitor so the picture has a
            // chosen size. Lives in the header (not the control row) so it
            // stays reachable when the monitor is dragged narrow and the
            // control rows overlap.
            ComboBox {
                id: sizeCombo
                anchors.right: parent.right
                anchors.rightMargin: 3
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(165, parent.width - 6)
                height: 22
                font.pixelSize: 11
                visible: projectMonitor.workspace && projectMonitor.workspace.layoutMode === "editing"
                model: projectMonitor.sizeEntries
                textRole: "label"
                displayText: {
                    var e = projectMonitor.sizeEntries
                    for (var i = 0; i < e.length; i++)
                        if (e[i].key === projectMonitor.chosenKey) return e[i].label
                    return "Size"
                }
                Accessible.role: Accessible.ComboBox
                Accessible.name: "Monitor size"
                ToolTip.visible: hovered && !popup.visible
                ToolTip.text: !projectMonitor.sizeBase ? "Resize the monitor so the picture has this size"
                    : "Picture size relative to " + projectMonitor.sizeBase.w + "\u00d7" + projectMonitor.sizeBase.h
                      + (projectMonitor.sizeBase.active ? " (active proxy size)"
                         : projectMonitor.sizeBase.proxy ? " (proxy size)" : " (default base)")

                onActivated: function(index) {
                    var e = projectMonitor.sizeEntries[index]
                    if (!e) return
                    projectMonitor.chosenKey = e.key
                    projectMonitor.applySizeEntry(e)
                    // Same reason as previewScaleCombo: hand focus back so
                    // Space etc. keep working.
                    if (projectMonitor.workspace) projectMonitor.workspace.forceActiveFocus()
                }
            }
        }

        // Video display area
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "black"

            Component.onCompleted: {
                console.log("Timeline Preview Rectangle created, size:", width, "x", height)
            }

            // qml6glsink spike: GstGLQt6VideoItem renders directly into
            // the QML scene graph - no native child window, no
            // GstVideoOverlay window-handle plumbing. Only active when
            // timelineEngine.glVideoSink is true.
            GstGLQt6VideoItem {
                id: timelineGLVideoItem
                anchors.fill: parent
                // Room for the canvas outline outside the picture.
                anchors.margins: projectMonitor.showCanvasFrame ? 2 : 0
                visible: projectMonitor.timelineEngine && projectMonitor.timelineEngine.glVideoSink

                // itemInitialized only goes true once this item has a
                // QQuickWindow AND that window's scene graph has
                // initialized a live GL context (onSceneGraphInitialized)
                // - strictly later than Component.onCompleted.
                // ges_pipeline_preview_set_video_sink() drives the sink to
                // GST_STATE_READY synchronously and fails outright if the
                // item isn't GL-ready yet, so this is the only safe place
                // to call setGLVideoItem().
                onItemInitializedChanged: {
                    if (itemInitialized && projectMonitor.timelineEngine) {
                        console.log("Timeline GstGLQt6VideoItem initialized, wiring to TimelineEngine")
                        projectMonitor.timelineEngine.setGLVideoItem(timelineGLVideoItem)
                    }
                }
                Component.onCompleted: {
                    if (itemInitialized && projectMonitor.timelineEngine) {
                        projectMonitor.timelineEngine.setGLVideoItem(timelineGLVideoItem)
                    }
                }
                Component.onDestruction: {
                    if (projectMonitor.timelineEngine) {
                        projectMonitor.timelineEngine.clearGLVideoItem()
                    }
                }
            }

            VideoUnavailableOverlay {
                glItem: timelineGLVideoItem
                monitored: projectMonitor.timelineEngine && projectMonitor.timelineEngine.glVideoSink
            }

            // Canvas outline: 1 px just outside the letterboxed picture.
            Rectangle {
                id: canvasFrameOutline
                readonly property real cw: projectMonitor.timelineEngine ? projectMonitor.timelineEngine.canvasWidth : 0
                readonly property real ch: projectMonitor.timelineEngine ? projectMonitor.timelineEngine.canvasHeight : 0
                readonly property bool ok: cw > 0 && ch > 0 && timelineGLVideoItem.width > 0 && timelineGLVideoItem.height > 0
                // The GL item centres the frame with integer arithmetic
                // (gst_video_sink_center_rect: truncated size, truncated
                // offset), so mirror that to land on the same pixels.
                readonly property int itemW: Math.floor(timelineGLVideoItem.width)
                readonly property int itemH: Math.floor(timelineGLVideoItem.height)
                readonly property bool fitW: ok && itemW * ch <= itemH * cw
                readonly property int picW: !ok ? 0 : (fitW ? itemW : Math.floor(itemH * cw / ch))
                readonly property int picH: !ok ? 0 : (fitW ? Math.floor(itemW * ch / cw) : itemH)
                readonly property int picX: Math.round(timelineGLVideoItem.x) + Math.floor((itemW - picW) / 2)
                readonly property int picY: Math.round(timelineGLVideoItem.y) + Math.floor((itemH - picH) / 2)
                visible: projectMonitor.showCanvasFrame
                         && projectMonitor.timelineEngine && projectMonitor.timelineEngine.glVideoSink
                         && ok
                z: 10
                color: "transparent"
                border.width: 1
                border.color: "#ffcc00"
                x: picX - 1
                y: picY - 1
                width: picW + 2
                height: picH + 2
            }

            // Video rendering area for timeline (native-window path - only
            // actually shown/mapped when NOT using the GL item above;
            // VideoOutput.cpp's own updateVisibility() keeps its native
            // window unmapped whenever this is invisible, so there's never
            // two live video sinks fighting over the same panel).
            // The native-window path only exists on Qt's xcb platform (it embeds
            // an X11 child window); on native Wayland the item is never created.
            Loader {
                id: timelineVideoLoader
                anchors.fill: parent
                active: !(projectMonitor.timelineEngine && projectMonitor.timelineEngine.glVideoSink)
                        && Backend.platformName === "xcb"
                sourceComponent: Component {
                VideoOutput {
                    anchors.fill: parent
                    visible: projectMonitor.timelineEngine ? !projectMonitor.timelineEngine.inGap : true

                    Component.onCompleted: {
                        console.log("Timeline VideoOutput created, visible:", visible, "size:", width, "x", height)
                    }

                    onWidthChanged: {
                        console.log("Timeline VideoOutput width changed:", width)
                        if (width > 0 && height > 0 && windowId > 0 && projectMonitor.timelineEngine) {
                            // Re-set window ID when geometry becomes valid
                            console.log("Re-setting window ID after geometry change")
                            projectMonitor.timelineEngine.setWindowId(windowId)
                            projectMonitor.timelineEngine.refreshVideo()
                        }
                    }

                    onHeightChanged: {
                        console.log("Timeline VideoOutput height changed:", height)
                        if (width > 0 && height > 0 && windowId > 0 && projectMonitor.timelineEngine) {
                            // Re-set window ID when geometry becomes valid
                            console.log("Re-setting window ID after geometry change")
                            projectMonitor.timelineEngine.setWindowId(windowId)
                            projectMonitor.timelineEngine.refreshVideo()
                        }
                    }

                    onWindowIdChanged: {
                        console.log("Timeline VideoOutput window ID ready:", windowId, "size:", width, "x", height)
                        console.log("Timeline VideoOutput visible:", visible, "parent visible:", parent.visible)

                        if (windowId === 0) {
                            // The native video window was actually destroyed
                            // (VideoOutput.releaseResources()) - without this,
                            // the engine keeps a handle to a dead X window.
                            console.log("Timeline VideoOutput window ID cleared - native window destroyed")
                            if (projectMonitor.timelineEngine) {
                                projectMonitor.timelineEngine.clearWindowId()
                            }
                            return
                        }

                        if (width > 0 && height > 0 && projectMonitor.timelineEngine) {
                            projectMonitor.timelineEngine.setWindowId(windowId)
                            // Try refresh after delays
                            Qt.callLater(function() {
                                console.log("Calling refreshVideo after window ID set")
                                if (projectMonitor.timelineEngine) {
                                    projectMonitor.timelineEngine.refreshVideo()
                                }
                            })
                        } else {
                            console.log("WARNING: VideoOutput has invalid size, waiting for geometry...")
                        }
                    }

                    onVisibleChanged: {
                        console.log("Timeline VideoOutput visibility changed:", visible)
                        if (visible && width > 0 && height > 0 && windowId > 0 && projectMonitor.timelineEngine) {
                            console.log("VideoOutput became visible with valid size, refreshing")
                            projectMonitor.timelineEngine.setWindowId(windowId)
                            projectMonitor.timelineEngine.refreshVideo()
                        }
                    }

                    onSurfaceExposed: {
                        // The native surface just repainted itself black
                        // (X Expose/resize) - re-push the current frame so
                        // a paused/static timeline position doesn't stay wiped.
                        if (projectMonitor.timelineEngine) {
                            projectMonitor.timelineEngine.refreshVideo()
                        }
                    }
                }
                }
            }


            // Only shown when there's genuinely nothing to preview yet -
            // once the timeline has real content, the video itself (native
            // window or GL item) is the thing on screen, not this label.
            Text {
                anchors.centerIn: parent
                visible: !projectMonitor.timelineEngine || projectMonitor.timelineEngine.totalDuration <= 0
                text: "Timeline Preview\n(empty timeline)"
                color: "#888888"
                z: 1
                font.pixelSize: 12
            }
        }

        // Timeline playback controls
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            color: palette.window

            Row {
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10

                Button {
                    id: playPauseButton
                    text: projectMonitor.timelineEngine && projectMonitor.timelineEngine.playing ? "⏸" : "▶"
                    width: 35
                    height: 35
                    font.pixelSize: 14
                    // A full GES teardown+rebuild is mid-flight (e.g. an
                    // active-proxy-resolution switch, which the user
                    // reported takes a visible few seconds) - blocking
                    // Play here is the simplest way to keep anyone from
                    // starting playback against a torn-down/partially-
                    // rebuilt timeline.
                    enabled: !(projectMonitor.timelineEngine && projectMonitor.timelineEngine.reloadingAssets)

                    onClicked: {
                        if (!projectMonitor.timelineEngine) {
                            console.error("ERROR: Timeline engine not set!")
                            return
                        }

                        if (projectMonitor.timelineEngine.playing) {
                            // Pause
                            console.log("Timeline pause clicked")
                            projectMonitor.timelineEngine.pause()
                        } else {
                            // Play
                            console.log("Timeline play clicked")

                            if (projectMonitor.timelineEngine.glVideoSink) {
                                // TimelineEngine::play() self-gates on
                                // videoOutputReady() and remembers the
                                // request (m_playRequestedAfterCommit) if
                                // the GL item isn't wired up yet - no QML-
                                // side readiness check needed here.
                                projectMonitor.timelineEngine.play()
                            } else {
                                // Check if VideoOutput is ready
                                const timelineVideoOutput = timelineVideoLoader.item
                                if (!timelineVideoOutput) {
                                    console.error("ERROR: no native video output on the", Backend.platformName, "platform")
                                    return
                                }
                                if (timelineVideoOutput.width <= 0 || timelineVideoOutput.height <= 0) {
                                    console.error("ERROR: VideoOutput not ready! Size:", timelineVideoOutput.width, "x", timelineVideoOutput.height)
                                    console.error("Waiting for VideoOutput to get valid size...")
                                    return
                                }

                                if (timelineVideoOutput.windowId <= 0) {
                                    console.error("ERROR: VideoOutput window ID not ready!")
                                    return
                                }

                                console.log("VideoOutput ready - Size:", timelineVideoOutput.width, "x", timelineVideoOutput.height, "Window ID:", timelineVideoOutput.windowId)

                                // Re-set window ID right before playing to ensure it's current
                                projectMonitor.timelineEngine.setWindowId(timelineVideoOutput.windowId)

                                // NE hívjuk meg az updateTimelineEngine()-t itt!
                                // Ez feleslegesen újraépíti a pipeline-t minden play-nél
                                projectMonitor.timelineEngine.play()
                            }
                        }
                    }
                }

                // Vertical separator
                Rectangle {
                    width: 1
                    height: 30
                    color: "#555555"
                    anchors.verticalCenter: parent.verticalCenter
                }

                // Timecode display
                Text {
                    text: {
                        if (projectMonitor.timelineEngine && projectMonitor.formatTimecode) {
                            return projectMonitor.formatTimecode(projectMonitor.timelineEngine.position)
                        }
                        return "00:00:00:00"
                    }
                    color: "#4a9eff"
                    font.pixelSize: 14
                    font.family: "Monospace"
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                }

                // How far into the clip under the playhead we are, e.g.
                // "+00:03:12" from that clip's own start - separate from
                // the absolute project timecode to the left.
                Text {
                    text: {
                        if (!projectMonitor.timelineEngine || !projectMonitor.formatTimecode) return ""
                        if (!projectMonitor.workspace || !projectMonitor.workspace.timelinePanel) return ""
                        var playheadSeconds = projectMonitor.timelineEngine.position / 1000.0
                        var clip = projectMonitor.workspace.timelinePanel.clipAtPlayhead(playheadSeconds)
                        if (!clip) return ""
                        var intoClipMs = (playheadSeconds - clip.startTime) * 1000.0
                        return "+" + projectMonitor.formatTimecode(intoClipMs)
                    }
                    visible: text !== ""
                    color: "#888888"
                    font.pixelSize: 12
                    font.family: "Monospace"
                    anchors.verticalCenter: parent.verticalCenter

                    ToolTip.visible: textMouseArea.containsMouse
                    ToolTip.text: "Time since the start of the clip under the playhead"
                    MouseArea {
                        id: textMouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                    }
                }

                // Vertical separator
                Rectangle {
                    width: 1
                    height: 30
                    color: "#555555"
                    anchors.verticalCenter: parent.verticalCenter
                }

                // Preview render scale - actually reduces the live
                // decode/render resolution (TimelineEngine.setPreviewScale),
                // not just the display widget size, so it's a real
                // performance knob for slower GPUs/high-res footage.
                ComboBox {
                    id: previewScaleCombo
                    anchors.verticalCenter: parent.verticalCenter
                    width: 110
                    model: ["Full 1:1", "Half 1:2", "Quarter 1:4"]
                    currentIndex: 0

                    Accessible.role: Accessible.ComboBox
                    Accessible.name: "Preview render scale"

                    onActivated: function(index) {
                        if (!projectMonitor.timelineEngine) return
                        var denom = index === 1 ? 2 : (index === 2 ? 4 : 1)
                        projectMonitor.timelineEngine.setPreviewScale(denom)
                        // A ComboBox keeps keyboard focus after selection,
                        // which steals it away from the workspace root -
                        // that's where the timeline's own shortcuts
                        // (Space, Delete, arrow-key seek, etc.) are
                        // handled, so losing focus here silently breaks
                        // them until something else is clicked.
                        if (projectMonitor.workspace) {
                            projectMonitor.workspace.forceActiveFocus()
                        }
                    }
                }
            }

            // proxy_build_plan.md Part J.4.3/J.1.7: "Active proxy" exposed
            // right here too, not just buried in Project Settings - lets
            // you flip between Original/a generated resolution without
            // leaving the monitor. Right-aligned, sized to content (not a
            // Row that fills/stretches) - mirrors the left-hand transport
            // controls' own Row, just anchored to the opposite edge.
            Row {
                id: activeProxyRow
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10

                // Refreshed explicitly (not a live model: binding - that
                // only evaluates once, the same staleness trap fixed in
                // ProjectSettingsDialog.qml's own copy of this combo) on
                // every event that could change which variants exist or
                // are installed.
                function refreshModel() {
                    var resolutions = ["Original (no proxy)"].concat(
                        Backend.cacheManager ? Backend.cacheManager.getAvailableProxyResolutions() : [])
                    activeProxyCombo.model = resolutions
                    var current = Backend.getSetting("project/proxyActiveResolution", "Original (no proxy)")
                    var idx = resolutions.indexOf(current)
                    activeProxyCombo.currentIndex = idx >= 0 ? idx : 0
                }

                Connections {
                    target: Backend.cacheManager
                    function onProxyReady() { activeProxyRow.refreshModel() }
                }
                Connections {
                    target: Backend
                    function onProxyInstallationChanged() { activeProxyRow.refreshModel() }
                }
                Component.onCompleted: refreshModel()

                Rectangle {
                    width: 1
                    height: 30
                    color: "#555555"
                    anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                    text: "Active proxy:"
                    color: "#888888"
                    font.pixelSize: 12
                    anchors.verticalCenter: parent.verticalCenter
                }

                ComboBox {
                    id: activeProxyCombo
                    anchors.verticalCenter: parent.verticalCenter
                    width: 160
                    model: ["Original (no proxy)"]
                    // Blocked while a switch is already rebuilding the
                    // timeline - re-triggering mid-rebuild would just
                    // queue another full teardown+rebuild right behind
                    // the one in flight.
                    enabled: !(projectMonitor.timelineEngine && projectMonitor.timelineEngine.reloadingAssets)

                    Accessible.role: Accessible.ComboBox
                    Accessible.name: "Active proxy resolution"

                    onActivated: function(index) {
                        projectMonitor.switchActiveProxy(activeProxyCombo.currentText)
                        if (projectMonitor.workspace) {
                            projectMonitor.workspace.forceActiveFocus()
                        }
                    }
                }

                Text {
                    text: "⟳ switching…"
                    color: "#f0b030"
                    font.pixelSize: 12
                    anchors.verticalCenter: parent.verticalCenter
                    visible: projectMonitor.timelineEngine && projectMonitor.timelineEngine.reloadingAssets
                }
            }
        }
    }
}
