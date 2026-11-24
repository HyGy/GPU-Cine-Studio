import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import "../components"

// Per-clip ordered effect stack: enable toggle, reorder, delete, and
// live parameter sliders. Reordering/enabling/deleting are instant
// (wrapped in a single undoable edit each) - only numeric parameter
// drags use the gesture idiom (EffectParamSlider.qml), since those are
// the only ones that fire many times per interaction.
Rectangle {
    id: root

    SplitView.minimumWidth: 260
    SplitView.preferredWidth: 580
    color: palette.window
    border.color: "#1d1d1d"
    border.width: 1

    property string selectedClipId: ""
    property var timelinePanel: null
    property var timelineEngine: null

    // param name -> {from, to} slider range. Params not listed here
    // (string paths - lut-file, location) get a text field instead.
    readonly property var paramRanges: ({
        "colorbalance.brightness": { from: -1, to: 1 },
        "colorbalance.contrast":   { from: 0,  to: 2 },
        "colorbalance.hue":        { from: -1, to: 1 },
        "colorbalance.saturation": { from: 0,  to: 2 },
        "gamma.gamma":             { from: 0.01, to: 10 },
        "lut3d.intensity":         { from: 0,  to: 1 },
        "imageoverlay.alpha":      { from: 0,  to: 1 },
        // Real frei0r select0r params (see ClipEffects.cpp) - all 0-1
        // doubles/floats, matching Kdenlive's own UI ranges exactly.
        "colorkey.selection-subspace":   { from: 0, to: 1 }, // 0=RGB 0.5=ABI 1=HCI
        "colorkey.subspace-shape":       { from: 0, to: 1 }, // 0=Box 0.5=Ellipsoid 1=Diamond
        "colorkey.edge-mode":            { from: 0, to: 1 },
        "colorkey.operation":            { from: 0, to: 1 },
        "colorkey.delta-r---a---hue":    { from: 0, to: 1 },
        "colorkey.delta-g---b---chroma": { from: 0, to: 1 },
        "colorkey.delta-b---i---i":      { from: 0, to: 1 },
        "colorkey.slope":                { from: 0, to: 1 },
        // fposx/fposy/fwidth/fheight are project-pixel coordinates, not
        // normalized - range is generous rather than exact since a
        // pan/zoom rect can legitimately exceed the frame on any side.
        "transform.fposx":  { from: -4000, to: 4000 },
        "transform.fposy":  { from: -4000, to: 4000 },
        "transform.fwidth":  { from: 0, to: 8000 },
        "transform.fheight": { from: 0, to: 8000 },
        // Durations in seconds, anchored to the clip's own start/end -
        // see ClipEffects.cpp's applyFade(). 0 = no fade on that side.
        "fade.in":  { from: 0, to: 10 },
        "fade.out": { from: 0, to: 10 },
        // Real frei0r brightness/contrast0r params - 0-1, 0.5=no change,
        // same range as Kdenlive's own UI (see ClipEffects.cpp).
        "brightness.brightness": { from: 0, to: 1 },
        "contrast.contrast":     { from: 0, to: 1 },
        // Linear amplitude multiplier (1.0=unity) - up to 2.0 (+6dB)
        // covers most practical gain-up use; GStreamer itself allows up
        // to 10.0 if ever needed.
        "volume.volume":         { from: 0, to: 2 },
        // GPU tonal curves (see ClipEffects.cpp/gstglcurves.c) - its
        // other param, "curve-points", is dispatched to EffectCurveEditor
        // below (isCurveParam), never reaches this range-based numeric
        // slider lookup at all.
        "curves.intensity":      { from: 0, to: 1 }
    })

    readonly property var effectNames: ({
        colorbalance: "Color Balance",
        gamma: "Gamma",
        lut3d: "3D LUT (GPU)",
        imageoverlay: "Image Overlay",
        colorkey: "Chroma Key: Advanced (Colour Selection)",
        transform: "Position and Zoom",
        fade: "Fade from/to Black",
        brightness: "Brightness (frei0r)",
        contrast: "Contrast (frei0r)",
        volume: "Volume",
        curves: "Curves"
    })

    // Params that must never be driven by a keyframe control source,
    // even though they're plain numbers like any other param:
    // - fade.in/out are durations anchored to the clip's own start/end
    //   (see ClipEffects.cpp's applyFade()), not a value-over-time curve.
    // - colorkey's "enum-as-float" params are frei0r's own encoding of a
    //   mode selector as a quantized double (see TODO.txt) - linearly
    //   interpolating between two modes steps through unrelated,
    //   meaningless intermediate modes rather than a smooth blend.
    readonly property var nonAnimatable: ({
        "fade.in": true, "fade.out": true,
        "colorkey.selection-subspace": true, "colorkey.subspace-shape": true,
        "colorkey.edge-mode": true, "colorkey.operation": true
    })

    // Per-param "is its keyframe editor expanded" state, keyed by
    // "effectId:paramName" and kept on the PANEL (not the Repeater
    // delegate) so it survives the delegate recreation every effects
    // edit causes (currentEffects() returns a fresh array each time,
    // so `model:` below always rebuilds) - otherwise committing a
    // keyframe drag would collapse its own editor.
    property var expandedParams: ({})
    property int expandedRevision: 0
    function isParamExpanded(key) { return !!root.expandedParams[key] }
    function toggleParamExpanded(key) {
        root.expandedParams[key] = !root.isParamExpanded(key)
        root.expandedRevision++
    }
    function expandParam(key) {
        root.expandedParams[key] = true
        root.expandedRevision++
    }

    // Same "survive delegate recreation" reasoning as expandedParams
    // above, for EffectCurveEditor's selected R/G/B/master channel -
    // every point add/move/delete commits through setClipEffects(),
    // which rebuilds this Repeater, which would otherwise reset the
    // editor's local activeChannel back to its "m" default on every
    // single edit (reported: switching to R, editing a point, snapping
    // back to RGB on release).
    property var curveActiveChannel: ({})
    property int curveChannelRevision: 0
    function getCurveActiveChannel(key) { return root.curveActiveChannel[key] || "m" }
    function setCurveActiveChannel(key, channel) {
        root.curveActiveChannel[key] = channel
        root.curveChannelRevision++
    }

    // "Fit to frame" row of the transform effect: its controls start from the
    // project default each time another clip is selected.
    property string fitScaling: "fit"
    property string fitAnchorH: "center"
    property string fitAnchorV: "center"
    function resetFitControls() {
        if (!timelinePanel) return
        var d = timelinePanel.fitDefaults()
        fitScaling = d.scaling; fitAnchorH = d.ah; fitAnchorV = d.av
    }
    onSelectedClipIdChanged: resetFitControls()
    onTimelinePanelChanged: resetFitControls()

    // Overwrites the clip's static position/size with the chosen fit. One
    // undo step (writeEffects). Returns false when it cannot apply.
    function applyFit(effectIndex) {
        var cv = timelinePanel ? timelinePanel.projectCanvasSize() : null
        var src = timelinePanel ? timelinePanel.clipSourceSize(root.selectedClipId) : null
        if (!cv || !src) return false
        var r = timelinePanel.computeFitRect(src.w, src.h, cv.w, cv.h, fitScaling, fitAnchorH, fitAnchorV)
        var effects = currentEffects()
        var p = effects[effectIndex].params
        p.fposx = r.fposx; p.fposy = r.fposy; p.fwidth = r.fwidth; p.fheight = r.fheight
        writeEffects(effects, "Fit to frame")
        return true
    }

    function currentEffects() {
        if (!timelinePanel || root.selectedClipId === "") return []
        return timelinePanel.clipEffects(root.selectedClipId)
    }

    function writeEffects(effects, label) {
        timelinePanel.beginUndoableEdit()
        timelinePanel.setClipEffects(root.selectedClipId, effects, true)
        timelinePanel.commitUndoableEdit(label)
    }

    function toggleEnabled(index) {
        var effects = currentEffects()
        effects[index].enabled = !effects[index].enabled
        writeEffects(effects, "Toggle effect")
    }

    function removeEffect(index) {
        var effects = currentEffects()
        var name = root.effectNames[effects[index].type] || effects[index].type
        effects.splice(index, 1)
        writeEffects(effects, "Remove " + name)
    }

    function moveEffect(index, delta) {
        var effects = currentEffects()
        var j = index + delta
        if (j < 0 || j >= effects.length) return
        var tmp = effects[index]
        effects[index] = effects[j]
        effects[j] = tmp
        writeEffects(effects, "Reorder effects")
    }

    FileDialog {
        id: pathPickerDialog
        property int targetEffectIndex: -1
        property string targetParam: ""
        onAccepted: {
            var effects = root.currentEffects()
            effects[targetEffectIndex].params[targetParam] = selectedFile.toString().replace("file://", "")
            root.writeEffects(effects, "Set " + targetParam)
        }
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
                text: "Effect Stack"
                color: "white"
                font.pixelSize: 13
                font.bold: true
            }
        }

        Text {
            Layout.fillWidth: true
            visible: root.selectedClipId === ""
            text: "Select a clip to see its effects."
            color: "#888888"
            font.pixelSize: 11
            wrapMode: Text.WordWrap
        }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.selectedClipId !== ""
            clip: true
            spacing: 6
            // Re-reads on every relevant model/selection change - the
            // effect stack is small (a handful of entries per clip), so
            // re-deriving the whole array is simpler and safer than
            // trying to keep an incremental ListModel in sync with the
            // JSON string stored on the clip row.
            //
            // The `root.timelinePanel.effectsRevision,` is a deliberate
            // forced dependency, not dead code: currentEffects() reads
            // the clip's effects through ListModel.get(), which QML's
            // binding tracker can't see into, so without reading this
            // counter the binding would never re-evaluate after the
            // first setClipEffects() call.
            //
            // Scroll position: assigning a new array rebuilds the delegates
            // and resets contentY. effectsRebuild() saves contentY first and
            // restores it (clamped) right after the synchronous relayout; it
            // only goes back to the top when the selected clip changed.
            id: effectList
            property string shownClipId: ""
            property int rev: root.timelinePanel ? root.timelinePanel.effectsRevision : 0
            function effectsRebuild() {
                var keep = (shownClipId === root.selectedClipId)
                var y = effectList.contentY
                shownClipId = root.selectedClipId
                effectList.model = root.currentEffects()
                effectList.forceLayout()
                if (keep) {
                    var maxY = Math.max(0, effectList.contentHeight - effectList.height)
                    effectList.contentY = Math.min(y, maxY)
                } else {
                    effectList.positionViewAtBeginning()
                }
            }
            onRevChanged: effectsRebuild()
            Connections {
                target: root
                function onSelectedClipIdChanged() { effectList.effectsRebuild() }
            }
            Component.onCompleted: effectsRebuild()
            ScrollBar.vertical: ScrollBar {
                id: effVBar
                policy: ScrollBar.AlwaysOn
                width: 12
                contentItem: Rectangle {
                    implicitWidth: 12
                    radius: 4
                    color: effVBar.pressed ? "#9aa0a6" : "#6b7075"
                }
                background: Rectangle { color: "#1c1f22" }
            }

            delegate: Rectangle {
                id: effectDelegate
                // Captured once, outside any nested Repeater scope, so
                // the inner param-list Repeater below (which has its own
                // `index`/`modelData` for the param name string) never
                // shadows the effect's own index/data.
                property int effectIndex: index
                property var effectData: modelData

                width: ListView.view.width - 16
                height: headerRow.height + paramsCol.height + 10
                color: "#2d2d2d"
                radius: 3
                border.color: "#1d1d1d"

                ColumnLayout {
                    id: contentCol
                    anchors.fill: parent
                    anchors.margins: 5
                    spacing: 4

                    RowLayout {
                        id: headerRow
                        Layout.fillWidth: true
                        spacing: 4

                        CheckBox {
                            checked: effectDelegate.effectData.enabled
                            onToggled: root.toggleEnabled(effectDelegate.effectIndex)
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.effectNames[effectDelegate.effectData.type] || effectDelegate.effectData.type
                            color: effectDelegate.effectData.enabled ? "white" : "#888888"
                            font.pixelSize: 12
                            font.bold: true
                        }
                        Button {
                            text: "▲"
                            implicitWidth: 24; implicitHeight: 24
                            enabled: effectDelegate.effectIndex > 0
                            onClicked: root.moveEffect(effectDelegate.effectIndex, -1)
                        }
                        Button {
                            text: "▼"
                            implicitWidth: 24; implicitHeight: 24
                            enabled: effectDelegate.effectIndex < root.currentEffects().length - 1
                            onClicked: root.moveEffect(effectDelegate.effectIndex, 1)
                        }
                        Button {
                            text: "✕"
                            implicitWidth: 24; implicitHeight: 24
                            onClicked: root.removeEffect(effectDelegate.effectIndex)
                        }
                    }

                    ColumnLayout {
                        id: paramsCol
                        Layout.fillWidth: true
                        spacing: 2

                        // Fit to frame (transform only)
                        ColumnLayout {
                            id: fitRow
                            objectName: "fitToFrameRow"
                            visible: effectDelegate.effectData.type === "transform"
                            Layout.fillWidth: true
                            Layout.preferredHeight: visible ? implicitHeight : 0
                            spacing: 3
                            readonly property var fitCanvas: (root.timelinePanel ? root.timelinePanel.effectsRevision : 0, root.timelinePanel ? root.timelinePanel.projectCanvasSize() : null)
                            readonly property var fitSrc: (root.timelinePanel ? root.timelinePanel.effectsRevision : 0, root.timelinePanel ? root.timelinePanel.clipSourceSize(root.selectedClipId) : null)
                            readonly property bool animatedGeometry: {
                                var p = effectDelegate.effectData.params
                                var names = ["fposx", "fposy", "fwidth", "fheight"]
                                for (var i = 0; i < names.length; i++) {
                                    var v = p[names[i]]
                                    if (v !== undefined && v !== null && typeof v === "object") return true
                                }
                                return false
                            }
                            readonly property string whyDisabled: animatedGeometry
                                ? "Position and size are keyframed - remove the keyframes first, Fit to frame sets static values."
                                : (!fitSrc ? "The source size of this clip is not known (no media metadata)."
                                   : (!fitCanvas ? "The project frame size is not set yet (auto profile)." : ""))
                            Text { text: "Fit to frame"; color: "#cccccc"; font.pixelSize: 11; font.bold: true }
                            FitControls {
                                Layout.fillWidth: true
                                showExplanation: false
                                textColor: "#dddddd"; dimColor: "#999999"
                                panelColor: "#3a3a3a"; borderColor: "#555555"
                                scaling: root.fitScaling
                                anchorH: root.fitAnchorH
                                anchorV: root.fitAnchorV
                                onScalingChanged: root.fitScaling = scaling
                                onAnchorHChanged: root.fitAnchorH = anchorH
                                onAnchorVChanged: root.fitAnchorV = anchorV
                            }
                            Button {
                                objectName: "fitApplyBtn"
                                text: "Apply"
                                implicitHeight: 24
                                enabled: fitRow.whyDisabled === ""
                                ToolTip.visible: hovered && fitRow.whyDisabled !== ""
                                ToolTip.text: fitRow.whyDisabled
                                onClicked: root.applyFit(effectDelegate.effectIndex)
                            }
                        }

                        Repeater {
                            model: Object.keys(effectDelegate.effectData.params)
                            delegate: Item {
                                id: paramItem
                                // This Repeater's own `index`/`modelData`
                                // (the param name string) intentionally
                                // shadow the outer effect delegate's -
                                // everything about the OUTER effect is
                                // reached through effectDelegate.* instead.
                                Layout.fillWidth: true
                                implicitHeight: paramItem.isColorTarget ? (colorSwatchRow.visible ? colorSwatchRow.implicitHeight : 0)
                                              : paramItem.isCurveParam ? curveRow.implicitHeight
                                              : paramItem.isBoolParam ? boolRow.implicitHeight
                                              : paramItem.isAnimated ? animatedCol.implicitHeight
                                              : pathRow.visible ? pathRow.implicitHeight : numericRow.implicitHeight

                                readonly property string paramName: modelData
                                readonly property string paramKey: effectDelegate.effectData.type + "." + paramName
                                readonly property var range: root.paramRanges[paramKey]
                                readonly property bool isAnimatable: paramItem.range !== undefined && !root.nonAnimatable[paramKey]
                                readonly property string expandKey: effectDelegate.effectData.id + ":" + paramName
                                // Forces a dependency on expandedRevision even
                                // though it's read through a plain function call -
                                // same pattern as effectsRevision elsewhere in
                                // this file, see its comment.
                                readonly property bool expanded: (root.expandedRevision, root.isParamExpanded(expandKey))
                                // colorkey's color-to-select-r/g/b are one RGB
                                // color, not three independent scalars - picked
                                // together via a single swatch (rendered once,
                                // on -r; -g/-b render nothing here at all).
                                readonly property bool isColorTarget:
                                    effectDelegate.effectData.type === "colorkey"
                                    && (paramName === "color-to-select-r" || paramName === "color-to-select-g" || paramName === "color-to-select-b")
                                readonly property bool isColorSwatchPrimary: isColorTarget && paramName === "color-to-select-r"
                                // The GPU curves effect's control-point
                                // string - rendered as the interactive
                                // EffectCurveEditor graph below, never as
                                // a slider (it's not a range-bound
                                // number) or the path-picker row (it's
                                // not a file path either, even though it
                                // IS a string - paramItem.range stays
                                // undefined for it on purpose, same as a
                                // path param, which is why both
                                // numericRow and pathRow below must
                                // additionally exclude isCurveParam).
                                readonly property bool isCurveParam:
                                    effectDelegate.effectData.type === "curves" && paramName === "curve-points"
                                readonly property bool isBoolParam:
                                    typeof effectDelegate.effectData.params[paramName] === "boolean"
                                // An animated param (ClipEffects.cpp's
                                // {"kf":[{t,v},...]} shape, see applyAnimation())
                                // is a JS object, not a plain number - the
                                // slider below expects a number and would
                                // render broken/NaN on one, and pathRow would
                                // show it as "[object Object]" with a
                                // meaningless file-picker button. v1 has no
                                // in-app keyframe editor (see TODO.txt) so
                                // this is a read-only indicator, not yet
                                // editable here.
                                readonly property bool isAnimated: {
                                    var v = effectDelegate.effectData.params[paramName]
                                    return !!v && typeof v === "object" && v.kf !== undefined
                                }

                                RowLayout {
                                    id: numericRow
                                    visible: !paramItem.isColorTarget && !paramItem.isCurveParam && !paramItem.isBoolParam && !paramItem.isAnimated && paramItem.range !== undefined
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    spacing: 2

                                    EffectParamSlider {
                                        id: paramSlider
                                        Layout.fillWidth: true
                                        timelinePanel: root.timelinePanel
                                        timelineEngine: root.timelineEngine
                                        clipId: root.selectedClipId
                                        effectId: effectDelegate.effectData.id
                                        paramName: paramItem.paramName
                                        label: paramItem.paramName
                                        from: paramItem.range ? paramItem.range.from : 0
                                        to: paramItem.range ? paramItem.range.to : 1
                                        value: effectDelegate.effectData.params[paramItem.paramName]
                                    }
                                    Button {
                                        text: "◆"
                                        visible: paramItem.isAnimatable
                                        implicitWidth: 20; implicitHeight: 20
                                        ToolTip.visible: hovered
                                        ToolTip.text: "Animate with keyframes"
                                        onClicked: {
                                            // Starts a 1-point curve at the
                                            // playhead's position within this
                                            // clip (clamped into it), holding
                                            // the param's current value - the
                                            // keyframe editor opens with
                                            // something sensible to drag from
                                            // rather than an empty plot.
                                            //
                                            // Capture the expand key and mark
                                            // it expanded BEFORE writeEffects():
                                            // that call bumps effectsRevision,
                                            // which rebuilds this very Repeater
                                            // (currentEffects() returns a fresh
                                            // array each time) - effectDelegate/
                                            // paramItem below may already be a
                                            // stale, about-to-be-destroyed
                                            // instance by the time a statement
                                            // AFTER writeEffects() runs, which
                                            // was silently losing this call
                                            // entirely (reported: the editor
                                            // never auto-opened).
                                            var key = effectDelegate.effectData.id + ":" + paramItem.paramName
                                            root.expandParam(key)

                                            var effects = root.currentEffects()
                                            var clipT = root.timelinePanel ? root.timelinePanel.clipTiming(root.selectedClipId) : null
                                            var mediaT = 0
                                            if (clipT && root.timelineEngine) {
                                                mediaT = (root.timelineEngine.position / 1000) - clipT.startTime + clipT.sourceOffset
                                                mediaT = Math.max(clipT.sourceOffset, Math.min(clipT.sourceOffset + clipT.durationSeconds, mediaT))
                                            }
                                            var v = effectDelegate.effectData.params[paramItem.paramName]
                                            effects[effectDelegate.effectIndex].params[paramItem.paramName] = { kf: [{ t: mediaT, v: v }] }
                                            root.writeEffects(effects, "Animate " + paramItem.paramName)
                                        }
                                    }
                                }

                                RowLayout {
                                    id: boolRow
                                    visible: paramItem.isBoolParam
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    spacing: 6
                                    CheckBox {
                                        text: paramItem.paramName
                                        checked: !!effectDelegate.effectData.params[paramItem.paramName]
                                        onToggled: {
                                            var effects = root.currentEffects()
                                            effects[effectDelegate.effectIndex].params[paramItem.paramName] = checked
                                            root.writeEffects(effects, "Set " + paramItem.paramName)
                                        }
                                        contentItem: Text {
                                            text: parent.text; color: "#cccccc"; font.pixelSize: 11
                                            leftPadding: parent.indicator.width + 6
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                    }
                                }

                                RowLayout {
                                    id: colorSwatchRow
                                    visible: paramItem.isColorSwatchPrimary
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    spacing: 6

                                    Text { text: "color"; color: "#cccccc"; font.pixelSize: 11; Layout.preferredWidth: 70 }
                                    Rectangle {
                                        Layout.preferredWidth: 22; Layout.preferredHeight: 22
                                        radius: 3
                                        border.color: "#555"; border.width: 1
                                        // select0r's color-to-select-* are
                                        // already normalized 0-1 floats -
                                        // Qt.rgba() wants exactly that, no
                                        // /255 conversion needed (unlike the
                                        // old target-r/g/b 0-255 ints).
                                        color: Qt.rgba(
                                            effectDelegate.effectData.params["color-to-select-r"],
                                            effectDelegate.effectData.params["color-to-select-g"],
                                            effectDelegate.effectData.params["color-to-select-b"], 1)
                                        MouseArea {
                                            anchors.fill: parent
                                            onClicked: {
                                                colorPicker.selectedColor = parent.color
                                                colorPicker.open()
                                            }
                                        }
                                    }
                                    Button {
                                        text: "Pick Color..."
                                        implicitHeight: 24
                                        onClicked: {
                                            colorPicker.selectedColor = Qt.rgba(
                                                effectDelegate.effectData.params["color-to-select-r"],
                                                effectDelegate.effectData.params["color-to-select-g"],
                                                effectDelegate.effectData.params["color-to-select-b"], 1)
                                            colorPicker.open()
                                        }
                                        background: Rectangle { color: "#4a4f55"; radius: 2 }
                                        contentItem: Text { text: parent.text; color: "white"; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                    }
                                    Item { Layout.fillWidth: true }

                                    ColorDialog {
                                        id: colorPicker
                                        title: "Pick Color to Key Out"
                                        onAccepted: {
                                            var effects = root.currentEffects()
                                            effects[effectDelegate.effectIndex].params["color-to-select-r"] = selectedColor.r
                                            effects[effectDelegate.effectIndex].params["color-to-select-g"] = selectedColor.g
                                            effects[effectDelegate.effectIndex].params["color-to-select-b"] = selectedColor.b
                                            root.writeEffects(effects, "Set Colour to select")
                                        }
                                    }
                                }

                                ColumnLayout {
                                    id: animatedCol
                                    visible: paramItem.isAnimated
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    spacing: 2

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 4

                                        Button {
                                            text: paramItem.expanded ? "▾" : "▸"
                                            implicitWidth: 18; implicitHeight: 18
                                            background: Rectangle { color: "transparent" }
                                            contentItem: Text { text: parent.text; color: "#cccccc"; font.pixelSize: 10; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                            onClicked: root.toggleParamExpanded(paramItem.expandKey)
                                        }
                                        Text {
                                            text: paramItem.paramName
                                            color: "#cccccc"
                                            font.pixelSize: 11
                                            Layout.preferredWidth: 60
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: {
                                                var v = effectDelegate.effectData.params[paramItem.paramName]
                                                var n = (v && v.kf) ? v.kf.length : 0
                                                return "animated (" + n + " keyframes)"
                                            }
                                            color: "#888888"
                                            font.pixelSize: 10
                                            font.italic: true
                                        }
                                        Button {
                                            text: "✕"
                                            implicitWidth: 18; implicitHeight: 18
                                            ToolTip.visible: hovered
                                            ToolTip.text: "Remove animation (keep current value)"
                                            onClicked: {
                                                var effects = root.currentEffects()
                                                var v = effectDelegate.effectData.params[paramItem.paramName]
                                                var kfArr = (v && v.kf) ? v.kf : []
                                                // Sample at the first keyframe rather
                                                // than picking an arbitrary point -
                                                // closest thing to "what it looked
                                                // like before any automation played".
                                                var staticValue = kfArr.length > 0 ? kfArr[0].v : paramItem.range.from
                                                effects[effectDelegate.effectIndex].params[paramItem.paramName] = staticValue
                                                root.writeEffects(effects, "Remove animation")
                                            }
                                        }
                                    }

                                    EffectKeyframeEditor {
                                        Layout.fillWidth: true
                                        visible: paramItem.expanded
                                        timelinePanel: root.timelinePanel
                                        timelineEngine: root.timelineEngine
                                        clipId: root.selectedClipId
                                        effectId: effectDelegate.effectData.id
                                        paramName: paramItem.paramName
                                        from: paramItem.range ? paramItem.range.from : 0
                                        to: paramItem.range ? paramItem.range.to : 1
                                        keyframes: {
                                            var v = effectDelegate.effectData.params[paramItem.paramName]
                                            return (v && v.kf) ? v.kf : []
                                        }
                                    }
                                }

                                RowLayout {
                                    id: curveRow
                                    visible: paramItem.isCurveParam
                                    anchors.left: parent.left
                                    anchors.right: parent.right

                                    EffectCurveEditor {
                                        Layout.fillWidth: true
                                        timelinePanel: root.timelinePanel
                                        timelineEngine: root.timelineEngine
                                        clipId: root.selectedClipId
                                        effectId: effectDelegate.effectData.id
                                        paramName: paramItem.paramName
                                        value: effectDelegate.effectData.params[paramItem.paramName]
                                        activeChannel: (root.curveChannelRevision, root.getCurveActiveChannel(paramItem.expandKey))
                                        onChannelSelected: function(channel) { root.setCurveActiveChannel(paramItem.expandKey, channel) }
                                    }
                                }

                                RowLayout {
                                    id: pathRow
                                    visible: !paramItem.isColorTarget && !paramItem.isCurveParam && !paramItem.isBoolParam && !paramItem.isAnimated && paramItem.range === undefined
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    spacing: 4

                                    Text {
                                        text: paramItem.paramName
                                        color: "#cccccc"
                                        font.pixelSize: 11
                                        Layout.preferredWidth: 70
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: {
                                            var v = effectDelegate.effectData.params[paramItem.paramName]
                                            return v && v !== "" ? v : "(none)"
                                        }
                                        color: "#888888"
                                        font.pixelSize: 10
                                        elide: Text.ElideMiddle
                                    }
                                    Button {
                                        text: "..."
                                        implicitWidth: 28; implicitHeight: 22
                                        onClicked: {
                                            pathPickerDialog.targetEffectIndex = effectDelegate.effectIndex
                                            pathPickerDialog.targetParam = paramItem.paramName
                                            pathPickerDialog.open()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
