import QtQuick
import QtQuick.Controls

// A single numeric effect parameter, wired with the SAME undo-gesture
// idiom as TimelineClip.qml's trim handles: press captures an undo
// checkpoint and the gesture only pushes LIVE values straight to GES
// (TimelineEngine::setClipEffectParam()) without touching clipsModel, so
// dragging is cheap and never re-triggers a GES rebuild per frame.
// Release writes the final value into the model (one setClipEffects()
// call) and closes the undo entry; a canceled grab reverts GES back to
// the pre-drag value and discards the undo entry.
Item {
    id: root

    property var timelinePanel: null
    property var timelineEngine: null
    property string clipId: ""
    property string effectId: ""
    property string paramName: ""
    property string label: paramName
    property real from: 0
    property real to: 1
    property real value: 0  // current committed value, bound by the caller

    implicitHeight: 40
    // Plain Item does NOT auto-bind height to implicitHeight the way
    // Control-derived types do - without this, height stays 0 (its
    // default), which anchors the Slider below to a zero-height parent:
    // it renders squashed to nothing and has no hit area to drag.
    height: implicitHeight

    // Set by the caller (EffectInspectorPanel) right before opening the
    // undo scope so a canceled drag has something exact to revert to.
    property real origValue: value
    property real liveValue: value

    Row {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 6

        Text {
            width: 90
            text: root.label
            color: "#cccccc"
            font.pixelSize: 11
            elide: Text.ElideRight
        }
        Text {
            text: root.liveValue.toFixed(2)
            color: "#888888"
            font.pixelSize: 11
        }
    }

    Slider {
        id: slider
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        // Comfortably larger than the 14px handle so the drag grab area
        // isn't pixel-tight - purely ergonomic, not required for the
        // implicitHeight=0 fix below to work.
        height: 18
        from: root.from
        to: root.to
        value: root.value

        // Only follow external model changes while the user isn't
        // actively dragging - otherwise every live setClipEffectParam()
        // round-trip would fight the user's own drag.
        onValueChanged: {
            if (!pressed) return
            root.liveValue = value
            if (root.timelineEngine)
                root.timelineEngine.setClipEffectParam(root.clipId, root.effectId, root.paramName, value)
            // setClipEffectParam() above already updated the GStreamer
            // element's property, but a PAUSED pipeline doesn't re-render
            // its currently-held frame just because a filter property
            // changed - the preview stays visually frozen on the
            // pre-change frame until something pushes a new buffer
            // through. holdRefreshTimer (re-armed on every move) fires
            // once the drag PAUSES while still held, forcing exactly one
            // redraw of the current frame - this is display-only, never
            // touches clipsModel/undo (those stay release-only, below).
            holdRefreshTimer.restart()
        }

        // See onValueChanged above. Deliberately debounced rather than
        // firing on every value change: a same-position seek is a real
        // (if cheap) GStreamer flush/reseek, and doing one per pixel of
        // mouse movement during a fast drag would be wasteful and could
        // visibly stutter the preview instead of smoothly following it.
        Timer {
            id: holdRefreshTimer
            interval: 120
            repeat: false
            onTriggered: {
                if (!slider.pressed) return
                if (!root.timelineEngine || root.timelineEngine.playing) return
                root.timelineEngine.seek(root.timelineEngine.position)
            }
        }

        onPressedChanged: {
            if (pressed) {
                root.origValue = root.value
                if (root.timelinePanel) root.timelinePanel.beginUndoableGesture()
            } else {
                // onPressedChanged(false) fires on both a normal release
                // and after a canceled grab - QQuickSlider has no
                // separate onCanceled, so detect "did the value actually
                // move" to decide commit vs. abort instead.
                if (Math.abs(value - root.origValue) > 1e-6) {
                    if (root.timelinePanel) {
                        var effects = root.timelinePanel.clipEffects(root.clipId)
                        for (var i = 0; i < effects.length; i++) {
                            if (effects[i].id === root.effectId) {
                                effects[i].params[root.paramName] = value
                                break
                            }
                        }
                        root.timelinePanel.setClipEffects(root.clipId, effects, true)
                        root.timelinePanel.commitUndoableEdit("Adjust " + root.label)
                    }
                } else {
                    if (root.timelineEngine)
                        root.timelineEngine.setClipEffectParam(root.clipId, root.effectId, root.paramName, root.origValue)
                    if (root.timelinePanel) root.timelinePanel.abortUndoableEdit()
                }
            }
        }

        // QQuickSlider derives its OWN implicitHeight from
        // implicitBackgroundHeight/implicitHandleHeight/implicitContentHeight
        // - never from these delegates' plain width/height. Without
        // implicitWidth/implicitHeight here, Slider.implicitHeight stays 0,
        // so the control's hit rect is empty (contains() false for every
        // point) even though the track/handle still PAINT correctly - Qt
        // Quick doesn't clip a child's rendering to its parent's bounds,
        // so a 0-height Slider with its handle positioned at
        // availableHeight/2-height/2 (negative, since availableHeight=0)
        // still looks right while being completely unclickable. Verified
        // live: slider.height was 0, handle y was -7, contains(handle
        // center) was false; after adding these two lines, height=14 and
        // contains() is true.
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
