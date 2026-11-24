import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import VideoEditor 1.0

Rectangle {
    id: projectBinPanel

    SplitView.minimumWidth: 200
    SplitView.preferredWidth: 300
    color: palette.window
    border.color: "#1d1d1d"
    border.width: 1

    // Properties
    property var clipVideoEngine: null
    property string editingItemId: ""
    property var workspaceRoot: null  // Reference to EditingWorkspace root

    signal itemDoubleClicked(string itemPath)
    // The user picked a bin item (click, Up/Down, Enter, double-click), also
    // when it was already the selected one - the Clip Information panel uses
    // it to switch back to describing the bin item.
    signal itemPicked()

    // Double-click / Enter on a media item: load it into the Clip Monitor.
    function loadIntoClipMonitor(itemType, itemPath) {
        if (!((itemType === "video" || itemType === "audio" || itemType === "image") && itemPath)) return
        // playbin (behind loadVideo(), despite the name) decodes audio-only
        // and single-image sources fine, not just video - restricting this
        // to "video" left double-click doing nothing for audio/image items.
        console.log("Loading to Clip Monitor:", itemPath)
        if (projectBinPanel.clipVideoEngine)
            projectBinPanel.clipVideoEngine.loadVideo(itemPath, itemType !== "image")
        projectBinPanel.itemDoubleClicked(itemPath)
    }

    // Enter on the selected bin item: what a double-click does for media and
    // titles; a folder toggles open/closed instead of starting a rename (the
    // top-level groups always stay open).
    function activateItem(itemId) {
        if (!itemId) return
        itemPicked()
        var m = Backend.projectBinModel
        var idx = m.indexFromItemId(itemId)
        if (!idx.valid) return
        var row = projectBinTree.rowAtIndex(idx)
        if (m.data(idx, ProjectBinModel.IsFolderRole) || m.data(idx, ProjectBinModel.PseudoRole)) {
            if (row >= 0 && projectBinTree.depth(row) > 0) projectBinTree.toggleExpanded(row)
            return
        }
        var type = m.data(idx, ProjectBinModel.TypeRole)
        if (type === "title") {
            if (projectBinPanel.workspaceRoot) projectBinPanel.workspaceRoot.layoutMode = "effects"
            return
        }
        projectBinPanel.loadIntoClipMonitor(type, m.data(idx, ProjectBinModel.PathRole))
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 5
        spacing: 5

        // Header
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            color: "#3d3d3d"

            Text {
                anchors.centerIn: parent
                text: "Project Bin"
                color: "white"
                font.pixelSize: 13
                font.bold: true
            }

            // Source files that are not on disk: opens the Missing media dialog.
            Rectangle {
                id: missingChip
                visible: Backend.mediaAvailability.missingCount > 0
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                height: 20
                width: chipText.implicitWidth + 14
                radius: 3
                color: chipArea.containsMouse ? "#5a4a22" : "#463a1c"
                border.color: "#ffcc66"
                Text {
                    id: chipText
                    anchors.centerIn: parent
                    text: "\u26a0 " + Backend.mediaAvailability.missingCount + " missing"
                    color: "#ffcc66"
                    font.pixelSize: 11
                }
                MouseArea {
                    id: chipArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Backend.mediaAvailability.requestDialog()
                }
                ToolTip.visible: chipArea.containsMouse
                ToolTip.delay: 400
                ToolTip.text: "Source files not found - click for details"
            }
        }

        // Toolbar
        Row {
            Layout.fillWidth: true
            spacing: 5

            Button {
                text: "+ Folder"
                width: 80
                height: 28
                onClicked: {
                    var m = Backend.projectBinModel
                    var target = Backend.selectedProjectBinItemId
                    // A file selected: create the folder next to it, in its own folder
                    if (target !== "" && !m.data(m.indexFromItemId(target), ProjectBinModel.IsFolderRole))
                        target = m.parentFolderId(target)
                    var newId = m.addFolder("New Folder", target)
                    // Make the new folder visible: expand its real parent (pseudo
                    // groups resolve to "" and are always expanded), select it and
                    // go straight into rename mode.
                    var realParent = m.parentFolderId(newId)
                    if (realParent !== "")
                        Backend.setItemExpanded("editing", realParent, true)
                    Backend.selectedProjectBinItemId = newId
                    projectBinPanel.editingItemId = newId
                    // The pane is small: scroll the new row into view (an off-screen
                    // row would drop the rename editor's focus when it gets recycled).
                    // Deferred: the TreeView adaptor needs a moment to add the row.
                    binRevealTimer.targetId = newId
                    binRevealTimer.restart()
                }
            }

            Button {
                text: "Delete"
                width: 70
                height: 28
                enabled: Backend.selectedProjectBinItemId !== ""
                             && !Backend.projectBinModel.isPseudoItem(Backend.selectedProjectBinItemId)
                onClicked: {
                    if (Backend.selectedProjectBinItemId) {
                        Backend.projectBinModel.removeItem(Backend.selectedProjectBinItemId)
                        Backend.selectedProjectBinItemId = ""
                    }
                }
            }
        }

        // Project bin TreeView
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: palette.base

            // Empty state background text
            Text {
                anchors.centerIn: parent
                visible: Backend.projectBinModel.rowCount() === 0
                text: "Project Bin\n(add folders and media)"
                color: "#888888"
                horizontalAlignment: Text.AlignHCenter
                z: 0
            }

            TreeView {
                id: projectBinTree
                anchors.fill: parent
                model: Backend.projectBinModel
                clip: true
                z: 1
                focus: true
                interactive: false  // Disable drag scrolling - a mouse-down-drag
                                     // here needs to start dragging an ITEM onto
                                     // the timeline, not pan the list. Qt's
                                     // Flickable also swallows wheel/keyboard
                                     // scrolling once interactive is false though
                                     // (confirmed live - neither worked at all),
                                     // so both are wired back explicitly below.

                ScrollBar.vertical: ScrollBar { id: binVBar; policy: ScrollBar.AsNeeded; z: 10 }  // TableView delegates have z=1; keep the bar above them

                WheelHandler {
                    target: null
                    onWheel: function(event) {
                        var step = 40
                        var dy = event.angleDelta.y > 0 ? -step : step
                        projectBinTree.contentY = Math.max(0,
                            Math.min(projectBinTree.contentHeight - projectBinTree.height,
                                     projectBinTree.contentY + dy))
                    }
                }

                // Bin-local keys (focus based, not registry shortcuts):
                // plain Up/Down step the selection row by row (across
                // folder boundaries) and scroll it into view; Enter loads
                // the selected item like a double-click does (a folder
                // toggles open/closed). Left/Right/Home/End/Space stay
                // registry shortcuts (frame step etc.), so they never get
                // here while the registry is armed. Not while a popup or
                // dialog is open (Backend.shortcuts.disarmReason()); while
                // the rename field is focused it gets the keys, not this.
                function binKeysAllowed(event) {
                    var mods = event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)
                    return mods === 0 && Backend.shortcuts.disarmReason() === ""
                }
                function rowOfItem(itemId) {
                    if (!itemId) return -1
                    return projectBinTree.rowAtIndex(Backend.projectBinModel.indexFromItemId(itemId))
                }
                function itemIdAtRow(row) {
                    var idx = projectBinTree.modelIndex(0, row)   // (column, row) on Qt 6.4.2 - see above
                    return idx.valid ? Backend.projectBinModel.data(idx, ProjectBinModel.IdRole) : ""
                }
                function stepSelection(dir) {
                    if (projectBinTree.rows <= 0) return
                    var r = rowOfItem(Backend.selectedProjectBinItemId)
                    var nr = r < 0 ? (dir > 0 ? 0 : projectBinTree.rows - 1)
                                   : Math.max(0, Math.min(projectBinTree.rows - 1, r + dir))
                    var id = itemIdAtRow(nr)
                    if (id === "") return
                    Backend.selectedProjectBinItemId = id
                    projectBinPanel.itemPicked()
                    // Qt 6.4.2's positionViewAtRow() crashes on a view that
                    // is not laid out (seen on a hidden, zero-size TreeView).
                    if (projectBinTree.visible && projectBinTree.height > 0)
                        projectBinTree.positionViewAtRow(nr, TableView.Contain)
                }
                Keys.onUpPressed: function(event) {
                    if (!binKeysAllowed(event)) { event.accepted = false; return }
                    stepSelection(-1)
                }
                Keys.onDownPressed: function(event) {
                    if (!binKeysAllowed(event)) { event.accepted = false; return }
                    stepSelection(1)
                }
                Keys.onReturnPressed: function(event) {
                    if (!binKeysAllowed(event)) { event.accepted = false; return }
                    projectBinPanel.activateItem(Backend.selectedProjectBinItemId)
                }
                Keys.onEnterPressed: function(event) {
                    if (!binKeysAllowed(event)) { event.accepted = false; return }
                    projectBinPanel.activateItem(Backend.selectedProjectBinItemId)
                }

                // Without this, the single column sizes to the max
                // implicitWidth of its delegates (content-sized), not the
                // view width - which is also why the refresh/proxy/audio-
                // video icon group drifted with filename length even
                // after being anchored to "the right edge": that edge was
                // the content's own right edge, not the panel's. Forcing
                // the column to the view's width is what actually makes
                // contentItem's right-anchored group land at a stable
                // position.
                columnWidthProvider: function(column) { return projectBinTree.width }
                onWidthChanged: forceLayout()

                // The two synthetic group folders are always kept open:
                // they are the tree's structure, not content, and the
                // delegate's own MouseArea swallows the clicks that
                // would otherwise reach TreeView's expand indicator, so
                // the user could never open them by hand. Every DEPTH-0
                // row is such a group (the model guarantees the true
                // root has exactly these two children), which is why
                // this needs no id/role lookup.
                //
                // (Previously, syncAllExpandStates()/onExpanded/onCollapsed
                // below called modelIndex(row, 0) - Qt 6.4.2's
                // TableView::modelIndex() takes (column, row), not
                // (row, column), so that was silently invalid for every
                // row > 0: expand/collapse state only ever persisted
                // correctly for whatever happened to be the FIRST visible
                // row. Confirmed live against a real, deeply-nested
                // Kdenlive-imported project (20231029/100-indulás, 8
                // items; 20231029/200-menetkozben, 12 items) - those
                // subfolders wouldn't visually expand at all. Fixed by
                // swapping the argument order to modelIndex(0, row)
                // everywhere in this file, re-verified against the same
                // project: expand/collapse now works and persists at any
                // depth, not just row 0.)
                onRowsChanged: Qt.callLater(ensureGroupsExpanded)
                function ensureGroupsExpanded() {
                    for (var row = 0; row < projectBinTree.rows; row++) {
                        if (projectBinTree.depth(row) === 0 && !projectBinTree.isExpanded(row))
                            projectBinTree.expand(row)
                    }
                }
                // onRowsChanged alone is not enough: expanding an EMPTY
                // group is a no-op in TreeView, so the first item added
                // to a still-empty group (the usual case for "Virtual")
                // changes no view row and would stay hidden behind a
                // collapsed arrow.
                Connections {
                    target: Backend.projectBinModel
                    function onRowsInserted() { Qt.callLater(projectBinTree.ensureGroupsExpanded) }
                    function onModelReset() { Qt.callLater(projectBinTree.ensureGroupsExpanded) }
                }

                function syncAllExpandStates() {
                    // Sync all expanded items from Backend
                    var expandedIds = Backend.expandedItemIds("editing")
                    for (var row = 0; row < projectBinTree.rows; row++) {
                        var idx = projectBinTree.modelIndex(0, row)
                        if (idx.valid) {
                            var itemId = Backend.projectBinModel.data(idx, ProjectBinModel.IdRole)
                            var shouldBeExpanded = expandedIds.includes(itemId)
                            var isCurrentlyExpanded = projectBinTree.isExpanded(row)

                            if (shouldBeExpanded && !isCurrentlyExpanded) {
                                projectBinTree.expand(row)
                            } else if (!shouldBeExpanded && isCurrentlyExpanded) {
                                projectBinTree.collapse(row)
                            }
                        }
                    }
                }

                Timer {
                    id: binRevealTimer
                    property string targetId: ""
                    interval: 80
                    onTriggered: {
                        var r = projectBinTree.rowAtIndex(Backend.projectBinModel.indexFromItemId(targetId))
                        if (r >= 0) projectBinTree.positionViewAtRow(r, TableView.Contain)
                    }
                }

                // Sync expand state changes from Backend
                Connections {
                    target: Backend
                    function onItemExpandStateChanged(view, itemId, expanded) {
                        if (view !== "editing") return
                        // Find item in TreeView and expand/collapse it
                        for (var row = 0; row < projectBinTree.rows; row++) {
                            var idx = projectBinTree.modelIndex(0, row)
                            if (idx.valid) {
                                var treeItemId = Backend.projectBinModel.data(idx, ProjectBinModel.IdRole)
                                if (treeItemId === itemId) {
                                    if (expanded && !projectBinTree.isExpanded(row)) {
                                        projectBinTree.expand(row)
                                    } else if (!expanded && projectBinTree.isExpanded(row)) {
                                        projectBinTree.collapse(row)
                                    }
                                    break
                                }
                            }
                        }
                    }
                }

                // Initialize: expand all items that are in Backend.expandedItemIds("editing")
                Component.onCompleted: {
                    syncAllExpandStates()
                    ensureGroupsExpanded()
                }

                // Re-sync when workspace becomes visible
                onVisibleChanged: {
                    if (visible) {
                        Qt.callLater(syncAllExpandStates)
                    }
                }

                // Save expand state to Backend when user expands/collapses
                onExpanded: function(row, depth) {
                    var modelIndex = projectBinTree.modelIndex(0, row)
                    if (modelIndex.valid) {
                        var itemId = Backend.projectBinModel.data(modelIndex, ProjectBinModel.IdRole)
                        Backend.setItemExpanded("editing", itemId, true)
                    }
                }

                onCollapsed: function(row, depth) {
                    var modelIndex = projectBinTree.modelIndex(0, row)
                    if (modelIndex.valid) {
                        var itemId = Backend.projectBinModel.data(modelIndex, ProjectBinModel.IdRole)
                        Backend.setItemExpanded("editing", itemId, false)
                    }
                }

                delegate: TreeViewDelegate {
                    id: treeDelegate

                    // Required properties from model
                    required property string itemId
                    required property string itemName
                    required property bool itemIsFolder
                    required property string itemPath
                    required property string itemType
                    required property string thumb
                    required property string duration
                    required property bool hasAudio
                    required property bool hasVideo
                    required property string proxyStatus
                    required property var proxyResolutions
                    // Generator ("Virtual") items: a title's params blob
                    // (copied into the clip on drop) and the flag that
                    // marks the two synthetic group folders.
                    required property string titleParams
                    required property bool itemIsPseudo
                    required property bool itemMissing

                    Accessible.role: Accessible.ListItem
                    Accessible.name: "Project bin " + (itemIsFolder ? "folder " : "item ") + itemName

                    // TreeView provides depth, expanded, hasChildren, isTreeNode
                    implicitHeight: 48
                    indentation: 16

                    // Drag support for files (not folders)
                    property bool isDragging: false

                    // Create a separate drag proxy that's not clipped by TreeView
                    Item {
                        id: dragProxy
                        parent: projectBinPanel.workspaceRoot  // Parent to EditingWorkspace root
                        visible: treeDelegate.isDragging
                        x: 0
                        y: 0
                        width: 800  // Very wide to prevent DropArea exit when dragging to x=0
                        height: 40
                        z: 10000

                        Drag.active: treeDelegate.isDragging
                        Drag.dragType: Drag.Internal
                        Drag.supportedActions: Qt.CopyAction
                        Drag.keys: ["project-bin-clip"]
                        Drag.hotSpot.x: width - 100  // 800 - 100 = 700
                        Drag.hotSpot.y: height / 2
                        Drag.mimeData: {
                            "text/plain": treeDelegate.itemPath,
                            "application/x-video-clip": JSON.stringify({
                                itemId: treeDelegate.itemId,
                                itemName: treeDelegate.itemName,
                                itemPath: treeDelegate.itemPath,
                                itemType: treeDelegate.itemType,
                                // Title bin items drop as a generated
                                // title clip, with a COPY of the bin
                                // item's params as they are right now -
                                // no live link back to the bin entry.
                                clipKind: treeDelegate.itemType === "title" ? "title" : "",
                                titleParams: treeDelegate.titleParams,
                                duration: treeDelegate.duration || "00:00:05.00",
                                // Previously missing entirely - TimelineDropArea's
                                // "cd.hasAudio !== false" check then always saw
                                // undefined and defaulted to true, so every video
                                // dropped onto the timeline got a phantom silent
                                // audio clip added to A1 even when the source file
                                // genuinely has no audio stream.
                                hasAudio: treeDelegate.hasAudio,
                                hasVideo: treeDelegate.hasVideo
                            })
                        }

                        Rectangle {
                            // Keep visual size at 200, but dragProxy is 800 to prevent early exit
                            anchors.right: parent.right
                            width: 200
                            height: parent.height
                            color: "#4a9eff"
                            // Use opacity instead of visible to prevent "flashing" when exiting DropArea
                            opacity: (projectBinPanel.workspaceRoot && projectBinPanel.workspaceRoot.timelineDropActive) ? 0 : 0.7
                            radius: 4

                            Text {
                                anchors.centerIn: parent
                                text: treeDelegate.itemName
                                color: "white"
                                font.pixelSize: 12
                                elide: Text.ElideRight
                                width: parent.width - 10
                            }
                        }
                    }

                    // "Generate proxy" / "Cancel proxy generation" - the
                    // only trigger for proxy generation as of Phase 3
                    // (proxy_build_plan.md); nothing calls
                    // requestProxyGeneration() automatically yet.
                    Menu {
                        id: proxyContextMenu
                        MenuItem {
                            text: "Generate Proxy"
                            visible: treeDelegate.itemType === "video"
                            enabled: treeDelegate.proxyStatus !== "pending" && treeDelegate.proxyStatus !== "generating"
                            onTriggered: {
                                var res = Backend.getSetting("project/proxyTargetResolution", "960x540")
                                var fmt = Backend.getSetting("project/proxyFormat", "h264_intra")
                                var dev = Backend.getSetting("project/proxyComputeDevice", "")
                                Backend.cacheManager.requestProxyGeneration(treeDelegate.itemId, res, fmt, dev)
                            }
                        }
                        MenuItem {
                            text: "Cancel Proxy Generation"
                            visible: treeDelegate.itemType === "video"
                                     && (treeDelegate.proxyStatus === "pending" || treeDelegate.proxyStatus === "generating")
                            onTriggered: {
                                var res = Backend.getSetting("project/proxyTargetResolution", "960x540")
                                var fmt = Backend.getSetting("project/proxyFormat", "h264_intra")
                                Backend.cacheManager.cancelProxyGeneration(treeDelegate.itemId, res, fmt)
                            }
                        }
                    }

                    MouseArea {
                        id: dragArea
                        anchors.fill: parent
                        preventStealing: true
                        propagateComposedEvents: false
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        // No explicit z needed (and none set) for
                        // contentItem's refresh-metadata icon to win
                        // clicks over this whole-row area: Control
                        // reparents `contentItem` AFTER plain children
                        // like this MouseArea in the delegate's child
                        // list, so contentItem's whole subtree already
                        // paints - and therefore hit-tests - above
                        // dragArea at equal z. (An earlier version of
                        // this file set z: -1 here and z: 10 on the icon,
                        // both actually no-ops for that reason - z only
                        // orders SIBLINGS, and worse, z: -1 here also
                        // sorted this below `background`, which happens
                        // to be harmless only because background is a
                        // plain Rectangle with no mouse handling of its
                        // own.)

                        property bool dragActive: false
                        property point dragStartPos

                        onPressed: function(mouse) {
                            console.log("Project bin item pressed:", treeDelegate.itemName, "isFolder:", treeDelegate.itemIsFolder)
                            Backend.selectedProjectBinItemId = treeDelegate.itemId
                            projectBinPanel.itemPicked()
                            dragStartPos = Qt.point(mouse.x, mouse.y)
                            dragActive = false

                            if (!treeDelegate.itemIsFolder) {
                                // Position drag proxy at mouse cursor
                                var globalPos = mapToItem(projectBinPanel.workspaceRoot, mouse.x, mouse.y)
                                dragProxy.x = globalPos.x - (dragProxy.width - 100)
                                dragProxy.y = globalPos.y - dragProxy.height / 2
                            }

                            mouse.accepted = true
                        }

                        onPositionChanged: function(mouse) {
                            if (!treeDelegate.itemIsFolder && pressed) {
                                // Update drag proxy position
                                var globalPos = mapToItem(projectBinPanel.workspaceRoot, mouse.x, mouse.y)
                                dragProxy.x = globalPos.x - (dragProxy.width - 100)
                                dragProxy.y = globalPos.y - dragProxy.height / 2

                                if (!dragActive) {
                                    // Start drag if moved more than 5 pixels
                                    var delta = Qt.point(mouse.x - dragStartPos.x, mouse.y - dragStartPos.y)
                                    var distance = Math.sqrt(delta.x * delta.x + delta.y * delta.y)
                                    if (distance > 5) {
                                        dragActive = true
                                        treeDelegate.isDragging = true
                                        console.log("Starting drag for:", treeDelegate.itemName)
                                        console.log("Calling Drag.start()")
                                        dragProxy.Drag.start()
                                    }
                                }
                            }
                        }

                        onReleased: function(mouse) {
                            console.log("Project bin item released, isDragging:", treeDelegate.isDragging, "dragActive:", dragActive)
                            if (treeDelegate.isDragging) {
                                console.log("Calling Drag.drop()")
                                var result = dragProxy.Drag.drop()
                                console.log("Project bin drop result:", result)
                                treeDelegate.isDragging = false
                            }
                            dragActive = false
                        }

                        onClicked: function(mouse) {
                            Backend.selectedProjectBinItemId = treeDelegate.itemId
                            // Keyboard Up/Down (selection) and Enter live on the tree;
                            // a click on a row must hand it the focus (a toolbar Button
                            // keeps it otherwise).
                            projectBinTree.forceActiveFocus()

                            if (mouse.button === Qt.RightButton) {
                                // Menu items are video-only; don't pop an empty menu.
                                if (treeDelegate.itemType === "video")
                                    proxyContextMenu.popup()
                                return
                            }

                            // The whole-row MouseArea swallows clicks meant for
                            // TreeViewDelegate's own expand indicator, so toggle
                            // here when the click lands in the indicator zone.
                            if (treeDelegate.hasChildren && mouse.x < dragArea.indicatorZoneEnd()) {
                                projectBinTree.toggleExpanded(treeDelegate.row)
                                return
                            }

                            console.log("Selected item:", treeDelegate.itemName, "id:", treeDelegate.itemId)
                            // Preview the first frame (paused) on a single
                            // click - double-click (below) is what actually
                            // starts playback. Folders/titles/pseudo-groups
                            // have nothing to preview.
                            if ((treeDelegate.itemType === "video" || treeDelegate.itemType === "audio" || treeDelegate.itemType === "image")
                                    && treeDelegate.itemPath && projectBinPanel.clipVideoEngine) {
                                projectBinPanel.clipVideoEngine.loadVideo(treeDelegate.itemPath, false)
                            }
                        }

                        function indicatorZoneEnd() {
                            return 4 + treeDelegate.depth * treeDelegate.indentation + treeDelegate.indentation + 6
                        }

                        onDoubleClicked: function(mouse) {
                            if (treeDelegate.hasChildren && mouse.x < indicatorZoneEnd()) {
                                // Second click of a quick double click on the
                                // arrow: toggle again, never start a rename.
                                projectBinTree.toggleExpanded(treeDelegate.row)
                                return
                            }
                            if (treeDelegate.itemIsPseudo) {
                                // Synthetic group folder: not renameable.
                                return
                            } else if (treeDelegate.itemType === "title") {
                                // The Title inspector lives in the
                                // Effects layout; switch to it so a
                                // double-click actually reveals the
                                // editor for the item just selected.
                                Backend.selectedProjectBinItemId = treeDelegate.itemId
                                if (projectBinPanel.workspaceRoot)
                                    projectBinPanel.workspaceRoot.layoutMode = "effects"
                            } else if (treeDelegate.itemIsFolder) {
                                projectBinPanel.editingItemId = treeDelegate.itemId
                            } else {
                                projectBinPanel.loadIntoClipMonitor(treeDelegate.itemType, treeDelegate.itemPath)
                            }
                        }
                    }

                    // Expand/collapse indicator
                    indicator: Item {
                        x: 4 + (treeDelegate.depth * treeDelegate.indentation)
                        y: treeDelegate.topPadding
                        implicitWidth: 16
                        implicitHeight: treeDelegate.height - treeDelegate.topPadding - treeDelegate.bottomPadding

                        Text {
                            anchors.centerIn: parent
                            visible: treeDelegate.hasChildren
                            text: treeDelegate.expanded ? "▾" : "▸"
                            color: Backend.selectedProjectBinItemId === treeDelegate.itemId ? "white" : "#4a9eff"
                            font.pixelSize: 12
                        }
                    }

                    // Custom styling
                    background: Rectangle {
                        color: Backend.selectedProjectBinItemId === treeDelegate.itemId ? palette.highlight :
                               (treeDelegate.row % 2 == 0 ? palette.base : palette.alternateBase)
                    }

                    contentItem: Item {
                        id: contentRoot
                        x: 4 + (treeDelegate.depth * treeDelegate.indentation) + treeDelegate.indentation + 6
                        width: treeDelegate.width - x
                        height: treeDelegate.height
                        // A plain Item (unlike the Row this replaced) has
                        // no implicit size of its own - TreeViewDelegate's
                        // own implicitWidth/implicitHeight (which set this
                        // delegate's actual row height and, via the
                        // column's content-based sizing, the column
                        // width) are derived FROM these, so leaving them
                        // at the Item default of 0 collapsed the whole
                        // column to a sliver and mis-centered content
                        // vertically. (columnWidthProvider above now
                        // forces the column to the view's width anyway,
                        // but implicitHeight still matters for row height,
                        // and implicitWidth is cheap insurance.)
                        implicitWidth: leftGroup.implicitWidth + rightGroup.implicitWidth + 12
                        implicitHeight: Math.max(leftGroup.implicitHeight, rightGroup.implicitHeight)

                        // Left group: icon/thumbnail/name/duration - grows
                        // with content, anchored to the left edge.
                        Row {
                            id: leftGroup
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 6

                        // File/Folder Icon
                        Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 22
                                horizontalAlignment: Text.AlignHCenter
                                text: treeDelegate.itemIsFolder ? "🗀"
                                      : treeDelegate.itemType === "video" ? "🎞"
                                      : treeDelegate.itemType === "audio" ? "♪"
                                      : treeDelegate.itemType === "image" ? "▣"
                                      : treeDelegate.itemType === "title" ? "T" : "▫"
                                color: treeDelegate.itemIsFolder ? "#e0c46c"
                                       : treeDelegate.itemType === "video" ? "#6cc06c"
                                       : treeDelegate.itemType === "audio" ? "#6cb0e0"
                                       : treeDelegate.itemType === "image" ? "#c08ce0"
                                       : treeDelegate.itemType === "title" ? "#e0a050" : "#777777"
                                font.bold: treeDelegate.itemType === "title"
                                font.pixelSize: 18
                                HoverHandler { id: typeIconHover }
                                ToolTip.visible: typeIconHover.hovered
                                ToolTip.delay: 500
                                ToolTip.text: treeDelegate.itemIsFolder ? "Folder"
                                              : treeDelegate.itemType === "video" ? "Video"
                                              : treeDelegate.itemType === "audio" ? "Audio"
                                              : treeDelegate.itemType === "image" ? "Image"
                                              : treeDelegate.itemType === "title" ? "Title" : "File"
                            }

                        // Thumbnail (if available)
                        Rectangle {
                            id: thumbRect
                            visible: treeDelegate.thumb !== "" && !treeDelegate.itemIsFolder
                            anchors.verticalCenter: parent.verticalCenter
                            width: 80
                            height: 45
                            opacity: treeDelegate.itemMissing ? 0.4 : 1.0
                            color: "#1a1a1a"
                            border.color: "#555"
                            border.width: 1

                            Text {
                                anchors.centerIn: parent
                                text: "▶"
                                font.pixelSize: 24
                                color: "#666"
                            }
                        }

                        // Text Block (name, duration)
                        Column {
                            id: nameColumn
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            // Space left of rightGroup (icon, thumbnail, spacings, margin)
                            width: Math.max(40, contentRoot.width - rightGroup.implicitWidth - 12
                                            - 22 - leftGroup.spacing
                                            - (thumbRect.visible ? 80 + leftGroup.spacing : 0))

                            // Editable name field or text
                            TextField {
                                id: nameEditor
                                visible: projectBinPanel.editingItemId === treeDelegate.itemId
                                width: 200
                                text: treeDelegate.itemName
                                selectByMouse: true
                                font.pixelSize: 12
                                font.bold: true
                                color: "white"
                                background: Rectangle {
                                    color: "#555555"
                                    border.color: "#4a9eff"
                                    border.width: 2
                                }

                                onVisibleChanged: {
                                    // The editor is created hidden and only shown on rename, so
                                    // onCompleted below never sees visible==true: grab focus here.
                                    if (visible) Qt.callLater(function() { forceActiveFocus(); selectAll() })
                                }

                                Component.onCompleted: {
                                    if (visible) {
                                        Qt.callLater(function() {
                                            forceActiveFocus()
                                            selectAll()
                                        })
                                    }
                                }

                                Keys.onReturnPressed: {
                                    Backend.projectBinModel.renameItem(treeDelegate.itemId, text)
                                    projectBinPanel.editingItemId = ""
                                    Backend.shortcuts.releaseTextFocus()
                                }
                                Keys.onEnterPressed: {
                                    Backend.projectBinModel.renameItem(treeDelegate.itemId, text)
                                    projectBinPanel.editingItemId = ""
                                    Backend.shortcuts.releaseTextFocus()
                                }

                                Keys.onEscapePressed: {
                                    projectBinPanel.editingItemId = ""
                                    Backend.shortcuts.releaseTextFocus()
                                }

                                onActiveFocusChanged: {
                                    if (!activeFocus && projectBinPanel.editingItemId === treeDelegate.itemId) {
                                        Backend.projectBinModel.renameItem(treeDelegate.itemId, text)
                                        projectBinPanel.editingItemId = ""
                                    }
                                }
                            }

                            Text {
                                visible: projectBinPanel.editingItemId !== treeDelegate.itemId
                                text: treeDelegate.itemName
                                color: treeDelegate.itemMissing ? "#ffcc66"
                                       : Backend.selectedProjectBinItemId === treeDelegate.itemId ? "white" : "#dddddd"
                                font.pixelSize: 12
                                font.bold: true
                                font.italic: treeDelegate.itemMissing
                                opacity: treeDelegate.itemMissing ? 0.85 : 1.0
                                width: nameColumn.width
                                elide: Text.ElideMiddle
                            }

                            Text {
                                visible: treeDelegate.duration !== "" && !treeDelegate.itemIsFolder
                                text: treeDelegate.duration
                                color: "#aaaaaa"
                                font.pixelSize: 10
                            }
                        }

                        } // leftGroup

                        // Right group: proxy/refresh/audio-video icons -
                        // anchored to the right edge so they form a
                        // stable click target regardless of filename
                        // length. Previously this was a trailing "Item {
                        // Layout.fillWidth: true }" spacer inside a plain
                        // Row - Layout.* attached properties are only
                        // honored inside RowLayout/ColumnLayout/GridLayout,
                        // so that spacer was inert and these icons just
                        // drifted left/right with the name column's width
                        // instead of staying put.
                        Row {
                            id: rightGroup
                            anchors.right: parent.right
                            // keep clear of the overlay scrollbar while it is shown
                            anchors.rightMargin: binVBar.size < 1.0 ? binVBar.width : 0
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 6

                            // Source file not found
                            Text {
                                visible: treeDelegate.itemMissing
                                anchors.verticalCenter: parent.verticalCenter
                                text: "\u26a0"
                                font.pixelSize: 14
                                color: "#ffcc66"
                                HoverHandler { id: missingIconHover }
                                ToolTip.visible: missingIconHover.hovered
                                ToolTip.delay: 300
                                ToolTip.text: "Source file not found: " + treeDelegate.itemPath
                            }

                            // Proxy icon
                            Text {
                                visible: treeDelegate.proxyStatus === "ready" && !treeDelegate.itemIsFolder
                                anchors.verticalCenter: parent.verticalCenter
                                text: "⚡"
                                font.pixelSize: 14
                                color: "#4a9eff"
                                HoverHandler { id: proxyIconHover }
                                ToolTip.visible: proxyIconHover.hovered
                                ToolTip.delay: 500
                                ToolTip.text: "Proxy ready" + (treeDelegate.proxyResolutions && treeDelegate.proxyResolutions.length > 0
                                              ? " (" + treeDelegate.proxyResolutions.join(", ") + ")" : "")
                            }

                            // Audio/Video indicators
                            Row {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 6

                                Text {
                                    visible: treeDelegate.hasAudio
                                    text: "♪"
                                    font.pixelSize: 14
                                    color: "#6cb0e0"
                                    HoverHandler { id: audioIconHover }
                                    ToolTip.visible: audioIconHover.hovered
                                    ToolTip.delay: 500
                                    ToolTip.text: "Has audio"
                                }

                                Text {
                                    visible: treeDelegate.hasVideo
                                    text: "🎞"
                                    font.pixelSize: 14
                                    color: "#6cc06c"
                                    HoverHandler { id: videoIconHover }
                                    ToolTip.visible: videoIconHover.hovered
                                    ToolTip.delay: 500
                                    ToolTip.text: "Has video"
                                }
                            }
                        } // rightGroup
                    }
                }
            }
        }
    }
}
