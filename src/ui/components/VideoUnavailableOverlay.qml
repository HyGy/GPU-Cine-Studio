import QtQuick
import VideoEditor 1.0

// Shown over a monitor when its GstGLQt6VideoItem never initialises. The
// usual cause is a GStreamer qml6 plugin built without support for the
// running Qt platform (e.g. no Wayland support on QT_QPA_PLATFORM=wayland):
// the item then stays uninitialised forever and the panel is just black.
// Fill the monitor's video area with it (anchors.fill: parent).
Rectangle {
    id: root
    // The GstGLQt6VideoItem to watch (needs itemInitialized + visible).
    property Item glItem: null
    // False when the GL path is not used at all (native-window sink).
    property bool monitored: true
    // Seconds the visible item may stay uninitialised before we complain.
    property int timeoutMs: 5000

    readonly property bool waiting: monitored && glItem !== null && glItem.visible
                                    && !glItem.itemInitialized
    property bool timedOut: false

    anchors.fill: parent
    z: 20
    color: "black"
    visible: timedOut && waiting

    onWaitingChanged: if (!waiting) timedOut = false

    Timer {
        interval: root.timeoutMs
        running: root.waiting
        onTriggered: root.timedOut = true
    }

    Text {
        anchors.centerIn: parent
        width: parent.width - 32
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        color: "#ffb060"
        font.pixelSize: 13
        text: Backend.platformName === "xcb"
              ? "Video preview unavailable (the GStreamer qml6 video item failed to initialise)."
              : "Video preview unavailable on this platform (GStreamer qml6 plugin lacks "
                + Backend.platformName + " support). Start with QT_QPA_PLATFORM=xcb."
    }
}
