import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import VideoEditor 1.0

// Codec feature status (Codecs singleton, src/core/CodecCheck.h) with the
// distro-specific install command. Shared by the startup "missing codecs"
// dialog (main.qml) and Settings > Codecs. Pure view.
ColumnLayout {
    id: root

    // Only the rows that are not OK (startup dialog) or every row (Settings).
    property bool onlyProblems: false
    property color textColor: "#eff0f1"
    property color dimColor: "#a0a4a8"
    property color panelColor: "#232629"
    property color borderColor: "#5d6066"
    property color okColor: "#27ae60"
    property color warnColor: "#f39c12"
    property color badColor: "#da4453"

    spacing: 8

    function statusMark(s) {
        if (s === "ok") return "✔"            // check mark
        if (s === "hardware-only") return "◐" // half circle: partly
        return "✘"                            // cross
    }
    function statusColor(s) {
        if (s === "ok") return okColor
        if (s === "hardware-only") return warnColor
        return badColor
    }
    function statusText(s) {
        if (s === "ok") return "OK"
        if (s === "hardware-only") return "GPU only"
        if (s === "incompatible") return "Installed but incompatible"
        return "Missing"
    }

    readonly property var shownFeatures: {
        var out = []
        var all = Codecs.features
        for (var i = 0; i < all.length; ++i)
            if (!onlyProblems || all[i].status !== "ok") out.push(all[i])
        return out
    }
    readonly property bool anyProblem: {
        var all = Codecs.features
        for (var i = 0; i < all.length; ++i)
            if (all[i].status !== "ok") return true
        return false
    }

    Repeater {
        model: root.shownFeatures
        delegate: RowLayout {
            objectName: "codecRow_" + modelData.id
            Layout.fillWidth: true
            spacing: 10
            Label {
                text: root.statusMark(modelData.status)
                color: root.statusColor(modelData.status)
                font.pixelSize: 16
                font.bold: true
                Layout.alignment: Qt.AlignTop
                Layout.preferredWidth: 18
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                RowLayout {
                    spacing: 8
                    Label { text: modelData.title; color: root.textColor; font.pixelSize: 12; font.bold: true }
                    Label { text: root.statusText(modelData.status); color: root.statusColor(modelData.status); font.pixelSize: 11 }
                }
                Label {
                    Layout.fillWidth: true
                    text: modelData.detail
                    color: root.dimColor
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                }
            }
        }
    }

    Label {
        visible: Codecs.incompatiblePlugins.length > 0
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: root.badColor
        font.pixelSize: 11
        text: "Installed but not loadable by the bundled GStreamer " + Codecs.gstreamerVersion + ":\n• "
              + Codecs.incompatiblePlugins.join("\n• ")
              + "\nA newer AppImage (built with a newer GStreamer) is needed for these."
    }

    Label {
        visible: Codecs.pluginMode === "appimage-nohost"
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: root.warnColor
        font.pixelSize: 11
        text: "GCS_NO_HOST_CODECS is set: the distribution's codec plugins are deliberately not used."
    }

    // --- what to install -----------------------------------------------------
    Label {
        visible: root.anyProblem
        Layout.topMargin: 6
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: root.textColor
        font.pixelSize: 12
        text: Codecs.pluginMode === "native" && Codecs.installCommand.indexOf("build-gstreamer") >= 0
              ? "To fix:"
              : "To fix, install your distribution's codec packages (" + Codecs.distroName + "), then restart the app or press Re-check:"
    }
    Rectangle {
        visible: root.anyProblem && Codecs.installCommand !== ""
        Layout.fillWidth: true
        implicitHeight: cmdRow.implicitHeight + 12
        color: root.panelColor
        border.color: root.borderColor
        radius: 3
        RowLayout {
            id: cmdRow
            anchors.fill: parent
            anchors.margins: 6
            spacing: 8
            TextEdit {
                id: cmdText
                objectName: "codecInstallCommand"
                Layout.fillWidth: true
                text: Codecs.installCommand
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.WrapAnywhere
                color: root.textColor
                font.family: "Monospace"
                font.pixelSize: 11
            }
            Button {
                id: copyButton
                text: copied ? "Copied" : "Copy"
                property bool copied: false
                Layout.alignment: Qt.AlignTop
                onClicked: { Codecs.copyToClipboard(Codecs.installCommand); copied = true; copiedReset.restart() }
                Timer { id: copiedReset; interval: 1500; onTriggered: copyButton.copied = false }
            }
        }
    }
    Label {
        visible: root.anyProblem && Codecs.installNote !== ""
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: root.dimColor
        font.pixelSize: 11
        text: Codecs.installNote
    }
}
