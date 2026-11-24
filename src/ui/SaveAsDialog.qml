import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Dialogs
import VideoEditor 1.0

// Save As. Deliberately NOT a third mode of ProjectSettingsDialog:
// that dialog's OK handler writes 11 settings keys and reconstructs the
// profile/decoder from storage LOSSILY (see its loadSettings(), which has
// no profile-matching logic and falls back to "first manual profile"), so
// reusing it here would silently rewrite a 4K project's profile to 1080p.
// Save As changes exactly three things: fileName, location, name.
//
// "Location" is the PARENT folder, same meaning as in New Project: the
// project gets its own dedicated subfolder so its .cache/ is never shared
// with an unrelated project (CacheManager::initialize() derives the cache
// dir from the project dir and nothing else).
Window {
    id: saveAsWindow
    title: "Save Project As — GPU Cine Studio"
    width: 620
    height: 300
    minimumWidth: 520
    minimumHeight: 280
    visible: false

    modality: Qt.ApplicationModal
    flags: Qt.Dialog | Qt.WindowStaysOnTopHint

    // (newParentDir, newProjectName, newFileName) - the caller does the
    // filesystem work and the rebind; this dialog only validates input.
    signal accepted(string parentDir, string projectName, string fileName)
    signal rejected()

    readonly property color colorBackground: "#31363b"
    readonly property color colorPanel: "#232629"
    readonly property color colorText: "#eff0f1"
    readonly property color colorHighlight: "#3daee9"
    readonly property color colorBorder: "#5d6066"
    color: colorBackground

    Component.onCompleted: {
        x = (Screen.width - width) / 2
        y = (Screen.height - height) / 2
    }

    onVisibleChanged: if (visible) loadDefaults()

    function loadDefaults() {
        errorLabel.text = ""

        // Default location = the PARENT of the current project's own
        // folder - i.e. wherever the user originally browsed to when
        // creating this project (their Videos folder, typically), not the
        // project's own dedicated subfolder. Default name = the current
        // project's name, unchanged - no "copy" decoration. Leaving the
        // name as-is with the original parent as location is a guaranteed
        // conflict only if the user doesn't change anything (same as
        // picking the exact same name/location in New Project) - the red
        // preview + disabled Save button make that obvious immediately,
        // same as everywhere else in this app rather than the app
        // silently inventing a different name.
        var curLoc = Backend.getSetting("project/location", "")
        var parent = curLoc.lastIndexOf("/") > 0
                     ? curLoc.substring(0, curLoc.lastIndexOf("/"))
                     : Backend.getDefaultVideosPath()
        parentDirField.text = parent
        projectNameField.text = Backend.getSetting("project/name", "Untitled Project")
        fileNameField.text = Backend.sanitizeFolderName(projectNameField.text) + ".gpucs"
        fileNameManuallyEdited = false
    }

    property bool fileNameManuallyEdited: false

    readonly property bool conflict:
        parentDirField.text.trim() !== "" && projectNameField.text.trim() !== ""
        && Backend.projectFolderWouldConflict(parentDirField.text, projectNameField.text)

    readonly property bool inputValid:
        parentDirField.text.trim() !== "" && projectNameField.text.trim() !== ""
        && fileNameField.text.trim() !== "" && !conflict

    FolderDialog {
        id: folderDialog
        title: "Select Parent Folder for the New Project Folder"
        onAccepted: parentDirField.text = selectedFolder.toString().replace("file://", "")
    }

    component Field : TextField {
        color: saveAsWindow.colorText
        Layout.fillWidth: true
        background: Rectangle {
            color: saveAsWindow.colorPanel
            border.color: saveAsWindow.colorBorder
            radius: 2
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 12

        GridLayout {
            Layout.fillWidth: true
            columns: 3
            rowSpacing: 8
            columnSpacing: 8

            Label {
                text: "Location:*"; color: colorText
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
            }
            Field {
                id: parentDirField
                placeholderText: "/path/to/parent/folder"
                Accessible.name: "Parent folder"
            }
            Button {
                // Plain ASCII, not an emoji glyph - U+1F4C1 renders as a
                // missing-glyph box without a color-emoji font installed.
                text: "..."
                Accessible.name: "Choose parent folder"
                Layout.preferredWidth: 40
                background: Rectangle { color: "#4d5057"; radius: 2 }
                contentItem: Text {
                    text: parent.text; color: colorText
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                onClicked: {
                    if (parentDirField.text)
                        folderDialog.currentFolder = "file://" + parentDirField.text
                    folderDialog.open()
                }
            }

            Label {
                text: "Project name:*"; color: colorText
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
            }
            Field {
                id: projectNameField
                Layout.columnSpan: 2
                placeholderText: "My Project copy"
                Accessible.name: "New project name"
                onTextEdited: {
                    if (!saveAsWindow.fileNameManuallyEdited)
                        fileNameField.text = Backend.sanitizeFolderName(text) + ".gpucs"
                }
            }

            Label {
                text: "File name:*"; color: colorText
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
            }
            Field {
                id: fileNameField
                Layout.columnSpan: 2
                placeholderText: "myproject.gpucs"
                Accessible.name: "New file name"
                onTextEdited: saveAsWindow.fileNameManuallyEdited = true
            }

            Label {
                text: "Project folder:"; color: colorText
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
            }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.columnSpan: 2
                spacing: 2

                Label {
                    Layout.fillWidth: true
                    elide: Text.ElideMiddle
                    font.pixelSize: 11
                    color: saveAsWindow.conflict ? "#e74c3c" : colorText
                    text: {
                        if (parentDirField.text.trim() === "") return "—"
                        if (projectNameField.text.trim() === "") return "—"
                        var p = Backend.resolveProjectFolderPath(
                            parentDirField.text, projectNameField.text)
                        return saveAsWindow.conflict ? (p + "  (already exists)") : p
                    }
                }
                Label {
                    id: errorLabel
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    color: "#e74c3c"
                    font.pixelSize: 11
                    visible: text !== ""
                    text: ""
                }
            }
        }

        Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            font.pixelSize: 11
            color: "#b0b3b8"
            text: "The current project file stays on disk unchanged. The editing "
                + "session continues in the new project from now on."
        }

        Item { Layout.fillHeight: true }

        RowLayout {
            Layout.alignment: Qt.AlignRight
            spacing: 10

            Button {
                text: "Cancel"
                Accessible.name: "Cancel save as"
                onClicked: { saveAsWindow.rejected(); saveAsWindow.close() }
                background: Rectangle {
                    color: "transparent"; border.color: colorBorder; radius: 2
                }
                contentItem: Text {
                    text: parent.text; color: colorText
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Button {
                text: "Save"
                highlighted: true
                Accessible.name: "Confirm save as"
                // Pre-emptive, same as the New Project dialog: a folder
                // conflict is a HARD REFUSAL, never an auto-appended
                // " (2)" - the user wants to be asked.
                enabled: saveAsWindow.inputValid
                opacity: enabled ? 1.0 : 0.5
                onClicked: {
                    // Re-check: the conflict may have appeared between
                    // opening this dialog and this click.
                    if (Backend.projectFolderWouldConflict(
                            parentDirField.text, projectNameField.text)) {
                        errorLabel.text = "\"" + Backend.resolveProjectFolderPath(
                                parentDirField.text, projectNameField.text)
                            + "\" already exists. Choose a different project name or location."
                        return
                    }
                    var fn = fileNameField.text.trim()
                    if (!fn.endsWith(".gpucs")) fn += ".gpucs"
                    errorLabel.text = ""
                    saveAsWindow.accepted(parentDirField.text.trim(),
                                          projectNameField.text.trim(), fn)
                }
                background: Rectangle {
                    color: parent.down ? "#2a9ad0" : colorHighlight; radius: 2
                }
                contentItem: Text {
                    text: parent.text; color: "white"
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }

    // Lets the caller report a post-click failure (folder creation, write)
    // without closing the dialog, so the user can correct and retry.
    function showError(msg) { errorLabel.text = msg }
}
