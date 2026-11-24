import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import VideoEditor 1.0

// Phase 1 title editor: a side-panel FORM (no on-canvas editing - that's
// Phase 2 and not approved). Visible only while a title-kind clip is
// selected; EffectInspectorPanel keeps handling ordinary clips.
//
// Live-edit idiom is copied verbatim from EffectParamSlider.qml because
// it's the one proven to work here:
//   * during a drag / while typing, push the value straight to GES via
//     TimelineEngine::setTitleParam() - no clipsModel write, no rebuild
//   * a PAUSED pipeline does NOT repaint just because a property
//     changed (VERIFIED LIVE against GES 1.24.2 - the title source
//     produces no new buffer until a FLUSHING seek), so a debounced
//     seek(position) forces exactly one redraw
//   * only on release / editingFinished write the value into the model
//     and close the undo scope
Rectangle {
    id: root

    color: palette.window
    border.color: "#1d1d1d"
    border.width: 1

    property string selectedClipId: ""
    property var timelinePanel: null
    property var timelineEngine: null

    // --- TWO EDIT TARGETS -------------------------------------------
    // The same form edits either a title CLIP on the timeline or a
    // reusable title ITEM in the Project Bin ("Virtual" group). The
    // timeline clip always wins when one is selected, because that is
    // the thing the user is looking at in the monitor; the bin item is
    // the fallback. Everything below funnels through params/commit/
    // pushLive, so only those three know which target is live.
    readonly property bool clipMode: timelinePanel !== null && selectedClipId !== ""
                                     && timelinePanel.isTitleClip(selectedClipId)
    // A bin item counts as a title target purely by having title params
    // (itemTitleParams returns "" for anything that isn't a title item),
    // so no extra plumbing from the bin panel is needed.
    readonly property string binTitleId: {
        var id = Backend.selectedProjectBinItemId
        if (!id || clipMode) return ""
        return Backend.projectBinModel.itemTitleParams(id) !== "" ? id : ""
    }
    readonly property bool binMode: !clipMode && binTitleId !== ""
    readonly property bool hasTitle: clipMode || binMode

    // Bumped by commit() in bin mode - itemTitleParams() is a plain
    // Q_INVOKABLE call and isn't dependency-tracked, exactly like
    // ListModel.get() on the timeline side (titleParamsRevision).
    property int binParamsRevision: 0

    // Re-read whenever the model blob changes (titleParamsRevision /
    // binParamsRevision) or the selection moves.
    readonly property var params: {
        var _ = timelinePanel ? timelinePanel.titleParamsRevision : 0
        var __ = root.binParamsRevision
        if (clipMode) return timelinePanel.clipTitleParams(selectedClipId) || ({})
        if (binMode) {
            try { return JSON.parse(Backend.projectBinModel.itemTitleParams(binTitleId)) || ({}) }
            catch (e) { console.error("TitleInspectorPanel: corrupt bin titleParams", e); return ({}) }
        }
        return ({})
    }

    function num(key, fallback) {
        var v = root.params[key]
        return (v === undefined || v === null) ? fallback : Number(v)
    }
    function str(key, fallback) {
        var v = root.params[key]
        return (v === undefined || v === null) ? fallback : String(v)
    }
    function flag(key, fallback) {
        var v = root.params[key]
        return (v === undefined || v === null) ? fallback : (v === true)
    }

    // Push to GES only (live preview), no model write. Bin items aren't
    // on the timeline, so there is nothing to preview live - they just
    // wait for commit().
    function pushLive(key, value) {
        if (!timelineEngine || !clipMode) return
        timelineEngine.setTitleParam(selectedClipId, key, value)
        repaintTimer.restart()
    }

    // Model write (+ undo entry and engine re-apply in clip mode).
    function commit(key, value, label) {
        if (clipMode) {
            var p = timelinePanel.clipTitleParams(selectedClipId) || {}
            if (p[key] === value) return
            p[key] = value
            timelinePanel.beginUndoableEdit()
            timelinePanel.setClipTitleParams(selectedClipId, p, true)
            timelinePanel.commitUndoableEdit(label || "Edit title")
        } else if (binMode) {
            // No undo scope: the timeline's undo stack covers timeline
            // state, and a bin item isn't part of it.
            var bp = root.params || {}
            if (bp[key] === value) return
            bp[key] = value
            Backend.projectBinModel.setItemTitleParams(binTitleId, JSON.stringify(bp))
            root.binParamsRevision++
        }
    }

    // See the class comment: forces one repaint of the held frame.
    Timer {
        id: repaintTimer
        interval: 120
        repeat: false
        onTriggered: {
            if (!root.timelineEngine || root.timelineEngine.playing) return
            root.timelineEngine.seek(root.timelineEngine.position)
        }
    }

    // --- ARGB uint <-> QML color -------------------------------------
    // GES/textoverlay colours are big-endian ARGB packed into a uint.
    function argbToColor(v) {
        var n = Math.max(0, Math.round(Number(v) || 0))
        var a = (n >>> 24) & 0xFF, r = (n >>> 16) & 0xFF, g = (n >>> 8) & 0xFF, b = n & 0xFF
        return Qt.rgba(r / 255, g / 255, b / 255, a / 255)
    }
    function colorToArgb(c) {
        var a = Math.round(c.a * 255), r = Math.round(c.r * 255)
        var g = Math.round(c.g * 255), b = Math.round(c.b * 255)
        // >>> 0 keeps it an unsigned 32-bit value: a plain shift would
        // make 0xFF...... negative and the C++ side would clamp it to 0.
        return ((a * 16777216) + (r << 16) + (g << 8) + b) >>> 0
    }

    ColorDialog {
        id: colorPicker
        property string targetKey: ""
        property string targetLabel: ""
        options: ColorDialog.ShowAlphaChannel
        onAccepted: root.commit(targetKey, root.colorToArgb(selectedColor), "Set " + targetLabel)
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 5
        spacing: 6

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            color: "#3d3d3d"
            Text {
                anchors.centerIn: parent
                text: root.binMode ? "Title (Project Bin item)" : "Title"
                color: "white"; font.pixelSize: 13; font.bold: true
            }
        }

        Text {
            Layout.fillWidth: true
            visible: !root.hasTitle
            text: "Select a title clip on the timeline, or a title item in the Project Bin's Virtual group, to edit it."
            color: "#888888"; font.pixelSize: 11; wrapMode: Text.WordWrap
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.hasTitle
            clip: true
            contentWidth: availableWidth

            ColumnLayout {
                width: parent ? parent.width : 0
                spacing: 8

                Text { text: "Text"; color: "#cccccc"; font.pixelSize: 11 }
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 80
                    color: "#1e1e1e"; border.color: "#3a3a3a"
                    TextArea {
                        id: textArea
                        anchors.fill: parent
                        anchors.margins: 2
                        color: "white"
                        wrapMode: TextArea.Wrap
                        selectByMouse: true
                        // Only re-seed from the model when the user isn't
                        // typing - otherwise the commit below would reset
                        // the cursor mid-edit.
                        text: root.str("text", "")
                        onTextChanged: if (activeFocus) root.pushLive("text", text)
                        onEditingFinished: root.commit("text", text, "Set title text")
                        // Enter is a new line here; Esc ends editing (commits).
                        Keys.onEscapePressed: Backend.shortcuts.releaseTextFocus()
                    }
                }

                Text { text: "Font (Pango description)"; color: "#cccccc"; font.pixelSize: 11 }
                TextField {
                    id: fontField
                    Layout.fillWidth: true
                    // "Sans Bold 36" ~= 12% of frame height at ANY project
                    // resolution - the size is resolution-relative, measured
                    // live (see TitleClips.h).
                    placeholderText: "Sans Bold 36"
                    text: root.str("font-desc", "Sans Bold 36")
                    onTextChanged: if (activeFocus) root.pushLive("font-desc", text)
                    onEditingFinished: root.commit("font-desc", text, "Set title font")
                    onAccepted: Backend.shortcuts.releaseTextFocus()
                    Keys.onEscapePressed: Backend.shortcuts.releaseTextFocus()
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text { text: "Text colour"; color: "#cccccc"; font.pixelSize: 11; Layout.preferredWidth: 90 }
                    Rectangle {
                        Layout.preferredWidth: 40; Layout.preferredHeight: 20
                        radius: 3; border.color: "#777"
                        color: root.argbToColor(root.num("color", 4294967295))
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                colorPicker.targetKey = "color"
                                colorPicker.targetLabel = "text colour"
                                colorPicker.selectedColor = parent.color
                                colorPicker.open()
                            }
                        }
                    }
                    Item { Layout.fillWidth: true }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text { text: "Outline colour"; color: "#cccccc"; font.pixelSize: 11; Layout.preferredWidth: 90 }
                    Rectangle {
                        Layout.preferredWidth: 40; Layout.preferredHeight: 20
                        radius: 3; border.color: "#777"
                        color: root.argbToColor(root.num("outline-color", 4278190080))
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                colorPicker.targetKey = "outline-color"
                                colorPicker.targetLabel = "outline colour"
                                colorPicker.selectedColor = parent.color
                                colorPicker.open()
                            }
                        }
                    }
                    Item { Layout.fillWidth: true }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text { text: "Background"; color: "#cccccc"; font.pixelSize: 11; Layout.preferredWidth: 90 }
                    Rectangle {
                        Layout.preferredWidth: 40; Layout.preferredHeight: 20
                        radius: 3; border.color: "#777"
                        color: root.argbToColor(root.num("foreground-color", 0))
                        // "foreground-color" is the videotestsrc's solid
                        // colour = the title card's BACKGROUND. Alpha 0
                        // (the default) is what makes the title an
                        // overlay instead of an opaque card.
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                colorPicker.targetKey = "foreground-color"
                                colorPicker.targetLabel = "background"
                                colorPicker.selectedColor = parent.color
                                colorPicker.open()
                            }
                        }
                    }
                    Button {
                        text: "Transparent"
                        implicitHeight: 22
                        onClicked: root.commit("foreground-color", 0, "Clear title background")
                    }
                    Item { Layout.fillWidth: true }
                }

                CheckBox {
                    text: "Drop shadow"
                    checked: root.flag("draw-shadow", true)
                    onToggled: root.commit("draw-shadow", checked, "Toggle title shadow")
                    contentItem: Text {
                        text: parent.text; color: "#cccccc"; font.pixelSize: 11
                        leftPadding: parent.indicator.width + 4
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                CheckBox {
                    text: "Shaded background behind text"
                    checked: root.flag("shaded-background", false)
                    onToggled: root.commit("shaded-background", checked, "Toggle title shading")
                    contentItem: Text {
                        text: parent.text; color: "#cccccc"; font.pixelSize: 11
                        leftPadding: parent.indicator.width + 4
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                // xpos/ypos are normalised 0..1 of the frame and CLAMPED
                // by textoverlay so the text can never leave the canvas
                // (halignment/valignment are pinned to 4 = "position" by
                // TitleClips::defaultParamsJson). Measured live at
                // 1920x1080: xpos 0.1 -> x=12 px, xpos 0.9 -> x=1488 px.
                TitlePosSlider {
                    Layout.fillWidth: true
                    panel: root
                    paramName: "xpos"
                    label: "X position"
                    value: root.num("xpos", 0.5)
                }
                TitlePosSlider {
                    Layout.fillWidth: true
                    panel: root
                    paramName: "ypos"
                    label: "Y position"
                    value: root.num("ypos", 0.5)
                }
            }
        }
    }
}
