import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Dialogs
import VideoEditor 1.0
import "components"

Window {
    id: projectSettingsWindow
    title: "Project Settings — GPU Cine Studio"
    width: 850
    height: 860
    // Beállítunk minimum méretet, hogy ne essen szét az elrendezés átméretezéskor
    minimumWidth: 600
    minimumHeight: 560
    visible: false

    // Modális ablak beállítások
    modality: Qt.ApplicationModal
    flags: Qt.Dialog | Qt.WindowStaysOnTopHint

    // Property to determine if this is for a new project or editing existing
    property bool isNewProject: true

    // Track if project name was manually edited
    property bool projectNameManuallyEdited: false

    // Pozicionálás
    Component.onCompleted: {
        x = (Screen.width - width) / 2
        y = (Screen.height - height) / 2
    }

    // Load settings when window opens
    onVisibleChanged: {
        if (visible) {
            loadSettings()
        }
    }

    // See loadSettings(): the project's stored project/decoder value and
    // whether the user changed the combo since the dialog opened.
    property string decoderOriginal: ""
    property bool decoderTouched: false

    function decoderComboIndexFor(value) {
        var d = String(value).toLowerCase()
        if (d.includes("nvdec") || d.includes("nvidia")) return 0
        if (d.includes("vaapi")) return 1
        return 2 // "cpu", "avdec_*", unknown
    }

    // Function to load either default or current project settings
    function loadSettings() {
        folderErrorLabel.text = ""
        if (isNewProject) {
            // Load default values for new project
            fileNameField.text = ""
            // Set default location to user's Videos folder
            projectLocationField.text = Backend.getDefaultVideosPath()
            projectNameField.text = ""
            projectDescriptionField.text = ""
            projectNameManuallyEdited = false

            timelinePreviewCombo.currentIndex = 0 // NVIDIA NVDEC
            decoderOriginal = ""
            decoderTouched = false
            videoTracksSpinBox.value = 2
            audioTracksSpinBox.value = 2
            videoThumbnailsCheckBox.checked = true
            audioThumbnailsCheckBox.checked = true
            transientProfile = null
            rebuildProfiles(Backend.profileStore.allProfiles()[0].name)
            fitControls.scaling = "fill"      // new projects crop to fill by default
            fitControls.anchorH = "center"
            fitControls.anchorV = "center"

            // New project: seed from the GLOBAL proxy defaults (QSettings
            // "proxy/default*", edited in the app-wide Settings dialog) -
            // per-project values don't exist yet.
            loadProxySettings(
                Backend.getSetting("proxy/defaultEnabled", false),
                Backend.getSetting("proxy/defaultTargetResolution", "960x540"),
                "Original (no proxy)",
                Backend.getSetting("proxy/defaultFormat", "h264_intra"),
                Backend.getSetting("proxy/defaultPauseDuringPlayback", false),
                Backend.getSetting("proxy/defaultComputeDevice", ""))
        } else {
            // Load current project settings
            fileNameField.text = Backend.getSetting("project/fileName", "")
            projectLocationField.text = Backend.getSetting("project/location", "")
            projectNameField.text = Backend.getSetting("project/name", "")
            projectDescriptionField.text = Backend.getSetting("project/description", "")
            projectNameManuallyEdited = true // Don't auto-update name in edit mode

            // project/decoder holds two vocabularies: the dialog's own ids
            // ("nvdec_h264" / "vaapi_h264" / "avdec_h264") and
            // BackendManager's ("nvidia" / "vaapi" / "cpu", written by New
            // Project / the Kdenlive import via Backend.preferredDecoder).
            // Map both to the combo, and remember the stored value so OK
            // writes it back verbatim unless the user touches the combo.
            decoderOriginal = String(Backend.getSetting("project/decoder", "nvdec_h264"))
            decoderTouched = false
            timelinePreviewCombo.currentIndex = decoderComboIndexFor(decoderOriginal)

            videoTracksSpinBox.value = Backend.getSetting("project/videoTracks", 2)
            audioTracksSpinBox.value = Backend.getSetting("project/audioTracks", 2)
            videoThumbnailsCheckBox.checked = Backend.getSetting("project/videoThumbnails", true)
            audioThumbnailsCheckBox.checked = Backend.getSetting("project/audioThumbnails", true)

            // Load profile setting: select the profile whose numbers equal the
            // project's (custom wins on an exact match). When none does, a
            // transient "Current project (...)" row is shown and selected, so
            // pressing OK can never silently rewrite the project's size.
            var savedWidth = Backend.getSetting("project/width", "auto")
            var savedHeight = Backend.getSetting("project/height", "auto")
            var savedFps = Backend.getSetting("project/fps", "auto")
            transientProfile = null
            if (savedWidth === "auto" || savedHeight === "auto" || savedFps === "auto") {
                rebuildProfiles(Backend.profileStore.allProfiles()[0].name)
            } else {
                var cw = parseInt(savedWidth), ch = parseInt(savedHeight)
                var cfps = String(savedFps)
                var mi = Backend.profileStore.findMatch(cw, ch, cfps)
                if (mi >= 0) {
                    rebuildProfiles(Backend.profileStore.allProfiles()[mi].name)
                } else {
                    transientProfile = {
                        name: "Current project (" + cw + "x" + ch + ", " + cfps + ")",
                        w: cw, h: ch, fps: cfps,
                        aspect: Backend.profileStore.aspectLabel(cw, ch),
                        description: "The size and frame rate this project currently uses. It is not a saved profile - use Duplicate to keep it as a custom profile.",
                        isAuto: false, builtin: false, isTransient: true
                    }
                    rebuildProfiles(transientProfile.name)
                }
            }

            fitControls.scaling = String(Backend.getSetting("project/fitScaling", "fit"))
            fitControls.anchorH = String(Backend.getSetting("project/fitAnchorH", "center"))
            fitControls.anchorV = String(Backend.getSetting("project/fitAnchorV", "center"))

            // Existing project: per-project values, each already defaulting
            // to the matching global default the FIRST time this project
            // was ever saved with a Proxy tab present (see save handler).
            loadProxySettings(
                Backend.getSetting("project/proxyEnabled", Backend.getSetting("proxy/defaultEnabled", false)),
                Backend.getSetting("project/proxyTargetResolution", Backend.getSetting("proxy/defaultTargetResolution", "960x540")),
                Backend.getSetting("project/proxyActiveResolution", "Original (no proxy)"),
                Backend.getSetting("project/proxyFormat", Backend.getSetting("proxy/defaultFormat", "h264_intra")),
                Backend.getSetting("project/proxyPauseDuringPlayback", Backend.getSetting("proxy/defaultPauseDuringPlayback", false)),
                Backend.getSetting("project/proxyComputeDevice", Backend.getSetting("proxy/defaultComputeDevice", "")))
        }

        // plan_home_end_canvasframe.md: app-wide view preference, read in both
        // the new-project and existing-project branches.
        canvasFrameCheckBox.checked = (function(v){ return v === true || String(v) === "true" })(Backend.getSetting("monitor/showCanvasFrame", false))
    }

    // ---- Profile list management (profiles live in Backend.profileStore) ----
    // True after commitSettings() if OK changed project width/height/fps;
    // main.qml reads it in its accepted handler to rebuild a loaded timeline.
    property bool profileChanged: false
    // Set by main.qml: returns how many clips carry a real transform effect.
    property var transformCountFn: null
    // Set by commitSettings() when the user chose "Rescale" for a frame-size
    // change: {oldW, oldH, newW, newH}; main.qml's accepted handler applies it
    // (timelinePanel.rescaleClipTransforms) together with the rebuild.
    property var rescaleRequest: null
    // "" = not asked yet, "rescale" | "keep" = the answer for this OK press.
    property string rescaleDecision: ""

    // {oldW, oldH, newW, newH} when OK would change the project's frame size
    // between two concrete sizes ("auto"/unknown on either side -> null).
    function pendingSizeChange() {
        if (isNewProject || profileList.currentIndex < 0) return null
        var sel = profileModel.get(profileList.currentIndex)
        if (sel.isTransient || sel.isAuto) return null
        var oldW = parseInt(Backend.getSetting("project/width", "auto"))
        var oldH = parseInt(Backend.getSetting("project/height", "auto"))
        var newW = parseInt(sel.w), newH = parseInt(sel.h)
        if (!(oldW > 0 && oldH > 0 && newW > 0 && newH > 0)) return null
        if (oldW === newW && oldH === newH) return null
        return { oldW: oldW, oldH: oldH, newW: newW, newH: newH }
    }
    // Not-persisted first row shown when the project's numbers match no profile.
    property var transientProfile: null

    function rebuildProfiles(selectName) {
        var all = Backend.profileStore.allProfiles()
        // A transient row that has since become a real profile goes away.
        if (transientProfile && Backend.profileStore.findMatch(
                transientProfile.w, transientProfile.h, transientProfile.fps) >= 0
                && selectName !== transientProfile.name)
            transientProfile = null
        profileModel.clear()
        if (transientProfile) profileModel.append(transientProfile)
        for (var i = 0; i < all.length; i++) {
            var p = all[i]
            profileModel.append({ name: p.name, w: p.w, h: p.h, fps: String(p.fps), aspect: p.aspect,
                                  description: p.description, isAuto: p.isAuto, builtin: p.builtin,
                                  isTransient: false })
        }
        var idx = 0
        for (var j = 0; j < profileModel.count; j++)
            if (profileModel.get(j).name === selectName) { idx = j; break }
        profileList.currentIndex = idx
    }

    function openProfileEditor(mode, src) {
        profileEditor.mode = mode
        profileEditor.originalName = (mode === "edit" && src) ? src.name : ""
        if (src) {
            profileEditor.nameText = (mode === "edit") ? src.name : Backend.profileStore.uniqueName(src.name)
            profileEditor.widthText = String(src.w)
            profileEditor.heightText = String(src.h)
            profileEditor.fpsValue = String(src.fps)
            profileEditor.descText = src.description || ""
        } else {
            profileEditor.nameText = Backend.profileStore.uniqueName("New profile")
            profileEditor.widthText = "3840"
            profileEditor.heightText = "1600"
            profileEditor.fpsValue = "23.98"
            profileEditor.descText = ""
        }
        profileEditor.open()
    }

    function duplicateSelectedProfile() {
        if (profileList.currentIndex < 0) return
        var src = profileModel.get(profileList.currentIndex)
        if (src.isAuto) return
        var base = src.isTransient ? ("Custom " + src.w + "x" + src.h + " " + src.fps + " fps") : src.name
        var copyName = src.isTransient ? Backend.profileStore.uniqueName(base) : Backend.profileStore.uniqueCopyName(base)
        var err = Backend.profileStore.addCustom({ name: copyName, w: src.w, h: src.h, fps: src.fps,
                                                   description: src.isTransient ? "" : src.description })
        if (err !== "") {
            // e.g. a transient row with an unsupported frame rate: let the
            // user fix it in the editor instead of failing silently.
            openProfileEditor("new", { name: copyName, w: src.w, h: src.h, fps: src.fps, description: "" })
            return
        }
        rebuildProfiles(copyName)
        openProfileEditor("edit", profileModel.get(profileList.currentIndex))
    }

    Dialog {
        id: profileEditor
        objectName: "profileEditor"
        title: mode === "edit" ? "Edit Profile" : "New Profile"
        modal: true
        anchors.centerIn: parent
        closePolicy: Popup.CloseOnEscape

        property string mode: "new"
        property string originalName: ""
        property alias nameText: pfName.text
        property alias widthText: pfWidth.text
        property alias heightText: pfHeight.text
        property string fpsValue: "23.98"
        property alias descText: pfDesc.text
        readonly property string errorText: Backend.profileStore.validate(
            pfName.text, parseInt(pfWidth.text), parseInt(pfHeight.text),
            pfFps.currentIndex >= 0 ? pfFps.currentText : "", originalName)
        readonly property string aspectText: (parseInt(pfWidth.text) > 0 && parseInt(pfHeight.text) > 0)
            ? Backend.profileStore.aspectLabel(parseInt(pfWidth.text), parseInt(pfHeight.text)) : "-"

        onAboutToShow: {
            var m = Backend.profileStore.supportedFps()
            pfFps.model = m
            var i = m.indexOf(Backend.profileStore.normalizeFps(fpsValue))
            pfFps.currentIndex = i   // -1 when unsupported -> Save disabled until chosen
        }

        contentItem: GridLayout {
            columns: 2
            columnSpacing: 10
            rowSpacing: 8
            Label { text: "Name:" }
            TextField { id: pfName; objectName: "pfName"; Layout.preferredWidth: 320; selectByMouse: true }
            Label { text: "Width:" }
            TextField { id: pfWidth; objectName: "pfWidth"; Layout.fillWidth: true; selectByMouse: true; inputMethodHints: Qt.ImhDigitsOnly }
            Label { text: "Height:" }
            TextField { id: pfHeight; objectName: "pfHeight"; Layout.fillWidth: true; selectByMouse: true; inputMethodHints: Qt.ImhDigitsOnly }
            Label { text: "Aspect ratio:" }
            Label { text: profileEditor.aspectText; color: colorHighlight }
            Label { text: "Frame rate:" }
            ComboBox { id: pfFps; objectName: "pfFps"; Layout.fillWidth: true }
            Label { text: "Description:" }
            TextField { id: pfDesc; objectName: "pfDesc"; Layout.fillWidth: true; selectByMouse: true }
            Label {
                objectName: "pfError"
                Layout.columnSpan: 2
                Layout.preferredWidth: 400
                text: profileEditor.errorText
                color: "#ff6b6b"
                wrapMode: Text.WordWrap
                visible: text !== ""
            }
        }

        footer: DialogButtonBox {
            Button {
                objectName: "pfSave"
                text: "Save"
                enabled: profileEditor.errorText === ""
                DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
            }
            Button { text: "Cancel"; DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
        }

        onAccepted: {
            var m = { name: pfName.text, w: parseInt(pfWidth.text), h: parseInt(pfHeight.text),
                      fps: pfFps.currentText, description: pfDesc.text }
            var err = (mode === "edit") ? Backend.profileStore.updateCustom(originalName, m)
                                        : Backend.profileStore.addCustom(m)
            if (err !== "") { console.warn("Profile save failed:", err); return }
            projectSettingsWindow.rebuildProfiles(m.name.trim())
        }
    }

    Dialog {
        id: deleteProfileDialog
        objectName: "deleteProfileDialog"
        title: "Delete Profile"
        modal: true
        anchors.centerIn: parent
        property string profName: profileList.currentIndex >= 0 ? profileModel.get(profileList.currentIndex).name : ""
        contentItem: Label {
            text: "Delete the custom profile \"" + deleteProfileDialog.profName + "\"?\n\nProjects that use these values are not changed."
            wrapMode: Text.WordWrap
        }
        footer: DialogButtonBox {
            Button { objectName: "pfDeleteConfirm"; text: "Delete"; DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole }
            Button { text: "Cancel"; DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
        }
        onAccepted: {
            var i = profileList.currentIndex
            var keep = (i > 0) ? profileModel.get(i - 1).name : ""
            Backend.profileStore.removeCustom(profName)
            rebuildProfiles(keep)
        }
    }

    // Shared by both the new-project (global defaults) and existing-project
    // (per-project, falling back to global) branches above.
    function loadProxySettings(enabled, targetResolution, activeResolution, formatId, pauseDuringPlayback, computeDevice) {
        proxyEnabledCheckBox.checked = enabled

        var presetIdx = proxyResolutionPresets.indexOf(targetResolution)
        if (presetIdx >= 0) {
            proxyTargetResolutionCombo.currentIndex = presetIdx
        } else {
            proxyTargetResolutionCombo.currentIndex = proxyResolutionPresets.length // Custom
            var res = parseResolution(targetResolution)
            proxyCustomWidthSpin.value = res.width
            proxyCustomHeightSpin.value = res.height
        }

        // Refresh explicitly rather than relying on the ComboBox's own
        // declarative `model:` binding (still set below, for the very
        // first creation) - that binding is a plain JS expression wrapping
        // an Q_INVOKABLE method call, which QML evaluates ONCE at
        // component creation and never again, since no property-changed
        // signal is involved. Without this, "Active resolution" was stuck
        // showing only whatever existed (usually just "Original") at the
        // moment this dialog was first ever created for the whole app
        // session, never picking up proxies generated afterward.
        proxyActiveResolutionCombo.model = ["Original (no proxy)"].concat(
            Backend.cacheManager ? Backend.cacheManager.getAvailableProxyResolutions() : [])
        var activeIdx = proxyActiveResolutionCombo.model.indexOf(activeResolution)
        proxyActiveResolutionCombo.currentIndex = activeIdx >= 0 ? activeIdx : 0

        var formatIdx = 0
        for (var i = 0; i < proxyFormats.length; i++) {
            if (proxyFormats[i].id === formatId) { formatIdx = i; break }
        }
        proxyFormatCombo.currentIndex = formatIdx

        proxyPauseDuringPlaybackCheckBox.checked = pauseDuringPlayback

        var deviceIdx = proxyComputeDeviceCombo.deviceTokens.indexOf(computeDevice)
        proxyComputeDeviceCombo.currentIndex = deviceIdx >= 0 ? deviceIdx : 0
    }

    signal accepted()
    // The OK handler changed proxy state that rebuilds the preview: main.qml
    // shows its blocking "switching" overlay and runs the (synchronous)
    // install itself, so the overlay is painted before that work starts.
    signal proxySwitchRequested(string label)
    signal rejected()

    // Folder dialog for selecting project location
    FolderDialog {
        id: folderDialog
        title: "Select Project Location"
        onAccepted: {
            projectLocationField.text = selectedFolder.toString().replace("file://", "")
        }
    }

    // Kdenlive / Breeze Dark színpaletta
    readonly property color colorBackground: "#31363b"
    readonly property color colorPanel: "#232629" // Listák, beviteli mezők háttere
    readonly property color colorText: "#eff0f1"
    readonly property color colorDisabled: "#7a7c7f"
    readonly property color colorHighlight: "#3daee9" // Kdenlive kék
    readonly property color colorBorder: "#5d6066"

    color: colorBackground

    // Proxy format shortlist, per proxy_build_plan.md B.6 (final decision,
    // 2026-11-03). gbPerHour is the MEASURED (B.4/B.5) rate at the
    // measurement baseline resolution (1920x820, except DNxHR which is
    // pinned to 1920x1080 regardless of the targetResolution setting - its
    // encoder only accepts two fixed resolutions, see B.5). Scaled to the
    // user's actual target resolution in proxyFormatHelperText() below.
    // "estimated" formats have no real Phase-0 measurement behind them -
    // the user explicitly asked for H.265 to be listed without measuring
    // it ("nem kell a h265-öt mérni... majd ha kell később").
    // `ignoresComputeDevice` marks the formats whose encoder ProxyGenerator
    // hardcodes instead of resolving through the device-aware encoder picker
    // (jpegenc / avenc_dnxhd, or no encoder at all for raw) - the Compute
    // device setting below genuinely has no effect on them, so the helper
    // text says so rather than letting the picker imply otherwise. The
    // H.26x labels deliberately no longer name NVENC: which encoder runs is
    // now the Compute device setting's business, not the format's.
    readonly property var proxyFormats: [
        { id: "h264_intra", label: "H.264 all-intra", gbPerHour: 0.9, estimated: false },
        { id: "h264_longgop", label: "H.264 long-GOP", gbPerHour: 7.0, estimated: false },
        { id: "h265_intra", label: "H.265 all-intra", gbPerHour: 3.5, estimated: true },
        { id: "mjpeg", label: "MJPEG", gbPerHour: 27.2, estimated: false, ignoresComputeDevice: "fixed CPU encoder" },
        { id: "raw_i420", label: "Raw I420 (uncompressed)", gbPerHour: 203.8, estimated: false, ignoresComputeDevice: "no encoder at all" },
        { id: "dnxhr_lb", label: "DNxHR LB", gbPerHour: 16.3, estimated: false, fixedResolution: "1920x1080", ignoresComputeDevice: "fixed CPU encoder" }
    ]
    readonly property var proxyResolutionPresets: ["1920x1080", "1280x720", "960x540", "640x360"]
    // Baseline the measured gbPerHour figures were measured at (B.4/B.5's
    // source proxy resolution) - used to scale the estimate to whatever
    // targetResolution the user actually picks.
    readonly property size proxyMeasurementBaseline: Qt.size(1920, 820)

    function parseResolution(token) {
        var parts = token.split("x")
        return Qt.size(parseInt(parts[0]) || 1, parseInt(parts[1]) || 1)
    }

    function proxyFormatHelperText(formatId, targetResolutionToken) {
        var fmt = null
        for (var i = 0; i < proxyFormats.length; i++) {
            if (proxyFormats[i].id === formatId) { fmt = proxyFormats[i]; break }
        }
        if (!fmt) return ""

        var gbPerHour = fmt.gbPerHour
        var note = fmt.estimated ? " (estimated, not yet measured)" : ""
        if (fmt.fixedResolution) {
            note += " · fixed at " + fmt.fixedResolution + ", ignores the resolution setting below"
        } else {
            var target = parseResolution(targetResolutionToken)
            var scale = (target.width * target.height) / (proxyMeasurementBaseline.width * proxyMeasurementBaseline.height)
            gbPerHour = fmt.gbPerHour * scale
        }
        if (fmt.ignoresComputeDevice) {
            note += " · " + fmt.ignoresComputeDevice + ", ignores the compute device setting below"
        }
        return "≈ " + gbPerHour.toFixed(1) + " GB/hour of footage" + note
    }

    // Egyedi stílus komponensek
    component StyledTabButton : TabButton {
        id: control
        contentItem: Text {
            text: control.text
            font.pixelSize: 13
            color: control.checked ? colorText : colorDisabled
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        background: Rectangle {
            color: "transparent"
            // Kék csík alul, ha aktív
            Rectangle {
                width: parent.width
                height: 2
                anchors.bottom: parent.bottom
                color: colorHighlight
                visible: control.checked
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 10

        // 1. FÜLEK (TABS)
        TabBar {
            id: tabBar
            Layout.fillWidth: true
            background: Rectangle { color: "transparent" } // Nincs háttér
            
            StyledTabButton { text: "Settings" }
            StyledTabButton { text: "Proxy" }
            StyledTabButton { text: "Cache" }
            StyledTabButton { text: "Markers" }
            StyledTabButton { text: "Metadata" }
        }

        // TARTALOM
        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: tabBar.currentIndex

            // --- SETTINGS TAB (A kép alapján) ---
            Item {
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 15

                    // 0) PROJECT INFO SECTION (File, Name, Description)
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 180
                        color: "transparent"
                        border.color: colorBorder
                        border.width: 1
                        radius: 3

                        GridLayout {
                            anchors.fill: parent
                            anchors.margins: 10
                            columns: 3
                            rowSpacing: 8
                            columnSpacing: 8

                            // File name
                            Label {
                                text: "File name:*"
                                color: colorText
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            TextField {
                                id: fileNameField
                                Layout.fillWidth: true
                                placeholderText: "myproject.gpucs"
                                color: colorText
                                Accessible.role: Accessible.EditableText
                                Accessible.name: "File name"
                                background: Rectangle {
                                    color: colorPanel
                                    border.color: colorBorder
                                    radius: 2
                                }
                                onTextChanged: {
                                    // Auto-fill project name if not manually edited
                                    if (!projectSettingsWindow.projectNameManuallyEdited) {
                                        var baseName = text.replace(/\.[^/.]+$/, "")
                                        projectNameField.text = baseName
                                    }
                                }
                            }
                            Item { Layout.preferredWidth: 1 }

                            // Project location
                            Label {
                                text: "Location:*"
                                color: colorText
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            TextField {
                                id: projectLocationField
                                Layout.fillWidth: true
                                placeholderText: "/path/to/project"
                                color: colorText
                                Accessible.role: Accessible.EditableText
                                Accessible.name: "Project location"
                                background: Rectangle {
                                    color: colorPanel
                                    border.color: colorBorder
                                    radius: 2
                                }
                            }
                            Button {
                                // Plain ASCII, not an emoji glyph - U+1F4C1
                                // (folder) renders as a missing-glyph box
                                // on systems without a color-emoji font
                                // installed (confirmed on this machine).
                                text: "..."
                                Accessible.name: "Choose project location"
                                Layout.preferredWidth: 40
                                background: Rectangle {
                                    color: "#4d5057"
                                    radius: 2
                                }
                                contentItem: Text {
                                    text: parent.text
                                    color: colorText
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                onClicked: {
                                    // Set the dialog to start from the current location
                                    if (projectLocationField.text) {
                                        folderDialog.currentFolder = "file://" + projectLocationField.text
                                    }
                                    folderDialog.open()
                                }
                            }

                            // Project name
                            Label {
                                text: "Project name:*"
                                color: colorText
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            TextField {
                                id: projectNameField
                                Layout.fillWidth: true
                                Layout.columnSpan: 2
                                placeholderText: "My Project"
                                color: colorText
                                Accessible.role: Accessible.EditableText
                                Accessible.name: "Project name"
                                background: Rectangle {
                                    color: colorPanel
                                    border.color: colorBorder
                                    radius: 2
                                }
                                onTextEdited: {
                                    projectSettingsWindow.projectNameManuallyEdited = true
                                }
                            }

                            // Resolved project folder (new projects only).
                            // "Location" is the PARENT folder the user
                            // browses to; the project gets its own
                            // dedicated subfolder inside it so its
                            // .cache/ is never shared with an unrelated
                            // project (see CacheManager::initialize()).
                            Label {
                                text: "Project folder:"
                                color: colorText
                                visible: projectSettingsWindow.isNewProject
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.columnSpan: 2
                                visible: projectSettingsWindow.isNewProject
                                spacing: 2

                                Label {
                                    id: resolvedFolderLabel
                                    Layout.fillWidth: true
                                    elide: Text.ElideMiddle
                                    font.pixelSize: 11

                                    property bool conflict: projectSettingsWindow.isNewProject
                                        && projectLocationField.text.trim() !== ""
                                        && projectNameField.text.trim() !== ""
                                        && Backend.projectFolderWouldConflict(
                                               projectLocationField.text, projectNameField.text)

                                    color: conflict ? "#e74c3c" : colorText
                                    text: {
                                        if (!projectSettingsWindow.isNewProject) return ""
                                        if (projectLocationField.text.trim() === "") return "—"
                                        if (projectNameField.text.trim() === "") return "—"
                                        var p = Backend.resolveProjectFolderPath(
                                            projectLocationField.text, projectNameField.text)
                                        return conflict ? (p + "  (already exists)") : p
                                    }
                                }
                                Label {
                                    id: folderErrorLabel
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    color: "#e74c3c"
                                    font.pixelSize: 11
                                    visible: text !== ""
                                    text: ""
                                }
                            }

                            // Description
                            Label {
                                text: "Description:"
                                color: colorText
                                Layout.alignment: Qt.AlignRight | Qt.AlignTop
                                Layout.topMargin: 5
                            }
                            TextArea {
                                id: projectDescriptionField
                                Layout.fillWidth: true
                                Layout.columnSpan: 2
                                Layout.preferredHeight: 50
                                placeholderText: "Optional project description..."
                                color: colorText
                                wrapMode: TextArea.Wrap
                                background: Rectangle {
                                    color: colorPanel
                                    border.color: colorBorder
                                    radius: 2
                                }
                            }
                        }
                    }

                    // B) PROFILE SELECTION (Középső nagy blokk)
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 5

                        Label {
                            text: "Select the profile (preset) of the project"
                            color: colorText
                            font.bold: true
                            Layout.alignment: Qt.AlignHCenter
                        }

                        // Kis térköz
                        Item { Layout.preferredHeight: 8 }

                        // Lista és Részletek SplitView
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            Layout.minimumHeight: 180
                            color: "transparent"
                            border.color: colorBorder
                            
                            RowLayout {
                                anchors.fill: parent
                                spacing: 0

                                // Left side: profile list + management buttons
                                ColumnLayout {
                                    Layout.fillHeight: true
                                    Layout.fillWidth: false
                                    Layout.preferredWidth: parent.width * 0.6
                                    Layout.maximumWidth: parent.width * 0.6
                                    spacing: 4

                                ListView {
                                    id: profileList
                                    Layout.fillHeight: true
                                    Layout.fillWidth: true
                                    clip: true
                                    model: ListModel { id: profileModel }

                                    delegate: Rectangle {
                                        width: ListView.view.width
                                        height: 25
                                        color: ListView.isCurrentItem ? "#2d5d7b" : "transparent"

                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.left: parent.left
                                            anchors.leftMargin: 5
                                            anchors.right: tagText.left
                                            anchors.rightMargin: 4
                                            elide: Text.ElideRight
                                            text: model.name
                                            color: model.isTransient ? colorHighlight : colorText
                                            font.pixelSize: 12
                                            font.italic: model.isTransient
                                        }
                                        Text {
                                            id: tagText
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.right: parent.right
                                            anchors.rightMargin: 6
                                            visible: !model.builtin && !model.isTransient
                                            text: "custom"
                                            color: colorHighlight
                                            font.pixelSize: 10
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            onClicked: profileList.currentIndex = index
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.margins: 4
                                    spacing: 4
                                    property var sel: profileList.currentIndex >= 0 ? profileModel.get(profileList.currentIndex) : null
                                    property bool selAuto: sel ? sel.isAuto : true
                                    property bool selEditable: sel ? (!sel.builtin && !sel.isTransient) : false
                                    Button {
                                        id: newProfileBtn; objectName: "profileNewBtn"
                                        text: "New..."; Layout.fillWidth: true
                                        onClicked: projectSettingsWindow.openProfileEditor("new", null)
                                    }
                                    Button {
                                        id: dupProfileBtn; objectName: "profileDuplicateBtn"
                                        text: "Duplicate"; Layout.fillWidth: true
                                        enabled: !parent.selAuto
                                        onClicked: projectSettingsWindow.duplicateSelectedProfile()
                                    }
                                    Button {
                                        id: editProfileBtn; objectName: "profileEditBtn"
                                        text: "Edit..."; Layout.fillWidth: true
                                        enabled: parent.selEditable
                                        onClicked: projectSettingsWindow.openProfileEditor("edit", profileModel.get(profileList.currentIndex))
                                    }
                                    Button {
                                        id: deleteProfileBtn; objectName: "profileDeleteBtn"
                                        text: "Delete"; Layout.fillWidth: true
                                        enabled: parent.selEditable
                                        onClicked: deleteProfileDialog.open()
                                    }
                                }
                                }

                                // Elválasztó
                                Rectangle { width: 1; Layout.fillHeight: true; color: colorBorder }

                                // Jobb oldal: Részletek
                                Rectangle {
                                    Layout.fillHeight: true
                                    Layout.fillWidth: true
                                    color: colorPanel
                                    
                                    ColumnLayout {
                                        anchors.fill: parent
                                        anchors.margins: 10
                                        spacing: 5

                                        property var currentProfile: profileList.currentIndex >= 0 ? profileModel.get(profileList.currentIndex) : null

                                        Label { text: "Video Settings"; font.bold: true; color: colorText }
                                        Rectangle { height: 1; Layout.fillWidth: true; color: colorBorder }

                                        // Automatic mode explanation
                                        Label {
                                            visible: parent.currentProfile && parent.currentProfile.isAuto
                                            text: "Profile will be automatically determined from the first video file added to the project."
                                            color: colorText
                                            font.pixelSize: 11
                                            wrapMode: Text.WordWrap
                                            Layout.fillWidth: true
                                            Layout.topMargin: 10
                                        }

                                        // Manual profile details
                                        ColumnLayout {
                                            visible: parent.currentProfile && !parent.currentProfile.isAuto
                                            spacing: 5
                                            Layout.fillWidth: true

                                            Label {
                                                text: parent.parent.currentProfile ? ("Frame size: " + parent.parent.currentProfile.w + " x " + parent.parent.currentProfile.h) : "Frame size: -"
                                                color: colorText
                                                font.pixelSize: 11
                                            }
                                            Label {
                                                text: parent.parent.currentProfile ? ("Frame rate: " + parent.parent.currentProfile.fps + " fps") : "Frame rate: -"
                                                color: colorText
                                                font.pixelSize: 11
                                            }
                                            Label { text: "Pixel aspect ratio: 1.0"; color: colorText; font.pixelSize: 11 }
                                            Label {
                                                text: parent.parent.currentProfile ? ("Display aspect ratio: " + parent.parent.currentProfile.aspect) : "Display aspect ratio: -"
                                                color: colorText
                                                font.pixelSize: 11
                                            }
                                            Label { text: "Color space: ITU-R 709"; color: colorText; font.pixelSize: 11 }
                                            Label { text: "Interlaced: no"; color: colorText; font.pixelSize: 11 }
                                            Label {
                                                visible: parent.parent.currentProfile && parent.parent.currentProfile.description !== ""
                                                text: parent.parent.currentProfile ? parent.parent.currentProfile.description : ""
                                                color: colorDisabled
                                                font.pixelSize: 11
                                                wrapMode: Text.WordWrap
                                                Layout.fillWidth: true
                                                Layout.topMargin: 8
                                            }
                                        }

                                        Item { Layout.fillHeight: true } // Kitöltés
                                    }
                                }
                            }
                        }
                    }

                    // B2) CLIP FITTING (project default for newly added clips)
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: fitGroupCol.implicitHeight + 16
                        color: "transparent"
                        border.color: colorBorder
                        radius: 3

                        ColumnLayout {
                            id: fitGroupCol
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 4
                            Label {
                                text: "Clip fitting - how a newly added clip is placed in the frame"
                                color: colorText
                                font.bold: true
                                font.pixelSize: 11
                            }
                            FitControls {
                                id: fitControls
                                objectName: "fitControls"
                                Layout.fillWidth: true
                                textColor: colorText
                                dimColor: colorDisabled
                                panelColor: colorPanel
                                borderColor: colorBorder
                            }

                            // plan_home_end_canvasframe.md: moved here from the
                            // monitor's control row. The stored key stays
                            // monitor/showCanvasFrame (app-wide view preference,
                            // not part of the project JSON).
                            CheckBox {
                                id: canvasFrameCheckBox
                                objectName: "canvasFrameCheckBox"
                                text: "Show canvas frame in the monitor"
                                contentItem: Text { text: parent.text; color: colorText; leftPadding: parent.indicator.width + 4 }
                            }
                            Label {
                                text: "Outline around the project canvas. Only with the GL video output."
                                color: colorDisabled
                                font.pixelSize: 11
                                wrapMode: Text.WordWrap
                                Layout.fillWidth: true
                            }
                        }
                    }

                    Rectangle { height: 1; Layout.fillWidth: true; color: colorBorder }

                    // C) ALSÓ BEÁLLÍTÁSOK (Tracks, Audio, etc.)
                    GridLayout {
                        columns: 2
                        rowSpacing: 10
                        columnSpacing: 15
                        Layout.fillWidth: true

                        // Video Tracks
                        Label { text: "Video tracks:"; color: colorText; Layout.alignment: Qt.AlignRight }
                        SpinBox {
                            id: videoTracksSpinBox
                            value: 2
                            editable: true
                            Layout.preferredHeight: 30
                            contentItem: TextInput {
                                text: parent.value
                                color: colorText
                                verticalAlignment: Qt.AlignVCenter
                                horizontalAlignment: Qt.AlignHCenter
                                readOnly: true
                            }
                            background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 2 }
                        }

                        // Audio Tracks
                        Label { text: "Audio tracks:"; color: colorText; Layout.alignment: Qt.AlignRight }
                        SpinBox {
                            id: audioTracksSpinBox
                            value: 2
                            editable: true
                            Layout.preferredHeight: 30
                            contentItem: TextInput {
                                text: parent.value
                                color: colorText
                                verticalAlignment: Qt.AlignVCenter
                                horizontalAlignment: Qt.AlignHCenter
                                readOnly: true
                            }
                            background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 2 }
                        }

                        // Thumbnails
                        Label { text: "Thumbnails:"; color: colorText; Layout.alignment: Qt.AlignRight | Qt.AlignTop }
                        ColumnLayout {
                            CheckBox {
                                id: videoThumbnailsCheckBox
                                text: "Video"
                                checked: true
                                contentItem: Text { text: parent.text; color: colorText; leftPadding: parent.indicator.width + 4 }
                            }
                            CheckBox {
                                id: audioThumbnailsCheckBox
                                text: "Audio"
                                checked: true
                                contentItem: Text { text: parent.text; color: colorText; leftPadding: parent.indicator.width + 4 }
                            }
                        }

                        // Timeline Preview
                        Label { text: "Timeline Preview:"; color: colorText; Layout.alignment: Qt.AlignRight }
                        RowLayout {
                            Layout.fillWidth: true
                            ComboBox {
                                id: timelinePreviewCombo
                                model: [
                                    "NVIDIA NVDEC (Hardware)",
                                    "VA-API (Hardware)",
                                    "Software (CPU)"
                                ]
                                currentIndex: 0
                                onActivated: projectSettingsWindow.decoderTouched = true
                                Layout.fillWidth: true
                                Layout.preferredHeight: 30
                                contentItem: Text {
                                    text: parent.displayText
                                    color: colorText
                                    verticalAlignment: Text.AlignVCenter
                                    leftPadding: 8
                                }
                                background: Rectangle {
                                    color: colorPanel
                                    border.color: colorBorder
                                    radius: 2
                                }
                            }
                        }
                    }
                }
            }

            // --- PROXY TAB ---
            Item {
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 14

                    CheckBox {
                        id: proxyEnabledCheckBox
                        text: "Enable proxy editing for this project"
                        checked: false
                        contentItem: Text { text: parent.text; color: colorText; leftPadding: parent.indicator.width + 4 }
                    }

                    GridLayout {
                        columns: 2
                        rowSpacing: 10
                        columnSpacing: 15
                        Layout.fillWidth: true
                        enabled: proxyEnabledCheckBox.checked
                        opacity: enabled ? 1.0 : 0.5

                        // Target resolution
                        Label { text: "Proxy resolution:"; color: colorText; Layout.alignment: Qt.AlignRight }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            ComboBox {
                                id: proxyTargetResolutionCombo
                                Layout.preferredWidth: 160
                                Layout.preferredHeight: 30
                                model: proxyResolutionPresets.concat(["Custom"])
                                contentItem: Text { text: parent.displayText; color: colorText; verticalAlignment: Text.AlignVCenter; leftPadding: 8 }
                                background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 2 }
                            }
                            SpinBox {
                                id: proxyCustomWidthSpin
                                visible: proxyTargetResolutionCombo.currentIndex === proxyResolutionPresets.length
                                from: 16; to: 7680; value: 960
                                editable: true
                                Layout.preferredWidth: 90
                                Layout.preferredHeight: 30
                                background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 2 }
                                contentItem: TextInput { text: parent.value; color: colorText; horizontalAlignment: Qt.AlignHCenter; verticalAlignment: Qt.AlignVCenter; readOnly: true }
                            }
                            Label { text: "×"; color: colorText; visible: proxyCustomWidthSpin.visible }
                            SpinBox {
                                id: proxyCustomHeightSpin
                                visible: proxyTargetResolutionCombo.currentIndex === proxyResolutionPresets.length
                                from: 16; to: 4320; value: 540
                                editable: true
                                Layout.preferredWidth: 90
                                Layout.preferredHeight: 30
                                background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 2 }
                                contentItem: TextInput { text: parent.value; color: colorText; horizontalAlignment: Qt.AlignHCenter; verticalAlignment: Qt.AlignVCenter; readOnly: true }
                            }
                            // Fits INSIDE the box, preserving the source's
                            // actual aspect ratio - drone/action-cam material
                            // isn't always 16:9 (proxy_build_plan.md F.1).
                            Label { text: "(fits inside, keeps aspect ratio)"; color: colorDisabled; font.pixelSize: 11 }
                        }

                        // Active resolution - which already-generated set preview uses
                        Label { text: "Active resolution:"; color: colorText; Layout.alignment: Qt.AlignRight }
                        ComboBox {
                            id: proxyActiveResolutionCombo
                            Layout.preferredWidth: 220
                            Layout.preferredHeight: 30
                            // Populated with "Original (no proxy)" plus
                            // whatever WxH variants currently exist on disk
                            // (CacheManager::getAvailableProxyResolutions())
                            // - re-read each time the dialog opens, since
                            // nothing else here triggers live model updates.
                            model: ["Original (no proxy)"].concat(
                                Backend.cacheManager ? Backend.cacheManager.getAvailableProxyResolutions() : [])
                            contentItem: Text { text: parent.displayText; color: colorText; verticalAlignment: Text.AlignVCenter; leftPadding: 8 }
                            background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 2 }
                        }

                        // Format
                        Label { text: "Format:"; color: colorText; Layout.alignment: Qt.AlignRight | Qt.AlignTop }
                        ColumnLayout {
                            spacing: 4
                            ComboBox {
                                id: proxyFormatCombo
                                Layout.preferredWidth: 260
                                Layout.preferredHeight: 30
                                model: proxyFormats.map(function(f) { return f.label })
                                contentItem: Text { text: parent.displayText; color: colorText; verticalAlignment: Text.AlignVCenter; leftPadding: 8 }
                                background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 2 }
                            }
                            Label {
                                text: proxyFormatHelperText(
                                    proxyFormats[proxyFormatCombo.currentIndex] ? proxyFormats[proxyFormatCombo.currentIndex].id : "h264_intra",
                                    proxyTargetResolutionCombo.currentIndex === proxyResolutionPresets.length
                                        ? (proxyCustomWidthSpin.value + "x" + proxyCustomHeightSpin.value)
                                        : proxyResolutionPresets[proxyTargetResolutionCombo.currentIndex])
                                color: colorDisabled
                                font.pixelSize: 11
                            }
                        }

                        // Compute device - which GPU/CPU generates the
                        // proxy, independent of the timeline's own preview
                        // decode device (Phase 4). Reuses the exact same
                        // backend tokens ("nvidia"/"vaapi"/"cpu") the
                        // render encoder picker already uses, rather than
                        // inventing a parallel device-identifier scheme -
                        // Backend.gpuDevices supplies real, detected
                        // hardware names/vendors for the labels.
                        Label { text: "Compute device:"; color: colorText; Layout.alignment: Qt.AlignRight }
                        ComboBox {
                            id: proxyComputeDeviceCombo
                            Layout.preferredWidth: 260
                            Layout.preferredHeight: 30
                            // deviceTokens[i] is the backend string actually
                            // passed to CacheManager::requestProxyGeneration()
                            // for model index i - "" (Auto) means prefer
                            // GPU, same fallback order as before Phase 4.
                            // Backend.gpuDevices' "id" is "nvidia-0"/
                            // "vaapi-0"/"cpu" - ONE entry per vendor, not per
                            // physical card (BackendManager::detectGPUDevices()
                            // hardcodes that; real per-device enumeration is
                            // Part D.3/D.4 of the plan and needs multi-GPU
                            // hardware to validate). On a two-identical-cards
                            // machine this list would therefore show a single
                            // entry for both - a known limitation, not a bug
                            // in this picker.
                            //
                            // Take the segment before the FIRST "-" rather
                            // than stripping a trailing "-<digits>": the plan's
                            // own future ids are "nvidia-<uuid>" and
                            // "vaapi-<renderNode>", neither of which ends in
                            // digits, so a trailing-digit strip would silently
                            // emit an unknown backend token the moment real
                            // enumeration lands (every device choice would
                            // then quietly degrade to Auto).
                            property var deviceTokens: [""].concat(Backend.gpuDevices.map(function(d) { return d.id.split("-")[0] }))
                            model: ["Auto (prefer GPU)"].concat(Backend.gpuDevices.map(function(d) { return d.name + " (" + d.vendor + ")" }))
                            contentItem: Text { text: parent.displayText; color: colorText; verticalAlignment: Text.AlignVCenter; leftPadding: 8 }
                            background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 2 }
                        }

                        // Pause generation during playback
                        Label { text: ""; Layout.alignment: Qt.AlignRight }
                        CheckBox {
                            id: proxyPauseDuringPlaybackCheckBox
                            text: "Pause proxy generation during playback"
                            checked: false
                            contentItem: Text { text: parent.text; color: colorText; leftPadding: parent.indicator.width + 4 }
                        }

                        // Bulk, explicit, opt-in - NOT automatic background
                        // generation (that's Phase 6, still undecided/
                        // unbuilt). For the "I dumped a folder of footage
                        // in tonight, want it all proxied by morning"
                        // case the user explicitly asked for, on top of
                        // (not instead of) the timeline-driven default
                        // being considered for Phase 6.
                        Label { text: ""; Layout.alignment: Qt.AlignRight | Qt.AlignTop }
                        ColumnLayout {
                            spacing: 4
                            Button {
                                text: "Generate Proxy for All Bin Items"
                                onClicked: {
                                    var res = proxyTargetResolutionCombo.currentIndex === proxyResolutionPresets.length
                                        ? (proxyCustomWidthSpin.value + "x" + proxyCustomHeightSpin.value)
                                        : proxyResolutionPresets[proxyTargetResolutionCombo.currentIndex]
                                    var fmt = proxyFormats[proxyFormatCombo.currentIndex] ? proxyFormats[proxyFormatCombo.currentIndex].id : "h264_intra"
                                    var dev = proxyComputeDeviceCombo.deviceTokens[proxyComputeDeviceCombo.currentIndex]
                                    var ids = Backend.projectBinModel.videoItemIds()
                                    for (var i = 0; i < ids.length; i++) {
                                        // Skip what's already done at this exact
                                        // (resolution, format) variant -
                                        // requestProxyGeneration() itself only
                                        // guards against re-queueing something
                                        // already pending/generating, not
                                        // something already finished. Passing
                                        // fmt here matters (registry v3,
                                        // Part J.1): without it, an item
                                        // already "ready" in a DIFFERENT
                                        // format at this resolution would be
                                        // wrongly skipped instead of generating
                                        // the format actually selected above.
                                        if (Backend.cacheManager.getProxyStatus(ids[i], res, fmt) === "ready") continue
                                        Backend.cacheManager.requestProxyGeneration(ids[i], res, fmt, dev)
                                    }
                                }
                            }
                            Label {
                                text: "Queues every video file currently in the Project Bin, using the resolution/format/device above. Progress shows in the Render workspace's Proxy Queue tab."
                                color: colorDisabled
                                font.pixelSize: 11
                                wrapMode: Text.WordWrap
                                Layout.maximumWidth: 320
                            }
                        }
                    }

                    Item { Layout.fillHeight: true }
                }
            }
            // --- CACHE TAB ---
            // Per-project (the .cache/ dir lives inside the project
            // folder, see proxy_build_plan.md A.4/F.2) - moved here from
            // the global Settings dialog after reconsidering: a GLOBAL
            // cache browser has no single project to act on. Scrollable
            // (ScrollView) in anticipation of the real per-category/
            // per-resolution browser (Phase 8) growing past one screen;
            // this phase just reserves the tab and its scroll behavior.
            Item {
                ScrollView {
                    anchors.fill: parent
                    clip: true
                    ColumnLayout {
                        width: parent.width
                        spacing: 12

                        Label {
                            text: "Cache"
                            color: colorHighlight
                            font.pixelSize: 14
                            font.bold: true
                        }

                        Label {
                            Layout.fillWidth: true
                            text: "Per-resolution proxy and waveform cache usage for this project — path, size, item counts, Reveal/Clear — coming in a later phase."
                            color: colorDisabled
                            font.pixelSize: 12
                            wrapMode: Text.WordWrap
                        }

                        Label {
                            Layout.fillWidth: true
                            text: "Location: " + (Backend.cacheManager ? Backend.cacheManager.cacheDir : "")
                            color: colorDisabled
                            font.pixelSize: 11
                            font.family: "Monospace"
                            elide: Text.ElideMiddle
                        }
                    }
                }
            }

            Item { Text { text: "Markers"; color: colorText; anchors.centerIn: parent } }
            Item { Text { text: "Metadata"; color: colorText; anchors.centerIn: parent } }
        }

        // 3. LÁBLÉC (GOMBOK)
        RowLayout {
            Layout.alignment: Qt.AlignRight
            spacing: 10

            Button {
                text: "Cancel"
                Accessible.name: "Cancel project settings"
                onClicked: {
                    projectSettingsWindow.rejected()
                    projectSettingsWindow.close()
                }
                background: Rectangle {
                    color: "transparent"
                    border.color: colorBorder
                    radius: 2
                }
                contentItem: Text { text: parent.text; color: colorText; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
            }

            Button {
                text: "✓ OK"
                highlighted: true
                Accessible.name: "Confirm project settings"
                // Catches the conflict case before the user can even
                // click - the inline red error in the click handler
                // below is still there as a fallback (e.g. the conflict
                // appearing between opening the dialog and clicking).
                enabled: fileNameField.text.trim() !== ""
                         && projectLocationField.text.trim() !== ""
                         && projectNameField.text.trim() !== ""
                         && !(projectSettingsWindow.isNewProject
                              && Backend.projectFolderWouldConflict(
                                     projectLocationField.text, projectNameField.text))
                opacity: enabled ? 1.0 : 0.5
                onClicked: {
                    // Validate required fields
                    if (fileNameField.text.trim() === "") {
                        console.log("Error: File name is required")
                        return
                    }
                    if (projectLocationField.text.trim() === "") {
                        console.log("Error: Location is required")
                        return
                    }
                    if (projectNameField.text.trim() === "") {
                        console.log("Error: Project name is required")
                        return
                    }

                    // For a NEW project, create its own dedicated folder
                    // now and treat THAT as project/location from here
                    // on: the user's "Location" is only the parent. Done
                    // before accepted() is emitted, because main.qml's
                    // onAccepted already clears the project bin and
                    // resets the timeline - a failure after that point
                    // would leave a half-created project with nowhere to
                    // save. For isNewProject === false (Project
                    // Settings of an already-open project) the location
                    // is used verbatim and no folder is created/moved.
                    var effectiveLocation = projectLocationField.text.trim()
                    if (projectSettingsWindow.isNewProject) {
                        if (Backend.projectFolderWouldConflict(effectiveLocation, projectNameField.text)) {
                            folderErrorLabel.text =
                                "\"" + Backend.resolveProjectFolderPath(effectiveLocation, projectNameField.text) +
                                "\" already exists. Choose a different project name or location."
                            return
                        }
                        var createdFolder = Backend.createProjectFolder(
                            effectiveLocation, projectNameField.text)
                        if (createdFolder === "") {
                            folderErrorLabel.text =
                                "Could not create the project folder in \"" +
                                effectiveLocation +
                                "\". Check that the location exists and is writable."
                            return
                        }
                        effectiveLocation = createdFolder
                        projectLocationField.text = createdFolder
                        folderErrorLabel.text = ""
                    }

                    // proxy_build_plan.md Part J.3: a target resolution/
                    // format change while proxy jobs are already queued/
                    // generating must ask first, not silently supersede
                    // them (D7'). Reads the OLD setting values - must run
                    // BEFORE any setSetting() call below overwrites them.
                    // Does NOT fire for disabling proxy editing outright
                    // (that's an unconditional cancel in commitSettings()
                    // below, no prompt needed - the user already said
                    // "stop") or for a brand-new project (nothing could
                    // possibly be queued yet).
                    var conflict = projectSettingsWindow.computeProxyQueueConflict(effectiveLocation)
                    if (conflict) {
                        proxyQueueConflictDialog.conflict = conflict
                        proxyQueueConflictDialog.effectiveLocation = effectiveLocation
                        proxyQueueConflictDialog.open()
                        return
                    }
                    projectSettingsWindow.commitSettings(effectiveLocation)
                }
                background: Rectangle {
                    color: parent.down ? "#2a9ad0" : colorHighlight
                    radius: 2
                }
                contentItem: Text { text: parent.text; color: "white"; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
            }
        }
    }

    // proxy_build_plan.md Part J.3 - D7': the mechanism (bulk dequeue,
    // CacheManager::cancelPendingProxyGeneration()) is the same one D7
    // originally proposed running automatically; what changed is WHO
    // decides. closePolicy NoAutoClose deliberately - unlike the open-time
    // backfill prompt (where "dismiss = Later" is harmless), a stray Esc
    // here would silently pick a fate for in-flight GPU work.
    Dialog {
        id: rescaleDialog
        title: "Frame Size Changes"
        modal: true
        anchors.centerIn: parent
        closePolicy: Popup.NoAutoClose

        property var sizeChange: null
        property string effectiveLocation: ""

        Label {
            width: 460
            wrapMode: Text.WordWrap
            text: rescaleDialog.sizeChange
                  ? ("The project frame size changes from " + rescaleDialog.sizeChange.oldW + "x" + rescaleDialog.sizeChange.oldH
                     + " to " + rescaleDialog.sizeChange.newW + "x" + rescaleDialog.sizeChange.newH
                     + ". Rescale the existing clip transforms (position, size, keyframes) to the new frame?")
                  : ""
        }

        footer: DialogButtonBox {
            Button { text: "Rescale"; highlighted: true; DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole }
            Button { text: "Keep as is"; DialogButtonBox.buttonRole: DialogButtonBox.DestructiveRole }
            Button { text: "Cancel"; DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
        }

        onAccepted: { projectSettingsWindow.rescaleDecision = "rescale"; projectSettingsWindow.commitSettings(effectiveLocation) }
        onDiscarded: { projectSettingsWindow.rescaleDecision = "keep"; projectSettingsWindow.commitSettings(effectiveLocation) }
        // Cancel: leave everything (profile included) as it was; the settings dialog stays open.
    }

    Dialog {
        id: proxyQueueConflictDialog
        title: "Proxy Jobs In Progress"
        modal: true
        anchors.centerIn: parent
        closePolicy: Popup.NoAutoClose

        property var conflict: null
        property string effectiveLocation: ""

        ColumnLayout {
            spacing: 15
            Label {
                Layout.preferredWidth: 440
                wrapMode: Text.WordWrap
                text: proxyQueueConflictDialog.conflict
                      ? ("You have " + proxyQueueConflictDialog.conflict.pendingCount
                         + " proxy job(s) waiting in the queue at "
                         + proxyQueueConflictDialog.conflict.oldResolution + " · "
                         + proxyQueueConflictDialog.conflict.oldFormat
                         + (proxyQueueConflictDialog.conflict.generatingCount > 0
                            ? " (one more is currently generating and will finish regardless)."
                            : "."))
                      : ""
            }
            Label {
                Layout.preferredWidth: 440
                wrapMode: Text.WordWrap
                color: "#888888"
                text: proxyQueueConflictDialog.conflict
                      ? ("Letting them finish means new proxies at "
                         + proxyQueueConflictDialog.conflict.newResolution + " · "
                         + proxyQueueConflictDialog.conflict.newFormat
                         + " will only start once the current queue drains.")
                      : ""
            }
        }

        footer: DialogButtonBox {
            Button { text: "Cancel Them"; DialogButtonBox.buttonRole: DialogButtonBox.DestructiveRole }
            Button { text: "Let Them Finish"; DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole }
        }

        // Both outcomes still save the settings change - this dialog is
        // about the fate of the QUEUE, not whether Save happens. The user
        // already pressed OK/Save; "let them finish" silently also
        // discarding that would be a third, unasked-for outcome hidden
        // behind a two-button dialog.
        onAccepted: projectSettingsWindow.commitSettings(effectiveLocation) // "Let Them Finish"
        onDiscarded: {
            // "Cancel Them" - DestructiveRole in a DialogButtonBox maps to
            // the box's discarded() signal, not accepted() - QtQuick.Controls'
            // own role-to-signal mapping, not a Part J invention.
            Backend.cacheManager.cancelPendingProxyGeneration(
                "resolution-changed", conflict.oldResolution, conflict.oldFormat)
            projectSettingsWindow.commitSettings(effectiveLocation)
        }
    }

    // Split out of the OK button's onClicked so the Part J.3 conflict
    // dialog above can delay it (or the open-time backfill prompt's
    // "Generate Now"/"Later" could, if ever threaded through here -
    // currently that one only touches already-open-project settings
    // directly via Backend, not this dialog). effectiveLocation is
    // threaded through explicitly rather than re-read from
    // projectLocationField.text, since for a brand-new project that
    // field was just rewritten to the freshly-created folder path above.
    function commitSettings(effectiveLocation) {
        // Frame-size change on an open project with transformed clips: ask
        // first (Cancel = nothing is changed at all and the dialog stays).
        rescaleRequest = null
        if (rescaleDecision === "") {
            var sc = pendingSizeChange()
            if (sc && transformCountFn && transformCountFn() > 0) {
                rescaleDialog.sizeChange = sc
                rescaleDialog.effectiveLocation = effectiveLocation
                rescaleDialog.open()
                return
            }
        }
        if (rescaleDecision === "rescale") rescaleRequest = pendingSizeChange()
        rescaleDecision = ""

        // D15/J.3.5: unchecking "Enable proxy editing" entirely cancels
        // whatever's still queued UNCONDITIONALLY, no prompt - the user
        // already said "stop", asking "are you sure you want to stop"
        // would be absurd. Read before the setSetting() below overwrites
        // it. Does NOT touch an in-flight job for the same reason the
        // Part J.3 conflict dialog doesn't: only the generator itself
        // knows when it has actually stopped.
        var wasProxyEnabled = Backend.getSetting("project/proxyEnabled", false)
        if (wasProxyEnabled && !proxyEnabledCheckBox.checked) {
            Backend.cacheManager.cancelPendingProxyGeneration("proxy-disabled")
        }

        // Save project info
        Backend.setSetting("project/fileName", fileNameField.text)
        Backend.setSetting("project/location", effectiveLocation)
        Backend.setSetting("project/name", projectNameField.text)
        Backend.setSetting("project/description", projectDescriptionField.text)

        // Save profile settings. The transient "Current project" row (and no
        // selection at all) leaves project/width/height/fps untouched.
        profileChanged = false
        if (profileList.currentIndex >= 0) {
            var selectedProfile = profileModel.get(profileList.currentIndex)
            if (selectedProfile.isTransient) {
                // keep the project's current values
            } else {
                var newW = selectedProfile.isAuto ? "auto" : selectedProfile.w
                var newH = selectedProfile.isAuto ? "auto" : selectedProfile.h
                var newF = selectedProfile.isAuto ? "auto" : selectedProfile.fps
                profileChanged = String(Backend.getSetting("project/width", "auto")) !== String(newW)
                    || String(Backend.getSetting("project/height", "auto")) !== String(newH)
                    || String(Backend.getSetting("project/fps", "auto")) !== String(newF)
                Backend.setSetting("project/width", newW)
                Backend.setSetting("project/height", newH)
                Backend.setSetting("project/fps", newF)
            }
        }

        // Clip fitting default (only affects clips added from now on)
        Backend.setSetting("project/fitScaling", fitControls.scaling)
        Backend.setSetting("project/fitAnchorH", fitControls.anchorH)
        Backend.setSetting("project/fitAnchorV", fitControls.anchorV)

        // Canvas frame is an app-wide view preference, not part of the project JSON.
        Backend.setSetting("monitor/showCanvasFrame", canvasFrameCheckBox.checked)

        // Save decoder setting
        var decoderIds = ["nvdec_h264", "vaapi_h264", "avdec_h264"]
        if (!decoderTouched && decoderOriginal !== "") {
            Backend.setSetting("project/decoder", decoderOriginal) // untouched: keep the stored value as is
        } else {
            Backend.setSetting("project/decoder", decoderIds[timelinePreviewCombo.currentIndex])
        }

        // Save track settings
        Backend.setSetting("project/videoTracks", videoTracksSpinBox.value)
        Backend.setSetting("project/audioTracks", audioTracksSpinBox.value)

        // Save thumbnail settings
        Backend.setSetting("project/videoThumbnails", videoThumbnailsCheckBox.checked)
        Backend.setSetting("project/audioThumbnails", audioThumbnailsCheckBox.checked)

        // Save proxy settings
        var oldProxyEnabled = Backend.getSetting("project/proxyEnabled", false)
        var oldProxyActive = Backend.getSetting("project/proxyActiveResolution", "Original (no proxy)")
        var oldProxyFormat = Backend.getSetting("project/proxyFormat", "h264_intra")
        Backend.setSetting("project/proxyEnabled", proxyEnabledCheckBox.checked)
        Backend.setSetting("project/proxyTargetResolution",
            proxyTargetResolutionCombo.currentIndex === proxyResolutionPresets.length
                ? (proxyCustomWidthSpin.value + "x" + proxyCustomHeightSpin.value)
                : proxyResolutionPresets[proxyTargetResolutionCombo.currentIndex])
        Backend.setSetting("project/proxyActiveResolution", proxyActiveResolutionCombo.currentText)
        Backend.setSetting("project/proxyFormat",
            proxyFormats[proxyFormatCombo.currentIndex] ? proxyFormats[proxyFormatCombo.currentIndex].id : "h264_intra")
        Backend.setSetting("project/proxyPauseDuringPlayback", proxyPauseDuringPlaybackCheckBox.checked)
        Backend.setSetting("project/proxyComputeDevice", proxyComputeDeviceCombo.deviceTokens[proxyComputeDeviceCombo.currentIndex])

        // proxy_build_plan.md Part J.4.3: proxyEnabled/proxyActiveResolution/
        // proxyFormat just (possibly) changed above - setSetting() has no
        // change-notification BackendManager could react to on its own,
        // so every QML site that writes these must explicitly ask it to
        // re-derive which proxies should be GES-installed.
        var newProxyActive = Backend.getSetting("project/proxyActiveResolution", "Original (no proxy)")
        var proxyStateChanged = (oldProxyEnabled !== Backend.getSetting("project/proxyEnabled", false))
            || (oldProxyActive !== newProxyActive)
            || (oldProxyFormat !== Backend.getSetting("project/proxyFormat", "h264_intra"))
        if (proxyStateChanged && !isNewProject) {
            var effectiveActive = Backend.getSetting("project/proxyEnabled", false) ? newProxyActive : "Original (no proxy)"
            projectSettingsWindow.proxySwitchRequested(effectiveActive === "Original (no proxy)" || effectiveActive === ""
                ? "Switching to original media…"
                : "Switching proxy to " + effectiveActive + "…")
        } else {
            Backend.refreshProxyInstallations()
        }

        projectSettingsWindow.accepted()
        projectSettingsWindow.close()
    }

    // proxy_build_plan.md Part J.3: returns {oldResolution, oldFormat,
    // newResolution, newFormat, pendingCount, generatingCount} if the
    // target variant is actually changing while proxy editing stays
    // enabled AND something is already queued/generating - null
    // otherwise (including: proxy editing being newly enabled or being
    // disabled entirely, a brand-new project, or no actual variant
    // change). Must be called BEFORE any setSetting() call in
    // commitSettings() - it reads the OLD values via Backend.getSetting.
    function computeProxyQueueConflict(effectiveLocation) {
        if (projectSettingsWindow.isNewProject) return null // nothing could be queued yet
        if (!proxyEnabledCheckBox.checked) return null // disabling has its own unconditional cancel
        var wasEnabled = Backend.getSetting("project/proxyEnabled", false)
        if (!wasEnabled) return null // newly enabling - nothing queued yet to conflict with

        var oldRes = Backend.getSetting("project/proxyTargetResolution", "960x540")
        var oldFmt = Backend.getSetting("project/proxyFormat", "h264_intra")
        var newRes = proxyTargetResolutionCombo.currentIndex === proxyResolutionPresets.length
            ? (proxyCustomWidthSpin.value + "x" + proxyCustomHeightSpin.value)
            : proxyResolutionPresets[proxyTargetResolutionCombo.currentIndex]
        var newFmt = proxyFormats[proxyFormatCombo.currentIndex] ? proxyFormats[proxyFormatCombo.currentIndex].id : "h264_intra"
        if (oldRes === newRes && oldFmt === newFmt) return null // no actual change

        var pending = Backend.cacheManager.pendingProxyCount()
        var generating = Backend.cacheManager.generatingProxyCount
        if (pending === 0 && generating === 0) return null // nothing queued to conflict with

        return {
            oldResolution: oldRes, oldFormat: oldFmt,
            newResolution: newRes, newFormat: newFmt,
            pendingCount: pending, generatingCount: generating
        }
    }
}
