import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import VideoEditor 1.0

// Proxy generation's own queue list - kept as a SEPARATE tab/list from
// RenderJobs.qml (not merged into one list), per explicit user decision:
// a batch of many proxy jobs (e.g. a future Phase 6 "generate proxies for
// a whole imported folder") would otherwise flood the Render Queue with
// one row per file. This view is purely a display layer: it does NOT
// share RenderEngine's actual device-conflict arbitration with proxy
// generation - CacheManager's own existing proxy queue (capped at 1
// concurrent job) is still what actually runs things. See
// proxy_build_plan.md Part E's status note for the full history of this
// scope decision.
Rectangle {
    id: proxyJobs
    color: palette.window
    border.color: "#1d1d1d"
    border.width: 1

    readonly property color colorText: "#eff0f1"
    readonly property color colorSubText: "#aaaaaa"
    readonly property color colorPanel: "#232629"
    readonly property color colorHighlight: "#3daee9"
    readonly property color colorSuccess: "#27ae60"
    readonly property color colorError: "#c0392b"
    readonly property color colorLink: "#5dade2"
    readonly property color colorStop: "#e74c3c"
    readonly property color colorQueued: "#f39c12"

    // Set when a job finishes/fails while this tab isn't the one being
    // looked at; cleared by markSeen() when the tab becomes current -
    // mirrors RenderJobs.qml's own hasUnseen/markSeen().
    property bool hasUnseen: false
    function markSeen() { hasUnseen = false }

    function formatTimeFromMs(ms) {
        if (!ms || ms <= 0) return "-";
        return Qt.formatTime(new Date(ms), "hh:mm:ss");
    }

    function formatDuration(ms) {
        if (!ms || ms <= 0) return "00:00:00";
        var seconds = Math.floor(ms / 1000);
        var h = Math.floor(seconds / 3600);
        var m = Math.floor((seconds % 3600) / 60);
        var s = seconds % 60;
        return (h < 10 ? "0"+h : h) + ":" + (m < 10 ? "0"+m : m) + ":" + (s < 10 ? "0"+s : s);
    }

    // Rows are keyed by "itemId|resolution@format" directly (strings, not
    // the synthetic int ids RenderJobs.qml needs) - proxy generation has
    // no RenderEngine-assigned job id to collide with, so there's no
    // reason to invent one here. Includes format (registry v3, Part J.1)
    // so two different formats queued at the same resolution get distinct
    // rows instead of colliding onto one.
    function rowKey(itemId, resolution, format) { return itemId + "|" + resolution + "@" + format }

    function rowForKey(key) {
        for (var i = 0; i < jobsModel.count; i++) {
            if (jobsModel.get(i).rowKey === key) return i;
        }
        return -1;
    }

    // Removes a single row. An active (pending/generating) job is
    // cancelled first - removing its row without stopping the backend job
    // would leave an orphaned proxy generation with no UI to track it.
    // Passes the row's exact format so this never touches a sibling job
    // at the same resolution but a different format.
    function removeRow(index) {
        var item = jobsModel.get(index)
        if (item.active) Backend.cacheManager.cancelProxyGeneration(item.itemId, item.resolution, item.format)
        jobsModel.remove(index)
    }

    function clearAll() {
        for (var i = jobsModel.count - 1; i >= 0; i--) removeRow(i)
    }

    function deviceDisplayName(token) {
        if (!token) return "Auto"
        var devices = Backend.gpuDevices
        for (var i = 0; i < devices.length; i++) {
            if (devices[i].id.split("-")[0] === token) return devices[i].name
        }
        return token
    }

    ListModel {
        id: jobsModel
    }

    Connections {
        target: Backend.cacheManager

        // A request is visible here the moment it's accepted, not only
        // once CacheManager's single-job proxy queue actually gets to it -
        // otherwise a batch request only ever shows the one item currently
        // generating, with everything else behind it invisible.
        function onProxyJobQueued(itemId, resolution, format, device, sourceFileName) {
            var key = proxyJobs.rowKey(itemId, resolution, format)
            if (proxyJobs.rowForKey(key) >= 0) return
            var now = new Date().getTime();
            jobsModel.insert(0, {
                "rowKey": key,
                "itemId": itemId,
                "resolution": resolution,
                "filename": sourceFileName,
                "path": "",
                "format": format,
                "deviceName": proxyJobs.deviceDisplayName(device),
                "progress": 0,
                "status": "Pending...",
                "active": true,
                "startTime": now,
                "endTime": now
            });
        }

        // Updates the row onProxyJobQueued already created, in place -
        // CacheManager runs one proxy job at a time, so by the time this
        // fires the row from the queued moment is always already there.
        function onProxyJobStarted(itemId, resolution, format, device, sourceFileName) {
            var now = new Date().getTime();
            var r = proxyJobs.rowForKey(proxyJobs.rowKey(itemId, resolution, format))
            if (r < 0) {
                jobsModel.insert(0, {
                    "rowKey": proxyJobs.rowKey(itemId, resolution, format),
                    "itemId": itemId,
                    "resolution": resolution,
                    "filename": sourceFileName,
                    "path": "",
                    "format": format,
                    "deviceName": proxyJobs.deviceDisplayName(device),
                    "progress": 0,
                    "status": "Generating...",
                    "active": true,
                    "startTime": now,
                    "endTime": now
                });
                return
            }
            jobsModel.setProperty(r, "status", "Generating...")
            jobsModel.setProperty(r, "startTime", now)
            jobsModel.setProperty(r, "endTime", now)
        }

        // Corrects the "Using: X" row to the backend the encoder ACTUALLY
        // resolved to, once ProxyGenerator figures that out (shortly
        // after onProxyJobStarted, which can only show the REQUESTED
        // device - "Auto" tells you nothing about whether that meant
        // nvidia, vaapi, or a CPU fallback).
        function onProxyJobBackendResolved(itemId, resolution, format, backend) {
            var r = proxyJobs.rowForKey(proxyJobs.rowKey(itemId, resolution, format))
            if (r < 0) return
            jobsModel.setProperty(r, "deviceName", proxyJobs.deviceDisplayName(backend))
        }

        // itemStatusChanged doesn't carry resolution, but CacheManager
        // caps concurrent proxy generation at 1, so "the row(s) currently
        // tracked for this itemId" is unambiguous in practice.
        function onItemStatusChanged(itemId, kind, status, progress) {
            if (kind !== "proxy" || status !== "generating") return
            for (var i = 0; i < jobsModel.count; i++) {
                if (jobsModel.get(i).itemId !== itemId) continue
                jobsModel.setProperty(i, "progress", progress)
                jobsModel.setProperty(i, "endTime", new Date().getTime())
            }
        }

        function onProxyReady(itemId, resolution, format, proxyPath) {
            var r = proxyJobs.rowForKey(proxyJobs.rowKey(itemId, resolution, format))
            if (r < 0) return
            var slash = proxyPath.lastIndexOf("/")
            jobsModel.setProperty(r, "path", slash >= 0 ? proxyPath.substring(0, slash) : "")
            jobsModel.setProperty(r, "filename", slash >= 0 ? proxyPath.substring(slash + 1) : proxyPath)
            jobsModel.setProperty(r, "active", false)
            jobsModel.setProperty(r, "progress", 100)
            jobsModel.setProperty(r, "status", "Finished")
            jobsModel.setProperty(r, "endTime", new Date().getTime())
            proxyJobs.hasUnseen = true
        }

        function onProxyFailed(itemId, resolution, format, error) {
            var r = proxyJobs.rowForKey(proxyJobs.rowKey(itemId, resolution, format))
            if (r < 0) return
            jobsModel.setProperty(r, "active", false)
            jobsModel.setProperty(r, "status", error === "Cancelled" ? "Cancelled" : ("Error: " + error))
            jobsModel.setProperty(r, "endTime", new Date().getTime())
            proxyJobs.hasUnseen = true
        }

        // Closes the row for a request that never got past "pending" -
        // onProxyFailed only ever fires for a job the generator actually
        // ran, so a still-queued request cancelled before its turn needs
        // this separate signal instead.
        function onProxyJobDequeued(itemId, resolution, format, reason) {
            var r = proxyJobs.rowForKey(proxyJobs.rowKey(itemId, resolution, format))
            if (r < 0) return
            jobsModel.setProperty(r, "active", false)
            jobsModel.setProperty(r, "status", reason === "resolution-changed" ? "Superseded" : "Cancelled")
            jobsModel.setProperty(r, "endTime", new Date().getTime())
            proxyJobs.hasUnseen = true
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 15
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            visible: jobsModel.count > 0

            Item { Layout.fillWidth: true }

            Button {
                text: "Clear All"
                Layout.preferredHeight: 26
                background: Rectangle { color: parent.down ? "#c0392b" : colorStop; radius: 3 }
                contentItem: Text {
                    text: parent.text
                    color: "white"
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    font.pixelSize: 11
                }
                onClicked: proxyJobs.clearAll()
            }
        }

        Label {
            visible: jobsModel.count === 0
            text: "No proxy jobs."
            color: colorSubText
            font.pixelSize: 14
            Layout.fillWidth: true
            Layout.fillHeight: true
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
        }

        ListView {
            id: jobsList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: jobsModel
            visible: jobsModel.count > 0
            spacing: 10

            ScrollBar.vertical: ScrollBar { id: vScrollBar }

            delegate: Rectangle {
                width: jobsList.width - (vScrollBar.visible ? vScrollBar.width : 0)
                height: 110
                color: colorPanel
                radius: 4
                border.width: 1
                border.color: model.status.startsWith("Error") ? colorError :
                              (model.status === "Finished" ? colorSuccess :
                              (model.active ? colorHighlight : "#444"))

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 4

                    // SOR 1: Fájlnév + Státusz + Stop Gomb
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        Rectangle {
                            Layout.preferredWidth: 60
                            Layout.preferredHeight: 22
                            color: "#e67e22"
                            radius: 3
                            Text {
                                anchors.centerIn: parent
                                text: "Proxy"
                                color: "white"
                                font.bold: true
                                font.pixelSize: 12
                            }
                        }

                        Text {
                            text: model.filename
                            color: model.status === "Finished" ? colorLink : colorText
                            font.bold: true
                            font.pixelSize: 16
                            font.underline: model.status === "Finished"
                            Layout.fillWidth: true
                            elide: Text.ElideRight

                            MouseArea {
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                width: Math.min(parent.contentWidth, parent.width)
                                enabled: model.status === "Finished"
                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                hoverEnabled: true
                                onClicked: {
                                    var fullPath = model.path
                                    if (fullPath.length > 0 && fullPath.charAt(fullPath.length - 1) !== '/') fullPath += "/";
                                    fullPath += model.filename;
                                    Backend.openFile(fullPath);
                                }
                            }
                        }

                        Button {
                            visible: model.path && model.path.length > 0
                            text: "Open Target Folder"
                            Layout.preferredHeight: 24
                            Layout.preferredWidth: 120
                            background: Rectangle {
                                color: parent.down ? "#4a7ea8" : "#5e92c2"
                                radius: 3
                            }
                            contentItem: Text {
                                text: parent.text
                                color: "white"
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                font.pixelSize: 11
                            }
                            onClicked: Backend.openFile(model.path)
                        }

                        Button {
                            visible: model.active
                            text: "Stop"
                            Layout.preferredHeight: 24
                            Layout.preferredWidth: 60
                            background: Rectangle {
                                color: parent.down ? "#c0392b" : colorStop
                                radius: 3
                            }
                            contentItem: Text {
                                text: parent.text
                                color: "white"
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                font.pixelSize: 11
                            }
                            onClicked: Backend.cacheManager.cancelProxyGeneration(model.itemId, model.resolution, model.format)
                        }

                        Text {
                            visible: model.active
                            text: model.status
                            color: model.status === "Pending..." ? colorQueued : colorHighlight
                            font.bold: true
                            font.pixelSize: 13
                        }

                        Text {
                            visible: !model.active
                            text: model.status
                            color: model.status === "Finished" ? colorSuccess :
                                   (model.status.startsWith("Error") ? colorError : colorHighlight)
                            font.bold: true
                            font.pixelSize: 13
                        }

                        Button {
                            text: "✕"
                            Layout.preferredHeight: 24
                            Layout.preferredWidth: 24
                            ToolTip.visible: hovered
                            ToolTip.text: "Remove from list"
                            background: Rectangle { color: parent.down ? "#555" : "transparent"; radius: 3 }
                            contentItem: Text {
                                text: parent.text
                                color: colorSubText
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                font.pixelSize: 13
                            }
                            onClicked: proxyJobs.removeRow(index)
                        }
                    }

                    // SOR 2: Eszköz + felbontás + formátum
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        Text {
                            text: "Using: " + model.deviceName
                            color: colorHighlight
                            font.pixelSize: 12
                            font.bold: true
                        }

                        Rectangle { width: 1; height: 12; color: "#555" }

                        Text {
                            text: model.resolution + "  |  " + model.format
                            color: colorSubText
                            font.pixelSize: 12
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }

                    // SOR 3: Útvonal
                    Text {
                        text: model.path
                        color: "#777"
                        font.pixelSize: 12
                        elide: Text.ElideMiddle
                        Layout.fillWidth: true
                        visible: model.path.length > 0
                    }

                    // SOR 4: Progress
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        ProgressBar {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 8
                            from: 0
                            to: 100
                            value: model.progress

                            background: Rectangle {
                                implicitWidth: 200; implicitHeight: 8; color: "#444"; radius: 4
                            }
                            contentItem: Item {
                                implicitWidth: 200; implicitHeight: 8
                                Rectangle {
                                    width: parent.parent.visualPosition * parent.width
                                    height: 8; radius: 4
                                    color: model.status === "Finished" ? colorSuccess : colorHighlight
                                }
                            }
                        }

                        Text {
                            text: model.progress + "%"
                            color: colorText
                            font.pixelSize: 13
                            font.bold: true
                            Layout.preferredWidth: 40
                            horizontalAlignment: Text.AlignRight
                        }

                        Text {
                            text: "Start: " + formatTimeFromMs(model.startTime) +
                                  (model.active ? "" : "  ·  Duration: " + formatDuration(model.endTime - model.startTime))
                            color: colorSubText
                            font.pixelSize: 12
                        }
                    }
                }
            }
        }
    }
}
