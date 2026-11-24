import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Dialogs
import VideoEditor 1.0

// Lists the source files of the open project that are not on disk, and lets
// the user retry (e.g. after reconnecting a drive), point the app at the
// folder the files moved to, or carry on without them. See
// MediaAvailability (C++) for the check and the folder search.
//
// Steps: "list" (the missing files), "searching" (folder search running),
// "confirm" (what the search found - nothing is changed until confirmed).
Window {
    id: dlg
    title: "Missing media"
    width: 660
    height: 500
    minimumWidth: 520
    minimumHeight: 380
    visible: false
    modality: Qt.ApplicationModal
    flags: Qt.Dialog

    readonly property color colorBackground: "#31363b"
    readonly property color colorPanel: "#232629"
    readonly property color colorText: "#eff0f1"
    readonly property color colorHighlight: "#3daee9"
    readonly property color colorBorder: "#5d6066"
    readonly property color colorSubText: "#aaaaaa"
    readonly property color colorWarn: "#ffcc66"
    color: colorBackground

    // The EditingWorkspace (timeline) - set by main.qml; may be null.
    property var workspace: null
    // Opened by the project-load sequence: main.qml runs the proxy-backfill
    // check once this closes.
    property bool afterLoad: false
    // Shown in the main window after the dialog closed by itself.
    signal statusMessage(string text)
    // The dialog opened by the load sequence was closed.
    signal closedAfterLoad()

    readonly property var mav: Backend.mediaAvailability
    property string step: "list"
    property string note: ""
    // true while a Retry / post-relink re-check runs
    property string recheckKind: ""          // "", "retry", "relink"
    property var prevMissing: []             // snapshot taken before a retry
    property int relinkedCount: 0
    property int scanned: 0
    property string searchRoot: ""
    property var foundMatches: []
    property int foundCount: 0
    property int ambiguousCount: 0
    property int notFoundCount: 0

    ListModel { id: listModel }
    ListModel { id: resultModel }

    readonly property int totalClips: {
        var n = 0
        for (var i = 0; i < listModel.count; i++) n += listModel.get(i).clipCount
        return n
    }

    function present(afterLoadFlag) {
        afterLoad = afterLoadFlag === true
        step = "list"
        note = ""
        recheckKind = ""
        relinkedCount = 0
        // Baseline for a fresh check that main.qml has just started.
        prevMissing = mav.missing.slice()
        refreshList()
        // Centered on the main window's screen like the other dialogs.
        x = (Screen.width - width) / 2
        y = (Screen.height - height) / 2
        show()
        raise()
        requestActivate()
    }

    function refreshList() {
        listModel.clear()
        var m = mav.missing
        for (var i = 0; i < m.length; i++) {
            listModel.append({
                path: m[i].path,
                fileName: m[i].fileName,
                group: m[i].group,
                folder: m[i].folder,
                clipCount: m[i].clipCount,
                notResponding: m[i].notResponding
            })
        }
    }

    function describeUse(clips) {
        return clips > 0 ? "used by " + clips + (clips === 1 ? " clip" : " clips") : "not on the timeline"
    }

    function listText() {
        var lines = []
        var m = mav.missing
        for (var i = 0; i < m.length; i++)
            lines.push(m[i].path + (m[i].notResponding ? "  (did not respond)" : ""))
        return lines.join("\n")
    }

    // ---- Retry ----
    function retry() {
        note = ""
        // slice(): mav.missing is a live reference to the C++ property, which
        // check() replaces.
        prevMissing = mav.missing.slice()
        recheckKind = "retry"
        mav.check(prevMissing)
    }

    // Compares the new check result with the list from before it: files that
    // came back get their bin items / cache entries registered and the
    // timeline rebuilt. Returns whether anything came back.
    function applyNewlyAvailable() {
        var still = {}
        var cur = mav.missing
        for (var i = 0; i < cur.length; i++) still[cur[i].path] = true
        var ids = [], clipsAffected = 0, found = 0, any = false
        for (var j = 0; j < prevMissing.length; j++) {
            var e = prevMissing[j]
            if (still[e.path]) continue
            any = true
            found++
            for (var k = 0; k < e.itemIds.length; k++) ids.push(e.itemIds[k])
            clipsAffected += e.clipCount
        }
        if (any) {
            if (ids.length > 0) Backend.projectBinModel.mediaBecameAvailable(ids)
            if (clipsAffected > 0 && workspace) workspace.retryMedia()
            reloadSourceMonitor()
            Backend.logOperation("media_retry", { found: found, stillMissing: cur.length, clips: clipsAffected })
        }
        prevMissing = []
        return any
    }

    function finishRecheck() {
        var kind = recheckKind
        recheckKind = ""
        if (kind === "relink") {
            refreshList()
            if (mav.missingCount === 0) {
                statusMessage("Relinked " + relinkedCount + (relinkedCount === 1 ? " file." : " files."))
                dlg.close()
            } else {
                note = "Relinked " + relinkedCount + (relinkedCount === 1 ? " file." : " files.")
            }
            return
        }
        // "retry" (Retry button) or "" (fresh check started by the File menu /
        // bin chip while the dialog is open).
        var any = applyNewlyAvailable()
        if (kind === "retry" && !any) note = "No missing files were found again."
        refreshList()
        if (mav.missingCount === 0 && step === "list") {
            statusMessage("All media found.")
            dlg.close()
        }
    }

    Connections {
        target: dlg.mav
        function onCheckFinished() { if (dlg.visible) dlg.finishRecheck() }
        function onSearchProgress(n) { dlg.scanned = n }
        function onSearchFinished(matches, ambiguous, notFound) { dlg.onSearchDone(matches, ambiguous, notFound) }
    }

    // ---- Locate folder ----
    FolderDialog {
        id: folderDialog
        title: "Select the folder that contains the missing files"
        onAccepted: {
            var f = selectedFolder.toString()
            f = dlg.mav.localPath(f)
            dlg.startSearch(f)
        }
    }

    function openFolderPicker() {
        folderDialog.parentWindow = dlg
        folderDialog.open()
    }

    function startSearch(folder) {
        searchRoot = folder
        scanned = 0
        step = "searching"
        mav.searchFolder(folder, mav.missing)
    }

    function cancelSearch() {
        mav.cancelSearch()
        step = "list"
    }

    function onSearchDone(matches, ambiguous, notFound) {
        if (step !== "searching") return
        foundMatches = matches
        resultModel.clear()
        for (var i = 0; i < matches.length; i++)
            resultModel.append({ kind: "found", oldPath: matches[i].oldPath, newPath: matches[i].newPath,
                                 byName: matches[i].byName })
        for (var a = 0; a < ambiguous.length; a++)
            resultModel.append({ kind: "ambiguous", oldPath: ambiguous[a].path,
                                 newPath: ambiguous[a].candidates.length + " candidates", byName: false })
        for (var n = 0; n < notFound.length; n++)
            resultModel.append({ kind: "zz-notfound", oldPath: notFound[n], newPath: "", byName: false })
        foundCount = matches.length
        ambiguousCount = ambiguous.length
        notFoundCount = notFound.length
        step = "confirm"
    }

    function applyRelink() {
        var obj = {}
        var mp = new Map()
        var byName = 0
        for (var i = 0; i < foundMatches.length; i++) {
            obj[foundMatches[i].oldPath] = foundMatches[i].newPath
            mp.set(foundMatches[i].oldPath, foundMatches[i].newPath)
            if (foundMatches[i].byName) byName++
        }
        var binIds = Backend.projectBinModel.relinkItems(obj)
        var clips = workspace ? workspace.timelinePanel.relinkSourcePaths(mp) : 0
        if (clips > 0) workspace.retryMedia()
        else Backend.refreshProxyInstallations()
        reloadSourceMonitor(mp)
        Backend.logOperation("media_relink", { files: foundMatches.length, binItems: binIds.length,
                                               clips: clips, foundByName: byName, folder: searchRoot })
        relinkedCount += foundMatches.length
        // Check what is left (the relinked files were verified by the search).
        var remaining = []
        var cur = mav.missing
        for (var j = 0; j < cur.length; j++)
            if (!mp.has(cur[j].path)) remaining.push(cur[j])
        foundMatches = []
        step = "list"
        note = ""
        recheckKind = "relink"
        mav.check(remaining)
    }

    // The Source Monitor keeps showing an old load error for a file that is
    // there now: reload what it has open when that file came back / moved.
    function reloadSourceMonitor(relinkMap) {
        if (!workspace || !workspace.sourceMonitor) return
        var eng = workspace.sourceMonitor.clipVideoEngine
        if (!eng || !eng.currentFile || eng.playing) return
        var cur = mav.localPath(String(eng.currentFile))
        var target = cur
        if (relinkMap && relinkMap.has(cur)) target = relinkMap.get(cur)
        else if (relinkMap) return
        eng.loadVideo(target)
    }

    onVisibleChanged: {
        if (!visible) {
            mav.cancelSearch()
            recheckKind = ""
            step = "list"
            if (afterLoad) {
                afterLoad = false
                closedAfterLoad()
            }
        }
    }

    // Closing by the window manager = Continue without them.
    onClosing: function(close) { step = "list" }

    component DialogButton: Button {
        id: btn
        property bool accent: false
        implicitHeight: 32
        implicitWidth: 150
        background: Rectangle {
            color: !btn.enabled ? "#3a3d41" : btn.accent ? (btn.down ? "#2a9ad0" : dlg.colorHighlight)
                                                         : (btn.down ? "#3d4045" : "#4d5057")
            radius: 2
        }
        contentItem: Text {
            text: btn.text
            color: !btn.enabled ? "#777" : btn.accent ? "white" : dlg.colorText
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.pixelSize: 12
        }
    }

    Shortcut { sequence: "Escape"; enabled: dlg.visible; onActivated: {
        if (dlg.step === "searching") dlg.cancelSearch()
        else if (dlg.step === "confirm") dlg.step = "list"
        else dlg.close()
    } }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Header
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 84
            color: dlg.colorPanel
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 15
                spacing: 4
                Text {
                    text: dlg.step === "list" ? "Missing media"
                          : dlg.step === "searching" ? "Locate folder" : "Locate folder - results"
                    font.pixelSize: 18
                    font.bold: true
                    color: dlg.colorWarn
                }
                Text {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    color: dlg.colorText
                    font.pixelSize: 12
                    visible: dlg.step === "list"
                    text: dlg.mav.checking && listModel.count === 0
                          ? "Checking the project's source files..."
                          : listModel.count + (listModel.count === 1 ? " source file" : " source files")
                            + " used by this project cannot be found."
                            + (dlg.totalClips > 0 ? " " + dlg.totalClips + (dlg.totalClips === 1 ? " clip" : " clips")
                                                    + " on the timeline use them." : "")
                }
                Text {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    elide: Text.ElideMiddle
                    color: dlg.colorText
                    font.pixelSize: 12
                    visible: dlg.step === "searching"
                    text: "Searching " + dlg.searchRoot + " ... (" + dlg.scanned + " files scanned)"
                }
                Text {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    color: dlg.colorText
                    font.pixelSize: 12
                    visible: dlg.step === "confirm"
                    text: "Found " + dlg.foundCount + " of " + (dlg.foundCount + dlg.ambiguousCount + dlg.notFoundCount)
                          + " files in " + dlg.searchRoot + "."
                }
            }
        }

        // ---- list step ----
        ColumnLayout {
            visible: dlg.step === "list"
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: 12
            spacing: 6

            Text {
                visible: dlg.note !== ""
                text: dlg.note
                color: dlg.colorHighlight
                font.pixelSize: 12
            }
            Text {
                visible: dlg.mav.checking
                text: "Checking..."
                color: dlg.colorSubText
                font.pixelSize: 12
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: dlg.colorPanel
                border.color: dlg.colorBorder
                ListView {
                    id: missingList
                    anchors.fill: parent
                    anchors.margins: 1
                    clip: true
                    model: listModel
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    section.property: "group"
                    section.criteria: ViewSection.FullString
                    section.delegate: Rectangle {
                        required property string section
                        width: missingList.width
                        height: 26
                        color: "#2c3034"
                        Text {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideMiddle
                            text: parent.section
                            color: parent.section === "Did not respond within 5 seconds" ? dlg.colorWarn : dlg.colorSubText
                            font.pixelSize: 11
                            font.bold: true
                        }
                        HoverHandler { id: secHover }
                        ToolTip.visible: secHover.hovered
                        ToolTip.delay: 400
                        ToolTip.text: parent.section || ""
                    }
                    delegate: Item {
                        id: row
                        required property var path
                        required property var fileName
                        required property var clipCount
                        width: missingList.width
                        height: 26
                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 18
                            anchors.right: useText.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.fileName
                            elide: Text.ElideMiddle
                            color: dlg.colorText
                            font.pixelSize: 12
                        }
                        Text {
                            id: useText
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: dlg.describeUse(row.clipCount)
                            color: dlg.colorSubText
                            font.pixelSize: 11
                        }
                        HoverHandler { id: rowHover }
                        ToolTip.visible: rowHover.hovered
                        ToolTip.delay: 600
                        ToolTip.text: row.path
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                DialogButton {
                    text: "Copy list"
                    implicitWidth: 100
                    onClicked: Codecs.copyToClipboard(dlg.listText())
                }
                Item { Layout.fillWidth: true }
                DialogButton { text: "Retry"; implicitWidth: 100; enabled: !dlg.mav.checking; onClicked: dlg.retry() }
                DialogButton { text: "Locate folder..."; implicitWidth: 140; enabled: !dlg.mav.checking && listModel.count > 0
                               onClicked: dlg.openFolderPicker() }
                DialogButton { id: continueBtn; text: "Continue without them"; accent: true; implicitWidth: 180
                               onClicked: dlg.close() }
            }
        }

        // ---- searching step ----
        ColumnLayout {
            visible: dlg.step === "searching"
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: 12
            spacing: 10
            Item { Layout.fillHeight: true }
            BusyIndicator { Layout.alignment: Qt.AlignHCenter; running: dlg.step === "searching" }
            Item { Layout.fillHeight: true }
            DialogButton { Layout.alignment: Qt.AlignRight; text: "Cancel"; onClicked: dlg.cancelSearch() }
        }

        // ---- confirm step ----
        ColumnLayout {
            visible: dlg.step === "confirm"
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: 12
            spacing: 6

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: dlg.colorPanel
                border.color: dlg.colorBorder
                ListView {
                    id: resultList
                    anchors.fill: parent
                    anchors.margins: 1
                    clip: true
                    model: resultModel
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    section.property: "kind"
                    section.criteria: ViewSection.FullString
                    section.delegate: Rectangle {
                        required property string section
                        width: resultList.width
                        height: 26
                        color: "#2c3034"
                        Text {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            verticalAlignment: Text.AlignVCenter
                            text: parent.section === "found" ? "Found: " + dlg.foundCount
                                  : parent.section === "ambiguous"
                                    ? "Several files with the same name, not relinked: " + dlg.ambiguousCount
                                    : "Not found: " + dlg.notFoundCount
                            color: parent.section === "found" ? "#6cc06c" : dlg.colorWarn
                            font.pixelSize: 11
                            font.bold: true
                        }
                    }
                    delegate: Item {
                        id: rrow
                        required property var kind
                        required property var oldPath
                        required property var newPath
                        required property var byName
                        width: resultList.width
                        height: rrow.kind === "found" ? 40 : 22
                        Column {
                            anchors.left: parent.left
                            anchors.leftMargin: 14
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1
                            Text {
                                width: parent.width
                                elide: Text.ElideMiddle
                                text: rrow.oldPath
                                color: rrow.kind === "found" ? dlg.colorSubText : dlg.colorText
                                font.pixelSize: rrow.kind === "found" ? 10 : 11
                            }
                            Text {
                                visible: rrow.kind === "found"
                                width: parent.width
                                elide: Text.ElideMiddle
                                text: "→ " + rrow.newPath + (rrow.byName ? "   (found by name)" : "")
                                color: dlg.colorText
                                font.pixelSize: 11
                            }
                        }
                        HoverHandler { id: rrHover }
                        ToolTip.visible: rrHover.hovered
                        ToolTip.delay: 600
                        ToolTip.text: rrow.kind === "found" ? rrow.oldPath + "\n→ " + rrow.newPath : rrow.oldPath
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: dlg.colorSubText
                font.pixelSize: 11
                text: "Relinking changes the file locations stored in this project. Nothing on disk is moved or changed. "
                      + "Save the project afterwards to keep the new locations."
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Item { Layout.fillWidth: true }
                DialogButton { text: "Back"; implicitWidth: 100; onClicked: dlg.step = "list" }
                DialogButton {
                    text: "Relink " + dlg.foundCount + (dlg.foundCount === 1 ? " file" : " files")
                    accent: true
                    implicitWidth: 160
                    enabled: dlg.foundCount > 0
                    onClicked: dlg.applyRelink()
                }
            }
        }
    }
}
