import QtQuick

Canvas {
    id: waveformCanvas

    property var waveformData: []
    property color waveformColor: "#ffcc80"
    property color backgroundColor: "transparent"
    property real sourceOffset: 0      // Kezdo ido masodpercben (forras offsetje)
    property real clipDuration: 1      // A klip idotartama masodpercben
    property int samplesPerSecond: 100 // Waveform file mintaveteli sebessege

    onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)

        if (!waveformData || waveformData.length === 0) return

        var centerY = height / 2

        // Szamitsuk ki, hogy melyik mintaktol meddig kell rajzolni
        var startSample = Math.floor(sourceOffset * samplesPerSecond)
        var endSample = Math.min(
            startSample + Math.ceil(clipDuration * samplesPerSecond),
            waveformData.length
        )

        var numSamples = endSample - startSample
        if (numSamples <= 0) return

        // Hany pixel jut egy mintara (vagy hany minta egy pixelre)
        var pixelsPerSample = width / numSamples

        ctx.fillStyle = waveformColor
        ctx.beginPath()

        // Felso hullam rajzolasa (max ertekek)
        ctx.moveTo(0, centerY)
        for (var x = 0; x < width; x++) {
            var sampleIndex = startSample + Math.floor(x / pixelsPerSample)
            if (sampleIndex >= waveformData.length) break
            if (sampleIndex < 0) continue

            var sample = waveformData[sampleIndex]
            if (!sample) continue

            var maxVal = sample.max || 0
            var y = centerY - (maxVal * centerY * 0.9)
            ctx.lineTo(x, y)
        }

        // Also hullam rajzolasa (min ertekek, visszafele)
        for (var x2 = width - 1; x2 >= 0; x2--) {
            var sampleIndex2 = startSample + Math.floor(x2 / pixelsPerSample)
            if (sampleIndex2 >= waveformData.length) continue
            if (sampleIndex2 < 0) continue

            var sample2 = waveformData[sampleIndex2]
            if (!sample2) continue

            var minVal = sample2.min || 0
            var y2 = centerY - (minVal * centerY * 0.9)
            ctx.lineTo(x2, y2)
        }

        ctx.closePath()
        ctx.fill()
    }

    onWaveformDataChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onSourceOffsetChanged: requestPaint()
    onClipDurationChanged: requestPaint()
}
