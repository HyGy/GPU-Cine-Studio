import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt.labs.folderlistmodel
// Qualified: Qt.labs.platform also exports Menu/MenuItem, and being
// imported after QtQuick.Controls it would shadow the Controls ones
// (native platform menus, which need a Window parent) for the media
// browser's row context menu.
import Qt.labs.platform as Platform
import VideoEditor 1.0
// qml6glsink (see src/core/Qml6GLSink.h) - renders straight into the QML
// scene graph instead of a native child X11 window. Only takes effect when
// videoEngine.glVideoSink is true (GCS_VIDEO_SINK=qml6glsink).
import org.freedesktop.gstreamer.Qt6GLVideoItem 1.0
import "components"

Item {
    id: loggingWorkspace

    // A hidden workspace must not keep its Clip Monitor audio running
    // (the Editing workspace has its own, separate engine).
    onVisibleChanged: if (!visible) videoEngine.pause()

    // Video player engine
    VideoEngine {
        id: videoEngine
        onError: function(message) {
            console.error("Video error:", message)
        }
        Component.onCompleted: {
            setDecoderPreference(Backend.preferredDecoder)
        }
    }

    // Connect decoder preference changes
    Connections {
        target: Backend
        function onPreferredDecoderChanged() {
            videoEngine.setDecoderPreference(Backend.preferredDecoder)
        }
    }

    // Helper function for file size formatting
    function formatFileSize(bytes) {
        if (bytes < 1024) return bytes + " B"
        if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB"
        if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + " MB"
        return (bytes / (1024 * 1024 * 1024)).toFixed(1) + " GB"
    }

    // Helper function for time formatting
    function formatTime(ms) {
        var seconds = Math.floor(ms / 1000)
        var minutes = Math.floor(seconds / 60)
        seconds = seconds % 60
        return minutes + ":" + (seconds < 10 ? "0" : "") + seconds
    }

    // Helper function to check if file is video
    function isVideoFile(filename) {
        var ext = filename.toLowerCase().split('.').pop()
        var videoExtensions = ['mp4', 'avi', 'mkv', 'mov', 'wmv', 'flv', 'webm', 'm4v', 'mpg', 'mpeg']
        return videoExtensions.indexOf(ext) !== -1
    }

    // playbin (behind videoEngine.loadVideo()) decodes audio-only and
    // single-image sources fine too, not just video - this is used to
    // stop gating the Clip Monitor preview to video files only.
    function isPlayableFile(filename) {
        return isVideoFile(filename) || isAudioFile(filename) || isImageFile(filename)
    }

    function isAudioFile(filename) {
        var ext = filename.toLowerCase().split('.').pop()
        return ['mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a', 'wma', 'opus', 'aiff', 'aif', 'ac3'].indexOf(ext) !== -1
    }

    function isImageFile(filename) {
        var ext = filename.toLowerCase().split('.').pop()
        return ['png', 'jpg', 'jpeg', 'bmp', 'gif', 'tif', 'tiff', 'webp'].indexOf(ext) !== -1
    }

    // Project Bin editing state
    property string editingItemId: ""

    // Generate complete project JSON
    function getProjectJSON() {
        var projectData = {
            sourceFiles: JSON.parse(Backend.projectBinModel.toJson())
        }

        return JSON.stringify(projectData, null, 2)
    }

    // Three vertical columns with resizable splitters
    SplitView {
        anchors.fill: parent
        orientation: Qt.Horizontal
        
        // LEFT COLUMN - Media Browser + Project Bin
        SplitView {
            SplitView.minimumWidth: 200
            SplitView.preferredWidth: Math.max(300, loggingWorkspace.width * 0.4)
            orientation: Qt.Vertical
            
            // Media Browser (top)
            Rectangle {
                id: mediaBrowser
                SplitView.minimumHeight: 150
                SplitView.preferredHeight: parent.height / 2
                color: "#2d2d2d"
                border.color: "#1d1d1d"
                border.width: 1

                // Column widths as fractions of the row width, shared by
                // the header and every row so the two can never drift
                // apart. Dragging a header divider edits these.
                property real nameFraction: 0.5
                property real sizeFraction: 0.25
                readonly property real dateFraction: Math.max(0.1, 1.0 - nameFraction - sizeFraction)

                // Sorting is applied to the FolderListModel itself (and
                // mirrored onto the temporary models used to expand a
                // sub-folder), not to the flattened tree ListModel -
                // the flattened model has to keep children directly
                // under their parent, so it can't be re-sorted as a
                // whole.
                property int sortColumn: 0          // 0=Name 1=Size 2=Date
                property bool sortDescending: false
                readonly property int sortFieldForModel: sortColumn === 1 ? FolderListModel.Size
                                                       : sortColumn === 2 ? FolderListModel.Time
                                                       : FolderListModel.Name
                // QDir sorts Size and Time LARGEST/NEWEST first by
                // default, Name smallest first - flip the two so the
                // "▴ / ▾" indicator means the same thing (small/old
                // first = ▴) in every column.
                readonly property bool sortReversedForModel: sortColumn === 0 ? sortDescending
                                                                              : !sortDescending
                // Shared by the "↑" button and the Backspace shortcut.
                function goToParentFolder() {
                    var cleanPath = folderModel.folder.toString().replace("file://", "")
                    if (cleanPath.endsWith("/") && cleanPath.length > 1) {
                        cleanPath = cleanPath.substring(0, cleanPath.length - 1)
                    }
                    var lastSlash = cleanPath.lastIndexOf("/")
                    if (lastSlash < 0) return
                    var parentPath = cleanPath.substring(0, lastSlash)
                    if (parentPath === "") parentPath = "/"
                    folderModel.folder = "file://" + parentPath
                }

                function toggleSort(column) {
                    if (sortColumn === column) {
                        sortDescending = !sortDescending
                    } else {
                        sortColumn = column
                        sortDescending = false
                    }
                    fileTreeView.rebuildTree()
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
                            text: "Media Browser"
                            color: "white"
                            font.pixelSize: 13
                            font.bold: true
                        }
                    }
                    
                    // File browser content area
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        color: palette.base

                        ColumnLayout {
                            anchors.fill: parent
                            spacing: 0

                            // Current path bar
                            Rectangle {
                                Layout.fillWidth: true
                                // Height follows the controls instead of a
                                // hardcoded 30: the buttons' and the text
                                // field's implicit heights come from the
                                // active Qt Quick Controls style, so a fixed
                                // number here silently clips them whenever
                                // that style's metrics differ (a Basic-style
                                // Button is 40px tall, a Fusion one 24px).
                                Layout.preferredHeight: pathBarRow.implicitHeight + 10
                                color: palette.alternateBase

                                RowLayout {
                                    id: pathBarRow
                                    anchors.fill: parent
                                    anchors.margins: 5
                                    spacing: 5

                                    Button {
                                        id: upButton
                                        text: "↑"
                                        Layout.preferredWidth: 30
                                        ToolTip.visible: hovered
                                        ToolTip.delay: 600
                                        ToolTip.text: "Go to parent folder (Backspace)"
                                        onClicked: mediaBrowser.goToParentFolder()
                                    }

                                    // Explicit entry point for the
                                    // multi-select add - double-click
                                    // alone was never discoverable, and
                                    // doesn't exist at all as a gesture
                                    // for "the N things I ctrl-clicked".
                                    Button {
                                        id: addToBinButton
                                        text: fileTreeView.selectedUrls.length > 1
                                              ? "+ Bin (" + fileTreeView.selectedUrls.length + ")"
                                              : "+ Bin"
                                        Layout.preferredWidth: fileTreeView.selectedUrls.length > 1 ? 86 : 56
                                        enabled: fileTreeView.selectedUrls.length > 0
                                        ToolTip.visible: hovered
                                        ToolTip.delay: 600
                                        ToolTip.text: fileTreeView.selectedUrls.length === 0
                                            ? "Select one or more files/folders (Ctrl-click, Shift-click, Ctrl+A)"
                                            : "Add " + fileTreeView.selectedUrls.length
                                              + " selected item(s) to the Project Bin (folders keep their subfolder structure)"
                                        onClicked: fileTreeView.addSelectionToBin()
                                    }

                                    TextField {
                                        id: pathField
                                        Layout.fillWidth: true
                                        color: "#cccccc"
                                        font.pixelSize: 11
                                        selectByMouse: true
                                        Accessible.role: Accessible.EditableText
                                        Accessible.name: "Media browser path"
                                        // A completely invisible
                                        // background made this look like
                                        // a static label, so nobody
                                        // realised a path could be typed
                                        // or pasted into it. Give it the
                                        // usual field affordance (and a
                                        // hint) without making it loud.
                                        placeholderText: "Type or paste a folder path, then Enter"
                                        ToolTip.visible: hovered && !activeFocus
                                        ToolTip.delay: 600
                                        ToolTip.text: "Type or paste a folder path and press Enter to jump there"
                                        background: Rectangle {
                                            color: pathField.activeFocus ? palette.base : "transparent"
                                            border.color: pathField.activeFocus ? "#4a9eff"
                                                        : (pathField.hovered ? "#5d6066" : "transparent")
                                            border.width: 1
                                            radius: 2
                                        }

                                        // Only reflect the model's folder while this field
                                        // doesn't have focus, so typing/pasting isn't
                                        // overwritten mid-edit by the live binding.
                                        property string modelPath: folderModel.folder.toString().replace("file://", "")
                                        text: modelPath
                                        onModelPathChanged: if (!activeFocus) text = modelPath

                                        // Clicking in to type a new path
                                        // used to drop a caret in the
                                        // middle of the existing one, so
                                        // typing/pasting produced
                                        // nonsense like
                                        // /home/me/home/me/Videos.
                                        onActiveFocusChanged: if (activeFocus) selectAll()

                                        Keys.onReturnPressed: navigateToTypedPath()
                                        Keys.onEnterPressed: navigateToTypedPath()
                                        // Abandon an edit and snap back
                                        // to the folder actually shown.
                                        Keys.onEscapePressed: {
                                            text = modelPath
                                            fileTreeView.forceActiveFocus()
                                        }

                                        function navigateToTypedPath() {
                                            var p = text.trim()
                                            if (p === "") return
                                            console.log("Navigating to typed/pasted path:", p)
                                            folderModel.folder = "file://" + p
                                        }
                                    }
                                }
                            }

                            // Column headers - clickable to sort, with
                            // draggable dividers to re-proportion the
                            // columns (they used to be fixed at
                            // 50/25/25 with no way to widen Name, which
                            // is the one column that actually needs it).
                            Rectangle {
                                id: columnHeader
                                Layout.fillWidth: true
                                Layout.preferredHeight: 25
                                color: "#333333"

                                component HeaderCell: Rectangle {
                                    property string label
                                    property int column
                                    height: parent.height
                                    color: headerMouse.containsMouse ? "#3d3d3d" : "transparent"

                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 8
                                        anchors.right: parent.right
                                        anchors.rightMargin: 8
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: parent.label + (mediaBrowser.sortColumn === parent.column
                                                              ? (mediaBrowser.sortDescending ? "  ▾" : "  ▴")
                                                              : "")
                                        color: mediaBrowser.sortColumn === parent.column ? "#dddddd" : "#aaaaaa"
                                        font.pixelSize: 11
                                        font.bold: true
                                        elide: Text.ElideRight
                                    }

                                    MouseArea {
                                        id: headerMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: mediaBrowser.toggleSort(parent.column)
                                        ToolTip.visible: containsMouse
                                        ToolTip.delay: 700
                                        ToolTip.text: "Sort by " + parent.label
                                    }
                                }

                                // A divider is positioned on a boundary
                                // and drags it; the fractions are
                                // clamped so no column can be squeezed
                                // out of existence.
                                component HeaderDivider: Rectangle {
                                    property int boundary   // 0 = name|size, 1 = size|date
                                    width: 1
                                    height: parent.height
                                    color: "#4a4a4a"

                                    MouseArea {
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: 9
                                        height: parent.height
                                        cursorShape: Qt.SizeHorCursor
                                        property real pressX: 0
                                        onPressed: function(mouse) { pressX = mouse.x }
                                        onPositionChanged: function(mouse) {
                                            if (!pressed || columnHeader.width <= 0) return
                                            var d = (mouse.x - pressX) / columnHeader.width
                                            if (parent.boundary === 0) {
                                                var n = mediaBrowser.nameFraction + d
                                                mediaBrowser.nameFraction =
                                                    Math.max(0.2, Math.min(0.75, n))
                                            } else {
                                                var s = mediaBrowser.sizeFraction + d
                                                mediaBrowser.sizeFraction =
                                                    Math.max(0.1, Math.min(0.9 - mediaBrowser.nameFraction, s))
                                            }
                                        }
                                    }
                                }

                                Row {
                                    anchors.fill: parent

                                    HeaderCell {
                                        label: "Name"; column: 0
                                        width: columnHeader.width * mediaBrowser.nameFraction - 1
                                    }
                                    HeaderDivider { boundary: 0 }
                                    HeaderCell {
                                        label: "Size"; column: 1
                                        width: columnHeader.width * mediaBrowser.sizeFraction - 1
                                    }
                                    HeaderDivider { boundary: 1 }
                                    HeaderCell {
                                        label: "Date"; column: 2
                                        width: columnHeader.width * mediaBrowser.dateFraction
                                    }
                                }
                            }

                            // File tree
                            ScrollView {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true

                                // Root folder model
                                FolderListModel {
                                    id: folderModel
                                    folder: Platform.StandardPaths.writableLocation(Platform.StandardPaths.HomeLocation)
                                    showDirs: true
                                    showFiles: true
                                    showDotAndDotDot: false
                                    showHidden: false
                                    showOnlyReadable: true
                                    nameFilters: ["*"]
                                    sortField: mediaBrowser.sortFieldForModel
                                    sortReversed: mediaBrowser.sortReversedForModel

                                    onFolderChanged: {
                                        console.log("Root folder changed to:", folder)
                                        fileTreeView.rebuildTree()
                                    }

                                    onStatusChanged: {
                                        if (status === FolderListModel.Ready) {
                                            fileTreeView.rebuildTree()
                                        }
                                    }
                                }

                                ListView {
                                    id: fileTreeView
                                    anchors.fill: parent
                                    model: ListModel {
                                        id: treeModel
                                    }

                                    // Keyboard navigation: the list had
                                    // none at all, so the only way to
                                    // move around was the mouse.
                                    focus: true
                                    keyNavigationEnabled: true
                                    currentIndex: -1
                                    highlightMoveDuration: 0

                                    // ---- Multi-selection ----
                                    // Keyed by itemUrl, NEVER by row
                                    // index: expandFolder()/
                                    // collapseFolder() insert and remove
                                    // rows in the middle of treeModel, so
                                    // any index-based selection silently
                                    // re-points at whatever slid into
                                    // that slot. The anchor is still an
                                    // index (it's only meaningful for a
                                    // shift-range over the CURRENT row
                                    // layout, and is re-validated on use).
                                    property var selectedUrls: []
                                    property int selectionAnchorIndex: -1

                                    function isUrlSelected(u) { return selectedUrls.indexOf(u) >= 0 }

                                    function clearSelection() {
                                        selectedUrls = []
                                        selectionAnchorIndex = -1
                                    }

                                    function selectOnlyRow(i) {
                                        if (i < 0 || i >= treeModel.count) return
                                        // Always REASSIGN the array - an
                                        // in-place push/splice does not
                                        // re-evaluate QML bindings.
                                        selectedUrls = [treeModel.get(i).itemUrl]
                                        selectionAnchorIndex = i
                                    }

                                    function toggleRowSelection(i) {
                                        if (i < 0 || i >= treeModel.count) return
                                        var u = treeModel.get(i).itemUrl
                                        var a = selectedUrls.slice()
                                        var at = a.indexOf(u)
                                        if (at >= 0) a.splice(at, 1)
                                        else a.push(u)
                                        selectedUrls = a
                                        selectionAnchorIndex = i
                                    }

                                    function selectRangeToRow(i, additive) {
                                        if (i < 0 || i >= treeModel.count) return
                                        var from = (selectionAnchorIndex >= 0 && selectionAnchorIndex < treeModel.count)
                                                   ? selectionAnchorIndex : i
                                        var lo = Math.min(from, i)
                                        var hi = Math.max(from, i)
                                        var a = additive ? selectedUrls.slice() : []
                                        for (var k = lo; k <= hi; k++) {
                                            var u = treeModel.get(k).itemUrl
                                            if (a.indexOf(u) < 0) a.push(u)
                                        }
                                        selectedUrls = a
                                        // Anchor deliberately stays put so
                                        // a follow-up shift-click grows or
                                        // shrinks the same range.
                                    }

                                    function selectAllRows() {
                                        var a = []
                                        for (var k = 0; k < treeModel.count; k++) a.push(treeModel.get(k).itemUrl)
                                        selectedUrls = a
                                        if (selectionAnchorIndex < 0 && treeModel.count > 0) selectionAnchorIndex = 0
                                    }

                                    // Adds every selected row to the
                                    // Project Bin, in treeModel order so
                                    // the bin ends up matching what the
                                    // user sees. Folders go through the
                                    // C++ recursive importer (which
                                    // recreates their subfolder
                                    // structure); plain files through
                                    // addFile().
                                    function addSelectionToBin() {
                                        // Never import real files into the
                                        // "Virtual" pseudo folder. C++
                                        // resolveFileParent() would reroute
                                        // them to "Filesystem" anyway, but
                                        // doing it here keeps the bin
                                        // selection the user sees honest.
                                        // Both pseudo folders map to ""
                                        // here, which C++ resolves to
                                        // "Filesystem" - the right answer
                                        // for both ("Filesystem" IS that
                                        // node, and "Virtual" must never
                                        // hold file-backed items).
                                        addSelectionToBinUnder(Backend.loggingSelectedBinItemId)
                                    }

                                    // Same import, but with an explicitly
                                    // chosen bin folder as the target -
                                    // this is what the drag-and-drop path
                                    // (drop onto a Project Bin folder row)
                                    // calls. Everything else about the
                                    // import (order, folder recursion,
                                    // double-add guard) is shared, so the
                                    // button/menu and the drop gesture can
                                    // never drift apart.
                                    function addSelectionToBinUnder(targetParentId) {
                                        if (selectedUrls.length === 0) return

                                        var parentId = targetParentId || ""
                                        if (parentId !== "" && Backend.projectBinModel.isPseudoItem(parentId))
                                            parentId = ""

                                        var lastFolderId = ""
                                        // Prefix list of folders already
                                        // being imported whole, so a
                                        // child row that happens to also
                                        // be selected isn't added twice.
                                        var importedDirs = []
                                        for (var i = 0; i < treeModel.count; i++) {
                                            var r = treeModel.get(i)
                                            if (!isUrlSelected(r.itemUrl)) continue

                                            var covered = false
                                            for (var d = 0; d < importedDirs.length; d++) {
                                                if (r.itemUrl.indexOf(importedDirs[d]) === 0) { covered = true; break }
                                            }
                                            if (covered) continue

                                            if (r.itemIsDir) {
                                                var newId = Backend.projectBinModel.importFolderTree(r.itemUrl, parentId, true)
                                                if (newId) lastFolderId = newId
                                                importedDirs.push(r.itemUrl + "/")
                                            } else {
                                                Backend.projectBinModel.addFile(r.itemUrl, parentId)
                                            }
                                        }

                                        // Show the user where a folder
                                        // import landed.
                                        if (lastFolderId !== "") Backend.loggingSelectedBinItemId = lastFolderId
                                    }

                                    // Drag-and-drop source support. The
                                    // dragged set is simply "the current
                                    // selection", so the drop side can
                                    // reuse addSelectionToBinUnder()
                                    // verbatim - which means the press
                                    // that starts a drag has to make the
                                    // selection match what the user
                                    // thinks they grabbed: keep an
                                    // existing multi-selection if the
                                    // pressed row is inside it, otherwise
                                    // collapse to that one row (the same
                                    // rule the double-click bulk-add
                                    // already uses).
                                    function prepareDragFromRow(i) {
                                        if (i < 0 || i >= treeModel.count) return
                                        var u = treeModel.get(i).itemUrl
                                        if (!(selectedUrls.length > 1 && isUrlSelected(u)))
                                            selectOnlyRow(i)
                                        currentIndex = i
                                    }

                                    // Activate = what a double-click
                                    // does: descend into a folder, or
                                    // add a file to the Project Bin.
                                    function activateRow(i) {
                                        if (i < 0 || i >= treeModel.count) return
                                        var row = treeModel.get(i)
                                        if (row.itemIsDir) {
                                            folderModel.folder = row.itemUrl
                                        } else {
                                            Backend.projectBinModel.addFile(row.itemUrl, Backend.loggingSelectedBinItemId)
                                        }
                                    }

                                    // Preview = what a single click
                                    // does on a file.
                                    function previewRow(i) {
                                        if (i < 0 || i >= treeModel.count) return
                                        var row = treeModel.get(i)
                                        if (!row.itemIsDir && loggingWorkspace.isPlayableFile(row.itemName)) {
                                            videoEngine.loadVideo(row.itemUrl, !loggingWorkspace.isImageFile(row.itemName))
                                        }
                                    }

                                    // With a multi-selection active,
                                    // Enter means "add all of it";
                                    // otherwise it keeps its original
                                    // single-row meaning exactly.
                                    function activateOrAddSelection() {
                                        if (selectedUrls.length > 1) addSelectionToBin()
                                        else activateRow(currentIndex)
                                    }

                                    Keys.onReturnPressed: activateOrAddSelection()
                                    Keys.onEnterPressed: activateOrAddSelection()
                                    Keys.onSpacePressed: previewRow(currentIndex)
                                    Keys.onPressed: function(event) {
                                        if (event.key === Qt.Key_Backspace) {
                                            mediaBrowser.goToParentFolder()
                                            event.accepted = true
                                        } else if (event.key === Qt.Key_A && (event.modifiers & Qt.ControlModifier)) {
                                            selectAllRows()
                                            event.accepted = true
                                        } else if (event.key === Qt.Key_Escape) {
                                            clearSelection()
                                            event.accepted = true
                                        }
                                    }

                                    Component.onCompleted: {
                                        rebuildTree()
                                    }

                                    function rebuildTree() {
                                        // Navigating / re-sorting throws
                                        // the whole row set away; carrying
                                        // a stale selection across that
                                        // would silently add files the
                                        // user can no longer see.
                                        clearSelection()
                                        treeModel.clear()
                                        for (var i = 0; i < folderModel.count; i++) {
                                            var isDir = folderModel.isFolder(i)
                                            treeModel.append({
                                                "itemName": folderModel.get(i, "fileName"),
                                                "itemSize": folderModel.get(i, "fileSize"),
                                                "itemModified": folderModel.get(i, "fileModified"),
                                                "itemIsDir": isDir,
                                                "itemUrl": folderModel.get(i, "fileURL"),
                                                "itemLevel": 0,
                                                "itemExpanded": false,
                                                "itemParentUrl": folderModel.folder
                                            })
                                        }
                                    }

                                    delegate: Rectangle {
                                        id: browserRow
                                        width: fileTreeView.width
                                        height: 30

                                        readonly property bool isCurrent: fileTreeView.currentIndex === index
                                        // Files playbin can't preview
                                        // (documents, archives, ...) are
                                        // dimmed so the media in a
                                        // mixed folder stands out.
                                        readonly property bool isMedia: itemIsDir || loggingWorkspace.isPlayableFile(itemName)
                                        // Keyed by url, so this stays
                                        // correct when expanding a folder
                                        // shifts every row below it.
                                        readonly property bool isSelected: fileTreeView.selectedUrls.indexOf(itemUrl) >= 0

                                        color: (isSelected && isCurrent) ? "#3f86d0"
                                             : isSelected ? "#2f5f93"
                                             : isCurrent ? "#2a5a8a"
                                             : mouseArea.containsMouse ? palette.button
                                             : (index % 2 ? palette.base : palette.alternateBase)

                                        Accessible.role: Accessible.ListItem
                                        Accessible.name: "Media browser " + (itemIsDir ? "folder " : "file ") + itemName

                                        // Single/double click do quite
                                        // different things here and
                                        // neither was discoverable.
                                        ToolTip.visible: mouseArea.containsMouse
                                        ToolTip.delay: 900
                                        ToolTip.text: itemIsDir
                                            ? itemName + "\nClick to expand · Double-click to open"
                                            : itemName + (browserRow.isMedia ? "\nClick to preview · Double-click to add to Project Bin"
                                                                             : "\nNot a previewable media file")

                                        // Drag proxy for dragging this
                                        // row (or the whole selection it
                                        // belongs to) down onto a Project
                                        // Bin folder. Reparented to the
                                        // workspace root so the media
                                        // browser's own clip:true doesn't
                                        // cut the ghost off at the panel
                                        // edge - same construction as
                                        // EffectBrowserPanel.qml /
                                        // ProjectBinPanel.qml, the
                                        // established drag-source pattern
                                        // in this codebase.
                                        Item {
                                            id: browserDragProxy
                                            parent: loggingWorkspace
                                            visible: mouseArea.dragActive
                                            width: 200; height: 28
                                            z: 10000

                                            Drag.active: mouseArea.dragActive
                                            Drag.dragType: Drag.Internal
                                            Drag.supportedActions: Qt.CopyAction
                                            Drag.keys: ["media-browser-selection"]
                                            Drag.hotSpot.x: 12
                                            Drag.hotSpot.y: height / 2
                                            // Payload is informational
                                            // only: the drop handler acts
                                            // on fileTreeView's live
                                            // selection (same QML engine),
                                            // which prepareDragFromRow()
                                            // has already made match the
                                            // dragged rows.
                                            Drag.mimeData: ({
                                                "text/plain": itemUrl,
                                                "application/x-media-browser-selection":
                                                    JSON.stringify(fileTreeView.selectedUrls)
                                            })

                                            Rectangle {
                                                anchors.fill: parent
                                                color: "#3f86d0"
                                                opacity: 0.85
                                                radius: 4
                                                Text {
                                                    anchors.fill: parent
                                                    anchors.margins: 6
                                                    verticalAlignment: Text.AlignVCenter
                                                    text: fileTreeView.selectedUrls.length > 1
                                                          ? ("▤ " + fileTreeView.selectedUrls.length + " items → Bin")
                                                          : ((itemIsDir ? "🗀 " : "▫ ") + itemName)
                                                    color: "white"
                                                    font.pixelSize: 11
                                                    elide: Text.ElideMiddle
                                                }
                                            }
                                        }

                                        Row {
                                            anchors.fill: parent

                                            // Name column
                                            Item {
                                                width: parent.width * mediaBrowser.nameFraction
                                                height: parent.height
                                                clip: true

                                                Row {
                                                    anchors.left: parent.left
                                                    anchors.leftMargin: 10 + (itemLevel * 20)
                                                    anchors.right: parent.right
                                                    anchors.rightMargin: 6
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    spacing: 5

                                                    // Expand/collapse arrow for directories
                                                    Text {
                                                        text: itemIsDir ? (itemExpanded ? "▾" : "▸") : " "
                                                        color: "#4a9eff"
                                                        font.pixelSize: 14
                                                        font.bold: true
                                                        width: 10
                                                    }

                                                    // Type glyph - every
                                                    // non-folder used to
                                                    // be the same "•",
                                                    // so a video was
                                                    // indistinguishable
                                                    // from a PDF at a
                                                    // glance.
                                                    Text {
                                                        text: itemIsDir ? "🗀"
                                                            : loggingWorkspace.isVideoFile(itemName) ? "🎞"
                                                            : loggingWorkspace.isAudioFile(itemName) ? "♪"
                                                            : loggingWorkspace.isImageFile(itemName) ? "▣"
                                                            : "▫"
                                                        color: itemIsDir ? "#e0c46c"
                                                             : loggingWorkspace.isVideoFile(itemName) ? "#6cc06c"
                                                             : loggingWorkspace.isAudioFile(itemName) ? "#6cb0e0"
                                                             : loggingWorkspace.isImageFile(itemName) ? "#c08ce0"
                                                             : "#777777"
                                                        font.pixelSize: 13
                                                        width: 16
                                                        horizontalAlignment: Text.AlignHCenter
                                                    }

                                                    Text {
                                                        // Long names used
                                                        // to run straight
                                                        // under the Size
                                                        // column.
                                                        width: Math.max(0, parent.width - 31)
                                                        text: itemName
                                                        color: browserRow.isMedia ? "#dddddd" : "#909090"
                                                        font.pixelSize: 13
                                                        elide: Text.ElideMiddle
                                                    }
                                                }
                                            }

                                            // Size column
                                            Item {
                                                width: parent.width * mediaBrowser.sizeFraction
                                                height: parent.height
                                                clip: true

                                                Text {
                                                    anchors.left: parent.left
                                                    anchors.leftMargin: 5
                                                    anchors.right: parent.right
                                                    anchors.rightMargin: 5
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: itemIsDir ? "" : loggingWorkspace.formatFileSize(itemSize)
                                                    color: "#aaaaaa"
                                                    font.pixelSize: 12
                                                    elide: Text.ElideRight
                                                }
                                            }

                                            // Date column
                                            Item {
                                                width: parent.width * mediaBrowser.dateFraction
                                                height: parent.height
                                                clip: true

                                                Text {
                                                    anchors.left: parent.left
                                                    anchors.leftMargin: 5
                                                    anchors.right: parent.right
                                                    anchors.rightMargin: 5
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: Qt.formatDateTime(itemModified, "yyyy-MM-dd HH:mm")
                                                    color: "#aaaaaa"
                                                    font.pixelSize: 12
                                                    elide: Text.ElideRight
                                                }
                                            }
                                        }

                                        MouseArea {
                                            id: mouseArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            acceptedButtons: Qt.LeftButton | Qt.RightButton

                                            property bool clickHandled: false

                                            // ---- Drag-to-bin gesture ----
                                            // Deliberately NOT "Drag.active
                                            // on press": this MouseArea
                                            // already owns plain click,
                                            // ctrl/shift click and
                                            // double-click, so a drag only
                                            // becomes real once the pointer
                                            // has moved past a small
                                            // threshold. Below it, every
                                            // existing gesture behaves
                                            // exactly as before.
                                            property bool dragActive: false
                                            property bool didDrag: false
                                            property point dragStartPos

                                            onPressed: function(mouse) {
                                                dragStartPos = Qt.point(mouse.x, mouse.y)
                                                dragActive = false
                                                didDrag = false
                                                if (mouse.button !== Qt.LeftButton) return
                                                var g = mapToItem(loggingWorkspace, mouse.x, mouse.y)
                                                browserDragProxy.x = g.x - browserDragProxy.Drag.hotSpot.x
                                                browserDragProxy.y = g.y - browserDragProxy.Drag.hotSpot.y
                                            }

                                            onPositionChanged: function(mouse) {
                                                if (!pressed || !(mouse.buttons & Qt.LeftButton)) return
                                                var g = mapToItem(loggingWorkspace, mouse.x, mouse.y)
                                                browserDragProxy.x = g.x - browserDragProxy.Drag.hotSpot.x
                                                browserDragProxy.y = g.y - browserDragProxy.Drag.hotSpot.y
                                                if (!dragActive) {
                                                    var dx = mouse.x - dragStartPos.x
                                                    var dy = mouse.y - dragStartPos.y
                                                    if (Math.sqrt(dx * dx + dy * dy) > 6) {
                                                        // A click-disambiguation
                                                        // timer must never fire
                                                        // in the middle of a drag.
                                                        clickTimer.stop()
                                                        mouseArea.clickHandled = false
                                                        // Only now is it safe to
                                                        // grab the gesture away
                                                        // from the enclosing
                                                        // ListView's flick: doing
                                                        // it unconditionally would
                                                        // kill drag-to-scroll in
                                                        // the file list.
                                                        preventStealing = true
                                                        fileTreeView.prepareDragFromRow(index)
                                                        dragActive = true
                                                        didDrag = true
                                                        browserDragProxy.Drag.start()
                                                    }
                                                }
                                            }

                                            onReleased: {
                                                if (dragActive) browserDragProxy.Drag.drop()
                                                dragActive = false
                                                preventStealing = false
                                            }

                                            onCanceled: {
                                                if (dragActive) browserDragProxy.Drag.cancel()
                                                dragActive = false
                                                didDrag = false
                                                preventStealing = false
                                            }

                                            Menu {
                                                id: rowMenu
                                                MenuItem {
                                                    text: fileTreeView.selectedUrls.length > 1
                                                          ? "Add " + fileTreeView.selectedUrls.length + " items to Project Bin"
                                                          : (itemIsDir ? "Add folder (with structure) to Project Bin"
                                                                       : "Add to Project Bin")
                                                    onTriggered: fileTreeView.addSelectionToBin()
                                                }
                                                MenuItem {
                                                    text: "Clear selection"
                                                    enabled: fileTreeView.selectedUrls.length > 0
                                                    onTriggered: fileTreeView.clearSelection()
                                                }
                                            }

                                            Timer {
                                                id: clickTimer
                                                interval: 300
                                                onTriggered: {
                                                    if (!mouseArea.clickHandled) {
                                                        console.log("Timer triggered - single click")
                                                        // No double-click came, so this
                                                        // really was a plain click:
                                                        // now collapse the selection.
                                                        fileTreeView.selectOnlyRow(index)
                                                        // Single click action
                                                        if (itemIsDir) {
                                                            // Toggle expand/collapse
                                                            var wasExpanded = itemExpanded
                                                            treeModel.setProperty(index, "itemExpanded", !wasExpanded)

                                                            if (!wasExpanded) {
                                                                // Expand - load children
                                                                fileTreeView.expandFolder(index, itemUrl, itemLevel)
                                                            } else {
                                                                // Collapse - remove children
                                                                fileTreeView.collapseFolder(index, itemLevel)
                                                            }
                                                        } else {
                                                            // File clicked - load it in the Clip Monitor if it's
                                                            // something playbin can actually decode/preview
                                                            if (loggingWorkspace.isPlayableFile(itemName)) {
                                                                console.log("Loading media (single click):", itemUrl)
                                                                videoEngine.loadVideo(itemUrl, !loggingWorkspace.isImageFile(itemName))
                                                            }
                                                        }
                                                    }
                                                    mouseArea.clickHandled = false
                                                }
                                            }

                                            onClicked: function(mouse) {
                                                // MouseArea still emits
                                                // clicked after a
                                                // press-move-release, so a
                                                // completed drag must not
                                                // also fire the row's
                                                // click action (previewing
                                                // the file / toggling the
                                                // folder open).
                                                if (didDrag) { didDrag = false; return }

                                                fileTreeView.forceActiveFocus()

                                                if (mouse.button === Qt.RightButton) {
                                                    // Right-click must never start the
                                                    // preview timer or collapse the
                                                    // selection: it opens a menu that
                                                    // acts on whatever is selected. Only
                                                    // select the row if it isn't already
                                                    // part of the selection.
                                                    if (!browserRow.isSelected)
                                                        fileTreeView.selectOnlyRow(index)
                                                    fileTreeView.currentIndex = index
                                                    rowMenu.popup()
                                                    return
                                                }

                                                if (mouse.modifiers & Qt.ShiftModifier) {
                                                    fileTreeView.selectRangeToRow(
                                                        index, (mouse.modifiers & Qt.ControlModifier) !== 0)
                                                    fileTreeView.currentIndex = index
                                                    return
                                                }
                                                if (mouse.modifiers & Qt.ControlModifier) {
                                                    fileTreeView.toggleRowSelection(index)
                                                    fileTreeView.currentIndex = index
                                                    return
                                                }

                                                // Plain click: unchanged original
                                                // behavior (current row + the
                                                // single/double-click disambiguation
                                                // timer), plus collapsing the
                                                // selection down to this one row.
                                                //
                                                // A plain click INSIDE an existing
                                                // multi-selection must NOT collapse it
                                                // here: the first click of a
                                                // double-click fires onClicked before
                                                // onDoubleClicked, so collapsing now
                                                // would destroy the very selection the
                                                // double-click is meant to bulk-add.
                                                // Deferred into clickTimer instead,
                                                // which the double-click cancels.
                                                if (!(fileTreeView.selectedUrls.length > 1 && browserRow.isSelected))
                                                    fileTreeView.selectOnlyRow(index)
                                                fileTreeView.currentIndex = index
                                                clickTimer.restart()
                                            }

                                            onDoubleClicked: {
                                                console.log("Double click detected!")
                                                clickHandled = true
                                                clickTimer.stop()

                                                // Double-clicking inside an existing
                                                // multi-selection adds the WHOLE
                                                // selection; otherwise behave exactly
                                                // as before.
                                                if (fileTreeView.selectedUrls.length > 1
                                                    && fileTreeView.isUrlSelected(itemUrl)) {
                                                    fileTreeView.addSelectionToBin()
                                                    return
                                                }

                                                if (itemIsDir) {
                                                    // Navigate into folder
                                                    console.log("Navigating to folder:", itemUrl)
                                                    folderModel.folder = itemUrl
                                                } else {
                                                    // File double-clicked - add to Project Bin (don't load video)
                                                    console.log("Adding to Project Bin (double click):", itemUrl)
                                                    // Add to C++ model (will automatically update TreeView)
                                                    Backend.projectBinModel.addFile(itemUrl, Backend.loggingSelectedBinItemId)
                                                    console.log("File added to Project Bin, NOT loading to video engine")
                                                }
                                            }
                                        }
                                    }

                                    function expandFolder(parentIndex, folderUrl, parentLevel) {
                                        // Create a temporary folder model to read this directory
                                        var childModel = Qt.createQmlObject(
                                            'import QtQuick; import Qt.labs.folderlistmodel; FolderListModel { showDirs: true; showFiles: true; showDotAndDotDot: false; showHidden: false; showOnlyReadable: true }',
                                            fileTreeView
                                        )

                                        // Expanded sub-folders must use
                                        // the same sort as the top
                                        // level, or clicking a column
                                        // header would only reorder half
                                        // the visible tree.
                                        childModel.sortField = mediaBrowser.sortFieldForModel
                                        childModel.sortReversed = mediaBrowser.sortReversedForModel

                                        childModel.folder = folderUrl

                                        // Wait for model to load
                                        var checkTimer = Qt.createQmlObject(
                                            'import QtQuick; Timer { interval: 50; repeat: true }',
                                            fileTreeView
                                        )

                                        checkTimer.triggered.connect(function() {
                                            if (childModel.status === FolderListModel.Ready) {
                                                checkTimer.stop()

                                                // Insert children after parent
                                                var insertPos = parentIndex + 1
                                                for (var i = 0; i < childModel.count; i++) {
                                                    var isDir = childModel.isFolder(i)
                                                    treeModel.insert(insertPos + i, {
                                                        "itemName": childModel.get(i, "fileName"),
                                                        "itemSize": childModel.get(i, "fileSize"),
                                                        "itemModified": childModel.get(i, "fileModified"),
                                                        "itemIsDir": isDir,
                                                        "itemUrl": childModel.get(i, "fileURL"),
                                                        "itemLevel": parentLevel + 1,
                                                        "itemExpanded": false,
                                                        "itemParentUrl": folderUrl
                                                    })
                                                }

                                                childModel.destroy()
                                                checkTimer.destroy()
                                            }
                                        })

                                        checkTimer.start()
                                    }

                                    function collapseFolder(parentIndex, parentLevel) {
                                        // Remove all items that are children of this folder
                                        var i = parentIndex + 1
                                        var dropped = []
                                        while (i < treeModel.count && treeModel.get(i).itemLevel > parentLevel) {
                                            dropped.push(treeModel.get(i).itemUrl)
                                            treeModel.remove(i)
                                        }
                                        // Drop the vanished rows from the
                                        // selection - they're no longer
                                        // visible, so keeping them would
                                        // make "Add to Bin (N)" lie.
                                        if (dropped.length > 0 && selectedUrls.length > 0) {
                                            var a = selectedUrls.filter(function(u) { return dropped.indexOf(u) < 0 })
                                            if (a.length !== selectedUrls.length) selectedUrls = a
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            // Project Bin with tabs (bottom)
            Rectangle {
                SplitView.minimumHeight: 150
                color: "#2d2d2d"
                border.color: "#1d1d1d"
                border.width: 1
                
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 5
                    spacing: 0
                    
                    // Tab bar
                    TabBar {
                        id: projectBinTabs
                        Layout.fillWidth: true
                        
                        TabButton {
                            text: "Project Bin"
                        }
                        
                        TabButton {
                            text: "Properties"
                        }
                    }
                    
                    // Tab content
                    StackLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        currentIndex: projectBinTabs.currentIndex
                        
                        // Project Bin tab content
                        Rectangle {
                            color: palette.base

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 5
                                spacing: 5

                                // Toolbar with folder management buttons
                                Row {
                                    Layout.fillWidth: true
                                    spacing: 5

                                    Button {
                                        text: "+ Folder"
                                        width: 80
                                        height: 28
                                        onClicked: {
                                            var m = Backend.projectBinModel
                                            var target = Backend.loggingSelectedBinItemId
                                            // A file selected: create the folder next to it, in its own folder
                                            if (target !== "" && !m.data(m.indexFromItemId(target), ProjectBinModel.IsFolderRole))
                                                target = m.parentFolderId(target)
                                            var newId = m.addFolder("New Folder", target)
                                            // Make the new folder visible: expand its real parent (pseudo
                                            // groups resolve to "" and are always expanded), select it and
                                            // go straight into rename mode.
                                            var realParent = m.parentFolderId(newId)
                                            if (realParent !== "")
                                                Backend.setItemExpanded("logging", realParent, true)
                                            Backend.loggingSelectedBinItemId = newId
                                            editingItemId = newId
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
                                        enabled: Backend.loggingSelectedBinItemId !== ""
                                                 && !Backend.projectBinModel.isPseudoItem(Backend.loggingSelectedBinItemId)
                                        onClicked: {
                                            if (Backend.loggingSelectedBinItemId) {
                                                Backend.projectBinModel.removeItem(Backend.loggingSelectedBinItemId)
                                                Backend.loggingSelectedBinItemId = ""
                                            }
                                        }
                                    }

                                    Button {
                                        text: "Refresh"
                                        width: 70
                                        height: 28
                                        ToolTip.visible: hovered
                                        ToolTip.text: "Re-extract metadata for every video in the Project Bin (e.g. after replacing a source file on disk)"
                                        onClicked: Backend.projectBinModel.refreshAllMetadata()
                                    }

                                    // (The "Debug Log" toggle used to sit
                                    // here only because there was room -
                                    // it now lives in File > Settings...
                                    // with the rest of the app-wide
                                    // preferences.)
                                }

                                // Project Bin tree view
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    color: palette.base

                                    // Empty state background text
                                    Text {
                                        anchors.centerIn: parent
                                        visible: Backend.projectBinModel.rowCount() === 0
                                        text: "Project Bin\n(drag files from Media Browser)"
                                        color: "#888888"
                                        horizontalAlignment: Text.AlignHCenter
                                        z: 0
                                    }

                                    // Catch-all drop target: anything
                                    // dropped on the bin panel that isn't
                                    // over a row delegate (the empty area
                                    // below the last row, the margins)
                                    // lands here and imports to the bin's
                                    // default target - "" , which C++
                                    // resolveFileParent() turns into the
                                    // "Filesystem" group. Sits UNDER the
                                    // TreeView (z 0 vs 1) so a row's own
                                    // DropArea always wins when there is
                                    // a row under the cursor.
                                    DropArea {
                                        id: binBackgroundDrop
                                        anchors.fill: parent
                                        z: 0
                                        keys: ["media-browser-selection"]
                                        onDropped: function(drop) {
                                            fileTreeView.addSelectionToBinUnder("")
                                            drop.acceptProposedAction()
                                        }
                                    }

                                    // Whole-panel hint while a media
                                    // browser drag is in flight over the
                                    // empty area.
                                    Rectangle {
                                        anchors.fill: parent
                                        visible: binBackgroundDrop.containsDrag
                                        color: "transparent"
                                        border.color: "#4a9eff"
                                        border.width: 2
                                        z: 2
                                    }

                                    TreeView {
                                        id: projectBinTree
                                        anchors.fill: parent
                                        model: Backend.projectBinModel
                                        clip: true
                                        // Without this, the single column
                                        // auto-sizes to its content's
                                        // implicit width instead of
                                        // stretching to the viewport, so
                                        // each row's alternating/selection
                                        // background (TreeViewDelegate's
                                        // own `background:`) stops partway
                                        // across instead of reaching the
                                        // panel's right edge.
                                        columnWidthProvider: function(column) { return projectBinTree.width }
                                        z: 1

                                        ScrollBar.vertical: ScrollBar { id: binVBar; policy: ScrollBar.AsNeeded; z: 10 }  // TableView delegates have z=1; keep the bar above them

                                        // Always keep the two synthetic
                                        // group folders (= every depth-0
                                        // row) open - see the longer
                                        // comment on the same handler in
                                        // ProjectBinPanel.qml.
                                        onRowsChanged: Qt.callLater(ensureGroupsExpanded)
                                        function ensureGroupsExpanded() {
                                            for (var r = 0; r < projectBinTree.rows; r++) {
                                                if (projectBinTree.depth(r) === 0 && !projectBinTree.isExpanded(r))
                                                    projectBinTree.expand(r)
                                            }
                                        }
                                        // See the same block in
                                        // ProjectBinPanel.qml: expanding
                                        // an empty group is a no-op, so
                                        // the model's own insert/reset
                                        // signals are needed too.
                                        Connections {
                                            target: Backend.projectBinModel
                                            function onRowsInserted() { Qt.callLater(projectBinTree.ensureGroupsExpanded) }
                                            function onModelReset() { Qt.callLater(projectBinTree.ensureGroupsExpanded) }
                                        }

                                        // Which bin folder a media-browser
                                        // drop on visual row `row` should
                                        // import into:
                                        //  - a folder row  -> that folder
                                        //  - a pseudo group -> "" (C++
                                        //    resolveFileParent() sends
                                        //    real files to "Filesystem";
                                        //    dropping on "Virtual" must
                                        //    behave exactly like every
                                        //    other add path, i.e. redirect)
                                        //  - a file row    -> its parent
                                        //    folder, so aiming slightly
                                        //    off a folder still does the
                                        //    obvious thing instead of
                                        //    silently rejecting the drop
                                        //
                                        // Everything here comes from the
                                        // delegate's own required
                                        // properties plus one C++ lookup -
                                        // deliberately NOT from
                                        // model.data(modelIndex(row, 0),
                                        // SomeRole): two traps, both
                                        // confirmed live (2026-11-03, via a
                                        // real deeply-nested Kdenlive-
                                        // imported project whose subfolders
                                        // wouldn't expand at all - see the
                                        // expand-state sync code below,
                                        // which walked into both and has
                                        // since been fixed the same way):
                                        // on this Qt (6.4.2),
                                        // TreeView.modelIndex() takes
                                        // (column, row), not (row, column)
                                        // - fixed by calling it as
                                        // modelIndex(0, row); and the
                                        // model's role enum is NOT reachable
                                        // through an instance property
                                        // (Backend.projectBinModel.IdRole
                                        // evaluates to undefined, so data()
                                        // silently falls back to
                                        // Qt::DisplayRole and returns the
                                        // item's NAME) - only through the
                                        // QML-registered TYPE name
                                        // (ProjectBinModel.IdRole, as used
                                        // elsewhere in this codebase, e.g.
                                        // SourceMonitor.qml).
                                        function dropParentId(itemId, isFolder, isPseudo) {
                                            if (isPseudo) return ""
                                            if (isFolder) return itemId
                                            return Backend.projectBinModel.parentFolderId(itemId)
                                        }

                                        function syncAllExpandStates() {
                                            // Sync all expanded items from Backend
                                            var expandedIds = Backend.expandedItemIds("logging")
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
                                                if (view !== "logging") return
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

                                        // Initialize: expand all items that are in Backend.expandedItemIds("logging")
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
                                                Backend.setItemExpanded("logging", itemId, true)
                                            }
                                        }

                                        onCollapsed: function(row, depth) {
                                            var modelIndex = projectBinTree.modelIndex(0, row)
                                            if (modelIndex.valid) {
                                                var itemId = Backend.projectBinModel.data(modelIndex, ProjectBinModel.IdRole)
                                                Backend.setItemExpanded("logging", itemId, false)
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
                                            required property bool itemIsPseudo
                                            required property bool itemMissing

                                            property bool isEditing: editingItemId === treeDelegate.itemId
                                            property bool isSelected: Backend.loggingSelectedBinItemId === treeDelegate.itemId

                                            // TreeView provides depth, expanded, hasChildren, isTreeNode
                                            implicitHeight: 48
                                            indentation: 16

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
                                                    color: isSelected ? "white" : "#4a9eff"
                                                    font.pixelSize: 12
                                                }
                                            }

                                            background: Rectangle {
                                                color: isSelected ? "#4a9eff" : (treeDelegate.row % 2 ? palette.alternateBase : palette.base)

                                                // Drop highlight. Drawn in
                                                // the background item so it
                                                // can never intercept the
                                                // delegate's own clicks.
                                                Rectangle {
                                                    anchors.fill: parent
                                                    visible: rowDropArea.containsDrag
                                                    color: "#2f5f93"
                                                    opacity: 0.55
                                                    border.color: "#7fc0ff"
                                                    border.width: 2
                                                }
                                            }

                                            // Drop target for a Media
                                            // Browser selection being
                                            // dragged into the bin. Every
                                            // row accepts (files resolve to
                                            // their parent folder) so the
                                            // gesture isn't finicky to aim.
                                            DropArea {
                                                id: rowDropArea
                                                anchors.fill: parent
                                                keys: ["media-browser-selection"]
                                                onDropped: function(drop) {
                                                    fileTreeView.addSelectionToBinUnder(
                                                        projectBinTree.dropParentId(
                                                            treeDelegate.itemId,
                                                            treeDelegate.itemIsFolder,
                                                            treeDelegate.itemIsPseudo))
                                                    drop.acceptProposedAction()
                                                }
                                            }

                                            contentItem: Item {
                                                id: contentRoot
                                                x: 4 + (treeDelegate.depth * treeDelegate.indentation) + treeDelegate.indentation + 6
                                                width: treeDelegate.width - x
                                                height: treeDelegate.height
                                                implicitWidth: leftGroup.implicitWidth + rightGroup.implicitWidth + 12
                                                implicitHeight: Math.max(leftGroup.implicitHeight, rightGroup.implicitHeight)

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
                                                    width: Math.max(40, contentRoot.width - rightGroup.implicitWidth - 12
                                                                    - 22 - leftGroup.spacing
                                                                    - (thumbRect.visible ? 80 + leftGroup.spacing : 0))

                                                    // Editable TextField when editing
                                                    TextField {
                                                        id: nameEditor
                                                        visible: isEditing
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
                                                            // Created hidden, shown only on rename: onCompleted
                                                            // below never sees it visible, so grab focus here.
                                                            if (visible) Qt.callLater(function() { forceActiveFocus(); selectAll() })
                                                        }

                                                        Component.onCompleted: {
                                                            if (isEditing) {
                                                                Qt.callLater(function() {
                                                                    forceActiveFocus()
                                                                    selectAll()
                                                                })
                                                            }
                                                        }

                                                        Keys.onReturnPressed: {
                                                            Backend.projectBinModel.renameItem(treeDelegate.itemId, text)
                                                            editingItemId = ""
                                                        }

                                                        Keys.onEscapePressed: {
                                                            editingItemId = ""
                                                        }

                                                        onActiveFocusChanged: {
                                                            if (!activeFocus && editingItemId === treeDelegate.itemId) {
                                                                Backend.projectBinModel.renameItem(treeDelegate.itemId, text)
                                                                editingItemId = ""
                                                            }
                                                        }
                                                    }

                                                    Text {
                                                        visible: !isEditing
                                                        text: treeDelegate.itemName
                                                        color: treeDelegate.itemMissing ? "#ffcc66" : isSelected ? "white" : "#dddddd"
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

                                                // Audio/Video indicators (right side)
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

                                            onClicked: {
                                                Backend.loggingSelectedBinItemId = treeDelegate.itemId
                                                // Logging workspace: a single click plays
                                                // immediately (unlike the Editing
                                                // workspace's Clip Monitor, which only
                                                // previews paused on a single click).
                                                if ((treeDelegate.itemType === "video" || treeDelegate.itemType === "audio" || treeDelegate.itemType === "image")
                                                        && treeDelegate.itemPath) {
                                                    videoEngine.loadVideo(treeDelegate.itemPath, treeDelegate.itemType !== "image")
                                                }
                                            }

                                            onDoubleClicked: {
                                                if (treeDelegate.itemIsPseudo) {
                                                    // Synthetic group folder - not renameable.
                                                    return
                                                } else if (treeDelegate.itemIsFolder) {
                                                    // Start editing folder name
                                                    editingItemId = treeDelegate.itemId
                                                } else if ((treeDelegate.itemType === "video" || treeDelegate.itemType === "audio" || treeDelegate.itemType === "image")
                                                        && treeDelegate.itemPath) {
                                                    // Load and play
                                                    videoEngine.loadVideo(treeDelegate.itemPath, treeDelegate.itemType !== "image")
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        
                        // Properties tab content
                        Rectangle {
                            color: palette.base
                            
                            Text {
                                anchors.centerIn: parent
                                text: "Properties"
                                color: "#888888"
                            }
                        }
                    }
                }
            }
        }
        
        // MIDDLE COLUMN - Clip Monitor + Clip Info
        SplitView {
            SplitView.minimumWidth: 300
            SplitView.preferredWidth: 500
            orientation: Qt.Vertical
            
            // Clip Monitor (top)
            Rectangle {
                SplitView.minimumHeight: 200
                SplitView.fillHeight: true
                color: "#2d2d2d"
                border.color: "#1d1d1d"
                border.width: 1
                
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
                            text: "Clip Monitor"
                            color: "white"
                            font.pixelSize: 13
                            font.bold: true
                        }
                    }
                    
                    // Video preview area
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        color: "black"

                        // qml6glsink: renders directly into the scene
                        // graph - no native child window, no
                        // GstVideoOverlay window-handle plumbing.
                        GstGLQt6VideoItem {
                            id: glVideoItem
                            anchors.fill: parent
                            visible: videoEngine.glVideoSink
                            // itemInitialized only goes true once this item
                            // has a live GL context (strictly later than
                            // Component.onCompleted) - qml6glsink's
                            // NULL->READY transition fails outright if
                            // wired up before that.
                            onItemInitializedChanged: {
                                if (itemInitialized) videoEngine.setGLVideoItem(glVideoItem)
                            }
                            Component.onCompleted: {
                                if (itemInitialized) videoEngine.setGLVideoItem(glVideoItem)
                            }
                        }

                        // Video rendering area - native window embedded
                        // GL item never initialised (qml6 plugin without support for
                        // this Qt platform): say so instead of a silent black panel.
                        VideoUnavailableOverlay {
                            glItem: glVideoItem
                            monitored: videoEngine.glVideoSink
                        }

                        // Native-window path: only exists on Qt's xcb platform.
                        Loader {
                            id: videoOutputLoader
                            anchors.fill: parent
                            active: !videoEngine.glVideoSink && Backend.platformName === "xcb"
                            sourceComponent: Component {
                            VideoOutput {
                                anchors.fill: parent

                                Component.onCompleted: {
                                    console.log("VideoOutput created (Component.onCompleted)")
                                }

                                onWindowIdChanged: {
                                    if (windowId === 0) {
                                        // Native window was destroyed -
                                        // without this, the engine keeps a
                                        // handle to a dead X window.
                                        videoEngine.clearWindowId()
                                        return
                                    }
                                    console.log("VideoOutput window ID changed:", windowId)
                                    videoEngine.setWindowId(windowId)
                                }

                                onSurfaceExposed: {
                                    // The native surface just repainted
                                    // itself black (X Expose/resize) -
                                    // re-push the current frame so a
                                    // paused clip doesn't stay wiped.
                                    videoEngine.refreshVideo()
                                }

                                onVideoWindowHidden: {
                                    // Workspace page switched away from -
                                    // the native surface is unmapped, so a
                                    // still-PLAYING overlay sink would just
                                    // be decoding and blitting into nothing
                                    // (and on some X/Xv drivers leaving a
                                    // stale image behind). Pause; position
                                    // is preserved.
                                    if (videoEngine.playing) {
                                        videoEngine.pause()
                                    }
                                }

                                onVisibleChanged: {
                                    console.log("VideoOutput visibility changed:", visible)
                                }

                                onWidthChanged: {
                                    console.log("VideoOutput width changed:", width)
                                }

                                onHeightChanged: {
                                    console.log("VideoOutput height changed:", height)
                                }
                            }
                            }
                        }

                        // Placeholder text when no video
                        Text {
                            anchors.centerIn: parent
                            text: videoEngine.currentFile ?
                                  "" :
                                  "No video loaded\nClick on a video file to play"
                            color: "#888888"
                            horizontalAlignment: Text.AlignHCenter
                            z: 1
                        }
                    }

                    // Video info and seek bar
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 60
                        color: "#2d2d2d"

                        Column {
                            anchors.fill: parent
                            anchors.margins: 5
                            spacing: 5

                            // File name and time info
                            Row {
                                width: parent.width
                                spacing: 10

                                Text {
                                    text: videoEngine.currentFile ? videoEngine.currentFile.split('/').pop() : ""
                                    color: "#cccccc"
                                    font.pixelSize: 12
                                    elide: Text.ElideMiddle
                                    width: parent.width - timeInfo.width - 10
                                }

                                Text {
                                    id: timeInfo
                                    text: formatTime(videoEngine.position) + " / " + formatTime(videoEngine.duration)
                                    color: "#cccccc"
                                    font.pixelSize: 12
                                }
                            }

                            // Seek bar
                            Slider {
                                id: seekSlider
                                width: parent.width
                                from: 0
                                to: videoEngine.duration
                                value: videoEngine.position

                                onMoved: {
                                    videoEngine.seek(value)
                                }

                                background: Rectangle {
                                    x: seekSlider.leftPadding
                                    y: seekSlider.topPadding + seekSlider.availableHeight / 2 - height / 2
                                    implicitWidth: 200
                                    implicitHeight: 4
                                    width: seekSlider.availableWidth
                                    height: implicitHeight
                                    radius: 2
                                    color: "#555555"

                                    Rectangle {
                                        width: seekSlider.visualPosition * parent.width
                                        height: parent.height
                                        color: "#4a9eff"
                                        radius: 2
                                    }
                                }

                                handle: Rectangle {
                                    x: seekSlider.leftPadding + seekSlider.visualPosition * (seekSlider.availableWidth - width)
                                    y: seekSlider.topPadding + seekSlider.availableHeight / 2 - height / 2
                                    implicitWidth: 12
                                    implicitHeight: 12
                                    radius: 6
                                    color: seekSlider.pressed ? "#ffffff" : "#4a9eff"
                                    border.color: "#ffffff"
                                    border.width: 1
                                }
                            }
                        }
                    }

                    // Playback controls
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 40
                        color: "#3d3d3d"

                        Row {
                            anchors.centerIn: parent
                            spacing: 10

                            // Every direct child anchors its own vertical
                            // center: a Row only lays out x, so its height
                            // is the tallest child's - and the tallest child
                            // here is a style-sized CheckBox, not one of the
                            // fixed-height buttons. Without these anchors the
                            // buttons sit flush with the Row's top and
                            // visibly jump whenever the style's checkbox
                            // metrics change (that is exactly what the
                            // "transport buttons shifted up" report was).
                            Button {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "⏮"
                                width: 35
                                height: 30
                                enabled: videoEngine.currentFile
                                onClicked: videoEngine.seek(0)
                            }

                            Button {
                                anchors.verticalCenter: parent.verticalCenter
                                text: videoEngine.playing ? "⏸" : "▶"
                                width: 35
                                height: 30
                                enabled: videoEngine.currentFile
                                onClicked: {
                                    if (videoEngine.playing) {
                                        videoEngine.pause()
                                    } else {
                                        videoEngine.play()
                                    }
                                }
                            }

                            Button {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "⏹"
                                width: 35
                                height: 30
                                enabled: videoEngine.currentFile
                                onClicked: videoEngine.stop()
                            }

                            // Separator
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 2
                                height: 30
                                color: "#555555"
                            }

                            // Metadata visibility checkbox
                            Row {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 5

                                // NOTE: despite the backend property
                                // name (videoEngine.showMetadata), this
                                // controls exactly one thing:
                                // GST_PLAY_FLAG_TEXT on the playbin,
                                // i.e. whether an embedded subtitle /
                                // text stream is rendered on top of the
                                // video. It has nothing to do with the
                                // "Clip Information" panel below, which
                                // is always populated. Labelled for
                                // what it actually does.
                                CheckBox {
                                    id: metadataCheckbox
                                    checked: videoEngine.showMetadata
                                    onCheckedChanged: {
                                        videoEngine.showMetadata = checked
                                    }
                                    ToolTip.visible: hovered
                                    ToolTip.delay: 600
                                    ToolTip.text: "Render the clip's embedded subtitle / text track over the video."
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "Show Subtitles"
                                    color: "#cccccc"
                                    font.pixelSize: 12

                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: metadataCheckbox.toggle()
                                        hoverEnabled: true
                                        ToolTip.visible: containsMouse
                                        ToolTip.delay: 600
                                        ToolTip.text: "Render the clip's embedded subtitle / text track over the video."
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            // Clip Information (bottom)
            Rectangle {
                SplitView.minimumHeight: 350
                SplitView.preferredHeight: 400
                color: "#2d2d2d"
                border.color: "#1d1d1d"
                border.width: 1
                
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
                            text: "Clip Information"
                            color: "white"
                            font.pixelSize: 13
                            font.bold: true
                        }
                    }
                    
                    // Info content
                    //
                    // The background Rectangle must NOT take its height
                    // from the content column while that same column
                    // also fills the Rectangle: that is a binding loop
                    // (rect.implicitHeight <- column.height <-
                    // rect.height), which Qt breaks by collapsing the
                    // Rectangle to roughly its margins. That collapsed,
                    // near-black (palette.base) band is exactly the
                    // "black stripe" that used to sit under the
                    // header, with the rest of the panel falling back
                    // to the lighter #2d2d2d panel colour. Keep the
                    // background as a plain fill of the panel and let
                    // the ScrollView scroll a content column whose
                    // height is its own.
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        color: palette.base

                        ScrollView {
                            id: infoScroll
                            anchors.fill: parent
                            anchors.margins: 10
                            clip: true
                            contentWidth: availableWidth

                            ColumnLayout {
                                id: infoColumn
                                width: infoScroll.availableWidth
                                spacing: 8

                                Text {
                                    text: "File Name: " + (videoEngine.currentFile ? videoEngine.currentFile.split('/').pop() : "-")
                                    color: "#cccccc"
                                    font.pixelSize: 11
                                    wrapMode: Text.Wrap
                                    Layout.fillWidth: true
                                }

                                Text {
                                    text: "Path: " + (videoEngine.currentFile ? videoEngine.currentFile : "-")
                                    color: "#cccccc"
                                    font.pixelSize: 11
                                    wrapMode: Text.Wrap
                                    Layout.fillWidth: true
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 1
                                    color: "#555555"
                                }

                                Text {
                                    text: "Duration: " + (videoEngine.duration > 0 ? formatTime(videoEngine.duration) : "-")
                                    color: "#cccccc"
                                    font.pixelSize: 11
                                }

                                Text {
                                    text: "Resolution: " + videoEngine.resolution
                                    color: "#cccccc"
                                    font.pixelSize: 11
                                }

                                Text {
                                    text: "Frame Rate: " + videoEngine.frameRate
                                    color: "#cccccc"
                                    font.pixelSize: 11
                                }

                                Text {
                                    text: "Aspect Ratio: " + videoEngine.aspectRatio
                                    color: "#cccccc"
                                    font.pixelSize: 11
                                }

                                Text {
                                    text: "Bitrate: " + videoEngine.bitrate
                                    color: "#cccccc"
                                    font.pixelSize: 11
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 1
                                    color: "#555555"
                                }

                                Text {
                                    text: "Video Codec: " + videoEngine.videoCodec
                                    color: "#cccccc"
                                    font.pixelSize: 11
                                }

                                Text {
                                    text: "Audio Codec: " + videoEngine.audioCodec
                                    color: "#cccccc"
                                    font.pixelSize: 11
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 1
                                    color: "#555555"
                                }

                                Text {
                                    text: "Encoder: " + videoEngine.encoder
                                    color: "#cccccc"
                                    font.pixelSize: 11
                                    wrapMode: Text.Wrap
                                    Layout.fillWidth: true
                                }

                                Text {
                                    text: "Creation Time: " + videoEngine.creationTime
                                    color: "#cccccc"
                                    font.pixelSize: 11
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 1
                                    color: "#555555"
                                }

                                Text {
                                    text: "Status: " + (videoEngine.playing ? "Playing" : (videoEngine.currentFile ? "Paused" : "No video loaded"))
                                    color: "#cccccc"
                                    font.pixelSize: 11
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
