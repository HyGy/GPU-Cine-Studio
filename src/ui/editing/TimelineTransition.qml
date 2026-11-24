import QtQuick
import QtQuick.Controls

Item {
    id: transitionItem

    // Parent references
    property var timeline
    property var clips

    // Properties from model
    property bool transitionActive: model.hasTransition === true
    // Live drag-resize preview (seconds, <= 0: none). Only the bar itself
    // is previewed; the model changes once, on release.
    property real previewDuration: -1
    property real previewLeftSec: 0
    property real previewCut: 0
    readonly property bool resizing: previewDuration > 0
    property real transDuration: previewDuration > 0 ? previewDuration
                                 : (model.transitionDuration || timeline.defaultTransitionDuration)
    // NOT used for applyTransition()/removeTransition() anymore - see
    // TimelinePanel.applyTransitionById()/removeTransitionById() for why
    // (index is the clipsModel row only as long as every row has exactly
    // one delegate; under any future filtered/virtualized view it would
    // be the position within the filtered group instead, silently
    // applying/removing a transition on the wrong clip).
    property string ownerClipId: model.clipId || ""  // Azonosítás transition mozgatáshoz

    // Mirrors TimelineClip.qml's calculateVisualWidth()'s own cutOffset
    // read (same !== undefined guard, same transDur/2.0 fallback for a
    // synthetic/dev clip row with no transitionCutOffset role at all) -
    // the REAL cut point between two already-trimmed clip rectangles is
    // at (overlap start + cutOffset), not at the overlap's midpoint,
    // whenever an imported Kdenlive mixcut was off-center. Found live:
    // a transition with transDuration=0.5005, cutOffset=0 rendered this
    // badge entirely inside the INCOMING clip's rectangle, because this
    // binding used to assume cutOffset == transDuration/2.0 always.
    property real transCutOffset: previewDuration > 0 ? previewCut
                                   : (model.transitionCutOffset !== undefined
                                      ? model.transitionCutOffset
                                      : transDuration / 2.0)
    property real cutPointSeconds: model.startTime + model.durationSeconds
                                    - transDuration + transCutOffset

    // X pozíció számítása az Overlap logikához - a sáv középpontja a
    // valódi vágásponton ül (cutPointSeconds), nem az overlap elején;
    // szimmetrikus esetben (cutOffset == transDuration/2) ez pontosan
    // ugyanazt az x-et adja, mint a korábbi "overlap start" képlet.
    x: transitionActive
       ? (resizing ? previewLeftSec * timeline.pixelsPerSecond
                   : (cutPointSeconds * timeline.pixelsPerSecond) - (transDuration * timeline.pixelsPerSecond / 2))
       : ((model.startTime + model.durationSeconds) * timeline.pixelsPerSecond) - 12 // Gomb pozíciója (fél gomb szélesség)

    // See TimelineClip.qml's y binding for why trackGeometryRevision is
    // deliberately read here via the comma expression.
    y: (timeline.trackGeometryRevision, timeline.getTrackYPosition(model.trackId) + 5)

    // Visszaköti a binding-et drag után (mint TimelineClip-ben)
    function rebindPosition() {
        x = Qt.binding(function() {
            return transitionActive
                ? (resizing ? previewLeftSec * timeline.pixelsPerSecond
                            : (cutPointSeconds * timeline.pixelsPerSecond) - (transDuration * timeline.pixelsPerSecond / 2))
                : ((model.startTime + model.durationSeconds) * timeline.pixelsPerSecond) - 12
        })
        // y was never restored here before either - same bug/fix as
        // TimelineClip.qml's rebindPosition(): updateTransitionGroupPosition()
        // sets overlay.y imperatively while dragging a transition group.
        y = Qt.binding(function() {
            return (timeline.trackGeometryRevision, timeline.getTrackYPosition(model.trackId) + 5)
        })
    }
    
    // Szélesség: Aktív állapotban az átfedés hossza, inaktív állapotban a gomb mérete
    width: transitionActive ? (transDuration * timeline.pixelsPerSecond) : 24
    height: 50 

    // Láthatóság és Szomszéd keresés
    property bool hasNeighbor: false

    // Accessibility: a geometria mindig ezen a root Item-en stabil (a belső
    // "+" Rectangle opacity 0-ra animál hoverig, ami miatt Qt accessibility
    // nem adna érvényes Component/geometria interfészt rá), ezért ide kerül
    // a név/szerep UI-automatizáláshoz.
    objectName: "transitionSlot_" + ownerClipId
    Accessible.role: transitionActive ? Accessible.StaticText : Accessible.Button
    Accessible.name: transitionActive
        ? ("Transition: " + (model.transitionType || ""))
        : (hasNeighbor ? "Add Transition" : "")

    Connections {
        target: timeline
        function onRequestNeighborCheck() { transitionItem.checkForNeighbor() }
    }

    // onXChanged: checkForNeighbor() REMOVED - x is bound to
    // timeline.pixelsPerSecond (via model.startTime/durationSeconds),
    // so every zoom step changed x on every transition delegate, which
    // re-ran this O(n) scan n times = O(n^2) PER ZOOM STEP. Neighbour-ness
    // depends only on model times, never on pixel position, so this
    // binding was pure waste - zooming never needs a new answer.
    onVisibleChanged: if(visible) checkForNeighbor()

    function checkForNeighbor() {
        if (!visible || transitionActive) return
        hasNeighbor = false
        if (!timeline || !timeline.clipIndexByTrack) return

        // O(log n) binary search over the per-track index (rebuilt by
        // TimelinePanel.rebuildClipIndex() on every edit) instead of an
        // O(n) scan of the whole clips model per transition delegate.
        var arr = timeline.clipIndexByTrack[model.trackId]
        if (!arr || arr.length === 0) return

        var cutPointTime = model.startTime + model.durationSeconds
        var tolerance = 0.1

        var lo = 0, hi = arr.length
        while (lo < hi) {
            var mid = (lo + hi) >> 1
            if (arr[mid].startTime < cutPointTime - tolerance) lo = mid + 1
            else hi = mid
        }
        for (var k = lo; k < arr.length && arr[k].startTime <= cutPointTime + tolerance; k++) {
            if (arr[k].clipId !== model.clipId && Math.abs(arr[k].startTime - cutPointTime) < tolerance) {
                hasNeighbor = true
                break
            }
        }
    }

    // Delegate-regiszter szinkronizálása a timeline.transitionItemsByOwner
    // map-be (lásd TimelinePanel.qml és TimelineClip.qml's syncClipRegistration
    // ugyanezen minta). ownerClipId ugyanúgy nem stabil, mint clipId
    // TimelineClip.qml-ben - splitAtPlayhead() a model.clipId role-t
    // módosíthatja anélkül, hogy ez a delegate instance megsemmisülne.
    property string previousRegisteredOwnerClipId: ""
    function syncOwnerRegistration() {
        if (!timeline) return
        if (previousRegisteredOwnerClipId && previousRegisteredOwnerClipId !== ownerClipId && timeline.unregisterTransitionItem) {
            timeline.unregisterTransitionItem(previousRegisteredOwnerClipId, transitionItem)
        }
        if (ownerClipId && timeline.registerTransitionItem) {
            timeline.registerTransitionItem(ownerClipId, transitionItem)
        }
        previousRegisteredOwnerClipId = ownerClipId
    }
    onOwnerClipIdChanged: syncOwnerRegistration()

    Component.onCompleted: {
        syncOwnerRegistration()
        checkForNeighbor()
    }

    Component.onDestruction: {
        if (timeline && timeline.unregisterTransitionItem && previousRegisteredOwnerClipId) {
            timeline.unregisterTransitionItem(previousRegisteredOwnerClipId, transitionItem)
        }
    }

    // --- "+" GOMB (Inaktív állapot) ---
    Rectangle {
        width: 24
        height: 24
        anchors.centerIn: parent

        radius: 12
        color: "white"
        border.color: "#333"
        border.width: 1
        visible: !parent.transitionActive && parent.hasNeighbor
        opacity: ma.containsMouse ? 1.0 : 0.0

        Behavior on opacity { NumberAnimation { duration: 200 } }

        Text { 
            anchors.centerIn: parent
            text: "+"
            font.bold: true
            color: "#333"
            y: -1 
        }

        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            onClicked: {
                var transType = model.trackId.startsWith("V") ? "dissolve" : "crossfade"
                console.log("Adding", transType, "to clip:", ownerClipId, "on track:", model.trackId)
                timeline.applyTransitionById(ownerClipId)
            }
        }
    }

    readonly property bool selected: transitionActive && timeline.selectedTransitionId === ownerClipId
    function formatDuration(d) {
        var fps = timeline.projectFps()
        return d.toFixed(2) + " s (" + Math.round(d * fps) + " f)"
    }

    // --- TRANSITION SÁV (Aktív állapot) ---
    Rectangle {
        visible: parent.transitionActive

        // Szélességben kitölti az átfedést (parent width)
        anchors.left: parent.left
        anchors.right: parent.right

        // JAVÍTÁS: Magasság csak 1/3, és alulra igazítva (eredeti design szerint)
        height: parent.height / 3
        anchors.bottom: parent.bottom

        color: "#b055ff"
        opacity: 0.9 // Kicsit erősebb opacity, mivel kisebb a felület
        border.color: transitionItem.selected ? "#ffe066" : "white"
        border.width: transitionItem.selected ? 2 : 1
        radius: 4

        // Transition szöveg - használjuk a model.transitionType-ot. A
        // mező most egy GES transition-type NICK-et hordozhat (pl.
        // "clock-cw12" egy importált luma wipe-ból, lásd
        // KdenliveImporter.cpp gesWipeNickForLumaResource()), nem csak
        // "dissolve"/"crossfade"-et - egy sima charAt(0).toUpperCase()
        // "Clock-cw12"-t adna, ezért a gyakori nickekhez emberi címke,
        // a többihez kötőjel-mentes title-case a fallback.
        // Shown only when it fits (3 px padding each side), centred in
        // the whole bar. The hover X button simply overlays it.
        Text {
            id: barLabel
            anchors.centerIn: parent
            visible: implicitWidth + 6 <= parent.width
            text: {
                if (!model.transitionType) return "Transition"
                var type = model.transitionType
                // "crossfade" is the SAME GES type on both an audio and
                // a video transition clip (GES has no "dissolve" type at
                // all, see GesTransitions::nickToType()) - but the two
                // conventional NLE names for it differ by track type,
                // and an audio track can never show anything else (GES's
                // GESAudioTransition has no "type" property/enum at all -
                // it's always a fixed linear crossfade, nothing to pick).
                if (type === "crossfade" || type === "dissolve") {
                    return model.trackId && model.trackId.startsWith("A") ? "Crossfade" : "Dissolve"
                }
                var labels = {
                    "clock-cw12": "Clock Wipe",
                    "bar-wipe-lr": "Bar Wipe (H)",
                    "bar-wipe-tb": "Bar Wipe (V)",
                    "box-wipe-br": "Box Wipe",
                    "box-wipe-bl": "Box Wipe",
                    "box-wipe-rc": "Box Wipe",
                    "iris-rect": "Iris Wipe",
                    "barndoor-v": "Barn Door (H)",
                    "barndoor-h": "Barn Door (V)",
                    "barndoor-dbl": "Barn Door (Diag)",
                    "barndoor-dtl": "Barn Door (Diag)",
                    "diagonal-tl": "Diagonal Wipe",
                    "diagonal-tr": "Diagonal Wipe",
                    "barnvee-u": "Barn Vee",
                    "four-box-wipe-ci": "Double Iris"
                }
                if (labels[type]) return labels[type]
                var words = type.split("-")
                for (var i = 0; i < words.length; i++)
                    words[i] = words[i].charAt(0).toUpperCase() + words[i].slice(1)
                return words.join(" ")
            }
            color: "white"
            font.pixelSize: 9
            font.bold: true
            style: Text.Outline
            styleColor: "black"
        }
        
        // Törlés gomb (X) - Jobb oldalon. z magasabb mint transMa-é, hogy
        // a típus-váltó kattintás-területe (lejjebb) ne nyelje el a
        // törlés kattintást ezen a kis, átfedő résen.
        Rectangle {
            z: 2
            width: 14
            height: 14
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.rightMargin: 8
            color: "#cc0000"
            radius: 7
            visible: transMa.containsMouse
            
            Text {
                anchors.centerIn: parent
                text: "×"
                color: "white"
                font.bold: true
                font.pixelSize: 10
                y: -1
            }
            
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    console.log("Removing transition from clip:", ownerClipId)
                    timeline.removeTransitionById(ownerClipId)
                }
            }
        }

        // Click selects this transition (edited in the Transition tab next
        // to the timeline; type/duration/remove live there, not in a menu).
        MouseArea {
            id: transMa
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            propagateComposedEvents: true
            onClicked: timeline.selectTransition(ownerClipId)
        }

        // Name + duration on hover (not while dragging a handle - the
        // drag tooltip above shows then). Mainly for bars too short to
        // show their label.
        ToolTip {
            visible: transMa.containsMouse && !transitionItem.resizing
            delay: 600
            text: barLabel.text + " - " + transitionItem.formatDuration(transitionItem.transDuration)
        }

        // Resize handles at both ends of the bar. The cut point stays put
        // (TimelinePanel.setTransitionDurationById()): the bar grows or
        // shrinks around it, the cut offset scaling with the duration
        // (the final, handle-clamped geometry is applied on release).
        // Whole project frames, one undo step on release.
        Repeater {
            model: 2
            Item {
                id: handle
                readonly property bool isLeft: index === 0
                z: 3
                width: 7
                height: parent.height
                x: isLeft ? 0 : parent.width - width
                property real startGX: 0
                property real startDur: 0
                property real startLeftSec: 0
                property real startCut: 0
                property real startCutSec: 0
                property real endDur: -1
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.SizeHorCursor
                    acceptedButtons: Qt.LeftButton
                    onPressed: function(mouse) {
                        handle.startGX = mapToGlobal(mouse.x, 0).x
                        handle.startDur = transitionItem.transDuration
                        handle.startLeftSec = transitionItem.x / timeline.pixelsPerSecond
                        handle.startCut = transitionItem.transCutOffset
                        handle.startCutSec = transitionItem.cutPointSeconds
                        handle.endDur = -1
                    }
                    onPositionChanged: function(mouse) {
                        if (!pressed) return
                        var dxSec = (mapToGlobal(mouse.x, 0).x - handle.startGX) / timeline.pixelsPerSecond
                        var raw = handle.isLeft ? handle.startDur - dxSec : handle.startDur + dxSec
                        var d = timeline.snapTransitionDuration(ownerClipId, raw)
                        handle.endDur = d
                        var cut = handle.startDur > 0 ? handle.startCut * d / handle.startDur : d / 2.0
                        transitionItem.previewCut = cut
                        transitionItem.previewLeftSec = handle.startCutSec - cut
                        transitionItem.previewDuration = d
                    }
                    onReleased: {
                        var d = handle.endDur
                        transitionItem.previewDuration = -1
                        if (d > 0) timeline.setTransitionDurationById(ownerClipId, d)
                        handle.endDur = -1
                    }
                    onCanceled: { transitionItem.previewDuration = -1; handle.endDur = -1 }
                    // propagateComposedEvents is off here on purpose: the
                    // press must not reach the type-menu area below.
                }
            }
        }

        // Duration tooltip while resizing: "1.20 s (30 f)".
        Rectangle {
            id: durTip
            visible: transitionItem.resizing
            z: 5
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.top
            anchors.bottomMargin: 4
            width: durTipText.implicitWidth + 12
            height: durTipText.implicitHeight + 6
            color: "#202020"
            border.color: "#b055ff"
            radius: 3
            Text {
                id: durTipText
                anchors.centerIn: parent
                color: "white"
                font.pixelSize: 11
                text: transitionItem.formatDuration(transitionItem.transDuration)
            }
        }
    }
}
