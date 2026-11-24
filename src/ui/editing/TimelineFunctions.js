// Timeline utility functions

function durationToSeconds(durationStr) {
    if (!durationStr || durationStr === "") return 5
    var parts = durationStr.split(":")
    if (parts.length < 3) return 5
    return (parseInt(parts[0]) || 0) * 3600 + (parseInt(parts[1]) || 0) * 60 + (parseFloat(parts[2]) || 0)
}

function getTrackIndexFromY(localY, trackHeight) {
    return Math.floor(localY / trackHeight)
}

function getTrackIdFromIndex(tracksModel, idx) {
    if (idx >= 0 && idx < tracksModel.count) {
        return tracksModel.get(idx).trackId
    }
    return null
}

function getTrackIndexFromId(tracksModel, trackId) {
    for (var i = 0; i < tracksModel.count; i++) {
        if (tracksModel.get(i).trackId === trackId) return i
    }
    return -1
}

function getTrackIdFromY(tracksModel, localY, trackHeight) {
    var idx = getTrackIndexFromY(localY, trackHeight)
    return getTrackIdFromIndex(tracksModel, idx)
}

function getTrackType(tracksModel, trackId) {
    for (var i = 0; i < tracksModel.count; i++) {
        if (tracksModel.get(i).trackId === trackId) {
            return tracksModel.get(i).type
        }
    }
    return null
}

function getTrackYPosition(tracksModel, trackId, trackHeight) {
    for (var i = 0; i < tracksModel.count; i++) {
        if (tracksModel.get(i).trackId === trackId) {
            return i * trackHeight
        }
    }
    return 0
}

function canPlaceClipAtTime(clipsModel, trackId, startTime, durationSeconds, excludeClipId) {
    var newStart = startTime
    var newEnd = startTime + durationSeconds
    var tolerance = 0.01

    for (var i = 0; i < clipsModel.count; i++) {
        var clip = clipsModel.get(i)
        if (excludeClipId && clip.clipId === excludeClipId) continue
        if (clip.trackId !== trackId) continue

        var otherStart = clip.startTime
        var otherEnd = clip.startTime + clip.durationSeconds

        if ((newStart + tolerance) < otherEnd && (newEnd - tolerance) > otherStart) {
            return false
        }
    }
    return true
}

function deleteSelectedClip(clipsModel, selectedClipId, updateTimelineEngine, checkAllClipNeighbors) {
    if (selectedClipId === "") return ""
    for (var i = 0; i < clipsModel.count; i++) {
        if (clipsModel.get(i).clipId === selectedClipId) {
            clipsModel.remove(i)
            if (updateTimelineEngine) updateTimelineEngine()
            Qt.callLater(checkAllClipNeighbors)
            return ""
        }
    }
    return selectedClipId
}

function splitAtPlayhead(timelineEngine, clipsModel, updateTimelineEngine, checkAllClipNeighbors) {
    if (!timelineEngine) return
    var playheadSeconds = timelineEngine.position / 1000.0
    var clipsToSplit = []

    for (var i = 0; i < clipsModel.count; i++) {
        var c = clipsModel.get(i)
        if (playheadSeconds > c.startTime && playheadSeconds < c.startTime + c.durationSeconds) {
            clipsToSplit.push({ index: i, data: c })
        }
    }

    if (clipsToSplit.length === 0) return

    for (var j = 0; j < clipsToSplit.length; j++) {
        var cd = clipsToSplit[j].data
        var firstPartDuration = playheadSeconds - cd.startTime
        var secondPartDuration = (cd.startTime + cd.durationSeconds) - playheadSeconds

        clipsModel.setProperty(clipsToSplit[j].index, "durationSeconds", firstPartDuration)

        clipsModel.append({
            clipId: "clip_" + Date.now() + "_" + j,
            trackId: cd.trackId,
            itemName: cd.itemName,
            itemPath: cd.itemPath,
            startTime: playheadSeconds,
            durationSeconds: secondPartDuration,
            hasVideo: cd.hasVideo,
            hasAudio: cd.hasAudio,
            sourceOffset: cd.sourceOffset + firstPartDuration,
            hasTransition: false
        })
    }

    if (updateTimelineEngine) updateTimelineEngine()
    Qt.callLater(checkAllClipNeighbors)
}

function zoomToFit(clipsModel, flickable, minPPS, maxPPS) {
    var maxEnd = 10
    for (var i = 0; i < clipsModel.count; i++) {
        var clip = clipsModel.get(i)
        var clipEnd = clip.startTime + clip.durationSeconds
        if (clipEnd > maxEnd) maxEnd = clipEnd
    }
    maxEnd *= 1.1

    var availableWidth = flickable.width - 20
    var newPPS = availableWidth / maxEnd
    flickable.contentX = 0
    return Math.max(minPPS, Math.min(maxPPS, newPPS))
}

function zoomIn(flickable, currentPPS, maxPPS) {
    var centerTime = (flickable.contentX + flickable.width / 2) / currentPPS
    var newPPS = Math.min(maxPPS, currentPPS * 1.25)
    flickable.contentX = Math.max(0, centerTime * newPPS - flickable.width / 2)
    return newPPS
}

function zoomOut(flickable, currentPPS, minPPS) {
    var centerTime = (flickable.contentX + flickable.width / 2) / currentPPS
    var newPPS = Math.max(minPPS, currentPPS / 1.25)
    flickable.contentX = Math.max(0, centerTime * newPPS - flickable.width / 2)
    return newPPS
}

function setZoomLevel(flickable, currentPPS, minPPS, maxPPS, level) {
    var centerTime = (flickable.contentX + flickable.width / 2) / currentPPS
    var newPPS = minPPS + (maxPPS - minPPS) * level
    flickable.contentX = Math.max(0, centerTime * newPPS - flickable.width / 2)
    return newPPS
}
