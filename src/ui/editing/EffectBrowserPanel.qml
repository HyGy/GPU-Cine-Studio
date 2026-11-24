import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import VideoEditor 1.0

// Categorized, searchable effect list. A plain click on a leaf row
// does nothing (deliberately - see itemArea's onClicked comment below);
// an effect (with sensible default params) is only applied to the
// currently selected clip(s)' stack via its "+" button, or by dragging
// the row onto a clip on the timeline.
Rectangle {
    id: root

    SplitView.minimumWidth: 220
    SplitView.preferredWidth: 280
    color: palette.window
    border.color: "#1d1d1d"
    border.width: 1

    property string selectedClipId: ""
    property var timelinePanel: null
    // Reparent target for the drag-to-timeline ghost (see Phase 3) -
    // must be an ancestor the ListView's own clip:true won't clip.
    property var workspaceRoot: null

    // Every preset carries mediaType: "video" or "audio" - which track
    // type (timeline.getTrackType(trackId)) it's allowed to land on.
    // Every registry entry in ClipEffects.cpp is inherently one or the
    // other (a video top-effect/GstFramePositioner property simply
    // doesn't exist on an audio track's GESAudioUriSource, and vice
    // versa for "volume") - dropping/applying the wrong type wouldn't
    // silently do nothing, it would fail inside GES. Enforced in both
    // the drag-drop path (TimelineClip.qml's DropArea) and the "+"/
    // selection path (TimelinePanel.applyPresetToClips() filters its
    // target list by this).
    //
    // Three top-level categories. Within a category an item may carry a
    // `group` (a second, nested expand/collapse level - see buildRows()):
    // "Video Effects" keeps the old "Color"/"Compositing" split that way,
    // the other two categories are flat (no `group` on their items).
    //
    // The "Titles" category's single entry is NOT an effect at all - it
    // has `kind: "title"` instead of a type/params pair, no "+" button,
    // and its drag carries the "new-title-clip" key, which only
    // TimelineDropArea (the timeline's track-area drop target) accepts:
    // dropping it CREATES a new title clip, it never applies anything to
    // an existing clip.
    readonly property var categories: [
        { name: "Video Effects", items: [
            { group: "Color", type: "colorbalance", name: "Color Balance", mediaType: "video",
              params: { brightness: 0.0, contrast: 1.0, hue: 0.0, saturation: 1.0 } },
            { group: "Color", type: "gamma", name: "Gamma", mediaType: "video",
              params: { gamma: 1.0 } },
            { group: "Color", type: "lut3d", name: "3D LUT (GPU)", mediaType: "video",
              params: { "lut-file": "", intensity: 1.0 } },
            // Real frei0r brightness/contrast0r filters (via gst-plugins-
            // bad's frei0r wrapper + the frei0r-plugins system package -
            // see ClipEffects.cpp), same param names/semantics/range
            // (0-1, 0.5=no change) as Kdenlive's own UI.
            { group: "Color", type: "brightness", name: "Brightness (frei0r)", mediaType: "video",
              params: { brightness: 0.5 } },
            { group: "Color", type: "contrast", name: "Contrast (frei0r)", mediaType: "video",
              params: { contrast: 0.5 } },
            // GPU tonal curves (Photoshop/Lightroom-style) - see
            // ClipEffects.cpp's "curves" entry / gstglcurves.c. Identity
            // curve on all four channels (master + R/G/B) by default;
            // "curve-points" is a packed control-point STRING (its own
            // GStreamer property's native format, see gstglcurves.c's
            // property doc), not a per-key-numeric param like every
            // other preset here - edited via EffectCurveEditor.qml, not
            // a slider.
            { group: "Color", type: "curves", name: "Curves", mediaType: "video",
              params: { "curve-points": "m:0,0;1,1|r:0,0;1,1|g:0,0;1,1|b:0,0;1,1", intensity: 1.0 } },
            { group: "Compositing", type: "imageoverlay", name: "Image Overlay", mediaType: "video",
              params: { location: "", alpha: 1.0 } },
            { group: "Compositing", type: "colorkey", name: "Chroma Key: Advanced (Colour Selection)", mediaType: "video",
              // Real frei0r select0r params (via gst-plugins-bad's frei0r
              // wrapper + the frei0r-plugins system package - see
              // ClipEffects.cpp) - same names/semantics as Kdenlive's own
              // UI. Defaults: black target, RGB subspace, Ellipsoid shape,
              // inverted (key OUT the target colour, the common case).
              params: { "color-to-select-r": 0.0, "color-to-select-g": 0.0, "color-to-select-b": 0.0,
                         "invert-selection": true,
                         "selection-subspace": 0.0, "subspace-shape": 0.5, "edge-mode": 0.0,
                         "operation": 0.0,
                         "delta-r---a---hue": 0.2, "delta-g---b---chroma": 0.2, "delta-b---i---i": 0.2,
                         "slope": 0.0 } },
            { group: "Compositing", type: "transform", name: "Position and Zoom", mediaType: "video",
              params: { fposx: 0, fposy: 0, fwidth: 0, fheight: 0 } },
            { group: "Compositing", type: "fade", name: "Fade from/to Black", mediaType: "video",
              // "in"/"out" are durations in seconds, anchored to the
              // clip's own start/end respectively (0 = no fade on that
              // side) - see ClipEffects.cpp's applyFade().
              params: { "in": 1.0, "out": 1.0 } }
        ] },
        { name: "Audio Effects", items: [
            // Linear amplitude multiplier (1.0=unity/no change), NOT
            // dB - see ClipEffects.cpp's "volume" registry entry.
            { type: "volume", name: "Volume", mediaType: "audio",
              params: { volume: 1.0 } }
        ] },
        { name: "Titles", items: [
            // Drag-only "clip generator" entry (see the block comment
            // above): dropped on a video track it stamps a fresh
            // GESTitleClip with Backend.defaultTitleParams(), which the
            // Title inspector then edits.
            { kind: "title", name: "Title", mediaType: "video" }
        ] }
    ]

    property string searchText: ""
    // name -> bool. Absent (undefined) means "expanded" (the default) -
    // see expanded() below. Plain JS object, not a ListModel - mutating
    // it doesn't trigger QML's dependency tracking on its own, hence
    // expandRevision (same pattern/reason as TimelinePanel's
    // effectsRevision: a binding that reads this object through a
    // function call needs an explicit property to depend on).
    property var expandedState: ({})
    property int expandRevision: 0

    function isExpanded(categoryName) {
        return root.expandedState[categoryName] !== false
    }

    function toggleCategory(categoryName) {
        root.expandedState[categoryName] = !root.isExpanded(categoryName)
        root.expandRevision++
    }

    function buildRows() {
        var rows = []
        var q = root.searchText.trim().toLowerCase()
        for (var c = 0; c < root.categories.length; c++) {
            var cat = root.categories[c]
            var matched = []
            for (var i = 0; i < cat.items.length; i++) {
                if (q === "" || cat.items[i].name.toLowerCase().indexOf(q) !== -1)
                    matched.push(cat.items[i])
            }
            // While searching, a category with no matches just disappears
            // rather than showing an empty, pointless expand arrow.
            if (q !== "" && matched.length === 0) continue
            var expanded = q !== "" ? true : root.isExpanded(cat.name)
            rows.push({ rowType: "category", name: cat.name, expanded: expanded })
            if (expanded) {
                // Second (optional) level: consecutive items sharing the
                // same `group` get one collapsible sub-header. Items with
                // no `group` (Audio Effects, Titles) render directly under
                // the category, exactly as before.
                var curGroup = ""
                var groupOpen = true
                for (var j = 0; j < matched.length; j++) {
                    var g = matched[j].group || ""
                    if (g !== curGroup) {
                        curGroup = g
                        if (g !== "") {
                            var gkey = cat.name + "/" + g
                            groupOpen = q !== "" ? true : root.isExpanded(gkey)
                            rows.push({ rowType: "group", name: g, key: gkey, expanded: groupOpen })
                        } else {
                            groupOpen = true
                        }
                    }
                    if (groupOpen)
                        rows.push({ rowType: "item", preset: matched[j] })
                }
            }
        }
        return rows
    }

    // The two leading reads force this binding to depend on searchText
    // and expandRevision even though buildRows() re-reads them itself -
    // without it, edits to either would never re-trigger ListView.model.
    readonly property var rows: (root.searchText, root.expandRevision, root.buildRows())

    // What an un-targeted gesture (row click / "+" button) applies to -
    // the full multi-selection if there is one, else the single
    // selectedClipId. Safe to call even before TimelinePanel gains
    // selectedClipIds (multi-select) - the guard just falls through.
    function targetClipIds() {
        if (timelinePanel && timelinePanel.selectedClipIds && timelinePanel.selectedClipIds.length > 0)
            return timelinePanel.selectedClipIds.slice()
        return root.selectedClipId !== "" ? [root.selectedClipId] : []
    }

    // "HH:MM:SS.mmm" - the duration format TimelinePanel.durationToSeconds()
    // (and therefore TimelineDropArea) expects, same as a bin item's.
    function titleDurationString() {
        var secs = (root.timelinePanel && root.timelinePanel.defaultTitleDuration)
                   ? root.timelinePanel.defaultTitleDuration : 5.0
        var h = Math.floor(secs / 3600)
        var m = Math.floor((secs % 3600) / 60)
        var s = secs - h * 3600 - m * 60
        function p2(n) { return (n < 10 ? "0" : "") + n }
        return p2(h) + ":" + p2(m) + ":" + (s < 10 ? "0" : "") + s.toFixed(3)
    }

    function applyPreset(preset) {
        if (!timelinePanel) return
        timelinePanel.applyPresetToClips(preset, root.targetClipIds())
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 5
        spacing: 5

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            color: "#3d3d3d"
            Text {
                anchors.centerIn: parent
                text: "Effects"
                color: "white"
                font.pixelSize: 13
                font.bold: true
            }
        }

        TextField {
            id: searchField
            Layout.fillWidth: true
            Layout.preferredHeight: 28
            placeholderText: "Search effects..."
            color: "white"
            font.pixelSize: 12
            onTextChanged: root.searchText = text
            // Enter / Esc end typing (the filter text stays).
            onAccepted: Backend.shortcuts.releaseTextFocus()
            Keys.onEscapePressed: Backend.shortcuts.releaseTextFocus()
            background: Rectangle {
                color: "#2d2d2d"
                border.color: "#1d1d1d"
                radius: 3
            }
        }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.rows

            delegate: Loader {
                width: ListView.view.width
                sourceComponent: modelData.rowType === "category" ? categoryRow
                                 : (modelData.rowType === "group" ? groupRow : itemRow)

                property var rowData: modelData

                Component {
                    id: categoryRow
                    Rectangle {
                        height: 28
                        width: parent.width
                        color: catArea.containsMouse ? "#3a3a3a" : "transparent"

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 6
                            spacing: 6
                            Text {
                                text: rowData.expanded ? "▾" : "▸"
                                color: "#aaaaaa"
                                font.pixelSize: 10
                            }
                            Text {
                                text: rowData.name
                                color: "#cccccc"
                                font.pixelSize: 12
                                font.bold: true
                            }
                        }

                        MouseArea {
                            id: catArea
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.toggleCategory(rowData.name)
                        }
                    }
                }

                // Second-level sub-header ("Color"/"Compositing" inside
                // "Video Effects") - same interaction as categoryRow,
                // just indented and non-bold so the two levels read
                // apart at a glance.
                Component {
                    id: groupRow
                    Rectangle {
                        height: 24
                        width: parent.width
                        color: groupArea.containsMouse ? "#343434" : "transparent"

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 18
                            spacing: 6
                            Text {
                                text: rowData.expanded ? "▾" : "▸"
                                color: "#999999"
                                font.pixelSize: 9
                            }
                            Text {
                                text: rowData.name
                                color: "#b0b0b0"
                                font.pixelSize: 11
                            }
                        }

                        MouseArea {
                            id: groupArea
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.toggleCategory(rowData.key)
                        }
                    }
                }

                Component {
                    id: itemRow
                    Rectangle {
                        id: itemRowRoot
                        height: 32
                        width: parent.width
                        color: itemArea.containsMouse ? "#4a4f55" : "transparent"
                        // A "clip generator" row (Titles) isn't applied to
                        // anything, so it is never dimmed and never shows
                        // the "+" button - drag it to the timeline instead.
                        readonly property bool isGenerator: rowData.preset.kind === "title"
                        readonly property bool hasTarget: isGenerator || (root.timelinePanel
                            && root.timelinePanel.hasCompatibleTarget(root.targetClipIds(), rowData.preset.mediaType))
                        opacity: hasTarget ? 1.0 : 0.5

                        // Drag proxy - reparented to workspaceRoot so the
                        // ListView's own clip:true doesn't cut it off,
                        // same construction as ProjectBinPanel.qml's bin-
                        // item drag source (the established pattern in
                        // this codebase - see that file for the fuller
                        // write-up of why a separate reparented proxy is
                        // needed at all).
                        Item {
                            id: dragProxy
                            parent: root.workspaceRoot
                            visible: itemArea.dragActive
                            width: 160; height: 28
                            z: 10000

                            Drag.active: itemArea.dragActive
                            Drag.dragType: Drag.Internal
                            Drag.supportedActions: Qt.CopyAction
                            // Two different drags share this one proxy:
                            //  - "effect-preset" -> TimelineClip.qml's
                            //    DropArea (apply onto THAT clip).
                            //  - "new-title-clip" -> TimelineDropArea.qml
                            //    (the track area; CREATE a title clip).
                            // Distinct keys, so neither target can ever
                            // see the other's drag.
                            Drag.keys: itemRowRoot.isGenerator ? ["new-title-clip"] : ["effect-preset"]
                            Drag.hotSpot.x: 12
                            Drag.hotSpot.y: height / 2
                            // The preset objects in root.categories are
                            // plain JSON-safe literals, so this round-
                            // trips losslessly - the drop side needs no
                            // registry lookup, just JSON.parse().
                            // The title drag instead speaks the SAME
                            // "application/x-video-clip" payload a
                            // Project Bin item drag uses, so
                            // TimelineDropArea's existing preview +
                            // clipKind==="title" placement code works
                            // unchanged (itemId is deliberately absent -
                            // the drop creates the bin item itself).
                            Drag.mimeData: itemRowRoot.isGenerator
                                ? ({
                                    "text/plain": rowData.preset.name,
                                    "application/x-video-clip": JSON.stringify({
                                        clipKind: "title",
                                        itemName: "Title",
                                        itemPath: "",
                                        duration: root.titleDurationString(),
                                        hasVideo: true,
                                        hasAudio: false
                                    })
                                })
                                : ({
                                    "text/plain": rowData.preset.name,
                                    "application/x-effect-preset": JSON.stringify(rowData.preset)
                                })

                            Rectangle {
                                anchors.fill: parent
                                color: "#5a9eff"
                                opacity: 0.85
                                radius: 4
                                Text {
                                    anchors.centerIn: parent
                                    text: "+ " + rowData.preset.name
                                    color: "white"
                                    font.pixelSize: 11
                                    elide: Text.ElideRight
                                    width: parent.width - 8
                                }
                            }
                        }

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 24
                            anchors.right: plusButton.left
                            anchors.rightMargin: 4
                            anchors.verticalCenter: parent.verticalCenter
                            text: rowData.preset.name
                            color: "white"
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }

                        MouseArea {
                            id: itemArea
                            anchors.fill: parent
                            hoverEnabled: true
                            // Inside the preset ListView (a Flickable) -
                            // without this, any drag gesture (even a
                            // purely horizontal one, which a drag-to-
                            // timeline move usually isn't) risks the
                            // ListView stealing the grab mid-gesture,
                            // same class of bug fixed for the keyframe
                            // editor earlier this session. Trade-off:
                            // drag-to-scroll this list no longer works -
                            // acceptable, it's ~10 rows, and the wheel
                            // still scrolls it.
                            preventStealing: true

                            property bool dragActive: false
                            property point dragStartPos

                            onPressed: function(mouse) {
                                dragStartPos = Qt.point(mouse.x, mouse.y)
                                dragActive = false
                                if (root.workspaceRoot) {
                                    var g = mapToItem(root.workspaceRoot, mouse.x, mouse.y)
                                    dragProxy.x = g.x - dragProxy.Drag.hotSpot.x
                                    dragProxy.y = g.y - dragProxy.Drag.hotSpot.y
                                }
                            }
                            onPositionChanged: function(mouse) {
                                if (!pressed || !root.workspaceRoot) return
                                var g = mapToItem(root.workspaceRoot, mouse.x, mouse.y)
                                dragProxy.x = g.x - dragProxy.Drag.hotSpot.x
                                dragProxy.y = g.y - dragProxy.Drag.hotSpot.y
                                if (!dragActive) {
                                    var dx = mouse.x - dragStartPos.x, dy = mouse.y - dragStartPos.y
                                    if (Math.sqrt(dx * dx + dy * dy) > 5) {
                                        dragActive = true
                                        dragProxy.Drag.start()
                                    }
                                }
                            }
                            onReleased: {
                                if (dragActive) dragProxy.Drag.drop()
                                dragActive = false
                            }
                            onCanceled: { dragActive = false }
                            // Deliberately NO onClicked here - a plain
                            // click on the row does nothing by design
                            // (explicit user request: only the "+"
                            // button or an actual drag-drop should apply
                            // an effect, not an easy-to-trigger-by-
                            // accident bare click). Hover highlight
                            // (this MouseArea's containsMouse, used by
                            // itemRowRoot's color above) and the drag
                            // gesture are this MouseArea's only jobs now.
                        }

                        // Explicit "add this" affordance, separate from the
                        // row's own click - requested so an effect can be
                        // added without first hunting for the right clip
                        // selection state; same codepath as the row click
                        // (root.applyPreset()), just a second entry point.
                        Rectangle {
                            id: plusButton
                            anchors.right: parent.right
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            width: 20; height: 20
                            radius: 3
                            color: plusArea.containsMouse ? "#5a9eff" : "#3a3a3a"

                            Text {
                                anchors.centerIn: parent
                                text: "+"
                                color: "white"
                                font.pixelSize: 14
                                font.bold: true
                            }

                            visible: !itemRowRoot.isGenerator && (itemArea.containsMouse || plusArea.containsMouse)

                            MouseArea {
                                id: plusArea
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: itemRowRoot.hasTarget
                                onClicked: root.applyPreset(rowData.preset)
                            }

                            ToolTip.visible: plusArea.containsMouse
                            ToolTip.text: "Add to selected clip(s)"
                            ToolTip.delay: 400
                        }
                    }
                }
            }
        }
    }
}
