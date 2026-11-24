import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import VideoEditor 1.0

Rectangle {
    id: renderSettings
    color: palette.button
    border.color: "#1d1d1d"
    border.width: 1

    // Színek
    readonly property color colorBackground: "#31363b"
    readonly property color colorPanel: "#232629"
    readonly property color colorText: "#eff0f1"
    readonly property color colorLabel: "#aaaaaa"
    readonly property color colorBorder: "#5d6066"
    readonly property color colorHighlight: "#3daee9"

    readonly property int inputHeight: 35
    property string selectedGStreamerEncoderId: ""

    // RenderEngine emits jobEnqueued() synchronously from inside
    // startRender(), so by the time that call returns this list says whether
    // the brand-new job went straight to a pipeline or into the FIFO queue.
    property var pendingQueuedIds: []
    Connections {
        target: Backend.renderEngine
        function onJobEnqueued(jobId, startedImmediately, queuePosition) {
            if (!startedImmediately) pendingQueuedIds = pendingQueuedIds.concat([jobId])
        }
    }

    function doStartRender(outputPath) {
        console.log("Starting render to:", outputPath)
        var mainWindow = renderSettings.Window.window
        if (!mainWindow) return;
        var clips = mainWindow.getTimelineClipsForRender()
        var totalDuration = mainWindow.getTimelineDurationForRender()
        if (!clips || clips.length === 0) { console.log("Error: No clips"); return }
        var gpuEncoderType = "cpu"
        if (selectedGStreamerEncoderId.indexOf("nvidia") !== -1) gpuEncoderType = "nvidia"
        else if (selectedGStreamerEncoderId.indexOf("vaapi") !== -1) gpuEncoderType = "vaapi"
        var settings = {
            "format": formatCombo.currentText, "codec": codecCombo.currentText, "resolution": resolutionCombo.currentText,
            "framerate": framerateCombo.currentText, "bitrate": parseInt(bitrateField.text) || 50, "gpuEncoder": gpuEncoderType,
            // Resolves relative LUT/overlay asset paths embedded in a
            // clip's effects JSON (ClipEffects::resolveAssetPath()).
            "projectDir": Backend.getSetting("project/location", ""),
            // Pixel-based effect parameters/transforms are project-canvas
            // pixels: the render composites at this size and scales to
            // "resolution" afterwards. 0 = "auto"/unknown canvas -> the
            // backend composites at the output size.
            "canvasWidth": Math.max(0, parseInt(Backend.getSetting("project/width", "auto")) || 0),
            "canvasHeight": Math.max(0, parseInt(Backend.getSetting("project/height", "auto")) || 0)
        }
        // The row is only created once the backend has accepted the
        // request and told us the job's id - creating it blindly is
        // exactly what used to make a rejected render steal the
        // running render's progress updates.
        var jobId = Backend.renderEngine.startRender(outputPath, clips, totalDuration, settings)
        if (jobId < 0) return

        var queued = pendingQueuedIds.indexOf(jobId) !== -1
        jobStarted(jobId, queued, filenameField.text, locationField.text, resolutionCombo.currentText, framerateCombo.currentText,
                   codecCombo.currentText, formatCombo.currentText, bitrateField.text + " Mbps", "Export", encoderCombo.currentText)
        pendingQueuedIds = []
    }

    // Same Window-based confirm pattern as TimelineToolbar.qml's
    // deleteTrackWindow (a Window, not a Popup, for guaranteed Z-order
    // above the native video area in this app's Quick scene).
    Window {
        id: overwriteConfirmWindow
        title: "Output file already exists"
        modality: Qt.ApplicationModal
        flags: Qt.Dialog
        width: 420
        height: 160
        visible: false
        color: renderSettings.colorPanel

        property string pendingOutputPath: ""

        property var mainWin: renderSettings.Window.window
        transientParent: mainWin
        x: mainWin ? mainWin.x + (mainWin.width - width) / 2 : 100
        y: mainWin ? mainWin.y + (mainWin.height - height) / 2 : 100

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 12

            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: renderSettings.colorText
                text: "\"" + overwriteConfirmWindow.pendingOutputPath + "\" already exists.\nOverwrite it with this render?"
            }

            Item { Layout.fillHeight: true }

            Row {
                Layout.alignment: Qt.AlignRight
                spacing: 8

                Button {
                    focusPolicy: Qt.NoFocus
                    text: "Cancel"
                    onClicked: overwriteConfirmWindow.visible = false
                }
                Button {
                    focusPolicy: Qt.NoFocus
                    text: "Overwrite"
                    onClicked: {
                        var path = overwriteConfirmWindow.pendingOutputPath
                        overwriteConfirmWindow.visible = false
                        renderSettings.doStartRender(path)
                    }
                }
            }
        }
    }

    // Signal definition - includes deviceName
    // jobId comes from RenderEngine::startRender(); `queued` is true when the
    // engine could not start it immediately (a render on the same encoder
    // backend, or to the same output file, is still running) and parked it in
    // the FIFO queue instead. A request is never rejected any more.
    signal jobStarted(int jobId, bool queued, string filename, string path, string resolution, string fps, string codec, string format, string bitrate, string type, string deviceName)

    Component.onCompleted: { initTimer.start() }
    Timer { id: initTimer; interval: 50; repeat: false; onTriggered: initData() }

    // Deliberately NOT re-run on every Render-tab visit (that would
    // stomp the user's own manual codec/resolution/bitrate choices each
    // time they tab away and back). The actual fix for "Automatic
    // profile" not taking effect is upstream, in TimelinePanel.qml's
    // maybeResolveAutoProfile(): project/width|height|fps get resolved
    // from the FIRST video clip's real metadata and written back as
    // concrete numbers the moment that clip lands on the timeline - by
    // the time this tab is ever opened, project/width is no longer the
    // literal string "auto", so this one-shot initData() already sees
    // the right numbers. The findFirstVideoClipMetadata() fallback below
    // only matters for the edge case of opening this tab while the
    // timeline is still empty and the profile is still unresolved.

    // Picks the project's OWN first video clip's real metadata when the
    // project profile is "Automatic (detect from first video)" -
    // ProjectSettingsDialog.qml stores that choice as the literal STRING
    // "auto" for project/width|height|fps, and nothing anywhere else in
    // the app ever resolves it to a real number - every "auto" read site
    // was silently falling back to a hardcoded 1920x1080/30fps/H.264/MP4
    // guess instead. This is the one read site that actually needs the
    // real answer (what the user will render), so it's the one that
    // does the resolving.
    function findFirstVideoClipMetadata() {
        var mainWindow = renderSettings.Window.window
        if (!mainWindow || !mainWindow.timelinePanelRef) return null
        var clips = mainWindow.timelinePanelRef.clipsArray()
        var first = null
        for (var i = 0; i < clips.length; i++) {
            var c = clips[i]
            if (!c.hasVideo) continue
            if (first === null || c.startTime < first.startTime) first = c
        }
        if (!first || !first.sourceItemId) return null
        var meta = Backend.projectBinModel.getItemMetadata(first.sourceItemId)
        if (!meta || !meta.resolution) return null
        meta.itemPath = first.itemPath || ""
        return meta
    }

    // "3840x2160" -> {w:3840,h:2160}, or null if unparseable (e.g. the
    // item's metadata extraction hasn't completed yet).
    function parseResolutionString(s) {
        if (!s) return null
        var m = /^(\d+)x(\d+)/.exec(s)
        if (!m) return null
        return { w: parseInt(m[1]), h: parseInt(m[2]) }
    }

    // "23.98 fps" -> 23.98
    function parseFpsString(s) {
        if (!s) return NaN
        var m = /([\d.]+)/.exec(s)
        return m ? parseFloat(m[1]) : NaN
    }

    // ---- Resolution list, built from the project canvas ------------------
    // Nearest even integer (4:2:0 needs even dimensions).
    function nearestEven(v) { return 2 * Math.round(v / 2) }

    // First entry is the project canvas itself ("WxH (Project)"); then
    // proportionally scaled versions that are strictly narrower. Every
    // string keeps the leading "WxH " form RenderEngine parses.
    function buildResolutionList(W, H) {
        var list = [W + "x" + H + " (Project)"]
        var targets = (W > 3840) ? [3840, 1920, 1280] : [1920, 1280]
        for (var i = 0; i < targets.length; i++) {
            var tw = targets[i]
            if (tw >= W) continue
            list.push(tw + "x" + nearestEven(H * tw / W) + " (" + tw + " wide)")
        }
        return list
    }

    // The canvas the render list is based on: the project's numbers, or for
    // an "auto" project the first video clip's metadata (today's behaviour),
    // or 1920x1080 when nothing is known yet.
    function currentCanvas() {
        var w = Backend.getSetting("project/width", "auto")
        var h = Backend.getSetting("project/height", "auto")
        var f = Backend.getSetting("project/fps", "auto")
        var W = parseInt(w), H = parseInt(h)
        if (!(W > 0 && H > 0)) {
            var meta = findFirstVideoClipMetadata()
            var res = meta ? parseResolutionString(meta.resolution) : null
            if (res) { W = res.w; H = res.h } else { W = 1920; H = 1080 }
        }
        return { w: (W + 1) & ~1, h: (H + 1) & ~1 }
    }

    property string resolutionSignature: ""
    // Rebuild the list when the canvas changed (or force). Keeps the user's
    // selection if the same entry still exists, otherwise falls back to the
    // Project entry (index 0).
    function rebuildResolutionList(force) {
        var c = currentCanvas()
        var sig = c.w + "x" + c.h
        if (!force && sig === resolutionSignature) return
        resolutionSignature = sig
        var prev = resolutionCombo.currentText
        var list = buildResolutionList(c.w, c.h)
        resolutionCombo.model = list
        var idx = list.indexOf(prev)
        resolutionCombo.currentIndex = idx >= 0 ? idx : 0
    }

    onVisibleChanged: if (visible) { rebuildResolutionList(false); rebuildFramerateList(false); updateBitrateDefault() }
    // Profile changes made in the Project Settings dialog (or an "auto"
    // profile resolving) have no change signal, so poll cheaply while visible.
    Timer {
        interval: 1000; repeat: true; running: renderSettings.visible
        onTriggered: { renderSettings.rebuildResolutionList(false); renderSettings.rebuildFramerateList(false); renderSettings.updateBitrateDefault() }
    }

    // ---- Frame-rate list, built like the resolution list ------------------
    // First entry "<project fps> fps (Project)" (the default), then the
    // standard rates without repeating the project's own. RenderEngine parses
    // the leading number through the shared FrameRate::parse().
    readonly property var standardFps: ["23.98", "24", "25", "29.97", "30", "50", "59.94", "60"]

    // The project's frame rate as the setting string; for an "auto" project
    // the first video clip's metadata, or "30" (what the timeline uses) when
    // nothing is known yet.
    function currentFpsString() {
        var f = String(Backend.getSetting("project/fps", "auto"))
        if (!isNaN(parseFloat(f)) && parseFloat(f) > 0) return f
        var meta = findFirstVideoClipMetadata()
        var v = meta ? parseFpsString(meta.frameRate) : NaN
        return (!isNaN(v) && v > 0) ? String(v) : "30"
    }

    function buildFramerateList(projFps) {
        var list = [projFps + " fps (Project)"]
        var pv = parseFloat(projFps)
        for (var i = 0; i < standardFps.length; i++) {
            if (Math.abs(parseFloat(standardFps[i]) - pv) < 0.005) continue
            list.push(standardFps[i] + " fps")
        }
        return list
    }

    property string framerateSignature: ""
    function rebuildFramerateList(force) {
        var f = currentFpsString()
        if (!force && f === framerateSignature) return
        framerateSignature = f
        var prev = framerateCombo.currentText
        var list = buildFramerateList(f)
        framerateCombo.model = list
        var idx = list.indexOf(prev)
        framerateCombo.currentIndex = idx >= 0 ? idx : 0
    }

    // Selects the codecCombo entry whose text matches the source clip's
    // codec family (e.g. source "H.265 (Main 10 Profile)" -> any
    // available "H.265"/"HEVC" encoder option), if the chosen encoder
    // device offers one - falls back to leaving whatever updateCodecs()
    // already selected (index 0) otherwise.
    function selectCodecComboForSource(sourceVideoCodec) {
        if (!sourceVideoCodec) return
        var family = sourceVideoCodec.indexOf("H.265") !== -1 || sourceVideoCodec.indexOf("HEVC") !== -1 ? ["H.265", "HEVC"]
                    : sourceVideoCodec.indexOf("H.264") !== -1 || sourceVideoCodec.indexOf("AVC") !== -1 ? ["H.264", "AVC"]
                    : sourceVideoCodec.indexOf("AV1") !== -1 ? ["AV1"]
                    : sourceVideoCodec.indexOf("VP9") !== -1 ? ["VP9"]
                    : null
        if (!family) return
        var model = codecCombo.model
        for (var i = 0; i < model.length; i++) {
            for (var j = 0; j < family.length; j++) {
                if (model[i].indexOf(family[j]) !== -1) { codecCombo.currentIndex = i; return }
            }
        }
    }

    // Highest video bitrate among the timeline's own clips, in whole
    // Mbps, or null if no clip has bitrate metadata yet. Deliberately
    // the MAX across all clips (not just the first) - rendering at
    // less than the richest source clip's bitrate would visibly
    // re-compress it down.
    function findMaxVideoBitrateMbps() {
        var mainWindow = renderSettings.Window.window
        if (!mainWindow || !mainWindow.timelinePanelRef) return null
        var clips = mainWindow.timelinePanelRef.clipsArray()
        var maxKbps = 0
        for (var i = 0; i < clips.length; i++) {
            var c = clips[i]
            if (!c.hasVideo || !c.sourceItemId) continue
            var meta = Backend.projectBinModel.getItemMetadata(c.sourceItemId)
            if (!meta || !meta.bitrate) continue
            var m = /([\d.]+)/.exec(meta.bitrate) // "12345 kbps" -> 12345
            if (!m) continue
            var kbps = parseFloat(m[1])
            if (kbps > maxKbps) maxKbps = kbps
        }
        if (maxKbps <= 0) return null
        return Math.max(1, Math.round(maxKbps / 1000))
    }

    // The bitrate field defaults to the richest source clip's bitrate (bin
    // metadata of the ORIGINAL media - never the proxy). initData() runs once
    // shortly after startup, before any project/metadata exists, so this is
    // re-run when the tab becomes visible, on the poll timer and whenever a
    // bin item's metadata arrives - until the user types into the field.
    property bool bitrateUserEdited: false
    function updateBitrateDefault() {
        if (bitrateUserEdited) return
        var mbps = findMaxVideoBitrateMbps()
        if (mbps !== null && bitrateField.text !== String(mbps)) bitrateField.text = String(mbps)
    }

    Connections {
        target: Backend.projectBinModel
        function onItemMetadataUpdated(itemId) { renderSettings.updateBitrateDefault() }
    }

    // H.265 is the preferred default codec (better compression at the
    // same bitrate than H.264) whenever the selected encoder device
    // actually offers it. Returns false (leaving updateCodecs()'s own
    // index-0 choice in place) if it doesn't.
    function selectHevcIfAvailable() {
        var model = codecCombo.model
        for (var i = 0; i < model.length; i++) {
            if (model[i].indexOf("H.265") !== -1 || model[i].indexOf("HEVC") !== -1) {
                codecCombo.currentIndex = i
                return true
            }
        }
        return false
    }

    function selectFormatComboForSource(sourcePath) {
        if (!sourcePath) return
        var ext = sourcePath.split(".").pop().toUpperCase()
        var map = { "MP4": "MP4", "M4V": "MP4", "MKV": "MKV", "MOV": "MOV", "WEBM": "WEBM" }
        var target = map[ext]
        if (!target) return
        var model = formatCombo.model
        var idx = model.indexOf(target)
        if (idx >= 0) formatCombo.currentIndex = idx
    }

    function initData() {
        try {
            if (Backend) {
                var savedFileName = Backend.getSetting("project/fileName", "");
                var savedLocation = Backend.getSetting("project/location", "");

                if (savedFileName !== "") {
                    var baseName = savedFileName.replace(/\.[^/.]+$/, "");
                    filenameField.text = baseName + ".mp4";
                } else {
                    filenameField.text = "output.mp4";
                }

                if (savedLocation !== "") locationField.text = savedLocation;
                else locationField.text = Backend.getDefaultVideosPath();

                var deviceNames = [];
                var devices = Backend.gpuDevices;
                if (devices) { for (var i = 0; i < devices.length; i++) deviceNames.push(devices[i].name + " (" + devices[i].type + ")"); }

                if (deviceNames.length > 0) { encoderCombo.model = deviceNames; encoderCombo.currentIndex = 0; updateCodecs(0); }
                else { encoderCombo.model = ["Software (CPU)"]; }

                var w = Backend.getSetting("project/width", "auto");
                var h = Backend.getSetting("project/height", "auto");
                var fpsSetting = Backend.getSetting("project/fps", "auto");
                var isAuto = (w === "auto" || h === "auto" || fpsSetting === "auto")
                var firstClipMeta = isAuto ? findFirstVideoClipMetadata() : null
                rebuildResolutionList(true)

                rebuildFramerateList(true)
                if (firstClipMeta) {
                    selectFormatComboForSource(firstClipMeta.itemPath)
                }

                // Prefer H.265 regardless of source codec (better
                // compression at the same bitrate); only fall back to
                // matching the source's own codec family if this
                // encoder device doesn't offer H.265 at all.
                if (!selectHevcIfAvailable() && firstClipMeta) {
                    selectCodecComboForSource(firstClipMeta.videoCodec)
                }

                updateBitrateDefault()
            }
        } catch(e) { console.error(e); }
    }

    function updateCodecs(index) {
        if (!Backend || !Backend.gpuDevices) return;
        var devices = Backend.gpuDevices;
        if (index >= 0 && index < devices.length) {
            var device = devices[index];
            selectedGStreamerEncoderId = device.id;
            var encoders = device.encoders;
            codecCombo.model = (encoders && encoders.length > 0) ? encoders : ["H.264"];
            codecCombo.currentIndex = 0;
        }
    }

    FolderDialog { id: folderDialog; title: "Select Render Output Folder"; onAccepted: locationField.text = selectedFolder.toString().replace("file://", "") }

    ColumnLayout {
        anchors.fill: parent; spacing: 0
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 50; color: colorPanel
            Text { anchors.centerIn: parent; text: "Render Settings"; font.bold: true; font.pixelSize: 16; color: colorText }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: colorBorder }

        Rectangle {
            Layout.fillWidth: true; Layout.fillHeight: true; color: colorBackground
            StackLayout {
                anchors.fill: parent; currentIndex: 0
                ScrollView {
                    id: scrollView; Layout.fillWidth: true; Layout.fillHeight: true; clip: true; ScrollBar.horizontal.policy: ScrollBar.AlwaysOff; contentWidth: availableWidth 
                    ColumnLayout {
                        anchors.left: parent.left; anchors.right: parent.right; anchors.margins: 20; spacing: 15; Item { Layout.preferredHeight: 10 }
                        Label { text: "Filename:"; color: colorLabel; font.pixelSize: 12 }
                        TextField { id: filenameField; Layout.fillWidth: true; Layout.preferredHeight: inputHeight; text: "output.mp4"; color: colorText; selectByMouse: true; background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 3 } }
                        Label { text: "Location:"; color: colorLabel; font.pixelSize: 12 }
                        RowLayout { Layout.fillWidth: true; spacing: 5
                            TextField { id: locationField; Layout.fillWidth: true; Layout.preferredHeight: inputHeight; text: "Loading..."; color: colorText; readOnly: true; background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 3 } }
                            Button { text: "Browse"; Layout.preferredHeight: inputHeight; onClicked: folderDialog.open(); background: Rectangle { color: parent.down ? "#4a7ea8" : "#5e92c2"; radius: 3 } contentItem: Text { text: parent.text; color: "white"; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 11 } }
                            Button {
                                text: "Open Folder"
                                Layout.preferredHeight: inputHeight
                                // QDesktopServices::openUrl() on a directory path opens it in
                                // the OS file manager - same call BackendManager already uses
                                // for "open this file", just pointed at a folder instead.
                                onClicked: Backend.openFile(locationField.text)
                                background: Rectangle { color: parent.down ? "#4a7ea8" : "#5e92c2"; radius: 3 }
                                contentItem: Text { text: parent.text; color: "white"; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 11 }
                            }
                        }
                        Rectangle { Layout.fillWidth: true; height: 1; color: colorBorder; Layout.topMargin: 10 }
                        CheckBox { id: videoCheckbox; text: "Video Enabled"; checked: true; contentItem: Text { text: parent.text; color: colorText; leftPadding: parent.indicator.width + 10; font.bold: true } }
                        
                        Label { text: "Encoder Device:"; color: colorLabel; font.pixelSize: 12 }
                        ComboBox { id: encoderCombo; Layout.fillWidth: true; Layout.preferredHeight: inputHeight; enabled: videoCheckbox.checked; onCurrentIndexChanged: updateCodecs(currentIndex); contentItem: Text { text: parent.displayText; color: colorText; verticalAlignment: Text.AlignVCenter; leftPadding: 8; elide: Text.ElideRight } background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 3 } }
                        
                        Label { text: "Codec:"; color: colorLabel; font.pixelSize: 12 }
                        ComboBox { id: codecCombo; Layout.fillWidth: true; Layout.preferredHeight: inputHeight; enabled: videoCheckbox.checked; contentItem: Text { text: parent.displayText; color: colorText; verticalAlignment: Text.AlignVCenter; leftPadding: 8 } background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 3 } }
                        // Why a codec you expected may be missing: the list is
                        // probed from the selected device's REAL encoder
                        // elements (BackendManager::detectCodecsForElement()).
                        // NVENC has no VP9 encoder on any NVIDIA GPU (VP9 is
                        // decode-only there), and GStreamer's VA plugin ships
                        // no VP9 encoder either - so VP9 only ever appears
                        // under Software (CPU).
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            color: colorLabel
                            font.pixelSize: 11
                            font.italic: true
                            text: codecCombo.model && codecCombo.model.indexOf("VP9") === -1
                                  ? "Only codecs this device can really encode are listed. VP9 hardware encoding is not available on NVIDIA (NVENC decodes VP9 but cannot encode it) nor via the VA-API plugin - pick Software (CPU) for VP9."
                                  : "Only codecs this device can really encode are listed."
                        }
                        Label { text: "Format:"; color: colorLabel; font.pixelSize: 12 }
                        ComboBox { id: formatCombo; Layout.fillWidth: true; Layout.preferredHeight: inputHeight; model: ["MP4", "MKV", "MOV", "WEBM"]; currentIndex: 0; enabled: videoCheckbox.checked; contentItem: Text { text: parent.displayText; color: colorText; verticalAlignment: Text.AlignVCenter; leftPadding: 8 } background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 3 } }
                        Label { text: "Resolution:"; color: colorLabel; font.pixelSize: 12 }
                        ComboBox { id: resolutionCombo; Layout.fillWidth: true; Layout.preferredHeight: inputHeight; model: []; enabled: videoCheckbox.checked; contentItem: Text { text: parent.displayText; color: colorText; verticalAlignment: Text.AlignVCenter; leftPadding: 8 } background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 3 } }
                        Label { text: "Framerate:"; color: colorLabel; font.pixelSize: 12 }
                        ComboBox { id: framerateCombo; Layout.fillWidth: true; Layout.preferredHeight: inputHeight; model: []; enabled: videoCheckbox.checked; contentItem: Text { text: parent.displayText; color: colorText; verticalAlignment: Text.AlignVCenter; leftPadding: 8 } background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 3 } }
                        Label { text: "Bitrate (Mbps):"; color: colorLabel; font.pixelSize: 12 }
                        TextField { id: bitrateField; onTextEdited: renderSettings.bitrateUserEdited = true; Layout.fillWidth: true; Layout.preferredHeight: inputHeight; text: "50"; color: colorText; selectByMouse: true; enabled: videoCheckbox.checked; validator: IntValidator { bottom: 1; top: 500 } background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 3 } }
                        Item { Layout.preferredHeight: 20 }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 65; color: colorPanel
            Button {
                anchors.centerIn: parent; width: 200; height: 40; text: "Start Render"
                background: Rectangle { color: parent.enabled ? (parent.down ? "#2a9ad0" : colorHighlight) : "#555555"; radius: 4 }
                contentItem: Text { text: parent.text; color: "white"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                onClicked: {
                    var outputPath = locationField.text + "/" + filenameField.text
                    if (renderSettings.warnMissingMedia(outputPath)) return
                    renderSettings.startRenderCheckingOverwrite(outputPath)
                }
            }
        }
    }

    function startRenderCheckingOverwrite(outputPath) {
        // startRender()'s own conflict check only guards two
        // SIMULTANEOUSLY RUNNING jobs from writing the same
        // file - a path that already has a FINISHED render (or
        // any other file) sitting on disk gets silently
        // overwritten otherwise.
        if (Backend.renderEngine.outputPathExists(outputPath)) {
            overwriteConfirmWindow.pendingOutputPath = outputPath
            overwriteConfirmWindow.visible = true
            return
        }
        renderSettings.doStartRender(outputPath)
    }

    // Source files that were not found at the last media check (project
    // load / Retry / Locate folder) render as black / silence. Returns true
    // when the warning window was shown instead of starting the render.
    function warnMissingMedia(outputPath) {
        var mav = Backend.mediaAvailability
        if (!mav || mav.missingCount === 0) return false
        var mainWindow = renderSettings.Window.window
        if (!mainWindow) return false
        var missingSet = new Map()
        var cur = mav.missing
        for (var i = 0; i < cur.length; i++) missingSet.set(cur[i].path, true)
        var clips = mainWindow.getTimelineClipsForRender() || []
        var files = new Map()
        var clipCount = 0
        for (var j = 0; j < clips.length; j++) {
            var p = mav.localPath(clips[j].itemPath || "")
            if (!missingSet.has(p)) continue
            clipCount++
            files.set(p, true)
        }
        if (files.size === 0) return false
        missingWarnWindow.pendingOutputPath = outputPath
        missingWarnWindow.fileCount = files.size
        missingWarnWindow.clipCount = clipCount
        missingWarnWindow.visible = true
        return true
    }

    Window {
        id: missingWarnWindow
        title: "Missing source files"
        modality: Qt.ApplicationModal
        flags: Qt.Dialog
        width: 460
        height: 180
        visible: false
        color: renderSettings.colorPanel

        property string pendingOutputPath: ""
        property int fileCount: 0
        property int clipCount: 0

        property var mainWin: renderSettings.Window.window
        transientParent: mainWin
        x: mainWin ? mainWin.x + (mainWin.width - width) / 2 : 100
        y: mainWin ? mainWin.y + (mainWin.height - height) / 2 : 100

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 12

            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: renderSettings.colorText
                text: (missingWarnWindow.fileCount === 1 ? "1 source file is" : missingWarnWindow.fileCount + " source files are")
                      + " missing (used by " + missingWarnWindow.clipCount
                      + (missingWarnWindow.clipCount === 1 ? " clip" : " clips")
                      + " in this render).\nThose parts will render as black / silence. Render anyway?"
            }

            Item { Layout.fillHeight: true }

            Row {
                Layout.alignment: Qt.AlignRight
                spacing: 8

                Button {
                    focusPolicy: Qt.NoFocus
                    text: "Show missing media..."
                    onClicked: {
                        missingWarnWindow.visible = false
                        Backend.mediaAvailability.requestDialog()
                    }
                }
                Button {
                    focusPolicy: Qt.NoFocus
                    text: "Cancel"
                    onClicked: missingWarnWindow.visible = false
                }
                Button {
                    focusPolicy: Qt.NoFocus
                    text: "Render anyway"
                    onClicked: {
                        var path = missingWarnWindow.pendingOutputPath
                        missingWarnWindow.visible = false
                        renderSettings.startRenderCheckingOverwrite(path)
                    }
                }
            }
        }
    }
}
