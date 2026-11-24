import QtQuick
import QtQuick.Controls

Rectangle {
    id: rulerRow

    property var timeline
    property var timelineEngine
    property var contentFlickable

    // Exposes rulerMouse's own scrub state to TimelinePanel.qml, so its
    // playhead auto-follow logic (ensurePlayheadVisible()) can tell "the
    // user is actively dragging the playhead cursor right now" apart from
    // "the playhead is moving because of normal playback" - without this,
    // auto-follow would yank the view out from under an in-progress scrub.
    property alias scrubbing: rulerMouse.scrubbing

    color: palette.base

    Row {
        anchors.fill: parent
        spacing: 0

        // Sequence label
        Rectangle {
            width: 150
            height: parent.height
            color: palette.button
            border.color: palette.base
            border.width: 1

            Text {
                anchors.centerIn: parent
                text: "Sequence"
                color: "#ccc"
                font.bold: true
            }
        }

        // Ruler area
        Rectangle {
            width: parent.width - 150
            height: parent.height
            color: palette.alternateBase
            border.color: palette.base
            border.width: 1
            clip: true

            // Click-and-drag to scrub + mouse tracking. Press seeks
            // immediately (so a plain click still works); while held, a
            // throttled timer re-seeks to the latest mouse position at
            // most every 120ms (same interval/idiom as
            // EffectParamSlider.qml's holdRefreshTimer) instead of once
            // per pixel of movement, which would flood the pipeline with
            // seeks faster than it can service them. Release always does
            // one final, frame-exact seek.
            MouseArea {
                id: rulerMouse
                anchors.fill: parent
                z: 10
                hoverEnabled: true
                propagateComposedEvents: false

                property bool scrubbing: false
                property real pendingScrubMs: -1

                function timeMsAt(mx) {
                    var timeX = mx + rulerFlickable.contentX
                    var ms = timeX / timeline.pixelsPerSecond * 1000
                    return Math.max(0, Math.min(ms, timeline.totalSeconds * 1000))
                }

                onPressed: function(mouse) {
                    scrubbing = true
                    pendingScrubMs = -1
                    if (timelineEngine) timelineEngine.seek(timeMsAt(mouse.x))
                    scrubThrottle.start()
                    mouse.accepted = true
                }

                onPositionChanged: function(mouse) {
                    var timeX = mouse.x + rulerFlickable.contentX
                    timeline.mouseTimeSeconds = Math.max(0, timeX / timeline.pixelsPerSecond)
                    if (!scrubbing) return
                    pendingScrubMs = timeMsAt(mouse.x)
                }

                onReleased: function(mouse) {
                    scrubbing = false
                    scrubThrottle.stop()
                    if (timelineEngine) timelineEngine.seek(timeMsAt(mouse.x))
                    pendingScrubMs = -1
                    mouse.accepted = true
                }

                onCanceled: {
                    scrubbing = false
                    scrubThrottle.stop()
                    if (pendingScrubMs >= 0 && timelineEngine) timelineEngine.seek(pendingScrubMs)
                    pendingScrubMs = -1
                }

                onExited: {
                    if (!scrubbing) timeline.mouseTimeSeconds = 0
                }

                Timer {
                    id: scrubThrottle
                    interval: 120
                    repeat: true
                    onTriggered: {
                        if (!rulerMouse.scrubbing) { stop(); return }
                        if (rulerMouse.pendingScrubMs < 0) return
                        // fast=true: KEY_UNIT seek (snaps to nearest keyframe
                        // instead of decoding forward to the exact frame) -
                        // an ACCURATE seek here was measured to take longer
                        // than this timer's own interval under a heavy,
                        // effect-laden multi-clip composition, wedging the
                        // pipeline's async seek state for seconds at a time.
                        if (timelineEngine) timelineEngine.seek(rulerMouse.pendingScrubMs, true)
                        rulerMouse.pendingScrubMs = -1
                    }
                }
            }

            // Scroll wheel handler
            WheelHandler {
                onWheel: function(event) {
                    var delta = event.angleDelta.y || event.angleDelta.x
                    if (event.modifiers & Qt.ControlModifier) {
                        // Ctrl + scroll = zoom
                        if (delta > 0) {
                            timeline.zoomIn()
                        } else {
                            timeline.zoomOut()
                        }
                    } else {
                        // Normal scroll = horizontal pan
                        contentFlickable.contentX = Math.max(0, Math.min(
                            contentFlickable.contentX - delta * 2,
                            contentFlickable.contentWidth - contentFlickable.width
                        ))
                    }
                }
            }

            Flickable {
                id: rulerFlickable
                anchors.fill: parent
                contentWidth: timeline.pixelsPerSecond * timeline.totalSeconds
                contentHeight: height
                boundsBehavior: Flickable.StopAtBounds
                clip: true
                interactive: false

                onContentXChanged: {
                    if (contentFlickable.contentX !== contentX) {
                        contentFlickable.contentX = contentX
                    }
                }

                Connections {
                    target: contentFlickable
                    function onContentXChanged() {
                        if (rulerFlickable.contentX !== contentFlickable.contentX) {
                            rulerFlickable.contentX = contentFlickable.contentX
                        }
                    }
                }

                // Adaptive tick spacing + windowing. totalSeconds is now
                // derived from actual project length (TimelinePanel.qml),
                // not hardcoded to 120 - a one-tick-per-second Repeater
                // (the old approach) would mean thousands of delegates for
                // any real-length project. Pick the smallest candidate
                // interval that keeps ticks at least ~60px apart at the
                // current zoom, and only instantiate ticks actually
                // within the visible range (+ a small margin each side).
                readonly property var tickCandidates: [1, 2,5,10, 15, 30, 60, 300, 600, 1800, 3600]
                readonly property int tickSeconds: {
                    for (var i = 0; i < tickCandidates.length; i++) {
                        if (tickCandidates[i] * timeline.pixelsPerSecond >= 60) return tickCandidates[i]
                    }
                    return tickCandidates[tickCandidates.length - 1]
                }
                readonly property int firstTickIndex: Math.max(0, Math.floor(contentX / (tickSeconds * timeline.pixelsPerSecond)) - 1)
                readonly property int visibleTickCount: Math.ceil(width / (tickSeconds * timeline.pixelsPerSecond)) + 3

                function formatTickLabel(seconds) {
                    if (seconds < 60) return String(seconds)
                    var m = Math.floor(seconds / 60)
                    var s = seconds % 60
                    return m + ":" + String(s).padStart(2, '0')
                }

                // Time markers - absolutely positioned (NOT a Row of
                // fixed-width blocks, since tick spacing is no longer 1
                // delegate per second) and windowed to the visible range.
                Repeater {
                    model: rulerFlickable.visibleTickCount
                    Item {
                        property int tickIndex: rulerFlickable.firstTickIndex + index
                        property real tickTimeSeconds: tickIndex * rulerFlickable.tickSeconds
                        x: tickTimeSeconds * timeline.pixelsPerSecond
                        y: 0
                        width: 1
                        height: rulerFlickable.height
                        visible: tickTimeSeconds <= timeline.totalSeconds

                        Rectangle {
                            x: 0
                            y: parent.height - 10
                            width: 1
                            height: 10
                            color: "#666"
                        }

                        Text {
                            x: 2
                            y: 2
                            text: rulerFlickable.formatTickLabel(tickTimeSeconds)
                            color: "#aaa"
                            font.pixelSize: 9
                        }
                    }
                }

                // Playhead triangle
                Canvas {
                    id: playheadTriangle
                    x: timelineEngine ? (timelineEngine.position / 1000) * timeline.pixelsPerSecond - 10 : -10
                    y: parent.height - 12
                    width: 20
                    height: 12
                    z: 100

                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        ctx.fillStyle = "#ff4444"
                        ctx.beginPath()
                        ctx.moveTo(10, 12)
                        ctx.lineTo(20, 0)
                        ctx.lineTo(0, 0)
                        ctx.fill()
                    }
                }
            }
        }
    }
}
