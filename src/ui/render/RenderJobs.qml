import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import VideoEditor 1.0

Rectangle {
    id: renderJobs
    color: palette.window
    border.color: "#1d1d1d"
    border.width: 1

    // Színek
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
    // looked at (RenderWorkspace.qml's TabBar reads this for the unread-
    // dot badge); cleared by markSeen() when the tab becomes current.
    property bool hasUnseen: false
    function markSeen() { hasUnseen = false }

    // --- SEGÉDFÜGGVÉNYEK ---
    function formatFileSize(bytes) {
        if (!bytes || bytes === 0) return "-";
        var sizes = ['Bytes', 'KB', 'MB', 'GB', 'TB'];
        var i = parseInt(Math.floor(Math.log(bytes) / Math.log(1024)));
        return (bytes / Math.pow(1024, i)).toFixed(2) + ' ' + sizes[i];
    }

    function formatDuration(ms) {
        if (!ms || ms <= 0) return "00:00:00";
        var seconds = Math.floor(ms / 1000);
        var h = Math.floor(seconds / 3600);
        var m = Math.floor((seconds % 3600) / 60);
        var s = seconds % 60;
        return (h < 10 ? "0"+h : h) + ":" + (m < 10 ? "0"+m : m) + ":" + (s < 10 ? "0"+s : s);
    }

    function formatTimeFromMs(ms) {
        if (!ms || ms <= 0) return "-";
        return Qt.formatTime(new Date(ms), "hh:mm:ss");
    }

    // Finds the model row for a backend job id. Rows are keyed by the id
    // RenderEngine::startRender() returns - the old code addressed row 0
    // ("the newest job") for every signal, which silently applied a second
    // render's status to the first one's row (and vice versa) as soon as two
    // renders existed. Returns -1 if the job has no row.
    function rowForJob(jobId) {
        for (var i = 0; i < jobsModel.count; i++) {
            if (jobsModel.get(i).jobId === jobId) return i;
        }
        return -1;
    }

    // Removes a single row. An active (queued/running) job is cancelled
    // first - removing its row without stopping the backend job would
    // leave an orphaned render with no UI to track it.
    function removeRow(index) {
        var item = jobsModel.get(index)
        if (item.active) Backend.renderEngine.cancelJob(item.jobId)
        jobsModel.remove(index)
    }

    function clearAll() {
        for (var i = jobsModel.count - 1; i >= 0; i--) removeRow(i)
    }

    // --- JOB HOZZÁADÁSA ---
    function addJob(jobId, queued, filename, path, resolution, fps, codec, format, bitrate, type, deviceName) {
        var now = new Date().getTime(); // Milliszekundum
        jobsModel.insert(0, {
            "jobId": jobId,
            "filename": filename,
            "path": path,
            "resolution": resolution,
            "fps": fps,
            "codec": codec,
            "format": format,
            "bitrate": bitrate,
            "type": type,
            "deviceName": deviceName,
            "progress": 0,
            "status": queued ? "Queued" : "Rendering...",
            "active": true,
            "running": !queued,
            "currentFps": 0.0,
            "avgFps": 0.0,
            "startTime": now,   // Számként tároljuk
            "endTime": now,     // Kezdetben egyezik a starttal (futó idő)
            "fileSize": 0
        });
    }

    // --- BACKEND KAPCSOLAT ---
    Connections {
        target: Backend.renderEngine

        function onJobStarted(jobId) {
            var r = rowForJob(jobId)
            if (r < 0) return
            // A queued job only now actually begins - restart its clock so the
            // reported duration is encode time, not time-spent-waiting.
            jobsModel.setProperty(r, "running", true)
            jobsModel.setProperty(r, "status", "Rendering...")
            jobsModel.setProperty(r, "startTime", new Date().getTime())
            jobsModel.setProperty(r, "endTime", new Date().getTime())
        }

        function onJobProgress(jobId, percent) {
            var r = rowForJob(jobId)
            if (r < 0 || !jobsModel.get(r).active) return
            jobsModel.setProperty(r, "progress", percent)
            // Frissítjük az endTime-ot a jelenlegi időre, hogy pörögjön a számláló
            jobsModel.setProperty(r, "endTime", new Date().getTime())
        }

        function onJobFinished(jobId, success, fileSize, errorMessage) {
            var r = rowForJob(jobId)
            if (r < 0) return
            jobsModel.setProperty(r, "active", false)
            jobsModel.setProperty(r, "running", false)
            jobsModel.setProperty(r, "currentFps", 0)
            jobsModel.setProperty(r, "endTime", new Date().getTime())
            if (success) {
                jobsModel.setProperty(r, "progress", 100)
                jobsModel.setProperty(r, "status", "Finished")
                jobsModel.setProperty(r, "fileSize", fileSize)
            } else if (errorMessage === "Cancelled") {
                jobsModel.setProperty(r, "status", "Cancelled")
            } else {
                jobsModel.setProperty(r, "status", "Error: " + errorMessage)
            }
            renderJobs.hasUnseen = true
        }

        function onJobFps(jobId, current, avg) {
            var r = rowForJob(jobId)
            if (r < 0 || !jobsModel.get(r).active) return
            jobsModel.setProperty(r, "currentFps", current)
            jobsModel.setProperty(r, "avgFps", avg)
        }

        // Only fires for requests that never became a job (no clips etc.) -
        // deliberately NOT applied to any existing row.
        function onError(message) {
            console.warn("Render request rejected:", message)
        }
    }

    ListModel {
        id: jobsModel
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
                onClicked: renderJobs.clearAll()
            }
        }

        Label {
            visible: jobsModel.count === 0
            text: "No jobs in queue."
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
                height: 140
                color: colorPanel
                radius: 4
                border.width: 1
                border.color: model.status.startsWith("Error") ? colorError :
                              (model.status === "Finished" ? colorSuccess :
                              (model.active ? (model.running ? colorHighlight : colorQueued) : "#444"))

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 4

                    // SOR 1: Típus + Fájlnév + Státusz + Stop Gomb
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        
                        Rectangle {
                            Layout.preferredWidth: 60
                            Layout.preferredHeight: 22
                            color: model.type === "Export" ? "#2980b9" : "#e67e22"
                            radius: 3
                            Text {
                                anchors.centerIn: parent
                                text: model.type
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
                                // Scoped to the painted text, not the
                                // Layout.fillWidth-stretched item - that
                                // item spans the whole row's slack space,
                                // so anchors.fill: parent used to make
                                // clicks far past a short filename still
                                // open the player.
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
                            onClicked: {
                                Backend.renderEngine.cancelJob(model.jobId);
                            }
                        }

                        Text {
                            visible: !model.active || !model.running
                            text: model.status
                            color: model.status === "Finished" ? colorSuccess :
                                   (model.status.startsWith("Error") ? colorError :
                                   (model.status === "Queued" ? colorQueued : colorHighlight))
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
                            onClicked: renderJobs.removeRow(index)
                        }
                    }

                    // SOR 2: Eszköz név + Részletes paraméterek
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
                            text: model.resolution + " @ " + model.fps + "  |  " + model.codec + "  |  " + model.format + "  |  " + model.bitrate
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
                    }

                    // SOR 4: Progress és FPS
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
                            visible: model.running || model.status === "Finished"
                            text: {
                                if (model.running) {
                                    return model.currentFps > 0 ? 
                                      model.currentFps.toFixed(1) + " fps (Avg: " + model.avgFps.toFixed(1) + ")" : 
                                      "Calculating...";
                                } else if (model.status === "Finished") {
                                    return "Avg: " + model.avgFps.toFixed(1) + " fps";
                                }
                                return "";
                            }
                            color: colorHighlight
                            font.pixelSize: 13
                            font.bold: true
                            font.italic: true
                        }
                    }

                    // SOR 5: STATISZTIKÁK (Start, End, Duration, Size)
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 1
                        color: "#444"
                        visible: model.active || model.status === "Finished"
                        Layout.topMargin: 5
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 20
                        visible: model.active || model.status === "Finished"
                        
                        Text {
                            text: "Start: " + formatTimeFromMs(model.startTime)
                            color: colorSubText
                            font.pixelSize: 12
                        }

                        Text {
                            visible: !model.active
                            text: "End: " + formatTimeFromMs(model.endTime)
                            color: colorSubText
                            font.pixelSize: 12
                        }

                        Text {
                            property var diff: (model.endTime > 0 && model.startTime > 0) ? 
                                               (model.endTime - model.startTime) : 0
                            text: "Duration: " + formatDuration(diff)
                            color: colorSubText
                            font.pixelSize: 12
                            font.bold: true
                        }

                        Item { Layout.fillWidth: true } // Spacer

                        Text {
                            text: "Size: " + formatFileSize(model.fileSize)
                            color: colorText 
                            font.pixelSize: 12
                            font.bold: true
                        }
                    }
                }
            }
        }
    }
}
