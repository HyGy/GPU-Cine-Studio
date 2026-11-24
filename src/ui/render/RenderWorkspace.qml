import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: renderWorkspace
    anchors.fill: parent

    SplitView {
        anchors.fill: parent
        orientation: Qt.Horizontal

        // Bal oldal - Settings
       RenderSettings {
            id: settingsPanel
            SplitView.minimumWidth: 400
            SplitView.preferredWidth: 450
            SplitView.fillHeight: true

            // JAVÍTÁS: Explicit paraméter deklaráció (Qt 6 kompatibilitás)
            onJobStarted: function(jobId, queued, filename, path, resolution, fps, codec, format, bitrate, type, deviceName) {
                jobsPanel.addJob(jobId, queued, filename, path, resolution, fps, codec, format, bitrate, type, deviceName)
            }
        }

        // Jobb oldal - Queue tabs (Render / Proxy)
        // Separate tabs, not one merged list: a batch of many proxy jobs
        // (Phase 6) would otherwise flood a single Render Queue list with
        // one row per file - user's explicit call. Unread-dot badge on
        // whichever tab ISN'T currently open, cleared the moment that tab
        // is actually selected (not on every individual event).
        ColumnLayout {
            SplitView.fillWidth: true
            SplitView.fillHeight: true
            spacing: 0

            // Plain QtQuick.Controls TabBar stretches its TabButtons to
            // fill the available width (50/50 for two tabs) - not wanted
            // here, so this is a hand-rolled, content-sized, left-aligned
            // tab strip instead: a Row of click targets sized to their own
            // label + unread-dot, with an underline marking the active one.
            Rectangle {
                id: queueTabBar
                Layout.fillWidth: true
                height: 36
                color: "#2a2e32"

                property int currentIndex: 0
                function select(i) {
                    currentIndex = i
                    if (i === 0) jobsPanel.markSeen()
                    else if (i === 1) proxyJobsPanel.markSeen()
                }

                Row {
                    id: queueTabRow
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom

                    Repeater {
                        model: [
                            { label: "Render Queue", panel: "render" },
                            { label: "Proxy Queue", panel: "proxy" }
                        ]

                        delegate: Item {
                            readonly property bool isCurrent: queueTabBar.currentIndex === index
                            readonly property bool hasUnseen: modelData.panel === "render" ? jobsPanel.hasUnseen : proxyJobsPanel.hasUnseen

                            width: tabRow.implicitWidth + 24
                            height: parent.height

                            Rectangle {
                                anchors.bottom: parent.bottom
                                width: parent.width
                                height: 2
                                color: "#3daee9"
                                visible: isCurrent
                            }

                            RowLayout {
                                id: tabRow
                                anchors.centerIn: parent
                                spacing: 6

                                Text {
                                    text: modelData.label
                                    color: isCurrent ? "#eff0f1" : "#888888"
                                    font.bold: true
                                    font.pixelSize: 16
                                    Layout.alignment: Qt.AlignVCenter
                                }
                                Rectangle {
                                    width: 8; height: 8; radius: 4
                                    color: "#e74c3c"
                                    visible: hasUnseen && !isCurrent
                                    Layout.alignment: Qt.AlignVCenter
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: queueTabBar.select(index)
                            }
                        }
                    }
                }
            }

            StackLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: queueTabBar.currentIndex

                RenderJobs {
                    id: jobsPanel
                }

                ProxyJobs {
                    id: proxyJobsPanel
                }
            }
        }
    }
}
