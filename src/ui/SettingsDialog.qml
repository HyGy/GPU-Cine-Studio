import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import VideoEditor 1.0
import "components"

// Application-wide preferences (File > Settings...).
//
// Deliberately separate from ProjectSettingsDialog.qml, which edits the
// CURRENT PROJECT's profile (resolution/fps/location) AND its per-project
// Cache usage (the cache lives inside the project folder, so a GLOBAL
// cache browser here would have no project to act on - moved there on
// user's explicit call after reconsidering the original plan).
//
// Deliberately does NOT duplicate decoder/encoder selection - the
// decoder is already reachable from the toolbar combo box in main.qml,
// and encoder choice is a per-export setting in the Render workspace
// (RenderSettings.qml's own "Encoder Device" combo), not a global
// preference that belongs here.
//
// Sidebar (vertical) tabs, not a horizontal TabBar like
// ProjectSettingsDialog - user's explicit choice, anticipating more
// sections being added here over time than the 2 there are today.
Window {
    id: settingsWindow
    title: "Settings — GPU Cine Studio"
    width: 780
    height: 600
    minimumWidth: 520
    minimumHeight: 360
    visible: false

    modality: Qt.ApplicationModal
    flags: Qt.Dialog | Qt.WindowStaysOnTopHint

    readonly property color colorBackground: "#31363b"
    readonly property color colorPanel: "#232629"
    readonly property color colorText: "#eff0f1"
    readonly property color colorSubText: "#a0a4a8"
    readonly property color colorHighlight: "#3daee9"
    readonly property color colorBorder: "#5d6066"
    color: colorBackground

    Component.onCompleted: {
        x = (Screen.width - width) / 2
        y = (Screen.height - height) / 2
    }

    // The log file's size is read from disk, so it has to be re-read
    // every time the dialog is opened (and after a clear) - there is no
    // change notification for a plain file.
    property string logSizeText: "-"

    // Emitted when the Autosave settings change, so main.qml can refresh
    // root.autosaveEnabled / root.autosaveIntervalSec immediately.
    signal autosaveSettingsChanged()

    // Opens the dialog on the Codecs page (sidebar index 6).
    function showCodecsPage() {
        sidebar.currentIndex = 6
        show()
        raise()
    }

    function refreshLogInfo() {
        logSizeText = Backend.operationLogSize()
    }
    // Machine-wide defaults for new projects (proxy_build_plan.md F.1) -
    // same id list as ProjectSettingsDialog.qml's proxyFormats, kept in
    // sync by hand since this dialog doesn't need the GB/hour helper text.
    readonly property var proxyFormatIds: ["h264_intra", "h264_longgop", "h265_intra", "mjpeg", "raw_i420", "dnxhr_lb"]
    // No "(NVENC)" in the H.26x labels any more: which encoder actually runs
    // is the Compute device setting's business now, not the format's. The
    // three fixed-encoder formats say so, since the device picker below has
    // no effect on them (ProxyGenerator hardcodes jpegenc / avenc_dnxhd /
    // no encoder at all) - mirrors ProjectSettingsDialog's helper text.
    readonly property var proxyFormatLabels: [
        "H.264 all-intra", "H.264 long-GOP", "H.265 all-intra (estimated)",
        "MJPEG (fixed CPU encoder)", "Raw I420 (uncompressed, no encoder)", "DNxHR LB (fixed CPU encoder)"
    ]
    function loadProxyDefaults() {
        proxyDefaultEnabledCheck.checked = Backend.getSetting("proxy/defaultEnabled", false)
        var resPreset = Backend.getSetting("proxy/defaultTargetResolution", "960x540")
        var resIdx = proxyDefaultResolutionCombo.model.indexOf(resPreset)
        proxyDefaultResolutionCombo.currentIndex = resIdx >= 0 ? resIdx : 2 // 960x540
        var fmtId = Backend.getSetting("proxy/defaultFormat", "h264_intra")
        var fmtIdx = proxyFormatIds.indexOf(fmtId)
        proxyDefaultFormatCombo.currentIndex = fmtIdx >= 0 ? fmtIdx : 0
        proxyDefaultPauseCheck.checked = Backend.getSetting("proxy/defaultPauseDuringPlayback", false)
        var devToken = Backend.getSetting("proxy/defaultComputeDevice", "")
        var devIdx = proxyDefaultDeviceCombo.deviceTokens.indexOf(devToken)
        proxyDefaultDeviceCombo.currentIndex = devIdx >= 0 ? devIdx : 0
    }
    onVisibleChanged: {
        if (visible) { refreshLogInfo(); loadProxyDefaults() }
        else keyboardPage.resetUiState()
    }

    component SidebarButton: Button {
        id: sidebarButton
        property bool current: false
        Layout.fillWidth: true
        Layout.preferredHeight: 34
        flat: true
        contentItem: Text {
            text: sidebarButton.text
            color: sidebarButton.current ? settingsWindow.colorText : settingsWindow.colorSubText
            font.pixelSize: 13
            font.bold: sidebarButton.current
            leftPadding: 12
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            color: sidebarButton.current ? settingsWindow.colorPanel : "transparent"
            radius: 3
            Rectangle {
                width: 3
                height: parent.height
                color: settingsWindow.colorHighlight
                visible: sidebarButton.current
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 14

        Label {
            text: "Settings"
            color: settingsWindow.colorText
            font.pixelSize: 18
            font.bold: true
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // ---------------- Sidebar ----------------
            // Fixed pixel width throughout (not Layout.preferredWidth) -
            // deliberately NOT relying on RowLayout/ColumnLayout fill
            // apportionment for the sidebar's own width, after that
            // produced a layout bug where the sidebar claimed almost the
            // entire window instead of staying at 140px.
            Column {
                id: sidebar
                width: 140
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                spacing: 2

                property int currentIndex: 0

                SidebarButton { width: 140; text: "Debug"; current: sidebar.currentIndex === 0; onClicked: sidebar.currentIndex = 0 }
                SidebarButton { width: 140; text: "Proxy"; current: sidebar.currentIndex === 1; onClicked: sidebar.currentIndex = 1 }
                SidebarButton { width: 140; text: "Autosave"; current: sidebar.currentIndex === 2; onClicked: sidebar.currentIndex = 2 }
                SidebarButton { width: 140; text: "Keyboard"; current: sidebar.currentIndex === 3; onClicked: sidebar.currentIndex = 3 }
                SidebarButton { width: 140; text: "Playback"; current: sidebar.currentIndex === 4; onClicked: sidebar.currentIndex = 4 }
                SidebarButton { width: 140; text: "Editing"; current: sidebar.currentIndex === 5; onClicked: sidebar.currentIndex = 5 }
                SidebarButton { objectName: "settingsCodecsTab"; width: 140; text: "Codecs"; current: sidebar.currentIndex === 6; onClicked: sidebar.currentIndex = 6 }
            }

            Rectangle {
                width: 1
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.left: sidebar.right
                anchors.leftMargin: 14
                color: settingsWindow.colorBorder
            }

            // ---------------- Content ----------------
            StackLayout {
                id: settingsStack
                anchors.left: sidebar.right
                anchors.leftMargin: 29 // divider (1) + 14px gap on each side
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                clip: true
                currentIndex: sidebar.currentIndex

                // --- Debug ---
                Item {
                    ColumnLayout {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        spacing: 8

                        CheckBox {
                            id: debugLogCheck
                            text: "Log editing operations to file"
                            checked: Backend.debugLoggingEnabled
                            onToggled: Backend.debugLoggingEnabled = checked
                            contentItem: Label {
                                text: debugLogCheck.text
                                color: settingsWindow.colorText
                                font.pixelSize: 12
                                verticalAlignment: Text.AlignVCenter
                                leftPadding: debugLogCheck.indicator.width + debugLogCheck.spacing
                            }
                            ToolTip.visible: hovered
                            ToolTip.delay: 600
                            ToolTip.text: "Appends every timeline/bin action (drags, trims, deletes, effect changes) to the operation log."
                        }

                        Label {
                            Layout.fillWidth: true
                            text: Backend.operationLogPath()
                            color: settingsWindow.colorSubText
                            font.pixelSize: 11
                            font.family: "Monospace"
                            elide: Text.ElideMiddle
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10

                            Label {
                                text: "Current size: " + settingsWindow.logSizeText
                                color: settingsWindow.colorSubText
                                font.pixelSize: 11
                            }

                            Item { Layout.fillWidth: true }

                            Button {
                                text: "Clear Log"
                                onClicked: {
                                    Backend.clearOperationLog()
                                    settingsWindow.refreshLogInfo()
                                }
                            }
                        }
                    }
                }

                // --- Proxy ---
                Item {
                    ColumnLayout {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        spacing: 10

                        Label {
                            text: "Defaults for new projects"
                            color: settingsWindow.colorSubText
                            font.pixelSize: 11
                        }

                        CheckBox {
                            id: proxyDefaultEnabledCheck
                            text: "Enable proxy editing by default"
                            onToggled: Backend.setSetting("proxy/defaultEnabled", checked)
                            contentItem: Label {
                                text: proxyDefaultEnabledCheck.text
                                color: settingsWindow.colorText
                                font.pixelSize: 12
                                verticalAlignment: Text.AlignVCenter
                                leftPadding: proxyDefaultEnabledCheck.indicator.width + proxyDefaultEnabledCheck.spacing
                            }
                        }

                        GridLayout {
                            columns: 2
                            rowSpacing: 8
                            columnSpacing: 10
                            Layout.fillWidth: true

                            Label { text: "Resolution:"; color: settingsWindow.colorSubText; font.pixelSize: 12 }
                            ComboBox {
                                id: proxyDefaultResolutionCombo
                                Layout.preferredWidth: 160
                                Layout.preferredHeight: 28
                                model: ["1920x1080", "1280x720", "960x540", "640x360"]
                                onActivated: Backend.setSetting("proxy/defaultTargetResolution", currentText)
                                contentItem: Text { text: parent.displayText; color: settingsWindow.colorText; verticalAlignment: Text.AlignVCenter; leftPadding: 8; font.pixelSize: 12 }
                                background: Rectangle { color: "#1d2023"; border.color: settingsWindow.colorBorder; radius: 2 }
                            }

                            Label { text: "Format:"; color: settingsWindow.colorSubText; font.pixelSize: 12 }
                            ComboBox {
                                id: proxyDefaultFormatCombo
                                Layout.preferredWidth: 260
                                Layout.preferredHeight: 28
                                model: settingsWindow.proxyFormatLabels
                                onActivated: Backend.setSetting("proxy/defaultFormat", settingsWindow.proxyFormatIds[currentIndex])
                                contentItem: Text { text: parent.displayText; color: settingsWindow.colorText; verticalAlignment: Text.AlignVCenter; leftPadding: 8; font.pixelSize: 12 }
                                background: Rectangle { color: "#1d2023"; border.color: settingsWindow.colorBorder; radius: 2 }
                            }

                            Label { text: "Compute device:"; color: settingsWindow.colorSubText; font.pixelSize: 12 }
                            ComboBox {
                                id: proxyDefaultDeviceCombo
                                Layout.preferredWidth: 260
                                Layout.preferredHeight: 28
                                // Segment before the first "-", not a trailing
                                // "-<digits>" strip - see the same property in
                                // ProjectSettingsDialog.qml for why (the plan's
                                // future "nvidia-<uuid>"/"vaapi-<renderNode>"
                                // ids don't end in digits), and for the
                                // one-entry-per-vendor limitation this list
                                // inherits from detectGPUDevices().
                                property var deviceTokens: [""].concat(Backend.gpuDevices.map(function(d) { return d.id.split("-")[0] }))
                                model: ["Auto (prefer GPU)"].concat(Backend.gpuDevices.map(function(d) { return d.name + " (" + d.vendor + ")" }))
                                onActivated: Backend.setSetting("proxy/defaultComputeDevice", deviceTokens[currentIndex])
                                contentItem: Text { text: parent.displayText; color: settingsWindow.colorText; verticalAlignment: Text.AlignVCenter; leftPadding: 8; font.pixelSize: 12 }
                                background: Rectangle { color: "#1d2023"; border.color: settingsWindow.colorBorder; radius: 2 }
                            }
                        }

                        CheckBox {
                            id: proxyDefaultPauseCheck
                            text: "Pause proxy generation during playback"
                            onToggled: Backend.setSetting("proxy/defaultPauseDuringPlayback", checked)
                            contentItem: Label {
                                text: proxyDefaultPauseCheck.text
                                color: settingsWindow.colorText
                                font.pixelSize: 12
                                verticalAlignment: Text.AlignVCenter
                                leftPadding: proxyDefaultPauseCheck.indicator.width + proxyDefaultPauseCheck.spacing
                            }
                        }
                    }
                }

                // --- Autosave ---
                Item {
                    ColumnLayout {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        spacing: 10

                        Label {
                            text: "Recovery copy"
                            color: settingsWindow.colorSubText
                            font.pixelSize: 11
                        }

                        CheckBox {
                            id: autosaveEnabledCheck
                            text: "Save a recovery copy automatically"
                            Component.onCompleted: {
                                var v = Backend.getSetting("autosave/enabled", true)
                                checked = (v === true || String(v) === "true")
                            }
                            onToggled: {
                                Backend.setSetting("autosave/enabled", checked)
                                settingsWindow.autosaveSettingsChanged()
                            }
                            contentItem: Label {
                                text: autosaveEnabledCheck.text
                                color: settingsWindow.colorText
                                font.pixelSize: 12
                                verticalAlignment: Text.AlignVCenter
                                leftPadding: autosaveEnabledCheck.indicator.width + autosaveEnabledCheck.spacing
                            }
                        }

                        GridLayout {
                            columns: 2
                            rowSpacing: 8
                            columnSpacing: 10
                            Layout.fillWidth: true

                            Label { text: "Interval (seconds):"; color: settingsWindow.colorSubText; font.pixelSize: 12 }
                            SpinBox {
                                id: autosaveIntervalSpin
                                Layout.preferredWidth: 140
                                from: 10
                                to: 3600
                                stepSize: 10
                                editable: true
                                Component.onCompleted: {
                                    var v = parseInt(Backend.getSetting("autosave/intervalSec", 60))
                                    if (!isNaN(v)) value = Math.max(10, Math.min(3600, v))
                                }
                                onValueModified: {
                                    Backend.setSetting("autosave/intervalSec", value)
                                    settingsWindow.autosaveSettingsChanged()
                                }
                            }
                        }

                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            color: settingsWindow.colorSubText
                            font.pixelSize: 11
                            text: "The recovery copy is written next to the project file (.gpucs.autosave). The project file itself is only changed by Save."
                        }
                    }
                }

                // --- Keyboard ---
                // Every application shortcut (Backend.shortcuts registry,
                // src/core/ShortcutManager.cpp). Changes apply and persist
                // immediately (app-wide QSettings "shortcuts/<id>").
                Item {
                    id: keyboardPage

                    property var rows: Backend.shortcuts.revision >= 0 ? Backend.shortcuts.actions() : []
                    readonly property var categories: ["Playback", "Navigation", "Tracks", "Editing", "View", "File"]
                    property string filterText: ""
                    // Cell waiting for a key press ("" = none).
                    property string captureId: ""
                    property int captureSlot: -1
                    // Conflict question shown under the row of pendingId.
                    property string pendingId: ""
                    property int pendingSlot: -1
                    property string pendingSeq: ""
                    property string pendingOther: ""
                    property string message: ""
                    property bool confirmResetAll: false

                    function resetUiState() {
                        captureId = ""; captureSlot = -1
                        pendingId = ""; message = ""; confirmResetAll = false
                    }
                    function startCapture(id, slot) {
                        pendingId = ""; message = ""; confirmResetAll = false
                        captureId = id; captureSlot = slot
                    }
                    function cancelCapture() { captureId = ""; captureSlot = -1 }
                    function rowsOf(category) {
                        var f = filterText.trim().toLowerCase()
                        return rows.filter(function(r) {
                            if (r.category !== category) return false
                            if (f === "") return true
                            if (r.title.toLowerCase().indexOf(f) >= 0) return true
                            for (var i = 0; i < r.sequences.length; i++)
                                if (Backend.shortcuts.nativeText(r.sequences[i]).toLowerCase().indexOf(f) >= 0) return true
                            return false
                        })
                    }
                    function apply(id, slot, seq) {
                        var list = Backend.shortcuts.sequences(id).slice()
                        if (slot < list.length) list[slot] = seq
                        else list.push(seq)
                        var out = []
                        for (var i = 0; i < list.length; i++)
                            if (out.indexOf(list[i]) < 0) out.push(list[i])
                        if (!Backend.shortcuts.setSequences(id, out))
                            message = "Could not bind " + Backend.shortcuts.nativeText(seq) + "."
                    }
                    // Returns false while only a modifier is held (keep waiting).
                    function captured(id, slot, key, modifiers) {
                        var seq = Backend.shortcuts.sequenceFromKey(key, modifiers)
                        if (seq === "") return false
                        cancelCapture()
                        if (Backend.shortcuts.isRejected(seq)) {
                            message = Backend.shortcuts.nativeText(seq) + " cannot be used as a shortcut (Esc, Enter and Tab are reserved for dialogs and focus)."
                            return true
                        }
                        var other = Backend.shortcuts.conflict(seq, id)
                        if (other !== "") {
                            pendingId = id; pendingSlot = slot; pendingSeq = seq; pendingOther = other
                            return true
                        }
                        apply(id, slot, seq)
                        return true
                    }
                    function clearSlot(id, slot) {
                        var list = Backend.shortcuts.sequences(id).slice()
                        if (slot >= list.length) return
                        list.splice(slot, 1)
                        Backend.shortcuts.setSequences(id, list)
                    }
                    function replacePending() {
                        var rest = Backend.shortcuts.sequences(pendingOther).filter(function(s) { return s !== pendingSeq })
                        Backend.shortcuts.setSequences(pendingOther, rest)
                        var id = pendingId, slot = pendingSlot, seq = pendingSeq
                        pendingId = ""
                        apply(id, slot, seq)
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 8

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            TextField {
                                id: shortcutFilterField
                                Layout.fillWidth: true
                                Layout.preferredHeight: 28
                                placeholderText: "Filter actions or keys..."
                                color: settingsWindow.colorText
                                font.pixelSize: 12
                                onTextChanged: keyboardPage.filterText = text
                                background: Rectangle { color: "#1d2023"; border.color: settingsWindow.colorBorder; radius: 2 }
                            }
                            Button {
                                text: "Reset all to defaults"
                                onClicked: { keyboardPage.resetUiState(); keyboardPage.confirmResetAll = true }
                            }
                        }

                        // Reset-all confirmation
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 38
                            visible: keyboardPage.confirmResetAll
                            color: settingsWindow.colorPanel
                            border.color: "#f0b030"
                            radius: 3
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 10
                                anchors.rightMargin: 6
                                spacing: 8
                                Label {
                                    Layout.fillWidth: true
                                    text: "Reset ALL keyboard shortcuts to their defaults?"
                                    color: settingsWindow.colorText
                                    font.pixelSize: 12
                                    elide: Text.ElideRight
                                }
                                Button {
                                    text: "Reset all"
                                    onClicked: { Backend.shortcuts.resetAll(); keyboardPage.confirmResetAll = false }
                                }
                                Button {
                                    text: "Cancel"
                                    onClicked: keyboardPage.confirmResetAll = false
                                }
                            }
                        }

                        Label {
                            Layout.fillWidth: true
                            visible: keyboardPage.message !== ""
                            text: keyboardPage.message
                            color: "#f0b030"
                            font.pixelSize: 12
                            wrapMode: Text.WordWrap
                        }

                        Label {
                            Layout.fillWidth: true
                            text: "Click a key cell and press the new key. Backspace/Delete on a selected cell removes that key."
                            color: settingsWindow.colorSubText
                            font.pixelSize: 11
                            wrapMode: Text.WordWrap
                        }

                        Flickable {
                            id: shortcutList
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            contentWidth: width
                            contentHeight: shortcutColumn.implicitHeight
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                            Column {
                                id: shortcutColumn
                                width: shortcutList.width - 14
                                spacing: 2

                                Repeater {
                                    model: keyboardPage.categories
                                    delegate: Column {
                                        id: categoryBlock
                                        width: shortcutColumn.width
                                        spacing: 2
                                        property var catRows: keyboardPage.rowsOf(modelData)
                                        visible: catRows.length > 0

                                        Label {
                                            text: modelData
                                            color: settingsWindow.colorHighlight
                                            font.pixelSize: 12
                                            font.bold: true
                                            topPadding: 8
                                            bottomPadding: 2
                                        }

                                        Repeater {
                                            model: categoryBlock.catRows
                                            delegate: Column {
                                                id: actionRow
                                                width: categoryBlock.width
                                                property var row: modelData
                                                spacing: 2

                                                RowLayout {
                                                    width: parent.width
                                                    height: 30
                                                    spacing: 6

                                                    Label {
                                                        Layout.fillWidth: true
                                                        text: actionRow.row.title
                                                        color: settingsWindow.colorText
                                                        font.pixelSize: 12
                                                        elide: Text.ElideRight
                                                    }

                                                    Repeater {
                                                        model: 2
                                                        delegate: Rectangle {
                                                            id: keyCell
                                                            readonly property int slot: index
                                                            readonly property string actionId: actionRow.row.id
                                                            readonly property var seqs: actionRow.row.sequences
                                                            readonly property bool capturing: keyboardPage.captureId === actionId
                                                                                              && keyboardPage.captureSlot === slot
                                                            Layout.preferredWidth: 170
                                                            Layout.preferredHeight: 26
                                                            radius: 2
                                                            activeFocusOnTab: true
                                                            color: capturing ? "#24465a" : (activeFocus ? "#3a3f44" : "#1d2023")
                                                            border.color: (capturing || activeFocus) ? settingsWindow.colorHighlight : settingsWindow.colorBorder
                                                            Accessible.role: Accessible.Button
                                                            Accessible.name: actionRow.row.title + " key " + (slot + 1)

                                                            Text {
                                                                anchors.fill: parent
                                                                anchors.leftMargin: 8
                                                                anchors.rightMargin: 4
                                                                verticalAlignment: Text.AlignVCenter
                                                                elide: Text.ElideRight
                                                                font.pixelSize: 12
                                                                text: keyCell.capturing ? "Press keys... (Esc to cancel)"
                                                                      : (keyCell.slot < keyCell.seqs.length
                                                                         ? Backend.shortcuts.nativeText(keyCell.seqs[keyCell.slot]) : "—")
                                                                color: keyCell.capturing ? settingsWindow.colorHighlight
                                                                      : (keyCell.slot < keyCell.seqs.length ? settingsWindow.colorText : settingsWindow.colorSubText)
                                                            }

                                                            MouseArea {
                                                                anchors.fill: parent
                                                                onClicked: {
                                                                    keyCell.forceActiveFocus()
                                                                    keyboardPage.startCapture(keyCell.actionId, keyCell.slot)
                                                                }
                                                            }

                                                            Keys.onPressed: function(event) {
                                                                if (keyCell.capturing) {
                                                                    event.accepted = true
                                                                    if (event.key === Qt.Key_Escape) { keyboardPage.cancelCapture(); return }
                                                                    keyboardPage.captured(keyCell.actionId, keyCell.slot, event.key, event.modifiers)
                                                                    return
                                                                }
                                                                var plain = (event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) === 0
                                                                if (plain && (event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete)) {
                                                                    keyboardPage.clearSlot(keyCell.actionId, keyCell.slot)
                                                                    event.accepted = true
                                                                } else if (plain && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space)) {
                                                                    keyboardPage.startCapture(keyCell.actionId, keyCell.slot)
                                                                    event.accepted = true
                                                                }
                                                            }
                                                            onActiveFocusChanged: if (!activeFocus && capturing) keyboardPage.cancelCapture()
                                                        }
                                                    }

                                                    Button {
                                                        Layout.preferredWidth: 30
                                                        Layout.preferredHeight: 26
                                                        text: "↺"
                                                        enabled: !actionRow.row.isDefault
                                                        focusPolicy: Qt.NoFocus
                                                        Accessible.name: "Reset " + actionRow.row.title
                                                        ToolTip.visible: hovered
                                                        ToolTip.delay: 500
                                                        ToolTip.text: "Reset to default: " + (actionRow.row.defaults.length
                                                            ? actionRow.row.defaults.map(function(s) { return Backend.shortcuts.nativeText(s) }).join(", ")
                                                            : "none")
                                                        onClicked: { keyboardPage.resetUiState(); Backend.shortcuts.resetAction(actionRow.row.id) }
                                                    }
                                                }

                                                // Conflict question for this row
                                                Rectangle {
                                                    width: parent.width
                                                    height: 36
                                                    visible: keyboardPage.pendingId === actionRow.row.id
                                                    color: settingsWindow.colorPanel
                                                    border.color: "#f0b030"
                                                    radius: 3
                                                    RowLayout {
                                                        anchors.fill: parent
                                                        anchors.leftMargin: 10
                                                        anchors.rightMargin: 6
                                                        spacing: 8
                                                        Label {
                                                            Layout.fillWidth: true
                                                            text: Backend.shortcuts.nativeText(keyboardPage.pendingSeq) + " is already used by “"
                                                                  + Backend.shortcuts.title(keyboardPage.pendingOther) + "”. Replace?"
                                                            color: settingsWindow.colorText
                                                            font.pixelSize: 12
                                                            elide: Text.ElideRight
                                                        }
                                                        Button { text: "Replace"; onClicked: keyboardPage.replacePending() }
                                                        Button { text: "Cancel"; onClicked: keyboardPage.pendingId = "" }
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

                // --- Playback ---
                Item {
                    ColumnLayout {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        spacing: 10

                        Label {
                            text: "Audio"
                            color: settingsWindow.colorSubText
                            font.pixelSize: 11
                        }

                        CheckBox {
                            id: audioScrubCheck
                            text: "Audio scrub when stepping frames"
                            Component.onCompleted: {
                                var v = Backend.getSetting("audio/scrubOnStep", true)
                                checked = (v === true || String(v) === "true")
                            }
                            onToggled: Backend.setSetting("audio/scrubOnStep", checked)
                            contentItem: Label {
                                text: audioScrubCheck.text
                                color: settingsWindow.colorText
                                font.pixelSize: 12
                                verticalAlignment: Text.AlignVCenter
                                leftPadding: audioScrubCheck.indicator.width + audioScrubCheck.spacing
                            }
                        }

                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            color: settingsWindow.colorSubText
                            font.pixelSize: 11
                            text: "While paused, each single frame step (Left / Right arrow, key repeat, jog knob) plays a short piece of the audio at the new position. Other seeks and normal playback are not affected."
                        }

                        Label {
                            text: "Display"
                            color: settingsWindow.colorSubText
                            font.pixelSize: 11
                        }

                        CheckBox {
                            id: forceX11Check
                            objectName: "forceX11Check"
                            text: "Force X11 (XWayland) on Wayland desktops - takes effect after restart"
                            Component.onCompleted: {
                                var v = Backend.getSetting("display/forceX11", false)
                                checked = (v === true || String(v) === "true")
                            }
                            onToggled: Backend.setSetting("display/forceX11", checked)
                            contentItem: Label {
                                text: forceX11Check.text
                                color: settingsWindow.colorText
                                font.pixelSize: 12
                                verticalAlignment: Text.AlignVCenter
                                leftPadding: forceX11Check.indicator.width + forceX11Check.spacing
                            }
                        }

                        Label {
                            objectName: "currentPlatformLabel"
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            color: settingsWindow.colorSubText
                            font.pixelSize: 11
                            text: "Current display platform: " + Backend.platformName
                                  + (Backend.platformName === "wayland" ? " (native Wayland)" : Backend.platformName === "xcb" ? " (X11 / XWayland)" : "")
                                  + ". On a non-Wayland desktop this setting has no effect. GCS_FORCE_X11=1 or QT_QPA_PLATFORM=xcb force X11 as well."
                        }
                    }
                }

                // --- Editing ---
                Item {
                    ColumnLayout {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        spacing: 10

                        Label {
                            text: "Transitions"
                            color: settingsWindow.colorSubText
                            font.pixelSize: 11
                        }

                        RowLayout {
                            spacing: 10
                            Label { text: "Default transition duration (seconds):"; color: settingsWindow.colorSubText; font.pixelSize: 12 }
                            TextField {
                                id: defTransField
                                objectName: "defaultTransitionDurationField"
                                Layout.preferredWidth: 90
                                color: settingsWindow.colorText
                                selectByMouse: true
                                validator: RegularExpressionValidator { regularExpression: /^[0-9]{0,4}([.,][0-9]{0,2})?$/ }
                                Component.onCompleted: {
                                    var v = parseFloat(Backend.getSetting("editing/defaultTransitionDuration", 2.0))
                                    text = (isNaN(v) || v <= 0 ? 2.0 : v).toFixed(2)
                                }
                                function commit() {
                                    var v = parseFloat(text.replace(",", "."))
                                    if (isNaN(v) || v <= 0) v = 2.0
                                    Backend.setSetting("editing/defaultTransitionDuration", v)
                                    text = v.toFixed(2)
                                }
                                onEditingFinished: commit()
                            }
                        }

                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            color: settingsWindow.colorSubText
                            font.pixelSize: 11
                            text: "Length of newly added transitions. Existing transitions keep their own length; resize them by dragging their ends on the timeline or via Duration... in their menu."
                        }
                    }
                }

                // --- Codecs ---
                // Live status from the Codecs singleton (src/core/CodecCheck.h):
                // which codec-dependent features work with the registered
                // GStreamer plugins and what to install otherwise.
                Item {
                    ScrollView {
                        id: codecsScroll
                        anchors.fill: parent
                        contentWidth: availableWidth
                        clip: true

                        ColumnLayout {
                            width: codecsScroll.availableWidth
                            spacing: 10

                            Label {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                color: settingsWindow.colorSubText
                                font.pixelSize: 11
                                text: Codecs.pluginMode === "native"
                                      ? "GStreamer " + Codecs.gstreamerVersion + ". Software H.264/H.265/AAC codecs come from the GStreamer installation this build runs against."
                                      : "GStreamer " + Codecs.gstreamerVersion + " (bundled). The AppImage does not include patent-encumbered software codecs (H.264/H.265/AAC); it uses the ones your distribution provides (gst-libav, x264, OpenH264, ...). GPU decoding/encoding (NVDEC/NVENC, VA-API) is bundled."
                            }

                            CodecStatusList {
                                Layout.fillWidth: true
                                textColor: settingsWindow.colorText
                                dimColor: settingsWindow.colorSubText
                                panelColor: settingsWindow.colorPanel
                                borderColor: settingsWindow.colorBorder
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Label {
                                    id: recheckInfo
                                    Layout.fillWidth: true
                                    color: settingsWindow.colorSubText
                                    font.pixelSize: 11
                                    text: ""
                                }
                                Button {
                                    objectName: "codecsRecheckButton"
                                    text: "Re-check"
                                    onClicked: {
                                        recheckInfo.text = "Rescanning plugins\u2026"
                                        Qt.callLater(function() {
                                            Codecs.recheck()
                                            recheckInfo.text = "Checked " + new Date().toLocaleTimeString(Qt.locale(), "HH:mm:ss")
                                        })
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Item { Layout.fillWidth: true }

            Button {
                text: "Close"
                onClicked: settingsWindow.close()
            }
        }
    }
}
