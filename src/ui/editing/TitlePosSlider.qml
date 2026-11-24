import QtQuick
import QtQuick.Controls

// One normalised 0..1 title position parameter (xpos / ypos). Same
// press/drag/release idiom as EffectParamSlider.qml - see the comment
// block at the top of TitleInspectorPanel.qml.
Item {
    id: root

    property var panel: null          // TitleInspectorPanel
    property string paramName: ""
    property string label: paramName
    property real value: 0.5

    property real origValue: value

    implicitHeight: 40
    height: implicitHeight

    Row {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 6
        Text {
            width: 90
            text: root.label
            color: "#cccccc"; font.pixelSize: 11; elide: Text.ElideRight
        }
        Text {
            text: slider.value.toFixed(2)
            color: "#888888"; font.pixelSize: 11
        }
    }

    Slider {
        id: slider
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 18
        from: 0
        to: 1
        value: root.value

        onValueChanged: {
            if (!pressed || !root.panel) return
            root.panel.pushLive(root.paramName, value)
        }

        onPressedChanged: {
            if (!root.panel) return
            // The panel edits either a timeline CLIP or a Project Bin
            // title ITEM. Only the clip case has an undo scope (the
            // timeline's) and a live GES preview; for a bin item the
            // write goes through the panel's own commit(), which knows
            // where to put it.
            var clipMode = root.panel.clipMode
            if (pressed) {
                root.origValue = root.value
                if (clipMode) root.panel.timelinePanel.beginUndoableGesture()
            } else if (Math.abs(value - root.origValue) > 1e-6) {
                if (clipMode) {
                    var p = root.panel.timelinePanel.clipTitleParams(root.panel.selectedClipId) || {}
                    p[root.paramName] = value
                    root.panel.timelinePanel.setClipTitleParams(root.panel.selectedClipId, p, true)
                    root.panel.timelinePanel.commitUndoableEdit("Move title")
                } else {
                    root.panel.commit(root.paramName, value, "Move title")
                }
            } else {
                root.panel.pushLive(root.paramName, root.origValue)
                if (clipMode) root.panel.timelinePanel.abortUndoableEdit()
            }
        }

        // Same implicitWidth/implicitHeight requirement as
        // EffectParamSlider.qml's delegates - without them the Slider's
        // hit rect is empty and the handle is unclickable.
        background: Rectangle {
            implicitWidth: 200
            implicitHeight: 4
            x: slider.leftPadding
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: slider.availableWidth
            height: 4
            radius: 2
            color: "#3a3a3a"
            Rectangle {
                width: slider.visualPosition * parent.width
                height: parent.height
                color: "#3daee9"
                radius: 2
            }
        }
        handle: Rectangle {
            implicitWidth: 14
            implicitHeight: 14
            x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: 14
            height: 14
            radius: 7
            color: slider.pressed ? "#5fc4f8" : "#3daee9"
        }
    }
}
