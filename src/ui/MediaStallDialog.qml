import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window

// Shown when TimelineEngine's media loader has been stuck on one source file
// for several seconds (unresponsive/disconnected drive). See
// TimelineEngine::mediaLoadStalled / skipStalledMedia() / abortMediaLoad().
Window {
    id: stallWindow
    title: cancelledNotice ? "Loading cancelled" : "Media not responding"
    width: 560
    height: cancelledNotice ? 230 : (blocked ? 280 : 400)
    visible: false

    // Same pattern as LoadingDialog.qml: application-modal, always on top.
    // Being shown later than the loading dialog it ends up above it.
    modality: Qt.ApplicationModal
    flags: Qt.Dialog | Qt.WindowStaysOnTopHint

    // Stílus változók (Breeze Dark)
    readonly property color colorBackground: "#31363b"
    readonly property color colorPanel: "#232629"
    readonly property color colorText: "#eff0f1"
    readonly property color colorHighlight: "#3daee9"
    readonly property color colorBorder: "#5d6066"
    readonly property color colorSubText: "#aaaaaa"
    readonly property color colorWarn: "#f67400"
    color: colorBackground

    // The TimelineEngine to watch.
    property var engine: null
    // User asked to retry after "Cancel loading" (EditingWorkspace re-sends the clip list).
    signal retryRequested()

    // Seconds the engine's own 5 s threshold had already elapsed when it fired.
    readonly property int thresholdSeconds: 5
    readonly property int reshowSeconds: 15

    property bool cancelledNotice: false
    property double stalledSinceMs: 0
    property int waitedSeconds: thresholdSeconds
    property string snoozedPath: ""

    readonly property string stalledPath: engine ? engine.stalledMediaPath : ""
    readonly property bool blocked: engine ? engine.mediaLoadBlockedByAbandoned : false
    readonly property string mountRoot: engine ? engine.stalledMediaMountRoot : ""
    readonly property string driveText: mountRoot === "/" ? "the system drive (/)" : mountRoot
    readonly property string fileName: stalledPath.length ? stalledPath.split("/").pop() : ""

    function present() {
        stallWindow.show()
        stallWindow.raise()
        stallWindow.requestActivate()
        // Raise again once the window is really mapped: another always-on-top
        // window (the project loading dialog) may have been stacked above it
        // in the meantime.
        raiseTimer.restart()
    }

    Timer {
        id: raiseTimer
        interval: 150
        onTriggered: { if (stallWindow.visible) { stallWindow.raise(); stallWindow.requestActivate() } }
    }

    // Centered on the main window's screen like the other dialogs.
    Component.onCompleted: {
        x = (Screen.width - width) / 2
        y = (Screen.height - height) / 2
    }

    function onStallChanged() {
        if (cancelledNotice) return
        if (engine && engine.mediaLoadStalled) {
            if (stalledSinceMs === 0) stalledSinceMs = Date.now()
            // A different file than the one the user chose to keep waiting for
            // is reported at once; the same file only after the snooze.
            if (snoozedPath !== "" && snoozedPath === stalledPath) return
            snoozedPath = ""
            reshowTimer.stop()
            present()
        } else {
            stalledSinceMs = 0
            snoozedPath = ""
            reshowTimer.stop()
            stallWindow.close()
        }
    }

    Connections {
        target: stallWindow.engine
        function onMediaLoadStalledChanged() { stallWindow.onStallChanged() }
    }

    Timer {
        id: secondsTimer
        interval: 1000
        repeat: true
        running: stallWindow.visible && !stallWindow.cancelledNotice
        onTriggered: stallWindow.waitedSeconds = stallWindow.thresholdSeconds
                     + Math.floor((Date.now() - stallWindow.stalledSinceMs) / 1000)
    }

    Timer {
        id: reshowTimer
        interval: stallWindow.reshowSeconds * 1000
        onTriggered: {
            if (stallWindow.engine && stallWindow.engine.mediaLoadStalled
                    && stallWindow.stalledPath === stallWindow.snoozedPath) {
                stallWindow.snoozedPath = ""
                stallWindow.present()
            }
        }
    }

    // The window being closed by the window manager counts as "Keep waiting".
    onClosing: function(close) {
        if (!cancelledNotice && engine && engine.mediaLoadStalled && snoozedPath === "") keepWaiting()
    }

    function keepWaiting() {
        snoozedPath = stalledPath
        reshowTimer.restart()
        stallWindow.close()
    }

    function skipFile(wholeDrive) {
        reshowTimer.stop()
        snoozedPath = ""
        // Clears the engine's stall state, which also closes this window.
        engine.skipStalledMedia(wholeDrive)
        stallWindow.close()
    }

    function cancelLoading() {
        reshowTimer.stop()
        snoozedPath = ""
        engine.abortMediaLoad()
        cancelledNotice = true
        present()
    }

    function closeNotice() {
        cancelledNotice = false
        stallWindow.close()
    }

    component DialogButton: Button {
        id: btn
        property bool accent: false
        implicitHeight: 32
        implicitWidth: 150
        background: Rectangle {
            color: btn.accent ? (btn.down ? "#2a9ad0" : stallWindow.colorHighlight)
                              : (btn.down ? "#3d4045" : "#4d5057")
            radius: 2
        }
        contentItem: Text {
            text: btn.text
            color: btn.accent ? "white" : stallWindow.colorText
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.pixelSize: 12
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Header
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 60
            color: stallWindow.colorPanel

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 15
                spacing: 5
                Text {
                    text: stallWindow.cancelledNotice ? "Loading cancelled" : "Media is not responding"
                    font.pixelSize: 18
                    font.bold: true
                    color: stallWindow.cancelledNotice ? stallWindow.colorText : stallWindow.colorWarn
                }
            }
        }

        // Cancelled notice
        ColumnLayout {
            visible: stallWindow.cancelledNotice
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: 15
            spacing: 10
            Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: stallWindow.colorText
                font.pixelSize: 13
                text: "Loading was cancelled. The timeline preview is not loaded; the clips are still in your project and nothing was removed or changed. Press \"Retry loading\" to try again, or reopen the project once the drive is available."
            }
            Item { Layout.fillHeight: true }
            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: 8
                DialogButton { text: "Close"; onClicked: stallWindow.closeNotice() }
                DialogButton {
                    text: "Retry loading"
                    accent: true
                    onClicked: { stallWindow.closeNotice(); stallWindow.retryRequested() }
                }
            }
        }

        // Stall message
        ColumnLayout {
            visible: !stallWindow.cancelledNotice
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: 15
            spacing: 8

            Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: stallWindow.colorText
                font.pixelSize: 13
                text: stallWindow.blocked
                      ? "Still waiting for the system to give up on this file; the remaining media will load afterwards."
                      : "A media file is taking very long to respond. The drive it is on may be disconnected or unresponsive."
            }
            Text {
                Layout.fillWidth: true
                text: stallWindow.fileName
                color: stallWindow.colorText
                font.bold: true
                font.pixelSize: 13
                elide: Text.ElideMiddle
            }
            Text {
                Layout.fillWidth: true
                text: stallWindow.stalledPath
                color: stallWindow.colorSubText
                font.pixelSize: 11
                elide: Text.ElideMiddle
                ToolTip.visible: pathHover.hovered
                ToolTip.text: stallWindow.stalledPath
                HoverHandler { id: pathHover }
            }
            Text {
                text: "Waiting for " + stallWindow.waitedSeconds + " s"
                color: stallWindow.colorSubText
                font.pixelSize: 12
            }
            Text {
                visible: !stallWindow.blocked
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: stallWindow.colorSubText
                font.pixelSize: 11
                text: "\"Skip all media on this drive\" applies to every file on " + stallWindow.driveText + "."
            }

            Item { Layout.fillHeight: true }

            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: 8
                DialogButton {
                    visible: !stallWindow.blocked
                    text: "Skip all on this drive"
                    implicitWidth: 170
                    ToolTip.visible: hovered
                    ToolTip.text: "Treat every media file on " + stallWindow.driveText + " that is still waiting to load as unavailable"
                    onClicked: stallWindow.skipFile(true)
                }
                DialogButton {
                    visible: !stallWindow.blocked
                    text: "Skip this file"
                    onClicked: stallWindow.skipFile(false)
                }
            }
            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: 8
                DialogButton { text: "Cancel loading"; onClicked: stallWindow.cancelLoading() }
                DialogButton {
                    text: "Keep waiting"
                    accent: true
                    onClicked: stallWindow.keepWaiting()
                }
            }
        }
    }
}
