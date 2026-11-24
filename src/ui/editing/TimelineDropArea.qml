import QtQuick
import QtQuick.Controls
import VideoEditor 1.0

DropArea {
    id: dropArea

    property var timeline
    property var clips
    property var workspace: null  // Reference to EditingWorkspace
    property var flickable: null  // Reference to Flickable for coordinate mapping
    property int headerWidth: 0  // Track headers width to offset x coordinate

    // Preview state
    property bool showPreview: false
    property real previewX: 0
    property real previewDuration: 0
    property string previewVideoTrackId: ""
    property string previewAudioTrackId: ""
    property string previewName: ""
    property bool previewIsValid: true
    property bool previewHasAudio: true
    property bool previewHasVideo: true

    // Store last drag position for recalculation during scroll
    property real lastDragX: 0
    property real lastDragY: 0

    // "project-bin-clip": an item dragged out of the Project Bin.
    // "new-title-clip":   the Effects panel's "Titles" entry - a clip
    //                     GENERATOR, not an effect (see
    //                     EffectBrowserPanel.qml). It speaks the same
    //                     "application/x-video-clip" payload, with
    //                     clipKind "title" and no itemId, so everything
    //                     below (preview, wall-snapping, placement) is
    //                     shared; the only extra step at drop time is
    //                     minting the backing Project Bin item.
    // Effect presets use a third key ("effect-preset") which only
    // TimelineClip.qml's own DropArea accepts, so an apply-to-clip drag
    // can never be mistaken for a create-a-clip drag here.
    keys: ["project-bin-clip", "new-title-clip"]

    // Recalculate preview position when flickable scrolls
    Connections {
        target: flickable
        function onContentXChanged() {
            if (showPreview && flickable) {
                // Recalculate using last known drag position
                updatePreviewPosition(lastDragX, lastDragY)
            }
        }
    }

    onEntered: function(drag) {
        console.log("TimelineDropArea: drag entered, keys:", drag.keys, "pos:", drag.x, drag.y)
        drag.accepted = true

        // Parse clip data for preview
        if (drag.source && drag.source.Drag && drag.source.Drag.mimeData) {
            var md = drag.source.Drag.mimeData
            if (md["application/x-video-clip"]) {
                var cd = JSON.parse(md["application/x-video-clip"])
                previewDuration = timeline.durationToSeconds(cd.duration)
                previewName = cd.itemName || "Clip"
                // Live lookup instead of the drag-start snapshot (cd.hasAudio) -
                // that snapshot is captured right when the drag begins, which
                // can race ahead of MetadataExtractor's async audio-codec probe
                // for a file just added moments earlier, wrongly reporting "no
                // audio" for files that do have an audio track.
                previewHasAudio = cd.itemId ? Backend.projectBinModel.itemHasAudio(cd.itemId) : (cd.hasAudio !== false)
                previewHasVideo = cd.itemId ? Backend.projectBinModel.itemHasVideo(cd.itemId) : (cd.hasVideo !== false)
                showPreview = true
                console.log("TimelineDropArea: Preview enabled, duration:", previewDuration, "name:", previewName, "hasVideo:", previewHasVideo, "hasAudio:", previewHasAudio)
            }
        }
    }

    function updatePreviewPosition(dragX, dragY) {
        // drag.x is relative to DropArea (starts at x=0), subtract headerWidth to get track area position
        var trackX = dragX - headerWidth
        // Add flickable scroll position to get content position
        var contentX = trackX + (flickable ? flickable.contentX : 0)

        // Edge scrolling logic (same as TimelineClip)
        if (flickable) {
            var scrollZone = 50
            var viewportWidth = flickable.width

            if (trackX > viewportWidth - scrollZone) {
                // Near right edge, scroll right
                timeline.scrollDirection = 1
            } else if (trackX < scrollZone) {
                // Near left edge, scroll left
                timeline.scrollDirection = -1
            } else {
                // In the middle, no scrolling
                timeline.scrollDirection = 0
            }
        }

        // Snap to 0 if negative
        var dropX = Math.max(0, contentX)
        var targetTrackId = timeline.getTrackIdFromY(dragY)

        if (!targetTrackId) {
            previewIsValid = false
            hidePreviewShowProxy()
            return
        }

        var targetTrackType = timeline.getTrackType(targetTrackId)

        // Drop validation based on track type and source content
        if (targetTrackType === "video") {
            // Video track: only if source has video
            if (!previewHasVideo) {
                previewIsValid = false
                hidePreviewShowProxy()
                return
            }
        } else if (targetTrackType === "audio") {
            // Audio track: only if source is audio-only (no video)
            if (previewHasVideo) {
                previewIsValid = false
                hidePreviewShowProxy()
                return
            }
        } else {
            previewIsValid = false
            hidePreviewShowProxy()
            return
        }

        previewVideoTrackId = targetTrackId

        // Find corresponding audio track (only for video tracks that split into V+A)
        var audioTrackId = ""
        if (targetTrackType === "video") {
            audioTrackId = timeline.getCorrespondingAudioTrack(targetTrackId) || ""
        }
        previewAudioTrackId = audioTrackId

        // Calculate clip width in pixels
        var clipWidth = previewDuration * timeline.pixelsPerSecond

        // Find valid position using same logic as TimelineClip
        var result = findValidDropPosition(dropX, clipWidth, targetTrackId, audioTrackId)

        if (result.valid) {
            previewX = result.x
            previewIsValid = true
            // Hide drag proxy, show preview
            if (workspace) {
                workspace.timelineDropActive = true
            }
        } else {
            previewIsValid = false
            hidePreviewShowProxy()
        }
    }

    onPositionChanged: function(drag) {
        if (!showPreview) return

        // Store last drag position
        lastDragX = drag.x
        lastDragY = drag.y

        // Update preview
        updatePreviewPosition(drag.x, drag.y)
    }

    function findValidDropPosition(suggestedX, clipWidth, videoTrackId, audioTrackId) {
        // Find walls (obstacles) on video track
        var videoWalls = findTrackWalls(suggestedX, clipWidth, videoTrackId, null)

        // Find walls on audio track if applicable
        var audioWalls = { leftWall: 0, rightWall: 99999999 }
        if (previewHasAudio && audioTrackId) {
            audioWalls = findTrackWalls(suggestedX, clipWidth, audioTrackId, null)
        }

        // Combined walls - most restrictive
        var leftWall = Math.max(videoWalls.leftWall, audioWalls.leftWall)
        var rightWall = Math.min(videoWalls.rightWall, audioWalls.rightWall)

        // Calculate final (snapped) position - the wall/bucket logic
        // above is kept ONLY for this: where to snap the drop so it
        // touches a neighboring clip cleanly instead of needing
        // pixel-perfect aim. It is NOT trusted for validity - see
        // TimelinePanel.hasOverlapInRange()'s comment: the center-based
        // bucket it's built on can pick the wrong neighbor as "the"
        // wall when the dragged item is much wider than the gap (a
        // title's fixed default duration into a short gap between two
        // existing clips, confirmed by a real user report), silently
        // under-reporting how far away the true obstacle is. Validity
        // is decided solely by the direct, authoritative overlap check
        // below, against the final (already-snapped) position.
        var finalX = suggestedX
        if (finalX < leftWall) finalX = leftWall
        if (finalX + clipWidth > rightWall) finalX = rightWall - clipWidth

        var startSec = finalX / timeline.pixelsPerSecond
        var endSec = (finalX + clipWidth) / timeline.pixelsPerSecond
        var videoOverlap = timeline.hasOverlapInRange(videoTrackId, startSec, endSec, null)
        var audioOverlap = previewHasAudio && audioTrackId &&
              timeline.hasOverlapInRange(audioTrackId, startSec, endSec, null)
        var isValid = finalX >= 0 && !videoOverlap && !audioOverlap

        return { valid: isValid, x: finalX }
    }

    function findTrackWalls(suggestedX, clipWidth, trackId, excludeClipId) {
        var mouseCenter = suggestedX + (clipWidth / 2)
        var centerSeconds = mouseCenter / timeline.pixelsPerSecond
        var excludeIds = excludeClipId ? [excludeClipId] : []
        var walls = timeline.getTrackWallsIndexed(trackId, centerSeconds, excludeIds)
        return { leftWall: walls.l, rightWall: walls.r }
    }

    function hidePreviewShowProxy() {
        console.log("TimelineDropArea.hidePreviewShowProxy() called - invalid position, showing drag proxy")
        // Show the drag proxy again (invalid position)
        if (workspace) {
            workspace.timelineDropActive = false
        }
    }

    onExited: {
        console.log("TimelineDropArea: drag EXITED - showPreview was:", showPreview, "previewX was:", previewX, "previewIsValid was:", previewIsValid)
        showPreview = false
        previewVideoTrackId = ""
        previewAudioTrackId = ""

        // Stop scrolling
        if (timeline) {
            timeline.scrollDirection = 0
        }

        // Show the drag proxy again
        if (workspace) {
            workspace.timelineDropActive = false
            console.log("TimelineDropArea: Set timelineDropActive = false")
        }
    }

    onDropped: function(drop) {
        console.log("TimelineDropArea: drop received")
        showPreview = false

        // Stop scrolling
        if (timeline) {
            timeline.scrollDirection = 0
        }

        // Hide the drag proxy
        if (workspace) {
            workspace.timelineDropActive = false
        }

        if (!drop.source.Drag.mimeData) return

        // Only accept if preview was valid
        if (!previewIsValid) {
            drop.accepted = false
            return
        }

        var md = drop.source.Drag.mimeData
        var dropTime = previewX / timeline.pixelsPerSecond  // Use calculated preview position

        if (!previewVideoTrackId) {
            drop.accepted = false
            return
        }

        if (md["application/x-video-clip"]) {
            timeline.beginUndoableEdit()
            var cd = JSON.parse(md["application/x-video-clip"])
            var ds = timeline.durationToSeconds(cd.duration)
            var sourceItemId = cd.itemId || ""
            // Live lookup at drop time (not the drag-start snapshot) - see
            // the matching comment in onEntered above.
            var hasAudioTrack = sourceItemId ? Backend.projectBinModel.itemHasAudio(sourceItemId) : (cd.hasAudio !== false)
            var hasVideoTrack = sourceItemId ? Backend.projectBinModel.itemHasVideo(sourceItemId) : (cd.hasVideo !== false)

            var timestamp = Date.now()

            // Get waveform path from CacheManager if available
            var waveformPath = ""
            if (sourceItemId && Backend.cacheManager.isWaveformReady(sourceItemId)) {
                waveformPath = Backend.cacheManager.getWaveformPath(sourceItemId)
            }

            var targetTrackType = timeline.getTrackType(previewVideoTrackId)

            if (cd.clipKind === "title") {
                // TITLE bin item: a generated clip with no file behind
                // it, so no V+A split and no link group. The params are
                // a STAMPED COPY of the bin item's params as of this
                // drop - editing the bin entry afterwards deliberately
                // does not reach back into clips already placed (same
                // as a media file's metadata, which is read when used,
                // not live-bound).
                var titleClipId = "title_" + timestamp
                var titleLabel = (cd.itemName || "Title").substring(0, 24)
                var titleJson = cd.titleParams || Backend.defaultTitleParams(titleLabel)
                // Every clip on the timeline is sourced from a Project
                // Bin item; a title is no different, it just has no file
                // behind it. Dragged FROM the bin, that item already
                // exists (sourceItemId above); dragged from the Effects
                // panel's "Titles" entry there is none yet, so mint one
                // here (it lands in the "Virtual" pseudo-folder) - the
                // bin-creation + place-a-clip pair collapsed into the
                // single drag gesture.
                var titleItemId = sourceItemId
                if (!titleItemId && Backend.projectBinModel.addTitleItem)
                    titleItemId = Backend.projectBinModel.addTitleItem(titleLabel, titleJson) || ""
                clips.append({
                    clipId: titleClipId,
                    trackId: previewVideoTrackId,
                    itemName: titleLabel,
                    itemPath: "",
                    startTime: dropTime,
                    durationSeconds: ds,
                    hasVideo: true,
                    hasAudio: false,
                    sourceOffset: 0,
                    hasTransition: false,
                    linkGroupId: "",
                    linkedClipId: "",
                    isLinked: false,
                    // The backing bin item. titleParams below stays a
                    // STAMPED COPY of it as of this drop (see above) -
                    // the id records provenance, it is not a live bind.
                    sourceItemId: titleItemId,
                    waveformPath: "",
                    clipKind: "title",
                    titleParams: titleJson
                })
                Backend.logOperation("title_drop", {
                    clipId: titleClipId, trackId: previewVideoTrackId,
                    startTime: dropTime, durationSeconds: ds, itemName: titleLabel,
                    binItemId: titleItemId
                })
            } else if (targetTrackType === "audio") {
                // Audio track: single audio-only clip
                var audioOnlyClipId = "clip_a_" + timestamp
                clips.append({
                    clipId: audioOnlyClipId,
                    trackId: previewVideoTrackId,
                    itemName: cd.itemName,
                    itemPath: cd.itemPath,
                    startTime: dropTime,
                    durationSeconds: ds,
                    hasVideo: false,
                    hasAudio: true,
                    sourceOffset: 0,
                    hasTransition: false,
                    linkGroupId: "",
                    linkedClipId: "",
                    isLinked: false,
                    sourceItemId: sourceItemId,
                    waveformPath: waveformPath
                })
                Backend.logOperation("clip_drop", {
                    clipId: audioOnlyClipId, trackId: previewVideoTrackId,
                    startTime: dropTime, durationSeconds: ds, itemName: cd.itemName
                })
            } else {
                // Video track: video + audio split with linked pair
                var videoClipId = "clip_v_" + timestamp
                var audioClipId = "clip_a_" + timestamp
                var linkGroupId = "link_" + timestamp

                var canCreateAudioClip = previewAudioTrackId &&
                                         hasAudioTrack &&
                                         hasVideoTrack

                // (No video-ness gate: audio-only items have no resolution, so
                // they yield null; a still image has one.)
                var videoFitJson = ""
                var fitFx = timeline.defaultFitEffectFor(sourceItemId)
                if (fitFx) videoFitJson = JSON.stringify([fitFx])

                clips.append({
                    clipId: videoClipId,
                    trackId: previewVideoTrackId,
                    itemName: cd.itemName,
                    itemPath: cd.itemPath,
                    startTime: dropTime,
                    durationSeconds: ds,
                    hasVideo: true,
                    hasAudio: false,
                    sourceOffset: 0,
                    hasTransition: false,
                    linkGroupId: canCreateAudioClip ? linkGroupId : "",
                    linkedClipId: canCreateAudioClip ? audioClipId : "",
                    isLinked: canCreateAudioClip,
                    sourceItemId: sourceItemId,
                    waveformPath: "",
                    // Project "Clip fitting" default (null = nothing to
                    // add: size unknown or identical to GES's own fit).
                    effects: videoFitJson
                })

                if (canCreateAudioClip) {
                    clips.append({
                        clipId: audioClipId,
                        trackId: previewAudioTrackId,
                        itemName: cd.itemName + " (Audio)",
                        itemPath: cd.itemPath,
                        startTime: dropTime,
                        durationSeconds: ds,
                        hasVideo: false,
                        hasAudio: true,
                        sourceOffset: 0,
                        hasTransition: false,
                        linkGroupId: linkGroupId,
                        linkedClipId: videoClipId,
                        isLinked: true,
                        sourceItemId: sourceItemId,
                        waveformPath: waveformPath
                    })
                }

                Backend.logOperation("clip_drop", {
                    videoClipId: videoClipId, videoTrack: previewVideoTrackId,
                    audioClipId: canCreateAudioClip ? audioClipId : "",
                    audioTrack: canCreateAudioClip ? previewAudioTrackId : "",
                    startTime: dropTime, durationSeconds: ds, itemName: cd.itemName
                })
            }

            if (timeline.updateTimelineEngine) {
                timeline.updateTimelineEngine()
            }

            drop.accept(Qt.CopyAction)
            Qt.callLater(timeline.checkAllClipNeighbors)
            timeline.commitUndoableEdit("Add clip")
        }
    }

    // Video clip preview
    Rectangle {
        id: videoPreview
        visible: showPreview && previewIsValid && previewVideoTrackId !== "" && timeline.getTrackType(previewVideoTrackId) === "video"
        x: headerWidth + previewX - (flickable ? flickable.contentX : 0)
        y: timeline ? timeline.getTrackYPosition(previewVideoTrackId) + 5 : 0
        width: previewDuration * (timeline ? timeline.pixelsPerSecond : 50)
        height: 50
        color: "#4a9eff"
        opacity: 0.7
        radius: 3
        border.color: "#88bbff"
        border.width: 2

        Text {
            anchors.centerIn: parent
            text: previewName
            color: "white"
            font.pixelSize: 10
            elide: Text.ElideRight
            width: parent.width - 10
        }
    }

    // Audio clip preview (linked audio on video track drop, or direct audio track drop)
    Rectangle {
        id: audioPreview
        visible: showPreview && previewIsValid && (
            (previewAudioTrackId !== "" && previewHasAudio && timeline.getTrackType(previewVideoTrackId) === "video") ||
            timeline.getTrackType(previewVideoTrackId) === "audio"
        )
        x: headerWidth + previewX - (flickable ? flickable.contentX : 0)
        y: {
            if (timeline.getTrackType(previewVideoTrackId) === "audio")
                return timeline ? timeline.getTrackYPosition(previewVideoTrackId) + 5 : 0
            return timeline ? timeline.getTrackYPosition(previewAudioTrackId) + 5 : 0
        }
        width: previewDuration * (timeline ? timeline.pixelsPerSecond : 50)
        height: 50
        color: "#ff9e4a"
        opacity: 0.7
        radius: 3
        border.color: "#ffcc88"
        border.width: 2

        Text {
            anchors.centerIn: parent
            text: timeline.getTrackType(previewVideoTrackId) === "audio" ? previewName : previewName + " (Audio)"
            color: "white"
            font.pixelSize: 10
            elide: Text.ElideRight
            width: parent.width - 10
        }
    }
}
