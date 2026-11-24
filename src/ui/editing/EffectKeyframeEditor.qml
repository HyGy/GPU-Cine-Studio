import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import VideoEditor 1.0

// Visual editor for one animated effect param (ClipEffects.cpp's
// {"kf":[{"t":secs,"v":val},...]} shape - see applyAnimation()). Lives
// inline inside EffectInspectorPanel.qml's per-param row, expanded in
// place of the plain read-only "animated (N keyframes)" summary.
//
// Time axis is deliberately CLIP-LOCAL (fit to the clip's own media
// window), not timeline-aligned via TimelinePanel's pixelsPerSecond -
// this panel is only ~300px wide, far too narrow to usefully show a
// whole clip at the timeline's zoom level, and nothing here needs to
// visually line up with the timeline itself.
//
// No live GStreamer preview during a drag: an animated param already
// has a GstControlBinding, which overrides any plain property write
// on every pipeline sync (verified live - see ClipEffects.cpp's
// applyAnimation() comment and TODO.txt) - so the slider's live-preview
// trick (TimelineEngine::setClipEffectParam()) cannot work here without
// new C++ to re-point the existing control source. v1 trades that for
// simplicity: the dot/curve redraw QML-side during the drag, and the
// real GES commit happens once on release - same per-gesture cost as
// every other effect edit in this app.
Item {
    id: root

    property var timelinePanel: null
    property var timelineEngine: null
    property string clipId: ""
    property string effectId: ""
    property string paramName: ""
    property real from: 0
    property real to: 1
    // Array of {t,v} - bound by the caller from the clip's own params
    // object, e.g. effectData.params[paramName].kf.
    property var keyframes: []

    implicitHeight: headerRow.implicitHeight + 6 + plot.height
    height: implicitHeight

    // Clip-local media-time window this param's keyframes live in -
    // same base as the clip's own sourceOffset (see ClipEffects.cpp's
    // applyAnimation() comment on the media-time vs clip-start-relative
    // split). Re-read on clipId change; a trim while this editor is
    // open is an accepted staleness window (re-select the clip to
    // refresh) rather than new plumbing for a rare case.
    readonly property var timing: (root.clipId, root.timelinePanel ? root.timelinePanel.clipTiming(root.clipId) : null)
    readonly property real mediaStart: timing ? timing.sourceOffset : 0
    readonly property real mediaSpan: timing && timing.durationSeconds > 0 ? timing.durationSeconds : 1

    readonly property real fps: {
        var s = typeof Backend !== "undefined" ? Backend.getSetting("project/fps", "30") : "30"
        var f = (s === "auto") ? 30 : parseFloat(s)
        return (f && f > 0) ? f : 30
    }

    property int selectedIndex: -1
    // While dragging, the dragged point's live {t,v} - everything else
    // (Canvas polyline, other dots) reads straight from `keyframes`.
    property var dragLive: null
    property int dragIndex: -1

    function clampT(t) {
        var lo = mediaStart, hi = mediaStart + mediaSpan
        return Math.max(lo, Math.min(hi, t))
    }
    function clampV(v) { return Math.max(root.from, Math.min(root.to, v)) }
    function snapT(t) { return Math.round(t * root.fps) / root.fps }

    function xForT(t) {
        if (mediaSpan <= 0) return 0
        return (t - mediaStart) / mediaSpan * plot.width
    }
    function tForX(x) {
        if (plot.width <= 0) return mediaStart
        return snapT(clampT(mediaStart + (x / plot.width) * mediaSpan))
    }
    function yForV(v) {
        var span = (root.to - root.from)
        if (span <= 0) return plot.height
        return plot.height - (v - root.from) / span * plot.height
    }
    function vForY(y) {
        var span = (root.to - root.from)
        if (span <= 0) return root.from
        return clampV(root.from + (plot.height - y) / plot.height * span)
    }

    function pointAt(i) {
        if (i === root.dragIndex && root.dragLive) return root.dragLive
        return root.keyframes[i]
    }

    readonly property real playheadMedia: {
        if (!root.timelineEngine || !root.timing) return -1
        return (root.timelineEngine.position / 1000) - root.timing.startTime + root.timing.sourceOffset
    }
    readonly property bool playheadVisible:
        root.playheadMedia >= root.mediaStart && root.playheadMedia <= root.mediaStart + root.mediaSpan

    // Writes the full new keyframe array back into the clip's effects
    // JSON, through the same undoable-edit + full-rebuild commit path
    // every other effect edit in this app uses (TimelinePanel.setClipEffects()).
    // An empty array is never persisted as {"kf":[]} - applyAnimation()
    // treats that as "nothing to animate" and leaves the property at
    // whatever GES defaults to, silently breaking the effect; instead
    // the param reverts to a plain static number (the removed point's
    // own value).
    function commitKf(newArray, label) {
        if (!root.timelinePanel) return
        var effects = root.timelinePanel.clipEffects(root.clipId)
        for (var i = 0; i < effects.length; i++) {
            if (effects[i].id !== root.effectId) continue
            if (newArray.length === 0) {
                // Caller already knows the fallback value - see callers.
            } else {
                newArray.sort(function(a, b) { return a.t - b.t })
                effects[i].params[root.paramName] = { kf: newArray }
            }
            break
        }
        root.timelinePanel.beginUndoableEdit()
        root.timelinePanel.setClipEffects(root.clipId, effects, true)
        root.timelinePanel.commitUndoableEdit(label)
        if (root.timelineEngine && !root.timelineEngine.playing) root.timelineEngine.seek(root.timelineEngine.position)
    }

    function revertToStatic(value, label) {
        if (!root.timelinePanel) return
        var effects = root.timelinePanel.clipEffects(root.clipId)
        for (var i = 0; i < effects.length; i++) {
            if (effects[i].id !== root.effectId) continue
            effects[i].params[root.paramName] = value
            break
        }
        root.timelinePanel.beginUndoableEdit()
        root.timelinePanel.setClipEffects(root.clipId, effects, true)
        root.timelinePanel.commitUndoableEdit(label)
    }

    function addKeyframeAt(t, v) {
        var arr = root.keyframes.slice()
        t = snapT(clampT(t))
        // Snap onto an existing point within half a frame instead of
        // creating a near-duplicate.
        var halfFrame = 0.5 / root.fps
        for (var i = 0; i < arr.length; i++) {
            if (Math.abs(arr[i].t - t) < halfFrame) {
                arr[i] = { t: arr[i].t, v: clampV(v) }
                commitKf(arr, "Move keyframe")
                root.selectedIndex = i
                return
            }
        }
        arr.push({ t: t, v: clampV(v) })
        arr.sort(function(a, b) { return a.t - b.t })
        commitKf(arr, "Add keyframe")
        for (var j = 0; j < arr.length; j++) if (Math.abs(arr[j].t - t) < 1e-9) { root.selectedIndex = j; break }
    }

    // Linear-sample the curve at `t`, for "add at playhead" (value =
    // current curve value there, not some arbitrary default) and for
    // de-animating back to a representative static value.
    function sampleAt(t) {
        var arr = root.keyframes
        if (arr.length === 0) return root.from
        if (t <= arr[0].t) return arr[0].v
        if (t >= arr[arr.length - 1].t) return arr[arr.length - 1].v
        for (var i = 0; i < arr.length - 1; i++) {
            if (t >= arr[i].t && t <= arr[i + 1].t) {
                var span = arr[i + 1].t - arr[i].t
                var frac = span > 0 ? (t - arr[i].t) / span : 0
                return arr[i].v + (arr[i + 1].v - arr[i].v) * frac
            }
        }
        return arr[arr.length - 1].v
    }

    function deleteSelected() {
        if (root.selectedIndex < 0 || root.selectedIndex >= root.keyframes.length) return
        var removedValue = root.keyframes[root.selectedIndex].v
        var arr = root.keyframes.slice()
        arr.splice(root.selectedIndex, 1)
        root.selectedIndex = -1
        if (arr.length === 0) {
            revertToStatic(removedValue, "Remove animation")
        } else {
            commitKf(arr, "Remove keyframe")
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 4

        RowLayout {
            id: headerRow
            Layout.fillWidth: true
            spacing: 4

            Text {
                text: root.paramName
                color: "#cccccc"
                font.pixelSize: 11
                Layout.preferredWidth: 70
            }
            Button {
                text: "+ at playhead"
                implicitHeight: 20
                enabled: root.playheadVisible
                onClicked: root.addKeyframeAt(root.playheadMedia, root.sampleAt(root.playheadMedia))
                background: Rectangle { color: "#4a4f55"; radius: 2 }
                contentItem: Text { text: parent.text; color: "white"; font.pixelSize: 10; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
            }
            Item { Layout.fillWidth: true }
            Text {
                visible: root.selectedIndex >= 0 && root.selectedIndex < root.keyframes.length
                text: root.selectedIndex >= 0 && root.selectedIndex < root.keyframes.length
                      ? root.keyframes[root.selectedIndex].t.toFixed(2) + "s"
                      : ""
                color: "#888888"
                font.pixelSize: 10
            }
            TextField {
                id: valueField
                visible: root.selectedIndex >= 0 && root.selectedIndex < root.keyframes.length
                implicitWidth: 60
                implicitHeight: 22
                font.pixelSize: 10
                color: "white"
                background: Rectangle { color: "#1d1d1d"; border.color: "#3a3a3a"; radius: 2 }
                text: root.selectedIndex >= 0 && root.selectedIndex < root.keyframes.length
                      ? root.keyframes[root.selectedIndex].v.toFixed(3) : ""
                onAccepted: {
                    Backend.shortcuts.releaseTextFocus()
                    if (root.selectedIndex < 0) return
                    var v = parseFloat(text)
                    if (isNaN(v)) return
                    var arr = root.keyframes.slice()
                    arr[root.selectedIndex] = { t: arr[root.selectedIndex].t, v: root.clampV(v) }
                    root.commitKf(arr, "Set " + root.paramName)
                }
                // Esc: drop the typed text, show the stored value again.
                Keys.onEscapePressed: {
                    text = Qt.binding(function() {
                        return root.selectedIndex >= 0 && root.selectedIndex < root.keyframes.length
                               ? root.keyframes[root.selectedIndex].v.toFixed(3) : ""
                    })
                    Backend.shortcuts.releaseTextFocus()
                }
            }
            Button {
                text: "⌫"
                implicitWidth: 22; implicitHeight: 22
                enabled: root.selectedIndex >= 0
                onClicked: root.deleteSelected()
            }
        }

        Rectangle {
            id: plot
            Layout.fillWidth: true
            Layout.preferredHeight: 100
            color: "#1d1d1d"
            border.color: "#3a3a3a"
            border.width: 1
            clip: true

            Canvas {
                id: canvas
                anchors.fill: parent
                readonly property var kfs: root.keyframes
                readonly property var live: root.dragLive
                onKfsChanged: requestPaint()
                onLiveChanged: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                Component.onCompleted: requestPaint()

                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)

                    // Value grid: from/mid/to, with numeric labels.
                    ctx.strokeStyle = "#333333"
                    ctx.fillStyle = "#666666"
                    ctx.font = "9px sans-serif"
                    var mid = (root.from + root.to) / 2
                    ;[root.from, mid, root.to].forEach(function(v) {
                        var y = root.yForV(v)
                        ctx.beginPath()
                        ctx.moveTo(0, y)
                        ctx.lineTo(width, y)
                        ctx.stroke()
                        ctx.fillText(v.toFixed(2), 2, Math.max(9, Math.min(height - 2, y - 2)))
                    })

                    var arr = root.keyframes
                    if (!arr || arr.length === 0) return

                    ctx.strokeStyle = "#3daee9"
                    ctx.lineWidth = 2
                    ctx.beginPath()
                    for (var i = 0; i < arr.length; i++) {
                        var p = root.pointAt(i)
                        var x = root.xForT(p.t)
                        var y = root.yForV(p.v)
                        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
                    }
                    ctx.stroke()
                }
            }

            // Red playhead line, matching TimelineRuler.qml's language.
            Rectangle {
                visible: root.playheadVisible
                x: root.xForT(root.playheadMedia)
                width: 1
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                color: "#ff4444"
                opacity: 0.8
            }

            MouseArea {
                anchors.fill: parent
                onClicked: function(mouse) {
                    root.addKeyframeAt(root.tForX(mouse.x), root.vForY(mouse.y))
                }
            }

            Repeater {
                model: root.keyframes.length
                delegate: Item {
                    id: dot
                    readonly property var kf: root.pointAt(index)
                    x: root.xForT(kf.t) - 6
                    y: root.yForV(kf.v) - 6
                    width: 12; height: 12

                    Rectangle {
                        anchors.fill: parent
                        radius: 6
                        color: root.selectedIndex === index ? "#5fc4f8" : "#3daee9"
                        border.color: "#1d1d1d"
                        border.width: 1
                    }

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        // This editor lives inside the effect stack's
                        // ListView (a Flickable) - without this, any
                        // vertical component of the drag (i.e. changing
                        // the keyframe's VALUE, not just its time) gets
                        // interpreted by the ListView as "start
                        // scrolling" and steals the mouse grab away from
                        // this MouseArea mid-gesture, which silently
                        // cancels the drag (onCanceled fires) before any
                        // movement is ever committed.
                        preventStealing: true
                        // Snapshot of the point BEFORE this drag, for the
                        // onReleased "did it actually move" check -
                        // dot.kf is NOT safe for that comparison: while
                        // dragIndex===index, pointAt() makes kf mirror
                        // dragLive itself, so comparing dragLive against
                        // kf at release time was always comparing it
                        // against itself (always "equal", so the drag was
                        // silently reverted every time via the abort
                        // branch - this was the actual cause of a dragged
                        // point always snapping back to its original spot).
                        property var pressOrigin: null
                        onPressed: {
                            root.selectedIndex = index
                            pressOrigin = { t: kf.t, v: kf.v }
                            root.dragIndex = index
                            root.dragLive = { t: kf.t, v: kf.v }
                            if (root.timelinePanel) root.timelinePanel.beginUndoableGesture()
                        }
                        onPositionChanged: function(mouse) {
                            if (root.dragIndex !== index) return
                            // This MouseArea is dot's child, anchored with
                            // -4 margins (bigger hit area than the 12px
                            // dot) - mouse.x/y are relative to ITS OWN
                            // origin, which sits 4px before dot's, so that
                            // offset must be added back to get plot-local
                            // coordinates.
                            var localX = dot.x - 4 + mouse.x
                            var localY = dot.y - 4 + mouse.y
                            var newT = root.tForX(localX)
                            // Never cross a neighbour - keeps the array
                            // sorted without needing to re-resolve the
                            // dragged index mid-gesture.
                            var lo = index > 0 ? root.keyframes[index - 1].t + (0.5 / root.fps) : root.mediaStart
                            var hi = index < root.keyframes.length - 1 ? root.keyframes[index + 1].t - (0.5 / root.fps) : root.mediaStart + root.mediaSpan
                            newT = Math.max(lo, Math.min(hi, newT))
                            root.dragLive = { t: newT, v: root.vForY(localY) }
                        }
                        onReleased: {
                            if (root.dragIndex !== index) return
                            var moved = root.dragLive && pressOrigin
                                && (Math.abs(root.dragLive.t - pressOrigin.t) > 1e-6 || Math.abs(root.dragLive.v - pressOrigin.v) > 1e-6)
                            var live = root.dragLive
                            root.dragIndex = -1
                            root.dragLive = null
                            if (moved) {
                                var arr = root.keyframes.slice()
                                arr[index] = { t: live.t, v: live.v }
                                root.commitKf(arr, "Move keyframe")
                            } else if (root.timelinePanel) {
                                root.timelinePanel.abortUndoableEdit()
                            }
                        }
                        onCanceled: {
                            if (root.dragIndex !== index) return
                            root.dragIndex = -1
                            root.dragLive = null
                            if (root.timelinePanel) root.timelinePanel.abortUndoableEdit()
                        }
                        onDoubleClicked: {
                            root.selectedIndex = index
                            root.deleteSelected()
                        }
                    }
                }
            }
        }
    }
}
