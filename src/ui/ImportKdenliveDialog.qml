import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Dialogs
import VideoEditor 1.0

// Import a Kdenlive (.kdenlive / MLT XML) project as a one-shot, one-way
// translation into a brand new GPU-Cine-Studio project - see
// src/core/KdenliveImporter.{h,cpp} for the actual parsing/conversion and
// TODO.txt's "PLANNED: Kdenlive project import" entry for the full design
// rationale. Modeled on SaveAsDialog.qml: a Window (not a QML Dialog),
// "dialog validates, caller mutates state" contract via accepted()/
// rejected() signals, same color palette.
Window {
    id: importWindow
    title: "Import Kdenlive Project — GPU Cine Studio"
    width: 760
    height: 620
    minimumWidth: 680
    minimumHeight: 520
    visible: false

    modality: Qt.ApplicationModal
    flags: Qt.Dialog | Qt.WindowStaysOnTopHint

    readonly property color colorBackground: "#31363b"
    readonly property color colorPanel: "#232629"
    readonly property color colorText: "#eff0f1"
    readonly property color colorHighlight: "#3daee9"
    readonly property color colorBorder: "#5d6066"
    readonly property color colorWarn: "#e7b43d"
    readonly property color colorBad: "#e74c3c"
    readonly property color colorInfo: "#888888"
    color: colorBackground

    // (kdenlivePath, parentDir, projectName, fileName, options) - same
    // "caller does the filesystem work" contract as SaveAsDialog.qml.
    signal accepted(string kdenlivePath, string parentDir, string projectName, string fileName, var options)
    signal rejected()

    Component.onCompleted: {
        x = (Screen.width - width) / 2
        y = (Screen.height - height) / 2
    }

    onVisibleChanged: if (visible) resetToStart()

    property int step: 0 // 0=pick file, 1=summary, 2=media, 3=unsupported, 4=destination
    property string kdenlivePath: ""
    property var summary: null
    // The canvas is only rounded up to even (4:2:0), never to 16 px.
    readonly property bool oddProfileSize: summary !== null && summary.profile !== undefined
        && (summary.profile.width % 2 !== 0 || summary.profile.height % 2 !== 0)
    property var options: ({ relinkMap: {}, searchRoots: [], missingMediaPlaceholder: true })
    readonly property bool destConflict:
        locationFieldK.text && nameField.text
        && Backend.projectFolderWouldConflict(locationFieldK.text, nameField.text)

    function resetToStart() {
        step = 0
        kdenlivePath = ""
        summary = null
        options = { relinkMap: {}, searchRoots: [], missingMediaPlaceholder: true }
        errorLabel.text = ""
    }

    function runInspect() {
        errorLabel.text = ""
        var s = Backend.inspectKdenliveProject(kdenlivePath, options)
        if (!s.ok) {
            errorLabel.text = s.error || "Could not read this file."
            return false
        }
        summary = s
        return true
    }

    FileDialog {
        id: pickFileDialog
        title: "Select Kdenlive Project File"
        nameFilters: ["Kdenlive Projects (*.kdenlive)", "All Files (*)"]
        fileMode: FileDialog.OpenFile
        onAccepted: {
            importWindow.kdenlivePath = selectedFile.toString().replace("file://", "")
            if (importWindow.runInspect()) {
                nameField.text = Backend.sanitizeFolderName(
                    importWindow.kdenlivePath.split("/").pop().replace(/\.kdenlive$/i, ""))
                fileNameFieldK.text = nameField.text + ".gpucs"
                locationFieldK.text = Backend.getDefaultVideosPath()
                importWindow.step = 1
            }
        }
    }

    FolderDialog {
        id: folderDialogK
        title: "Select Parent Folder for the New Project Folder"
        onAccepted: locationFieldK.text = selectedFolder.toString().replace("file://", "")
    }

    FolderDialog {
        id: searchRootDialog
        title: "Add a Folder to Search for Missing Media"
        onAccepted: {
            var p = selectedFolder.toString().replace("file://", "")
            var roots = importWindow.options.searchRoots.slice()
            if (roots.indexOf(p) === -1) roots.push(p)
            importWindow.options = Object.assign({}, importWindow.options, { searchRoots: roots })
            importWindow.runInspect()
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 10

        Label {
            text: {
                switch (importWindow.step) {
                    case 0: return "Select a Kdenlive project file (.kdenlive) to import."
                    case 1: return "Project summary"
                    case 2: return "Media files"
                    case 3: return "What will not be imported"
                    case 4: return "Destination"
                }
                return ""
            }
            color: colorText
            font.pixelSize: 15
            font.bold: true
        }

        // ---------------- Step 0: pick file ----------------
        ColumnLayout {
            visible: importWindow.step === 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 12

            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: "#b0b3b8"
                font.pixelSize: 12
                text: "This reads an existing Kdenlive (MLT XML) project and creates a NEW GPU Cine Studio "
                    + "project from it - tracks, clip placement/trims, gaps, linked audio/video clips, and "
                    + "dissolve transitions. Effects, keyframed parameters, fades, speed changes and titles "
                    + "are not supported yet and will be listed before you commit, not silently dropped."
            }
            Item { Layout.fillHeight: true }
            Button {
                Layout.alignment: Qt.AlignHCenter
                text: "Choose .kdenlive File..."
                onClicked: pickFileDialog.open()
                background: Rectangle { color: parent.down ? "#2a9ad0" : colorHighlight; radius: 3 }
                contentItem: Text { text: parent.text; color: "white"; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 13 }
                implicitHeight: 40; implicitWidth: 220
            }
            Item { Layout.fillHeight: true }
        }

        // ---------------- Step 1: summary ----------------
        ScrollView {
            visible: importWindow.step === 1
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            ColumnLayout {
                width: parent.width
                spacing: 10
                visible: importWindow.summary !== null

                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    rowSpacing: 4; columnSpacing: 10
                    Label { text: "Kdenlive version:"; color: "#aaa"; font.pixelSize: 12 }
                    Label { text: importWindow.summary ? importWindow.summary.kdenliveVersion : ""; color: colorText; font.pixelSize: 12 }
                    Label { text: "Profile:"; color: "#aaa"; font.pixelSize: 12 }
                    Label {
                        color: colorText; font.pixelSize: 12
                        text: importWindow.summary
                            ? (importWindow.summary.profile.width + "x" + importWindow.summary.profile.height
                               + " @ " + importWindow.summary.profile.fpsLabel + " fps"
                               + (importWindow.summary.profile.fpsMapped ? "" : "  (nearest supported rate - see unsupported list)"))
                            : ""
                    }
                    Label {
                        visible: importWindow.oddProfileSize
                        text: "Note:"; color: colorWarn; font.pixelSize: 12
                    }
                    Label {
                        visible: importWindow.oddProfileSize
                        color: colorWarn; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true
                        text: importWindow.oddProfileSize
                            ? ("frame size will be rounded up to even: "
                               + ((importWindow.summary.profile.width + 1) & ~1) + "x"
                               + ((importWindow.summary.profile.height + 1) & ~1))
                            : ""
                    }
                    Label { text: "Totals:"; color: "#aaa"; font.pixelSize: 12 }
                    Label {
                        color: colorText; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true
                        text: importWindow.summary
                            ? (importWindow.summary.counts.clips + " clips · " + importWindow.summary.counts.gaps + " gaps · "
                               + importWindow.summary.counts.transitions + " transitions · "
                               + importWindow.summary.counts.linkPairs + " linked audio/video pairs · "
                               + importWindow.summary.counts.binItems + " bin items in " + importWindow.summary.counts.binFolders + " folders")
                            : ""
                    }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: colorBorder }

                Label { text: "Tracks"; color: colorText; font.bold: true; font.pixelSize: 13 }
                Repeater {
                    model: importWindow.summary ? importWindow.summary.tracks : []
                    delegate: RowLayout {
                        Layout.fillWidth: true
                        Label { text: modelData.gcsTrackId; color: colorHighlight; font.bold: true; Layout.preferredWidth: 40 }
                        Label { text: modelData.type; color: "#aaa"; Layout.preferredWidth: 60 }
                        Label { text: modelData.name !== "" ? modelData.name : "—"; color: colorText; Layout.fillWidth: true }
                        Label { text: modelData.clips + " clips"; color: "#aaa" }
                    }
                }
            }
        }

        // ---------------- Step 2: media ----------------
        ColumnLayout {
            visible: importWindow.step === 2
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                Label {
                    Layout.fillWidth: true
                    color: colorText; font.pixelSize: 12
                    text: importWindow.summary
                        ? (importWindow.summary.mediaSummary.original + " original · "
                           + importWindow.summary.mediaSummary.rescued + " relinked by name · "
                           + importWindow.summary.mediaSummary.missing + " missing")
                        : ""
                }
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: "#888"
                font.pixelSize: 11
                text: "Kdenlive's own proxies are never used as a substitute, even when only a proxy is found - "
                    + "they're a lower-resolution stand-in Kdenlive generated for its own editing performance. "
                    + "An item without its real original file is treated as missing."
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 15
                Item { Layout.fillWidth: true }
                Button {
                    text: "Add Search Folder..."
                    onClicked: searchRootDialog.open()
                    background: Rectangle { color: "#4d5057"; radius: 2 }
                    contentItem: Text { text: parent.text; color: colorText; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 11 }
                    implicitHeight: 26
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: importWindow.summary && importWindow.summary.mediaSummary.missing > 0
                spacing: 6
                CheckBox {
                    id: placeholderCheck
                    checked: importWindow.options.missingMediaPlaceholder !== false
                    onToggled: importWindow.options = Object.assign({}, importWindow.options, { missingMediaPlaceholder: checked })
                }
                Label {
                    text: "Use placeholder for missing clips"
                    color: colorText
                    font.pixelSize: 12
                }
            }
            Label {
                Layout.fillWidth: true
                visible: importWindow.summary && importWindow.summary.mediaSummary.missing > 0
                wrapMode: Text.WordWrap
                color: "#888"
                font.pixelSize: 11
                text: placeholderCheck.checked
                    ? "Missing clips keep their exact position, name and effects on the timeline - nothing is changed or removed. "
                      + "If you put the original files back at their recorded location later, they'll just work, no re-import needed."
                    : "Missing clips will be left out of the project entirely (a true gap, not reserved)."
            }

            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                ListView {
                    model: importWindow.summary ? importWindow.summary.media : []
                    spacing: 2
                    delegate: RowLayout {
                        width: ListView.view.width
                        Rectangle {
                            width: 8; height: 8; radius: 4
                            color: modelData.resolution === "original" ? "#5cb85c"
                                 : modelData.resolution === "rescued" ? colorHighlight
                                 : modelData.resolution === "proxy" ? colorWarn
                                 : colorBad
                        }
                        Label { text: modelData.name; color: colorText; font.pixelSize: 11; Layout.preferredWidth: 260; elide: Text.ElideRight }
                        Label { text: modelData.resolution; color: "#aaa"; font.pixelSize: 11; Layout.preferredWidth: 60 }
                        Label { text: modelData.resolvedPath; color: "#888"; font.pixelSize: 10; elide: Text.ElideLeft; Layout.fillWidth: true }
                    }
                }
            }
        }

        // ---------------- Step 3: unsupported ----------------
        ColumnLayout {
            visible: importWindow.step === 3
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 6

            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: "#b0b3b8"
                font.pixelSize: 11
                text: "These items from the Kdenlive project could not be translated and will NOT appear after import. "
                    + "They are recorded in the project folder - when the matching feature is built, they can be "
                    + "applied without re-importing."
            }
            // A single, multi-line, read-only TextArea instead of a
            // ListView of per-row Labels: plain Text/Label has NO
            // selection support at all in QtQuick (no selectByMouse
            // property on either), so none of that text was ever
            // mouse-copyable. TextArea with selectByMouse is the same
            // mechanism already used for exactly this purpose elsewhere
            // in the app (LoadingDialog.qml's log view) - a normal
            // click-drag selects across lines and Ctrl+C/right-click-copy
            // just work, no clipboard-button plumbing needed. The
            // severity color-coding is necessarily lost (one TextArea,
            // one color) in exchange for that - each line is prefixed
            // with its severity instead so the information isn't lost.
            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                TextArea {
                    readOnly: true
                    selectByMouse: true
                    selectByKeyboard: true
                    wrapMode: TextArea.Wrap
                    font.pixelSize: 12
                    color: colorText
                    background: Rectangle { color: "transparent" }
                    text: {
                        var items = importWindow.summary ? importWindow.summary.unsupportedSummary : []
                        var lines = []
                        for (var i = 0; i < items.length; i++) {
                            var it = items[i]
                            lines.push("[" + it.count + "x, " + it.severity + "] " + it.title)
                        }
                        return lines.join("\n")
                    }
                }
            }
        }

        // ---------------- Step 4: destination ----------------
        GridLayout {
            visible: importWindow.step === 4
            Layout.fillWidth: true
            columns: 3
            rowSpacing: 8; columnSpacing: 8

            Label { text: "Project name:*"; color: colorText; Layout.alignment: Qt.AlignRight }
            TextField {
                id: nameField
                Layout.fillWidth: true; Layout.columnSpan: 2
                color: colorText
                background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 2 }
                onTextEdited: fileNameFieldK.text = Backend.sanitizeFolderName(text) + ".gpucs"
            }
            Label { text: "File name:*"; color: colorText; Layout.alignment: Qt.AlignRight }
            TextField {
                id: fileNameFieldK
                Layout.fillWidth: true; Layout.columnSpan: 2
                color: colorText
                background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 2 }
            }
            Label { text: "Location:*"; color: colorText; Layout.alignment: Qt.AlignRight }
            TextField {
                id: locationFieldK
                Layout.fillWidth: true
                color: colorText
                background: Rectangle { color: colorPanel; border.color: colorBorder; radius: 2 }
            }
            Button {
                text: "..."
                Layout.preferredWidth: 40
                background: Rectangle { color: "#4d5057"; radius: 2 }
                contentItem: Text { text: parent.text; color: colorText; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                onClicked: { if (locationFieldK.text) folderDialogK.currentFolder = "file://" + locationFieldK.text; folderDialogK.open() }
            }

            Label { text: "Project folder:"; color: colorText; Layout.alignment: Qt.AlignRight }
            Label {
                Layout.fillWidth: true; Layout.columnSpan: 2
                elide: Text.ElideMiddle; font.pixelSize: 11
                color: importWindow.destConflict ? colorBad : colorText
                text: {
                    if (locationFieldK.text.trim() === "" || nameField.text.trim() === "") return "—"
                    var p = Backend.resolveProjectFolderPath(locationFieldK.text, nameField.text)
                    return importWindow.destConflict ? (p + "  (already exists)") : p
                }
            }
        }

        Label {
            id: errorLabel
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: colorBad
            font.pixelSize: 11
            visible: text !== ""
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Button {
                text: "Back"
                visible: importWindow.step > 0
                onClicked: importWindow.step -= 1
                background: Rectangle { color: "transparent"; border.color: colorBorder; radius: 2 }
                contentItem: Text { text: parent.text; color: colorText; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                implicitHeight: 32; implicitWidth: 80
            }

            Item { Layout.fillWidth: true }

            Button {
                text: "Cancel"
                onClicked: { importWindow.rejected(); importWindow.close() }
                background: Rectangle { color: "transparent"; border.color: colorBorder; radius: 2 }
                contentItem: Text { text: parent.text; color: colorText; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                implicitHeight: 32; implicitWidth: 80
            }

            Button {
                text: importWindow.step < 4 ? "Next" : "Import"
                visible: importWindow.step > 0
                enabled: importWindow.step < 4
                    || (nameField.text.trim() !== "" && fileNameFieldK.text.trim() !== ""
                        && locationFieldK.text.trim() !== "" && !importWindow.destConflict)
                opacity: enabled ? 1.0 : 0.5
                highlighted: true
                onClicked: {
                    if (importWindow.step < 4) { importWindow.step += 1; return }
                    var fn = fileNameFieldK.text.trim()
                    if (!fn.endsWith(".gpucs")) fn += ".gpucs"
                    importWindow.accepted(importWindow.kdenlivePath, locationFieldK.text.trim(),
                                           nameField.text.trim(), fn, importWindow.options)
                }
                background: Rectangle { color: parent.down ? "#2a9ad0" : colorHighlight; radius: 2 }
                contentItem: Text { text: parent.text; color: "white"; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                implicitHeight: 32; implicitWidth: 90
            }
        }
    }

    function showError(msg) { errorLabel.text = msg }
}
