import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window

Window {
    id: loadingDialog
    title: "Loading Project..."
    width: 700
    height: 500
    color: "#2d2d2d"

    // Window flags: always on top, no close button, modal-like behavior
    flags: Qt.Window | Qt.WindowStaysOnTopHint | Qt.CustomizeWindowHint | Qt.WindowTitleHint
    modality: Qt.ApplicationModal

    property string currentWorkspace: ""
    property string currentStep: ""
    property var logMessages: []

    function open() {
        loadingDialog.show()
        loadingDialog.raise()
        loadingDialog.requestActivate()
    }

    function reset() {
        currentWorkspace = ""
        currentStep = ""
        logMessages = []
    }

    function setWorkspace(workspace) {
        currentWorkspace = workspace
        addLog("--- " + workspace + " ---")
    }

    function setStep(step) {
        currentStep = step
        addLog("  " + step)
    }

    function addLog(message) {
        var newMessages = logMessages.slice()
        newMessages.push(message)
        logMessages = newMessages
        // REMOVED: logListView.positionViewAtEnd() 
        // Scrolling is handled by onLogMessagesChanged below
    }

    function finish() {
        addLog("")
        addLog("Project loaded successfully!")
        loadingDialog.close()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 15
        spacing: 10

        // Header
        Text {
            text: "Loading Project..."
            color: "white"
            font.bold: true
            font.pixelSize: 18
            Layout.alignment: Qt.AlignHCenter
        }

        // Current workspace indicator
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 60
            color: "#3a3a3a"
            radius: 4

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 4

                Text {
                    text: currentWorkspace || "Initializing..."
                    color: "#4a9eff"
                    font.bold: true
                    font.pixelSize: 14
                }

                Text {
                    text: currentStep || "Please wait..."
                    color: "#aaa"
                    font.pixelSize: 12
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }
        }

        // Progress indicator
        BusyIndicator {
            Layout.alignment: Qt.AlignHCenter
            running: loadingDialog.visible
            palette.dark: "#4a9eff"
        }

        // Log area - scrollable and selectable
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "#1e1e1e"
            radius: 4
            border.color: "#444"
            border.width: 1

            ScrollView {
                id: logScrollView
                anchors.fill: parent
                anchors.margins: 8
                clip: true

                TextArea {
                    id: logTextArea
                    readOnly: true
                    selectByMouse: true
                    selectByKeyboard: true
                    wrapMode: TextArea.Wrap
                    font.pixelSize: 11
                    font.family: "monospace"
                    color: "#ccc"
                    background: Rectangle { color: "transparent" }
                    text: logMessages.join("\n")
                }
            }
        }
    }

    // Helper to scroll to bottom
    function scrollToBottom() {
        // Option 1: Scroll bar manipulation (what you currently have)
        if (logScrollView.ScrollBar.vertical) {
             logScrollView.ScrollBar.vertical.position = 1.0 - logScrollView.ScrollBar.vertical.size
        }
        
        // Option 2 (Alternative): Move cursor to end, which forces scroll
        // logTextArea.cursorPosition = logTextArea.length
    }

    onLogMessagesChanged: {
        Qt.callLater(scrollToBottom)
    }
}
