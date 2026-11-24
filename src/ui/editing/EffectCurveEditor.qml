import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Visual editor for the "curves" effect's "curve-points" param - a
// Photoshop/Lightroom-style tonal curve tool. Structurally mirrors
// EffectKeyframeEditor.qml (Canvas plot + Repeater of draggable dots,
// same undo-gesture/commit idioms), but the X/Y axes are input-level/
// output-level (both fixed 0-1), not time/value, and - unlike the
// keyframe editor - this param has NO GstControlBinding fighting a live
// write (see gstglcurves.c: "curve-points" is a plain string property,
// not GST_PARAM_CONTROLLABLE), so live preview during a drag works the
// same way EffectParamSlider.qml's does.
//
// ONE instance edits all four channels at once (master RGB + R/G/B
// independently) - the inactive three render as dim "ghost" curves in
// their own channel colour so the whole grade stays visible while
// editing any one of them, same model as Photoshop's own Curves panel.
// See gstglcurves.c's "curve-points" property doc for the exact wire
// format this editor reads/writes:
//   "m:in,out;...|r:in,out;...|g:in,out;...|b:in,out;..."
Item {
    id: root

    property var timelinePanel: null
    property var timelineEngine: null
    property string clipId: ""
    property string effectId: ""
    property string paramName: "curve-points"
    // Current committed value (the raw GES property string), bound by
    // the caller from effectData.params["curve-points"].
    property string value: "m:0,0;1,1|r:0,0;1,1|g:0,0;1,1|b:0,0;1,1"

    implicitHeight: headerRow.implicitHeight + channelRow.implicitHeight + 8 + plot.height
    height: implicitHeight

    readonly property var channelMeta: ({
        m: { label: "RGB", color: "#e8e8e8" },
        r: { label: "R",   color: "#e55353" },
        g: { label: "G",   color: "#4caf50" },
        b: { label: "B",   color: "#4a9eff" }
    })
    // Driven by the caller (EffectInspectorPanel persists this per
    // effect/param across delegate rebuilds - see its
    // curveActiveChannel map) rather than owned purely locally: every
    // point edit here commits through setClipEffects(), which rebuilds
    // the Repeater this component lives in, destroying and recreating
    // this very instance - a locally-owned activeChannel would silently
    // reset to "m" after every single add/move/delete.
    property string activeChannel: "m"
    signal channelSelected(string channel)

    // Parsed working copy: {m:[{i,o},...], r:[...], g:[...], b:[...]}.
    // Re-derived from `value` whenever it changes EXTERNALLY (i.e. not
    // from our own live writes mid-drag, which update `curves` directly
    // without waiting for the round-trip) - same "don't fight the user's
    // own drag" guard as EffectParamSlider.qml's Slider.onValueChanged.
    property var curves: decodeCurves(value)
    property bool dragging: false
    onValueChanged: if (!dragging) curves = decodeCurves(value)

    property int selectedIndex: -1
    property var dragLive: null
    property int dragIndex: -1

    readonly property int maxPointsPerChannel: 16

    function decodeCurves(str) {
        var out = {
            m: [{ i: 0, o: 0 }, { i: 1, o: 1 }],
            r: [{ i: 0, o: 0 }, { i: 1, o: 1 }],
            g: [{ i: 0, o: 0 }, { i: 1, o: 1 }],
            b: [{ i: 0, o: 0 }, { i: 1, o: 1 }]
        }
        if (!str) return out
        var channels = str.split("|")
        for (var c = 0; c < channels.length; c++) {
            var ch = channels[c]
            if (ch.length < 2 || ch.charAt(1) !== ":") continue
            var letter = ch.charAt(0)
            if (!out.hasOwnProperty(letter)) continue
            var pts = []
            var segs = ch.substring(2).split(";")
            for (var s = 0; s < segs.length; s++) {
                var parts = segs[s].split(",")
                if (parts.length !== 2) continue
                var inV = parseFloat(parts[0]), outV = parseFloat(parts[1])
                if (isNaN(inV) || isNaN(outV)) continue
                pts.push({ i: Math.max(0, Math.min(1, inV)), o: Math.max(0, Math.min(1, outV)) })
            }
            pts.sort(function(a, b) { return a.i - b.i })
            var dedup = []
            for (var k = 0; k < pts.length; k++) {
                if (dedup.length > 0 && pts[k].i - dedup[dedup.length - 1].i < 1e-6) continue
                dedup.push(pts[k])
            }
            if (dedup.length >= 2) out[letter] = dedup
        }
        return out
    }

    function encodeCurves(curvesObj) {
        var letters = ["m", "r", "g", "b"]
        var parts = []
        for (var i = 0; i < letters.length; i++) {
            var l = letters[i]
            var pts = curvesObj[l]
            var segs = []
            for (var j = 0; j < pts.length; j++)
                segs.push(pts[j].i.toFixed(4) + "," + pts[j].o.toFixed(4))
            parts.push(l + ":" + segs.join(";"))
        }
        return parts.join("|")
    }

    // Monotone cubic Hermite (Fritsch-Carlson), matching gstglcurves.c's
    // pchip_eval() so the drawn curve is exactly what the GPU shader
    // renders (straight-line segments would otherwise look subtly
    // different from the real, smoothed output).
    function pchipEval(xs, ys, x) {
        var n = xs.length
        if (n < 2) return Math.max(0, Math.min(1, x))
        x = Math.max(xs[0], Math.min(xs[n - 1], x))
        if (n === 2) return ys[0] + (ys[1] - ys[0]) * ((x - xs[0]) / (xs[1] - xs[0]))

        var h = [], d = []
        for (var k = 0; k < n - 1; k++) {
            h[k] = xs[k + 1] - xs[k]
            d[k] = h[k] > 1e-6 ? (ys[k + 1] - ys[k]) / h[k] : 0
        }
        var m = new Array(n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        if (n > 2) {
            var m0 = ((2 * h[0] + h[1]) * d[0] - h[0] * d[1]) / (h[0] + h[1])
            if ((m0 > 0) !== (d[0] > 0)) m0 = 0
            else if ((d[0] > 0) !== (d[1] > 0) && Math.abs(m0) > 3 * Math.abs(d[0])) m0 = 3 * d[0]
            m[0] = m0

            var mn = ((2 * h[n - 2] + h[n - 3]) * d[n - 2] - h[n - 2] * d[n - 3]) / (h[n - 2] + h[n - 3])
            if ((mn > 0) !== (d[n - 2] > 0)) mn = 0
            else if ((d[n - 2] > 0) !== (d[n - 3] > 0) && Math.abs(mn) > 3 * Math.abs(d[n - 2])) mn = 3 * d[n - 2]
            m[n - 1] = mn
        }
        for (var ki = 1; ki < n - 1; ki++) {
            if (d[ki - 1] === 0 || d[ki] === 0 || (d[ki - 1] > 0) !== (d[ki] > 0)) { m[ki] = 0; continue }
            var w1 = 2 * h[ki] + h[ki - 1], w2 = h[ki] + 2 * h[ki - 1]
            m[ki] = (w1 + w2) / (w1 / d[ki - 1] + w2 / d[ki])
        }
        for (var kj = 0; kj < n - 1; kj++) {
            if (d[kj] === 0) { m[kj] = 0; m[kj + 1] = 0; continue }
            var alpha = m[kj] / d[kj], beta = m[kj + 1] / d[kj]
            var sq = alpha * alpha + beta * beta
            if (sq > 9) {
                var tau = 3 / Math.sqrt(sq)
                m[kj] = tau * alpha * d[kj]
                m[kj + 1] = tau * beta * d[kj]
            }
        }
        var seg = n - 2
        for (var si = 0; si < n - 1; si++) { if (x <= xs[si + 1]) { seg = si; break } }
        var t = (x - xs[seg]) / h[seg]
        var t2 = t * t, t3 = t2 * t
        var h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t, h01 = -2 * t3 + 3 * t2, h11 = t3 - t2
        return h00 * ys[seg] + h10 * h[seg] * m[seg] + h01 * ys[seg + 1] + h11 * h[seg] * m[seg + 1]
    }

    function evalChannelAt(letter, x) {
        var pts = (root.dragging && letter === root.activeChannel) ? liveChannelPoints() : root.curves[letter]
        var xs = [], ys = []
        for (var i = 0; i < pts.length; i++) { xs.push(pts[i].i); ys.push(pts[i].o) }
        return pchipEval(xs, ys, x)
    }

    function liveChannelPoints() {
        var pts = root.curves[root.activeChannel]
        if (root.dragIndex < 0 || !root.dragLive) return pts
        var out = pts.slice()
        out[root.dragIndex] = root.dragLive
        return out
    }

    function xForI(v) { return v * plot.width }
    function iForX(x) { return Math.max(0, Math.min(1, plot.width > 0 ? x / plot.width : 0)) }
    function yForO(v) { return plot.height - v * plot.height }
    function oForY(y) { return Math.max(0, Math.min(1, plot.height > 0 ? 1 - y / plot.height : 0)) }

    function pointAt(i) {
        if (i === root.dragIndex && root.dragLive) return root.dragLive
        return root.curves[root.activeChannel][i]
    }

    // Live preview: pushes the raw property straight to GES, same
    // mechanism/debounce as EffectParamSlider.qml (no control binding on
    // this param to fight, unlike the keyframe editor).
    function pushLive() {
        if (!root.timelineEngine) return
        root.timelineEngine.setClipEffectParam(root.clipId, root.effectId, root.paramName, root.encodeCurves(root.curves))
        holdRefreshTimer.restart()
    }

    function commitCurves(label) {
        if (!root.timelinePanel) return
        var effects = root.timelinePanel.clipEffects(root.clipId)
        var str = root.encodeCurves(root.curves)
        for (var i = 0; i < effects.length; i++) {
            if (effects[i].id !== root.effectId) continue
            effects[i].params[root.paramName] = str
            break
        }
        root.timelinePanel.setClipEffects(root.clipId, effects, true)
        root.timelinePanel.commitUndoableEdit(label)
        root.value = str
    }

    function addPointAt(x, y) {
        var pts = root.curves[root.activeChannel]
        if (pts.length >= root.maxPointsPerChannel) return
        var iv = iForX(x), ov = oForY(y)
        var halfPx = 1.0 / Math.max(1, plot.width)
        for (var k = 0; k < pts.length; k++) {
            if (Math.abs(pts[k].i - iv) < halfPx * 6) return // too close to an existing point
        }
        var next = pts.slice()
        next.push({ i: iv, o: ov })
        next.sort(function(a, b) { return a.i - b.i })

        root.timelinePanel.beginUndoableGesture()
        var updated = {}
        for (var l in root.curves) updated[l] = root.curves[l]
        updated[root.activeChannel] = next
        root.curves = updated
        commitCurves("Add curve point")
        for (var j = 0; j < next.length; j++) if (Math.abs(next[j].i - iv) < 1e-9) { root.selectedIndex = j; break }
    }

    function deletePoint(index) {
        var pts = root.curves[root.activeChannel]
        if (pts.length <= 2) return // never below 2 points - a curve needs at least its endpoints
        var next = pts.slice()
        next.splice(index, 1)
        root.timelinePanel.beginUndoableGesture()
        var updated = {}
        for (var l in root.curves) updated[l] = root.curves[l]
        updated[root.activeChannel] = next
        root.curves = updated
        root.selectedIndex = -1
        commitCurves("Delete curve point")
    }

    function resetChannel(letter) {
        root.timelinePanel.beginUndoableGesture()
        var updated = {}
        for (var l in root.curves) updated[l] = root.curves[l]
        updated[letter] = [{ i: 0, o: 0 }, { i: 1, o: 1 }]
        root.curves = updated
        root.selectedIndex = -1
        commitCurves("Reset " + letter + " curve")
    }

    function resetAll() {
        root.timelinePanel.beginUndoableGesture()
        root.curves = {
            m: [{ i: 0, o: 0 }, { i: 1, o: 1 }],
            r: [{ i: 0, o: 0 }, { i: 1, o: 1 }],
            g: [{ i: 0, o: 0 }, { i: 1, o: 1 }],
            b: [{ i: 0, o: 0 }, { i: 1, o: 1 }]
        }
        root.selectedIndex = -1
        commitCurves("Reset all curves")
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 4

        RowLayout {
            id: headerRow
            Layout.fillWidth: true
            spacing: 4

            Text {
                text: "Curves"
                color: "#cccccc"
                font.pixelSize: 11
                Layout.preferredWidth: 50
            }
            Item { Layout.fillWidth: true }
            Button {
                text: "Reset " + root.channelMeta[root.activeChannel].label
                implicitHeight: 20
                onClicked: root.resetChannel(root.activeChannel)
                background: Rectangle { color: "#4a4f55"; radius: 2 }
                contentItem: Text { text: parent.text; color: "white"; font.pixelSize: 10; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
            }
            Button {
                text: "Reset all"
                implicitHeight: 20
                onClicked: root.resetAll()
                background: Rectangle { color: "#4a4f55"; radius: 2 }
                contentItem: Text { text: parent.text; color: "white"; font.pixelSize: 10; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
            }
        }

        // Channel selector - segmented control, Photoshop-style.
        RowLayout {
            id: channelRow
            Layout.fillWidth: true
            spacing: 2

            Repeater {
                model: ["m", "r", "g", "b"]
                delegate: Button {
                    required property string modelData
                    Layout.fillWidth: true
                    implicitHeight: 22
                    text: root.channelMeta[modelData].label
                    onClicked: { root.channelSelected(modelData); root.selectedIndex = -1 }
                    background: Rectangle {
                        color: root.activeChannel === modelData ? root.channelMeta[modelData].color : "#33373c"
                        radius: 2
                        border.color: root.channelMeta[modelData].color
                        border.width: 1
                    }
                    contentItem: Text {
                        text: parent.text
                        color: root.activeChannel === modelData ? "#1d1d1d" : root.channelMeta[modelData].color
                        font.bold: true
                        font.pixelSize: 10
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }

        Rectangle {
            id: plot
            Layout.fillWidth: true
            Layout.preferredHeight: 160
            color: "#1d1d1d"
            border.color: "#3a3a3a"
            border.width: 1
            clip: true

            Canvas {
                id: canvas
                anchors.fill: parent
                readonly property var liveCurves: root.curves
                readonly property var live: root.dragLive
                readonly property string active: root.activeChannel
                onLiveCurvesChanged: requestPaint()
                onLiveChanged: requestPaint()
                onActiveChanged: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                Component.onCompleted: requestPaint()

                function drawCurve(ctx, letter, color, lineWidth, alpha) {
                    ctx.strokeStyle = color
                    ctx.globalAlpha = alpha
                    ctx.lineWidth = lineWidth
                    ctx.beginPath()
                    var steps = Math.max(2, Math.floor(width))
                    for (var s = 0; s <= steps; s++) {
                        var x = s / steps
                        var y = root.evalChannelAt(letter, x)
                        var px = root.xForI(x), py = root.yForO(y)
                        if (s === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py)
                    }
                    ctx.stroke()
                    ctx.globalAlpha = 1.0
                }

                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)

                    // Quarter grid.
                    ctx.strokeStyle = "#333333"
                    ctx.lineWidth = 1
                    for (var q = 0; q <= 4; q++) {
                        var gx = width * q / 4, gy = height * q / 4
                        ctx.beginPath(); ctx.moveTo(gx, 0); ctx.lineTo(gx, height); ctx.stroke()
                        ctx.beginPath(); ctx.moveTo(0, gy); ctx.lineTo(width, gy); ctx.stroke()
                    }

                    // Identity diagonal (the "no change" reference line).
                    ctx.strokeStyle = "#555555"
                    ctx.setLineDash([4, 3])
                    ctx.beginPath()
                    ctx.moveTo(0, height)
                    ctx.lineTo(width, 0)
                    ctx.stroke()
                    ctx.setLineDash([])

                    // Ghost curves for the three inactive channels.
                    var letters = ["m", "r", "g", "b"]
                    for (var i = 0; i < letters.length; i++) {
                        if (letters[i] === root.activeChannel) continue
                        drawCurve(ctx, letters[i], root.channelMeta[letters[i]].color, 1.5, 0.35)
                    }
                    // Active channel on top, full strength.
                    drawCurve(ctx, root.activeChannel, root.channelMeta[root.activeChannel].color, 2.5, 1.0)
                }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: function(mouse) {
                    root.addPointAt(mouse.x, mouse.y)
                }
            }

            Repeater {
                model: root.curves[root.activeChannel].length
                delegate: Item {
                    id: dot
                    readonly property var pt: root.pointAt(index)
                    readonly property bool isEndpoint: index === 0 || index === root.curves[root.activeChannel].length - 1
                    x: root.xForI(pt.i) - 6
                    y: root.yForO(pt.o) - 6
                    width: 12; height: 12

                    Rectangle {
                        anchors.fill: parent
                        radius: 6
                        color: root.selectedIndex === index ? "#ffffff" : root.channelMeta[root.activeChannel].color
                        border.color: "#1d1d1d"
                        border.width: 1
                    }

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        // Same ListView-steals-the-grab hazard as
                        // EffectKeyframeEditor.qml's dots - see its
                        // comment on preventStealing for the full story.
                        preventStealing: true
                        property var pressOrigin: null
                        onPressed: {
                            root.selectedIndex = index
                            pressOrigin = { i: dot.pt.i, o: dot.pt.o }
                            root.dragIndex = index
                            root.dragLive = { i: dot.pt.i, o: dot.pt.o }
                            root.dragging = true
                            if (root.timelinePanel) root.timelinePanel.beginUndoableGesture()
                        }
                        onPositionChanged: function(mouse) {
                            if (root.dragIndex !== index) return
                            var localX = dot.x - 4 + mouse.x
                            var localY = dot.y - 4 + mouse.y
                            var pts = root.curves[root.activeChannel]
                            var newI
                            if (index === 0) newI = 0
                            else if (index === pts.length - 1) newI = 1
                            else {
                                var lo = pts[index - 1].i + 1e-3
                                var hi = pts[index + 1].i - 1e-3
                                newI = Math.max(lo, Math.min(hi, root.iForX(localX)))
                            }
                            root.dragLive = { i: newI, o: root.oForY(localY) }
                            root.pushLive()
                        }
                        onReleased: {
                            if (root.dragIndex !== index) return
                            var moved = root.dragLive && pressOrigin
                                && (Math.abs(root.dragLive.i - pressOrigin.i) > 1e-6 || Math.abs(root.dragLive.o - pressOrigin.o) > 1e-6)
                            var live = root.dragLive
                            root.dragIndex = -1
                            root.dragLive = null
                            root.dragging = false
                            if (moved) {
                                var pts = root.curves[root.activeChannel].slice()
                                pts[index] = { i: live.i, o: live.o }
                                var updated = {}
                                for (var l in root.curves) updated[l] = root.curves[l]
                                updated[root.activeChannel] = pts
                                root.curves = updated
                                root.commitCurves("Adjust curve")
                            } else if (root.timelinePanel) {
                                root.timelinePanel.abortUndoableEdit()
                                if (root.timelineEngine)
                                    root.timelineEngine.setClipEffectParam(root.clipId, root.effectId, root.paramName, root.value)
                            }
                        }
                        onCanceled: {
                            if (root.dragIndex !== index) return
                            root.dragIndex = -1
                            root.dragLive = null
                            root.dragging = false
                            if (root.timelinePanel) root.timelinePanel.abortUndoableEdit()
                            if (root.timelineEngine)
                                root.timelineEngine.setClipEffectParam(root.clipId, root.effectId, root.paramName, root.value)
                        }
                        onDoubleClicked: {
                            if (!dot.isEndpoint) root.deletePoint(index)
                        }
                    }
                }
            }
        }

        // See EffectParamSlider.qml's holdRefreshTimer - same reasoning:
        // a paused pipeline doesn't repaint its held frame just because
        // a filter property changed, so a debounced re-seek forces
        // exactly one redraw once the drag pauses.
        Timer {
            id: holdRefreshTimer
            interval: 120
            repeat: false
            onTriggered: {
                if (!root.dragging) return
                if (!root.timelineEngine || root.timelineEngine.playing) return
                root.timelineEngine.seek(root.timelineEngine.position)
            }
        }
    }
}
