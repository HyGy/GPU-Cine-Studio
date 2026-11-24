import QtQuick
import QtQuick.Controls
import VideoEditor 1.0

Item {
    id: clipItem

    // Parent references
    property var timeline
    property var container
    property var flickable
    property var clips
    property var tracks

    // Expose model properties
    property string clipId: model.clipId
    property string trackId: model.trackId

    // Accessibility: egyedi, stabil azonosító UI-automatizáláshoz (AT-SPI),
    // mivel ez egy kézzel rajzolt Item, nem Qt Quick Control, és alapból
    // nem jelenne meg névvel az accessibility fában.
    objectName: "timelineClip_" + model.clipId
    Accessible.role: Accessible.ListItem
    Accessible.name: (model.itemName || "") + " [" + model.trackId + "]" + (model.mediaMissing ? " (missing media)" : "")

    // === VISUAL OVERLAP CALCULATION ===
    // Ha ez a klip átfedésben van egy transition-nel rendelkező klippel (B klip)
    property real overlapAmount: 0
    // The REAL cut point within the incoming overlap, measured from the
    // overlap's start - NOT necessarily overlapAmount/2.0. Differs from
    // the midpoint for a Kdenlive-imported asymmetric mixcut (see
    // KdenliveImporter.cpp's transitionCutOffset / TimelinePanel.qml's
    // incomingCutOffsetById); a natively-applied GCS transition
    // (TimelinePanel.applyTransition()) always writes duration/2.0 here,
    // so this is a strict generalization, not a behavior change for the
    // common case.
    property real incomingCutOffset: 0

    function calculateOverlapAmount() {
        if (!clips || !timeline) return 0
        // O(1) index lookup (timeline.overlapByClipId, rebuilt by
        // TimelinePanel.rebuildClipIndex() on every edit) instead of an
        // O(n) scan of the whole clips model per clip per edit.
        return timeline.overlapByClipId[model.clipId] || 0
    }

    function calculateIncomingCutOffset(overlap) {
        if (!timeline || !timeline.incomingCutOffsetById) return overlap / 2.0
        var v = timeline.incomingCutOffsetById[model.clipId]
        return v !== undefined ? v : overlap / 2.0
    }

    function updateOverlapAmount() {
        overlapAmount = calculateOverlapAmount()
        incomingCutOffset = calculateIncomingCutOffset(overlapAmount)

        // Deliberately NOT derived from timeline.clipTransitionZone():
        // that function returns at most ONE zone, and its outgoing branch
        // returns first, so for a clip that is both sides of two
        // different dissolves (the middle clip of an A->B->C chain) the
        // incoming zone is unreachable - it cannot express "both edges
        // constrained". The two conditions it is built from are read
        // directly here instead: a plain model field read plus one O(1)
        // hash lookup into the index rebuilt by
        // TimelinePanel.rebuildClipIndex(), i.e. no more expensive than
        // one clipTransitionZone() call. The `> 0` guards mirror that
        // function's own, so a stray hasTransition flag with zero
        // duration doesn't hide a handle.
        var incomingDur = (timeline && timeline.incomingTransDurById)
                            ? timeline.incomingTransDurById[model.clipId] : 0
        leftTrimmable = !(incomingDur > 0)
        rightTrimmable = !(model.hasTransition && model.transitionDuration > 0)
    }

    // Connections a timeline signal-hoz
    Connections {
        target: timeline
        function onRequestNeighborCheck() {
            clipItem.updateOverlapAmount()
        }
    }

    // === VISUAL POSITION/SIZE CALCULATION FUNCTIONS ===
    function calculateVisualX() {
        var baseX = model.startTime * timeline.pixelsPerSecond
        // Ha átfedésben vagyunk (B klip), az elejét levágom vizuálisan a
        // TÉNYLEGES vágáspontig (incomingCutOffset - alapesetben az
        // overlap fele, de Kdenlive-ból importált aszimmetrikus mixcut
        // esetén eltérhet attól, lásd incomingCutOffset kommentjét).
        if (overlapAmount > 0) {
            return baseX + (incomingCutOffset * timeline.pixelsPerSecond)
        }
        return baseX
    }

    function calculateVisualWidth() {
        // Trim amount is ADDITIVE, not either/or: a clip can be both the
        // outgoing side of one dissolve AND the incoming side of another
        // at the same time (the middle clip of an A->B->C chain). Each
        // half-trim is independent of the other - an early-return here
        // (only ever applying ONE of the two) left such a clip too WIDE,
        // its visual end overlapping into the NEXT clip's start, even
        // though calculateVisualX() below already correctly shifts the
        // clip's start rightward for the incoming half on its own.
        var trimSeconds = 0

        // Ha ennek a klipnek van transition-je (A klip), a végét vágom a
        // TÉNYLEGES vágáspontig - model.transitionCutOffset az overlap
        // elejétől mért vágáspont, a trim ettől a klip VÉGÉIG tart, azaz
        // (transDur - cutOffset). Alapesetben cutOffset == transDur/2.0,
        // tehát ez ugyanazt adja, mint a korábbi mindig-felező logika;
        // Kdenlive-ból importált aszimmetrikus mixcut esetén tér el.
        if (model.hasTransition) {
            var transDur = model.transitionDuration || timeline.defaultTransitionDuration
            var cutOffset = model.transitionCutOffset !== undefined ? model.transitionCutOffset : transDur / 2.0
            trimSeconds += (transDur - cutOffset)
        }

        // Ha ez a klip átfedésben van (B klip), az elejét vágom a
        // tényleges bejövő vágáspontig (incomingCutOffset).
        if (overlapAmount > 0) {
            trimSeconds += incomingCutOffset
        }

        return (model.durationSeconds - trimSeconds) * timeline.pixelsPerSecond
    }

    // Visszaköti a binding-eket drag után
    function rebindPosition() {
        x = Qt.binding(calculateVisualX)
        width = Qt.binding(calculateVisualWidth)
        // y was NEVER restored here before - drag code (updateSingleClipPosition()/
        // updateTransitionGroupPosition()) sets clipItem.y imperatively while
        // dragging, which breaks the declarative y binding below permanently.
        // A clip dragged even once would then keep a frozen literal y forever,
        // never reacting to a later track add/remove/reorder - the exact bug
        // trackGeometryRevision was added to fix, except it had nothing left
        // to re-evaluate for any clip that had already been moved.
        y = Qt.binding(function() {
            return (timeline.trackGeometryRevision, timeline.getTrackYPosition(model.trackId) + 5)
        })
    }

    // Vizuális pozíció és méret binding-ek
    x: calculateVisualX()
    // The comma-expression read of trackGeometryRevision is deliberate and
    // load-bearing: getTrackYPosition() reads timeline.trackIndexById via
    // a plain function call, which QML's binding dependency tracker does
    // NOT pick up on its own (same non-reactivity trap documented for
    // clipTransitionZone()) - without this, a track add/remove would
    // leave every surviving clip's y stuck at its old row until some
    // unrelated binding happened to re-evaluate it.
    y: (timeline.trackGeometryRevision, timeline.getTrackYPosition(model.trackId) + 5)
    width: calculateVisualWidth()
    height: 50

    property bool isDropValid: true
    property bool isDragging: false
    property real dragStartX: 0
    property real dragStartY: 0
    property string itemStartTrackId: ""
    property real itemStartTime: 0
    property real lastMouseX: 0
    property real lastMouseY: 0
    property bool actuallyMoved: false
    // Set in onPressed when a plain (no-modifier) click landed on a clip
    // that's already part of a larger selection - we deliberately don't
    // collapse the selection right away there (so the whole group can
    // still be dragged together), but if the gesture turns out to be a
    // plain click with no actual drag, onReleased uses this to do the
    // collapse retroactively. Without it, a no-modifier click on any
    // member of an existing multi-selection never reduced the selection
    // to just that clip - the user had to click every other clip
    // individually to deselect them.
    property bool pendingSelectOnlyOnRelease: false
    // Tracks whether THIS drag gesture opened an undo scope (via
    // timeline.beginUndoableGesture() on first real movement) so
    // onReleased/onCanceled know whether to commit/abort it.
    property bool undoScopeOpen: false

    // Linked movement properties
    property string linkedTrackId: "" // Ez az eredeti sáv ID a húzás kezdetekor

    // Transition group movement properties. NOTE: this group's state is
    // deliberately MODEL-DERIVED, not delegate-derived - no live QML item
    // reference (TimelineClip/TimelineTransition instance) is ever stored
    // across more than one statement. Previously linkedVisualItem/
    // transitionGroupItems/transitionGroupOverlays held live references
    // across the whole drag (onPressed -> every mouse-move ->
    // onReleased); under a future filtered/virtualized clip view, a group
    // member scrolled out of view has NO delegate, so those references
    // would silently be wrong/stale mid-drag (edgeScrollTimer auto-scrolls
    // during drag, so this isn't an edge case). Every value needed to
    // move/save the group is captured from the MODEL in onPressed instead
    // (mirroring TimelineClip.calculateVisualX()'s and
    // TimelineTransition.qml's own x-binding formulas), and any live
    // delegate is resolved fresh, on demand, via findClipVisualItem()/
    // findTransitionOverlay() - which return null for an off-screen
    // member rather than a dangling reference, and every call site treats
    // that null as "nothing to visually update right now", not an error.
    property var transitionGroupClipIds: []  // A transition csoportban lévő összes clipId
    property var transitionGroupStartTimes: {} // Eredeti startTime-ok csoportonként
    property var transitionGroupStartTracks: {} // Eredeti trackId-k csoportonként
    property var transitionGroupVisualX: {} // Eredeti vizuális X pozíciók (overlap-pel együtt!)
    property var transitionGroupOverlayX: {}  // Transition overlay eredeti X pozíciók
    property var transitionGroupOverlayOwners: []  // Azon csoporttag clipId-k, amelyeknek van aktív transition overlay-je
    property var transitionGroupLinked: {}    // clipId -> isLinked (modellből, onPressed-ben cache-elve)
    property var transitionGroupLinkedId: {}  // clipId -> linkedClipId (modellből, onPressed-ben cache-elve)
    property var transitionGroupEndX: {}      // clipId -> (startTime+durationSeconds)*pps (onPressed-ben cache-elve)
    // A csoport commitolt elmozdulása (onReleased menti ebből, nem egy
    // élő delegate .x-éből olvasva) - updateTransitionGroupPosition()
    // állítja be minden sikeres pozíció-frissítésnél.
    property real finalDeltaSeconds: 0
    property int finalTrackDelta: 0  // Track eltolódás (onReleased-hez)
    property string finalTargetTrackId: ""  // Cél track ID (onReleased-hez)
    // Igaz/hamis egyszer kiszámolva onPressed-ben, amikor
    // transitionGroupClipIds felépül - ez nem változhat a drag alatt
    // (a modell nem módosul addig), ezért újraszámolása minden egyes
    // egérmozgásnál (ahogy korábban updateDragPosition()/onReleased is
    // tette, egy O(g*n^2) beágyazott cikluson keresztül) tiszta, felesleges
    // munka volt - ez volt a legköltségesebb hotspot nagy projekteknél,
    // mert ez a drag mozgás minden egyes frame-jén lefutott.
    property bool draggingTransitionGroup: false

    // True when this drag's "group" is really an arbitrary multi-
    // selection (more than one clip Ctrl/Shift-selected, not just a
    // transition-chain/linked-pair closure) - set once in onPressed,
    // same "computed once, never mid-drag" discipline as
    // draggingTransitionGroup above. Gates two different behaviours in
    // updateTransitionGroupPosition()/onReleased: track CHANGE is
    // disabled entirely (moving several clips across different tracks
    // to one target track isn't expressible - see groupMinDeltaX/
    // MaxDeltaX below), and the group's position is clamped via a
    // press-time PER-MEMBER delta window instead of the transition-
    // group code's single rigid bounding-box wall check (which assumes
    // a spatially-contiguous chain - a scattered multi-selection isn't
    // one, and would get wall-blocked by anything merely sitting
    // between two selected clips' time spans on any involved track).
    property bool multiSelectDrag: false
    // Tightest [min,max] time-delta (PIXELS, matching
    // transitionGroupVisualX's own unit) every selected clip can move
    // by without any one of them colliding with a non-selected
    // neighbour - computed once in onPressed from each member's own
    // walls (getTrackWallsExcludeGroup already excludes every OTHER
    // selected clip, so clips within the selection never wall each
    // other). 0 is always inside this range (the press-time layout is
    // already legal), so clamping into it can never produce an empty/
    // invalid range - unlike the single-clip-move wall check, there is
    // no "doesn't fit" case to refuse here, only "stops at the
    // tightest neighbour".
    property real groupMinDeltaX: 0
    property real groupMaxDeltaX: 0

    // Waveform support
    property string waveformPath: model.waveformPath || ""
    // Reactive binding, NOT an imperatively-set property anymore - reads
    // model.sourceOffset/model.durationSeconds directly as call
    // arguments, so QML's dependency tracker picks them up the same way
    // it already does for model.clipId (direct role reads on THIS
    // delegate are always reactive; the non-reactivity trap elsewhere in
    // this file only applies to reading OTHER rows via ListModel.get()
    // inside a called function). This means trimming (which changes
    // sourceOffset/durationSeconds without touching waveformPath) now
    // correctly re-fetches the clip's own slice instead of showing a
    // stale one.
    //
    // loadWaveformSlice() (WaveformGenerator, C++) returns ONLY this
    // clip's own slice of the source file's waveform, from a cache
    // parsed once per file - previously every clip delegate loaded and
    // held the ENTIRE source file's waveform data (tens of MB of JS heap
    // for a single clip cut from a long source), reading the file from
    // disk again on every delegate creation.
    // Set by the trim handles below while a drag is actually in progress
    // on THIS clip, so the waveform preview tracks the live (uncommitted)
    // trim instead of staying stale until commitTrim() writes the model -
    // without this, dragging an audio clip's trim handle visually
    // "squeezes" the whole old-duration waveform into the shrinking
    // width (clipDuration/sourceOffset below only changing at commit),
    // then snaps to the correct, smaller slice on release.
    property bool trimPreviewActive: false
    property real trimPreviewSourceOffset: 0
    property real trimPreviewDuration: 0

    property var waveformData: {
        if (!timeline || !waveformPath || waveformPath.length === 0) return []
        if (timeline.getTrackType(model.trackId) !== "audio") return []
        var off = trimPreviewActive ? trimPreviewSourceOffset : (model.sourceOffset || 0)
        var dur = trimPreviewActive ? trimPreviewDuration : model.durationSeconds
        return Backend.waveformGenerator.loadWaveformSlice(waveformPath, off, dur) || []
    }

    // Link support
    property bool isLinked: model.isLinked || false
    property string linkedClipId: model.linkedClipId || ""

    // Set by TimelineEngine's clipMediaMissing signal (relayed via
    // EditingWorkspace.qml) when the clip's source file couldn't be
    // found on disk at the last setClips() - e.g. a Kdenlive-imported
    // placeholder whose original media hasn't been relinked yet. Purely
    // a display marker; the clip's position, duration, name and
    // effects are completely unaffected (see KdenliveImporter's "use
    // placeholder" notes in TODO.txt) and it plays normally again on
    // its own, with no re-import, the next time setClips() runs after
    // the file becomes available.
    property bool isMediaMissing: model.mediaMissing || false

    Rectangle {
        anchors.fill: parent
        color: clipItem.isMediaMissing ? "#5a5a5a"
             : (timeline.getTrackType(model.trackId) === "video" ? "#4a9eff" : "#ff9e4a")
        readonly property bool isPrimary: timeline.selectedClipId === model.clipId
        readonly property bool inSelection: !isPrimary && timeline.isClipInSelection && timeline.isClipInSelection(model.clipId)
        readonly property bool isLinkedPartnerSelected: !isPrimary && !inSelection && clipItem.isLinked && timeline.isClipSelected && timeline.isClipSelected(model.clipId)
        border.color: {
            if (isPrimary) return "white"
            if (inSelection) return "#cccccc"
            if (isLinkedPartnerSelected) return "#7a7aff"
            return "#222"
        }
        border.width: (isPrimary || inSelection || isLinkedPartnerSelected) ? 2 : 1
        radius: 3
        opacity: clipItem.isDragging ? 0.7 : 0.9

        // Drop target for an effect preset dragged from
        // EffectBrowserPanel.qml - DropArea takes no mouse events at
        // all, so it can never interfere with this clip's own move-
        // drag (plain MouseArea-based, above) or its trim handles; the
        // two also never overlap in time, since the clip-move drag
        // carries Drag.keys ["timeline-clip"], which this DropArea's
        // own `keys` filter rejects outright (and vice versa - the
        // clip itself isn't a DropArea target for its own drag key).
        DropArea {
            id: fxDropArea
            anchors.fill: parent
            keys: ["effect-preset"]

            // A preset carries mediaType ("video"/"audio" - see
            // EffectBrowserPanel.qml) - every registry entry it maps to
            // only exists on ONE track type's GES element (a video top-
            // effect's properties/GstFramePositioner simply aren't
            // there on an audio track's GESAudioUriSource, and vice
            // versa for "volume"), so e.g. "Position and Zoom" must be
            // refused on an audio clip, not just cosmetically "work for
            // nothing" - computed on hover-enter so the highlight below
            // can show the right colour BEFORE the user commits to the
            // drop, not just after a silently-ignored one.
            property bool dropCompatible: false

            function presetFromEvent(event) {
                var md = event.source && event.source.Drag ? event.source.Drag.mimeData : null
                if (!md || !md["application/x-effect-preset"]) return null
                try { return JSON.parse(md["application/x-effect-preset"]) }
                catch (e) { return null }
            }

            onEntered: function(drag) {
                var preset = presetFromEvent(drag)
                dropCompatible = !!preset && (!preset.mediaType || preset.mediaType === timeline.getTrackType(model.trackId))
            }
            onExited: { dropCompatible = false }

            onDropped: function(drop) {
                var preset = presetFromEvent(drop)
                if (!preset) return
                if (preset.mediaType && preset.mediaType !== timeline.getTrackType(model.trackId)) return
                timeline.applyPresetToClipsFromDrop(preset, model.clipId)
                drop.acceptProposedAction()
            }
        }

        // Drop feedback - the whole clip rectangle, not just an edge/
        // corner marker, so it reads unambiguously as "this is where
        // it's landing" even for a thin/short clip. Blue = this clip
        // will accept the effect; red = wrong media type (e.g. a
        // video-only effect over an audio clip) - same red-means-
        // refused language as the single-clip move drag's
        // ForbiddenCursor elsewhere in this file.
        Rectangle {
            anchors.fill: parent
            visible: fxDropArea.containsDrag
            color: fxDropArea.dropCompatible ? "#5a9eff" : "#e74c3c"
            opacity: 0.35
            border.color: fxDropArea.dropCompatible ? "white" : "#e74c3c"
            border.width: 2
            radius: 3
            z: 50
        }

        // Waveform display
        WaveformView {
            anchors.fill: parent
            anchors.margins: 2
            visible: (timeline.getTrackType(model.trackId) === "audio") && waveformData.length > 0
            waveformData: clipItem.waveformData
            waveformColor: "#ffcc80"
            // waveformData is already THIS clip's own slice (loadWaveformSlice()),
            // not the full source file anymore - no further offset needed.
            sourceOffset: 0
            clipDuration: clipItem.trimPreviewActive ? clipItem.trimPreviewDuration : model.durationSeconds
        }

        // Clip name
        Text {
            anchors.centerIn: parent
            text: (clipItem.isMediaMissing ? "⚠ " : "") + (model.itemName || "?")
            color: clipItem.isMediaMissing ? "#ffcc66" : "white"
            font.pixelSize: 10
            elide: Text.ElideRight
            width: parent.width - 20
            visible: timeline.getTrackType(model.trackId) !== "audio" || waveformData.length === 0
        }

        // Missing-media badge - same corner-circle convention as the
        // link icon below (which sits on the opposite corner), so a
        // placeholder clip is identifiable even at a glance/thumbnail
        // size where the name text may be elided away entirely.
        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.margins: 3
            width: 14
            height: 14
            radius: 7
            color: "#c0392b"
            visible: clipItem.isMediaMissing
            opacity: 0.9

            Text {
                anchors.centerIn: parent
                text: "!"
                color: "white"
                font.bold: true
                font.pixelSize: 10
            }
        }

        // Link icon - drawn as two overlapping ring outlines rather than the
        // 🔗 emoji glyph, which this app's default QML font doesn't contain
        // (rendered as a "missing glyph" box instead of the chain symbol).
        Rectangle {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: 3
            width: 14
            height: 14
            radius: 7
            color: "#333"
            visible: clipItem.isLinked
            opacity: 0.8

            Item {
                anchors.centerIn: parent
                width: 10
                height: 7
                rotation: -40

                Rectangle {
                    width: 6
                    height: 5
                    radius: 2.5
                    color: "transparent"
                    border.color: "white"
                    border.width: 1
                    x: 0
                    y: 1
                }
                Rectangle {
                    width: 6
                    height: 5
                    radius: 2.5
                    color: "transparent"
                    border.color: "white"
                    border.width: 1
                    x: 4
                    y: 1
                }
            }
        }

        // Effects badge - top-left (link icon above already owns
        // top-right). hasEffects is plain text comparison, not JSON.parse:
        // this runs once per model-role change for every visible clip
        // delegate, and the only question is "non-empty array or not" -
        // parsing the full JSON just to check that would be wasted work
        // repeated per clip per redraw.
        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.margins: 3
            width: fxLabel.implicitWidth + 6
            height: 14
            radius: 3
            color: "#333"
            visible: {
                var e = model.effects || ""
                return e !== "" && e !== "[]"
            }
            opacity: 0.85

            Text {
                id: fxLabel
                anchors.centerIn: parent
                text: "fx"
                color: "#7ad1ff"
                font.pixelSize: 9
                font.bold: true
            }
        }
    }

    // --- ÚJ HELPER: Sáv párjának keresése (V1 <-> A1 logic) ---
    function getPairTrackId(trackId) {
        if (!trackId) return null

        var typePrefix = trackId.substring(0, 1) // "V" vagy "A"
        var trackNum = trackId.substring(1)      // "1", "2", ...

        var targetPrefix = (typePrefix === "V") ? "A" : "V"
        var pairId = targetPrefix + trackNum

        // Ellenőrizzük, hogy létezik-e ez a sáv a tracks modellben
        for (var i = 0; i < tracks.count; i++) {
            if (tracks.get(i).trackId === pairId) {
                return pairId
            }
        }
        return null // Ha nem létezik a párja (pl. van V3 de nincs A3)
    }

    function findClipVisualItem(searchClipId) {
        if (!searchClipId) return null;
        return (timeline && timeline.clipItemsById) ? (timeline.clipItemsById.get(searchClipId) || null) : null;
    }

    function findTransitionOverlay(searchClipId) {
        if (!searchClipId) return null;
        return (timeline && timeline.transitionItemsByOwner) ? (timeline.transitionItemsByOwner.get(searchClipId) || null) : null;
    }

    // Helper a falak kereséséhez - O(log n) a timeline.getTrackWallsIndexed()
    // indexén keresztül, nem O(n) scan a teljes clips modellen.
    function getTrackWalls(targetTrackId, centerX, excludeId1, excludeId2) {
        var excludeIds = []
        if (excludeId1) excludeIds.push(excludeId1)
        if (excludeId2) excludeIds.push(excludeId2)
        var centerSeconds = centerX / timeline.pixelsPerSecond
        return timeline.getTrackWallsIndexed(targetTrackId, centerSeconds, excludeIds)
    }

    function updateDragPosition() {
        if (!clipItem.isDragging) return

        var parentPos = clipItem.mapToItem(container, clipItem.lastMouseX, clipItem.lastMouseY)
        var targetX = parentPos.x - clipItem.dragStartX
        var targetCenterY = parentPos.y - clipItem.dragStartY + (clipItem.height / 2)

        // Automatikus görgetés logika (változatlan)
        var viewportPos = clipItem.mapToItem(flickable, clipItem.lastMouseX, clipItem.lastMouseY)
        var viewportWidth = flickable.width
        var scrollZone = 50
        var clipVisualX = clipItem.mapToItem(flickable, 0, 0).x
        var clipVisualRight = clipVisualX + clipItem.width

        if (viewportPos.x > viewportWidth - scrollZone || (clipVisualRight > viewportWidth - scrollZone && clipItem.lastMouseX > clipItem.dragStartX)) {
            timeline.scrollDirection = 1
        } else if (viewportPos.x < scrollZone || (clipVisualX < scrollZone && clipItem.lastMouseX < clipItem.dragStartX)) {
            timeline.scrollDirection = -1
        } else {
            timeline.scrollDirection = 0
        }

        // === TRANSITION CSOPORT KEZELÉSE ===
        // hasTransitionGroup kiszámolása (valódi transition kapcsolat
        // ellenőrzése, nem csak linked pár) MOST már csak egyszer történik,
        // onPressed-ben (lásd draggingTransitionGroup) - a modell nem
        // változik a drag alatt, ezért minden mouse-move-nál ugyanazt az
        // eredményt adta volna, csak O(g*n^2) költséggel.
        if (clipItem.draggingTransitionGroup) {
            // Transition csoportot mozgatunk együtt
            updateTransitionGroupPosition(targetX, targetCenterY)
        } else {
            // Normál egyedi klip mozgatás (régi logika)
            updateSingleClipPosition(targetX, targetCenterY)
        }
    }

    function updateSingleClipPosition(targetX, targetCenterY) {
        // --- Cél sáv meghatározása a húzott kliphez ---
        var targetTrackIdx = timeline.getTrackIndexFromY(targetCenterY)
        if (targetTrackIdx < 0) targetTrackIdx = 0
        if (targetTrackIdx >= tracks.count) targetTrackIdx = tracks.count - 1

        var targetTrackId = timeline.getTrackIdFromIndex(targetTrackIdx)
        var currentClipType = timeline.getTrackType(clipItem.itemStartTrackId)
        var targetTrackType = timeline.getTrackType(targetTrackId)

        // Ellenőrzés: típus egyezés (pl. Videót csak Videó sávra, AV-t csak AV-re)
        var typeMatch = (currentClipType === targetTrackType)

        // --- Ütközésvizsgálat ---
        var myWidth = clipItem.width
        var suggestedX = Math.max(0, targetX)
        var dragCenter = suggestedX + (myWidth / 2)
        var leftWall = 0
        var rightWall = 99999999
        var partnerTargetTrackId = null

        // 1. Falak a húzott klip cél sávján
        var myWalls = getTrackWalls(targetTrackId, dragCenter, model.clipId, clipItem.linkedClipId)
        leftWall = myWalls.l
        rightWall = myWalls.r

        // 2. Falak a CSATOLT klip cél sávján (ha van)
        if (clipItem.isLinked && clipItem.linkedClipId && typeMatch) {
             // Megkeressük a húzott klip cél sávjának a párját (pl. V2 -> A2)
             partnerTargetTrackId = getPairTrackId(targetTrackId)
             
             if (partnerTargetTrackId) {
                 // Ha létezik a pár sáv, megnézzük ott a falakat a csatolt klipnek
                 var linkedWalls = getTrackWalls(partnerTargetTrackId, dragCenter, clipItem.linkedClipId, model.clipId)
                 
                 // Egyesítjük a korlátokat (szűkebb keresztmetszet)
                 if (linkedWalls.l > leftWall) leftWall = linkedWalls.l
                 if (linkedWalls.r < rightWall) rightWall = linkedWalls.r
             } else {
                 // Ha nem létezik a pár sáv (pl. V3 van, de A3 nincs), akkor az egész húzás érvénytelen
                 typeMatch = false
             }
        }

        // Pozíció számítás a korlátok alapján
        var finalX = suggestedX
        if (finalX < leftWall) finalX = leftWall
        if (finalX + myWidth > rightWall) finalX = rightWall - myWidth

        // Hely ellenőrzése
        var gapSize = rightWall - leftWall
        var newIsDropValid = typeMatch && gapSize >= myWidth

        // Autoritatív végső ellenőrzés - lásd TimelinePanel.qml
        // hasOverlapInRange() kommentjét: a fenti közép-pont alapú fal-
        // számítás egy résnél szélesebb (pl. egy title fix hosszú klip
        // egy rövid A-B rés) esetén rossz szomszédot választhat
        // referenciafalnak, és "valid"-nak jelezhet egy valójában átfedő
        // pozíciót. Ugyanezért hívja ezt a TimelineDropArea.qml drop
        // logikája is - itt eddig hiányzott, ez okozta a jelentett
        // regressziót (meglévő klip áthúzásakor nem volt végső check).
        if (newIsDropValid) {
            var checkStartSec = finalX / timeline.pixelsPerSecond
            var checkEndSec = (finalX + myWidth) / timeline.pixelsPerSecond
            var myExcludeIds = [model.clipId]
            if (clipItem.linkedClipId) myExcludeIds.push(clipItem.linkedClipId)
            if (timeline.hasOverlapInRange(targetTrackId, checkStartSec, checkEndSec, myExcludeIds)) {
                newIsDropValid = false
            } else if (partnerTargetTrackId
                    && timeline.hasOverlapInRange(partnerTargetTrackId, checkStartSec, checkEndSec, myExcludeIds)) {
                newIsDropValid = false
            }
        }

        if (newIsDropValid) {
            // --- Húzott klip mozgatása ---
            clipItem.x = finalX
            clipItem.y = targetTrackIdx * timeline.trackHeight + 5

            // --- Csatolt klip mozgatása (friss lookup - lásd a property
            // blokk megjegyzését arról, hogy miért nincs tárolt referencia) ---
            if (clipItem.isLinked && clipItem.linkedClipId && partnerTargetTrackId) {
                var lv = findClipVisualItem(clipItem.linkedClipId)
                if (lv) {
                    lv.x = finalX
                    // Itt a lényeg: A csatolt klipet is átrakjuk a megfelelő pár sávra
                    lv.y = timeline.getTrackYPosition(partnerTargetTrackId) + 5
                    // Vizuális visszajelzés
                    lv.opacity = 0.7
                }
            }
        } else {
            // Visszaállítás érvénytelen pozíció esetén (eredeti helyre)
            clipItem.x = clipItem.itemStartTime * timeline.pixelsPerSecond
            clipItem.y = timeline.getTrackYPosition(clipItem.itemStartTrackId) + 5

            if (clipItem.isLinked && clipItem.linkedClipId) {
                var lv2 = findClipVisualItem(clipItem.linkedClipId)
                if (lv2) {
                    lv2.x = clipItem.itemStartTime * timeline.pixelsPerSecond
                    // A csatolt elem is visszamegy az eredeti sávjára (linkedTrackId a dragStart-ból)
                    lv2.y = timeline.getTrackYPosition(clipItem.linkedTrackId) + 5
                    lv2.opacity = 1.0
                }
            }
        }

        clipItem.isDropValid = newIsDropValid
    }

    // Visszaállítja a csoport minden tagjának (klip + transition overlay)
    // vizuális pozícióját/opacity-jét az eredeti (press-kori) állapotra -
    // ezt a logikát három különböző hívás ponton (típus-eltérés, fal
    // ütközés mindkét ágon) ismételte korábban a kód szó szerint
    // ugyanúgy. Csak az ÉPPEN ÉLŐ delegate-eken hat - egy delegate
    // nélküli csoporttagnak nincs mit visszaállítani.
    function restoreGroupVisuals() {
        for (var n = 0; n < clipItem.transitionGroupClipIds.length; n++) {
            var gid = clipItem.transitionGroupClipIds[n]
            var vItem = findClipVisualItem(gid)
            if (vItem) {
                vItem.x = clipItem.transitionGroupVisualX[gid]
                vItem.y = timeline.getTrackYPosition(clipItem.transitionGroupStartTracks[gid]) + 5
                vItem.opacity = 1.0
            }
        }
        for (var p = 0; p < clipItem.transitionGroupOverlayOwners.length; p++) {
            var oid = clipItem.transitionGroupOverlayOwners[p]
            var ovl = findTransitionOverlay(oid)
            if (ovl) {
                ovl.x = clipItem.transitionGroupOverlayX[oid]
                ovl.y = timeline.getTrackYPosition(clipItem.transitionGroupStartTracks[oid]) + 5
            }
        }
    }

    function updateTransitionGroupPosition(targetX, targetCenterY) {
        // Multi-select drag: single shared time-delta ONLY, never a
        // track change - see multiSelectDrag's property comment. This
        // completely bypasses the track-delta/pair-mapping/bbox-wall
        // logic below, which assumes a spatially contiguous chain.
        if (clipItem.multiSelectDrag) {
            clipItem.finalTrackDelta = 0
            var mySx = clipItem.transitionGroupVisualX[model.clipId]
            var rawDeltaX = targetX - mySx
            var clampedDeltaX = Math.max(clipItem.groupMinDeltaX, Math.min(clipItem.groupMaxDeltaX, rawDeltaX))
            clipItem.finalDeltaSeconds = clampedDeltaX / timeline.pixelsPerSecond

            for (var mdi = 0; mdi < clipItem.transitionGroupClipIds.length; mdi++) {
                var mdId = clipItem.transitionGroupClipIds[mdi]
                var mdItem = findClipVisualItem(mdId)
                if (!mdItem) continue
                mdItem.x = clipItem.transitionGroupVisualX[mdId] + clampedDeltaX
                mdItem.y = timeline.getTrackYPosition(clipItem.transitionGroupStartTracks[mdId]) + 5
                mdItem.opacity = 0.7
            }
            for (var mdo = 0; mdo < clipItem.transitionGroupOverlayOwners.length; mdo++) {
                var mdOid = clipItem.transitionGroupOverlayOwners[mdo]
                var mdOverlay = findTransitionOverlay(mdOid)
                if (!mdOverlay) continue
                mdOverlay.x = clipItem.transitionGroupOverlayX[mdOid] + clampedDeltaX
                mdOverlay.y = timeline.getTrackYPosition(clipItem.transitionGroupStartTracks[mdOid]) + 5
            }
            // 0 is always inside [groupMinDeltaX, groupMaxDeltaX] (the
            // press-time layout already fits), so this can never be
            // invalid on the time axis - the group just stops at
            // whichever neighbour is tightest, same spirit as single-
            // clip wall-clamping, never a hard refuse.
            clipItem.isDropValid = true
            return
        }

        // Transition csoport együttes mozgatása track-ek között is

        // === CEL TRACK MEGHATAROZASA ===
        var targetTrackIdx = timeline.getTrackIndexFromY(targetCenterY)
        if (targetTrackIdx < 0) targetTrackIdx = 0
        if (targetTrackIdx >= tracks.count) targetTrackIdx = tracks.count - 1
        var targetTrackId = timeline.getTrackIdFromIndex(targetTrackIdx)

        // Ellenőrizzük hogy a húzott klip típusa megegyezik-e a cél track típusával
        var currentClipType = timeline.getTrackType(clipItem.itemStartTrackId)
        var targetTrackType = timeline.getTrackType(targetTrackId)
        var typeMatch = (currentClipType === targetTrackType)

        if (!typeMatch) {
            // Ha nem egyezik a típus, visszaállítjuk az eredeti pozíciókra
            clipItem.finalDeltaSeconds = 0
            clipItem.restoreGroupVisuals()
            clipItem.isDropValid = false
            return
        }

        // Track delta számítása (hány track-et mozdultunk) - O(1) lookup
        // a timeline.trackIndexById indexből, nem O(tracks.count) scan.
        var originalTrackIdx = timeline.getTrackIndexFromId(clipItem.itemStartTrackId)
        var trackDelta = targetTrackIdx - originalTrackIdx
        clipItem.finalTrackDelta = trackDelta  // Elmentjük onReleased-hez
        clipItem.finalTargetTrackId = targetTrackId  // Elmentjük onReleased-hez

        // Delta számítás a húzott klip VIZUÁLIS pozíciója alapján
        var myOriginalVisualX = clipItem.transitionGroupVisualX[model.clipId]
        var deltaX = targetX - myOriginalVisualX

        // Meghatározzuk a csoport széleit a VIZUÁLIS pozíciók alapján
        var groupMinX = 999999
        var groupMaxX = 0

        for (var i = 0; i < clipItem.transitionGroupClipIds.length; i++) {
            var groupClipId = clipItem.transitionGroupClipIds[i]
            var visualX = clipItem.transitionGroupVisualX[groupClipId]
            // A klip valós vége (startTime + duration, NEM visualX + duration) -
            // onPressed-ben cache-elve, nem kell a clips modellt scannelni
            // minden egérmozgásnál.
            var clipRealEnd = clipItem.transitionGroupEndX[groupClipId] || 0

            if (visualX < groupMinX) groupMinX = visualX
            if (clipRealEnd > groupMaxX) groupMaxX = clipRealEnd
        }

        var groupWidth = groupMaxX - groupMinX

        // Új pozíció a csoport bal széle számára
        var newGroupMinX = groupMinX + deltaX
        newGroupMinX = Math.max(0, newGroupMinX)  // Ne menjen negatívba

        // Wall detection az ÚJ cél track-ekre
        // Megkeressük az összes egyedi trackId-t a csoportban és kiszámoljuk az új track-jeiket
        var newTracksInGroup = {}
        // A húzott klip típusa határozza meg melyik típus használ trackDelta-t
        var draggedClipType = timeline.getTrackType(clipItem.itemStartTrackId)

        for (var k = 0; k < clipItem.transitionGroupClipIds.length; k++) {
            var gid = clipItem.transitionGroupClipIds[k]
            var originalTrackId = clipItem.transitionGroupStartTracks[gid]
            var originalTrackType = timeline.getTrackType(originalTrackId)

            var newTrackId_calc = ""

            // SZABÁLY:
            // - Azonos típusú klipek mint a húzott klip → trackDelta
            // - Ellentétes típusú klipek (linked párok) → pair mapping
            if (originalTrackType === draggedClipType) {
                // TRACK DELTA: Azonos típus mint a húzott klip
                var origIdx = timeline.getTrackIndexFromId(originalTrackId)
                var newIdx = origIdx + trackDelta
                if (newIdx >= 0 && newIdx < tracks.count) {
                    newTrackId_calc = tracks.get(newIdx).trackId
                }
            } else {
                // PAIR MAPPING: Ellentétes típus, a húzott típus új trackjéből számoljuk
                // Megkeressük a linked párját (ami a húzott típusú) - a
                // onPressed-ben cache-elt transitionGroupLinked/LinkedId-ból,
                // nem a clips modellt scannelve minden egérmozgásnál.
                var linkedClipIdInGroup = clipItem.transitionGroupLinked[gid] ? clipItem.transitionGroupLinkedId[gid] : ""

                if (linkedClipIdInGroup) {
                    var linkedOrigTrackId = clipItem.transitionGroupStartTracks[linkedClipIdInGroup]
                    var linkedOrigTrackIdx = timeline.getTrackIndexFromId(linkedOrigTrackId)
                    var linkedNewTrackIdx = linkedOrigTrackIdx + trackDelta
                    if (linkedNewTrackIdx >= 0 && linkedNewTrackIdx < tracks.count) {
                        var linkedNewTrackId = tracks.get(linkedNewTrackIdx).trackId
                        newTrackId_calc = getPairTrackId(linkedNewTrackId)
                    }
                }
            }

            // Ha nem tudtunk érvényes új trackot számolni, skip
            if (!newTrackId_calc) continue

            var newTrackType = timeline.getTrackType(newTrackId_calc)
            var originalTrackType_check = timeline.getTrackType(originalTrackId)

            // Típus ellenőrzés: video->video, audio->audio
            if (newTrackType !== originalTrackType_check) {
                typeMatch = false
                break
            }

            newTracksInGroup[newTrackId_calc] = true
        }

        if (!typeMatch) {
            // Ha típus nem egyezik, visszaállítjuk
            clipItem.finalDeltaSeconds = 0
            clipItem.restoreGroupVisuals()
            clipItem.isDropValid = false
            return
        }

        // Számoljuk ki a falakat az ÚJ track-ekre
        var leftWall = 0
        var rightWall = 99999999

        for (var newTrackId in newTracksInGroup) {
            if (!newTracksInGroup.hasOwnProperty(newTrackId)) continue

            // Falak az új tracken, EXCLUDE minden csoport tagot
            var trackWalls = getTrackWallsExcludeGroup(newTrackId, newGroupMinX + groupWidth / 2)
            if (trackWalls.l > leftWall) leftWall = trackWalls.l
            if (trackWalls.r < rightWall) rightWall = trackWalls.r
        }

        // Pozíció korrekció a falak alapján
        var finalGroupMinX = newGroupMinX
        if (finalGroupMinX < leftWall) finalGroupMinX = leftWall
        if (finalGroupMinX + groupWidth > rightWall) finalGroupMinX = rightWall - groupWidth

        // Ellenőrizzük hogy van-e elég hely
        var gapSize = rightWall - leftWall
        var isValid = gapSize >= groupWidth && finalGroupMinX >= 0

        if (isValid) {
            // Mozgatjuk az összes klipet a csoportban
            var finalDeltaX = finalGroupMinX - groupMinX
            // Ez a commitolt delta - onReleased ebből menti vissza a
            // modellt, sosem egy élő delegate .x-éből olvasva.
            clipItem.finalDeltaSeconds = finalDeltaX / timeline.pixelsPerSecond

            // A húzott klip típusa határozza meg melyik típus használ trackDelta-t
            var draggedClipType2 = timeline.getTrackType(clipItem.itemStartTrackId)

            for (var m = 0; m < clipItem.transitionGroupClipIds.length; m++) {
                var gid2 = clipItem.transitionGroupClipIds[m]
                var visualItem = findClipVisualItem(gid2)
                if (!visualItem) continue

                // X pozíció: Használjuk a VIZUÁLIS X pozíciót, nem a startTime-ot!
                var originalVisualX = clipItem.transitionGroupVisualX[gid2]
                visualItem.x = originalVisualX + finalDeltaX

                // Y pozíció kiszámítása
                var origTrackId = clipItem.transitionGroupStartTracks[gid2]
                var origTrackType2 = timeline.getTrackType(origTrackId)
                var newTrackId2 = ""

                // SZABÁLY:
                // - Azonos típusú klipek mint a húzott klip → trackDelta
                // - Ellentétes típusú klipek (linked párok) → pair mapping
                if (origTrackType2 === draggedClipType2) {
                    // TRACK DELTA: Azonos típus mint a húzott klip
                    var origTrackIdx2 = timeline.getTrackIndexFromId(origTrackId)
                    var newTrackIdx2 = origTrackIdx2 + trackDelta
                    if (newTrackIdx2 >= 0 && newTrackIdx2 < tracks.count) {
                        newTrackId2 = tracks.get(newTrackIdx2).trackId
                    }
                } else if (clipItem.transitionGroupLinked[gid2]) {
                    // PAIR MAPPING: Ellentétes típus
                    var linkedId2 = clipItem.transitionGroupLinkedId[gid2]
                    var linkedOrigTrackId = clipItem.transitionGroupStartTracks[linkedId2]
                    var linkedOrigTrackIdx = timeline.getTrackIndexFromId(linkedOrigTrackId)
                    var linkedNewTrackIdx = linkedOrigTrackIdx + trackDelta
                    if (linkedNewTrackIdx >= 0 && linkedNewTrackIdx < tracks.count) {
                        var linkedNewTrackId = tracks.get(linkedNewTrackIdx).trackId
                        newTrackId2 = getPairTrackId(linkedNewTrackId)
                    }
                }

                if (newTrackId2) {
                    visualItem.y = timeline.getTrackYPosition(newTrackId2) + 5
                }

                visualItem.opacity = 0.7
            }

            // Mozgatjuk a transition overlay-eket is
            for (var o = 0; o < clipItem.transitionGroupOverlayOwners.length; o++) {
                var oid2 = clipItem.transitionGroupOverlayOwners[o]
                var overlay = findTransitionOverlay(oid2)
                if (!overlay) continue

                // X pozíció
                var originalOverlayX = clipItem.transitionGroupOverlayX[oid2]
                overlay.x = originalOverlayX + finalDeltaX

                // Y pozíció: ugyanaz a szabály mint a klipeknél
                var ownerOrigTrackId = clipItem.transitionGroupStartTracks[oid2]
                var ownerOrigTrackType = timeline.getTrackType(ownerOrigTrackId)
                var ownerNewTrackId_calc = ""

                // SZABÁLY:
                // - Azonos típus mint a húzott klip → trackDelta
                // - Ellentétes típus → pair mapping
                if (ownerOrigTrackType === draggedClipType2) {
                    // TRACK DELTA
                    var ownerOrigTrackIdx = timeline.getTrackIndexFromId(ownerOrigTrackId)
                    var ownerNewTrackIdx = ownerOrigTrackIdx + trackDelta
                    if (ownerNewTrackIdx >= 0 && ownerNewTrackIdx < tracks.count) {
                        ownerNewTrackId_calc = tracks.get(ownerNewTrackIdx).trackId
                    }
                } else if (clipItem.transitionGroupLinked[oid2]) {
                    // PAIR MAPPING: owner clip linked párja - cache-elve
                    var ownerLinkedId = clipItem.transitionGroupLinkedId[oid2]
                    var ownerLinkedOrigTrackId = clipItem.transitionGroupStartTracks[ownerLinkedId]
                    var ownerLinkedOrigTrackIdx = timeline.getTrackIndexFromId(ownerLinkedOrigTrackId)
                    var ownerLinkedNewTrackIdx = ownerLinkedOrigTrackIdx + trackDelta
                    if (ownerLinkedNewTrackIdx >= 0 && ownerLinkedNewTrackIdx < tracks.count) {
                        var ownerLinkedNewTrackId = tracks.get(ownerLinkedNewTrackIdx).trackId
                        ownerNewTrackId_calc = getPairTrackId(ownerLinkedNewTrackId)
                    }
                }

                if (ownerNewTrackId_calc) {
                    overlay.y = timeline.getTrackYPosition(ownerNewTrackId_calc) + 5
                }
            }
        } else {
            clipItem.finalDeltaSeconds = 0
            clipItem.restoreGroupVisuals()
        }

        clipItem.isDropValid = isValid
    }

    function getTrackWallsExcludeGroup(targetTrackId, centerX) {
        var centerSeconds = centerX / timeline.pixelsPerSecond
        return timeline.getTrackWallsIndexed(targetTrackId, centerSeconds, clipItem.transitionGroupClipIds)
    }

    Drag.active: isDragging
    Drag.dragType: Drag.Internal
    Drag.keys: ["timeline-clip"]
    Drag.hotSpot.x: width / 2
    Drag.hotSpot.y: height / 2

    MouseArea {
        anchors.fill: parent
        drag.target: null
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: clipItem.isDragging ? (clipItem.isDropValid ? Qt.ClosedHandCursor : Qt.ForbiddenCursor) : Qt.OpenHandCursor

        onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton) {
                timeline.setActiveTrack(model.trackId)
                // Right-clicking a clip that's already part of the
                // current multi-selection just re-primaries it (so a
                // future "apply to selection" context action stays
                // possible); right-clicking anything else collapses to
                // just that clip - so Delete/etc. can never silently
                // act on a surprising, unrelated prior selection.
                if (timeline.isClipInSelection(model.clipId)) {
                    timeline.selectedClipId = model.clipId
                    timeline.clipSelectionTouched()
                } else {
                    timeline.selectOnly(model.clipId)
                }
                // Shared menu instance (TimelinePanel.qml) - see its
                // definition for why this isn't a per-clip Menu anymore.
                timeline.menuClipId = model.clipId
                timeline.clipContextMenu.popup()
            }
        }

        onPressed: function(mouse) {
            if (mouse.button === Qt.RightButton) return
            // A click on a clip also makes its track the active track.
            timeline.setActiveTrack(model.trackId)

            var shiftMod = (mouse.modifiers & Qt.ShiftModifier) !== 0
            var ctrlMod = (mouse.modifiers & Qt.ControlModifier) !== 0
            if (shiftMod) {
                // Range-select only - never starts a drag, same as
                // Ctrl below (a careful range-click's slight tremor
                // must never turn into an accidental move).
                timeline.selectRange(model.clipId, ctrlMod)
                return
            }
            if (ctrlMod) {
                timeline.toggleSelection(model.clipId)
                return
            }
            if (timeline.isClipInSelection(model.clipId) && timeline.selectedClipIds.length > 1) {
                // Clicking a member of an existing multi-selection
                // re-primaries it (so e.g. the Effect Stack inspector
                // follows) WITHOUT collapsing the selection - this is
                // what lets "select several, then grab one of them to
                // drag/drop them all together" work. But if this turns
                // out to be a plain click (no actual drag), onReleased
                // below collapses the selection to just this clip, same
                // as clicking any other single clip would.
                timeline.selectedClipId = model.clipId
                timeline.selectionAnchorClipId = model.clipId
                timeline.clipSelectionTouched()
                clipItem.pendingSelectOnlyOnRelease = true
            } else {
                timeline.selectOnly(model.clipId)
                clipItem.pendingSelectOnlyOnRelease = false
            }
            timeline.activeDragItem = clipItem
            clipItem.isDragging = true
            clipItem.isDropValid = true
            clipItem.actuallyMoved = false
            clipItem.dragStartX = mouse.x
            clipItem.dragStartY = mouse.y
            clipItem.itemStartTrackId = model.trackId
            clipItem.itemStartTime = model.startTime
            clipItem.lastMouseX = mouse.x
            clipItem.lastMouseY = mouse.y

            if (clipItem.isLinked && clipItem.linkedClipId) {
                // Megkeressük a csatolt elem eredeti sávját az adatmodellből
                for(var i=0; i<clips.count; i++) {
                    if(clips.get(i).clipId === clipItem.linkedClipId) {
                        clipItem.linkedTrackId = clips.get(i).trackId
                        break
                    }
                }
            } else {
                clipItem.linkedTrackId = ""
            }

            // === TRANSITION CSOPORT / MULTI-SELECT CSOPORT FELÉPÍTÉSE ===
            // A grabbed clip egy több-elemű kijelölés tagja -> a "csoport"
            // a KIJELÖLÉS minden tagjának saját transition/linked
            // lezártjainak uniója (nem csak a grabbed klipé), hogy egy
            // Ctrl/Shift-tel kijelölt, transition-láncban NEM lévő klip
            // is együtt mozogjon a többivel.
            clipItem.multiSelectDrag = timeline.isClipInSelection(model.clipId) && timeline.selectedClipIds.length > 1
            var dragSeeds = clipItem.multiSelectDrag ? timeline.selectedClipIds : [model.clipId]
            var groupSet = {}
            var groupIds = []
            for (var sdi = 0; sdi < dragSeeds.length; sdi++) {
                var closure = timeline.buildTransitionGroup(dragSeeds[sdi])
                for (var sdj = 0; sdj < closure.length; sdj++) {
                    if (!groupSet[closure[sdj]]) { groupSet[closure[sdj]] = true; groupIds.push(closure[sdj]) }
                }
            }
            clipItem.transitionGroupClipIds = groupIds

            // Ellenőrizzük, hogy van-e TÉNYLEG transition kapcsolat a
            // csoportban (nem csak linked pár) - EGYSZER, itt onPressed-ben,
            // mert a modell nem módosul a drag alatt, tehát ugyanazt az
            // eredményt adná minden mouse-move-nál újraszámolva is. Egy
            // multi-select drag mindig a csoport-útvonalat használja,
            // akkor is, ha a kijelölésben egyik klipnek sincs valódi
            // transition kapcsolata - az egyedi-klip útvonal csak 1
            // klipre készült.
            clipItem.draggingTransitionGroup = clipItem.multiSelectDrag
            if (!clipItem.multiSelectDrag && clipItem.transitionGroupClipIds.length > 1) {
                for (var tg = 0; tg < clipItem.transitionGroupClipIds.length; tg++) {
                    var tgId = clipItem.transitionGroupClipIds[tg]
                    for (var tgm = 0; tgm < clips.count; tgm++) {
                        if (clips.get(tgm).clipId === tgId) {
                            if (clips.get(tgm).hasTransition) {
                                clipItem.draggingTransitionGroup = true
                                break
                            }
                            for (var tgm2 = 0; tgm2 < clips.count; tgm2++) {
                                if (clips.get(tgm2).hasTransition && clips.get(tgm2).transitionOriginalBId === tgId) {
                                    clipItem.draggingTransitionGroup = true
                                    break
                                }
                            }
                            break
                        }
                    }
                    if (clipItem.draggingTransitionGroup) break
                }
            }

            clipItem.transitionGroupStartTimes = {}
            clipItem.transitionGroupStartTracks = {}
            clipItem.transitionGroupVisualX = {}
            clipItem.transitionGroupOverlayX = {}
            clipItem.transitionGroupOverlayOwners = []
            clipItem.transitionGroupLinked = {}
            clipItem.transitionGroupLinkedId = {}
            clipItem.transitionGroupEndX = {}
            clipItem.finalDeltaSeconds = 0

            // Ha van transition csoport (több mint 1 elem, mert a saját clipId is benne van)
            // A csoporttagok adatait a MODELLBŐL gyűjtjük, NEM élő
            // delegate-ekből - lásd a property blokk megjegyzését. A két
            // formula (transitionGroupVisualX / transitionGroupOverlayX)
            // szó szerint a calculateVisualX() és a TimelineTransition.qml
            // x-binding-jának (aktív ág) tükörképe.
            if (clipItem.multiSelectDrag || clipItem.transitionGroupClipIds.length > 1) {
                for (var j = 0; j < clipItem.transitionGroupClipIds.length; j++) {
                    var groupClipId = clipItem.transitionGroupClipIds[j]

                    for (var k = 0; k < clips.count; k++) {
                        var groupClip = clips.get(k)
                        if (groupClip.clipId !== groupClipId) continue

                        clipItem.transitionGroupStartTimes[groupClipId] = groupClip.startTime
                        clipItem.transitionGroupStartTracks[groupClipId] = groupClip.trackId
                        clipItem.transitionGroupLinked[groupClipId] = groupClip.isLinked || false
                        clipItem.transitionGroupLinkedId[groupClipId] = groupClip.linkedClipId || ""
                        clipItem.transitionGroupEndX[groupClipId] =
                            (groupClip.startTime + groupClip.durationSeconds) * timeline.pixelsPerSecond

                        // calculateVisualX() tükre: alap X + incomingCutOffset
                        // jobbra, ha ez a klip valamelyik szomszéd
                        // transition-jének B oldala (timeline.overlapByClipId
                        // / incomingCutOffsetById, a Stage-1 index). NEM
                        // ov/2.0 - az csak a szimmetrikus esetben egyezik
                        // meg az asymmetric cutOffset-tel (lásd
                        // TimelineTransition.qml transCutOffset
                        // kommentjét) - egy importált aszimmetrikus
                        // Kdenlive-mixcuttal rendelkező klip máshova
                        // ugrott volna press-kor, mint ahol valójában
                        // állt, és EZ a rossz X lett volna a drag alapja.
                        var ov = timeline.overlapByClipId[groupClipId] || 0
                        var groupCutOffset = timeline.incomingCutOffsetById[groupClipId] !== undefined
                            ? timeline.incomingCutOffsetById[groupClipId] : ov / 2.0
                        clipItem.transitionGroupVisualX[groupClipId] =
                            (groupClip.startTime * timeline.pixelsPerSecond) + (groupCutOffset * timeline.pixelsPerSecond)

                        // TimelineTransition.qml x-binding-jának tükre
                        // (aktív ág): ha ennek a klipnek van saját
                        // transition-je, az overlay x-e és owner-listája.
                        if (groupClip.hasTransition) {
                            var td = groupClip.transitionDuration || timeline.defaultTransitionDuration
                            var ownCutOffset = groupClip.transitionCutOffset !== undefined
                                ? groupClip.transitionCutOffset : td / 2.0
                            var cutPointSec = groupClip.startTime + groupClip.durationSeconds - td + ownCutOffset
                            clipItem.transitionGroupOverlayOwners.push(groupClipId)
                            clipItem.transitionGroupOverlayX[groupClipId] =
                                (cutPointSec * timeline.pixelsPerSecond) - (td * timeline.pixelsPerSecond / 2)
                        }
                        break
                    }
                }
            }

            // Multi-select drag: compute the single shared time-delta
            // window (PIXELS) every member can move within without
            // colliding with a NON-selected neighbour - see the
            // groupMinDeltaX/MaxDeltaX property comment for why this
            // (not the transition-group code's bounding-box wall check,
            // and not per-clip independent clamping) is correct here.
            // Computed once at press time: the model never changes
            // mid-drag, so walls can't move either.
            if (clipItem.multiSelectDrag) {
                var gMinDx = -1e9, gMaxDx = 1e9
                for (var gwi = 0; gwi < clipItem.transitionGroupClipIds.length; gwi++) {
                    var gwId = clipItem.transitionGroupClipIds[gwi]
                    var gSx = clipItem.transitionGroupVisualX[gwId]
                    var gEx = clipItem.transitionGroupEndX[gwId]
                    if (gSx === undefined || gEx === undefined) continue
                    var gTrackId = clipItem.transitionGroupStartTracks[gwId]
                    var gWalls = getTrackWallsExcludeGroup(gTrackId, (gSx + gEx) / 2)
                    var memberMinDx = gWalls.l - gSx
                    var memberMaxDx = gWalls.r - gEx
                    if (memberMinDx > gMinDx) gMinDx = memberMinDx
                    if (memberMaxDx < gMaxDx) gMaxDx = memberMaxDx
                    // Never let any member's start go negative.
                    if (-gSx > gMinDx) gMinDx = -gSx
                }
                clipItem.groupMinDeltaX = gMinDx
                clipItem.groupMaxDeltaX = gMaxDx
            }

            clipItem.Drag.start()

            Backend.logOperation("clip_drag_start", {
                clipId: model.clipId, trackId: model.trackId, startTime: model.startTime,
                isLinked: clipItem.isLinked, linkedClipId: clipItem.linkedClipId,
                transitionGroupSize: clipItem.transitionGroupClipIds.length,
                draggingTransitionGroup: clipItem.draggingTransitionGroup
            })
        }

        onPositionChanged: function(mouse) {
            // --- MÓDOSÍTÁS: Timecode frissítése mozgatás közben is (akár hover, akár drag) ---
            // A klipen belüli egér pozíció + klip kezdőpontja = globális pixel pozíció
            var globalMouseX = clipItem.x + mouse.x
            // Visszaírjuk a globális változóba
            timeline.mouseTimeSeconds = Math.max(0, globalMouseX / timeline.pixelsPerSecond)

            if (!clipItem.isDragging) return

            // Ellenőrizzük, hogy tényleg mozgott-e az egér
            var deltaX = Math.abs(mouse.x - clipItem.dragStartX)
            var deltaY = Math.abs(mouse.y - clipItem.dragStartY)
            if ((deltaX > 2 || deltaY > 2) && !clipItem.actuallyMoved) {
                clipItem.actuallyMoved = true
                // First real movement of this gesture - a plain selection
                // click never reaches here, so no snapshot is wasted on
                // clicks. The model itself isn't written until onReleased
                // commits, so the BEFORE state is identical anywhere from
                // press to here.
                clipItem.undoScopeOpen = timeline.beginUndoableGesture()
            }

            clipItem.lastMouseX = mouse.x
            clipItem.lastMouseY = mouse.y
            clipItem.updateDragPosition()
        }

        onReleased: {
            timeline.activeDragItem = null
            timeline.scrollDirection = 0
            clipItem.isDragging = false
            clipItem.Drag.drop()

            if (clipItem.isLinked && clipItem.linkedClipId) {
                var releasedLinkedItem = findClipVisualItem(clipItem.linkedClipId)
                if (releasedLinkedItem) releasedLinkedItem.opacity = 0.9
            }

            if (clipItem.actuallyMoved && !clipItem.isDropValid) {
                Backend.logOperation("clip_drag_release_rejected", {
                    clipId: model.clipId, trackId: model.trackId, startTime: model.startTime
                })
            } else if (!clipItem.actuallyMoved) {
                Backend.logOperation("clip_drag_release_noop", { clipId: model.clipId })
            }

            if (!clipItem.actuallyMoved && clipItem.pendingSelectOnlyOnRelease) {
                timeline.selectOnly(model.clipId)
            }
            clipItem.pendingSelectOnlyOnRelease = false

            // Csak akkor írjuk vissza az adatmodellbe, ha tényleg mozgott a klip
            if (clipItem.actuallyMoved && clipItem.isDropValid) {
                // Ugyanaz a flag, amit onPressed-ben egyszer számoltunk ki -
                // a modell nem módosult a drag alatt, tehát itt sem kell
                // újraszámolni.
                if (clipItem.draggingTransitionGroup) {
                    // === TRANSITION CSOPORT MENTÉSE ===
                    // Minden klip új pozícióját a PRESS-kori snapshot (model-
                    // ből, onPressed-ben rögzítve) + a commitolt
                    // finalDeltaSeconds alapján mentjük - SOHA egy élő
                    // delegate .x-éből olvasva. Így egy csoporttag, amelynek
                    // épp nincs élő delegate-je, ugyanúgy helyesen menthető.
                    for (var m = 0; m < clipItem.transitionGroupClipIds.length; m++) {
                        var gid3 = clipItem.transitionGroupClipIds[m]
                        var originalStartTime = clipItem.transitionGroupStartTimes[gid3]
                        // undefined: a csoporttag nem volt feloldható a
                        // modellben onPressed idején (pl. egy korábbi
                        // split miatt elárvult transitionOriginalBId
                        // hivatkozás - lásd a split+transition TODO
                        // bejegyzést) - ilyenkor nincs mit menteni rá.
                        if (originalStartTime === undefined) continue

                        var row = clipItem.findClipRow(gid3)
                        if (row < 0) continue

                        var newStartTime = originalStartTime + clipItem.finalDeltaSeconds
                        clips.setProperty(row, "startTime", newStartTime)

                        // Track frissítése: Audio klipekhez pair mapping, másokhoz trackDelta
                        var originalTrackId = clipItem.transitionGroupStartTracks[gid3]
                        var origTrackTypeSave = timeline.getTrackType(originalTrackId)
                        var newTrackId4 = ""

                        var gLinked = clipItem.transitionGroupLinked[gid3]
                        var gLinkedId = clipItem.transitionGroupLinkedId[gid3]

                        // Ha ez egy AUDIO klip ÉS van linked video párja a csoportban -> pair mapping
                        var usesPairMappingSave = false
                        if (origTrackTypeSave === "audio" && gLinked && gLinkedId) {
                            for (var gi2 = 0; gi2 < clipItem.transitionGroupClipIds.length; gi2++) {
                                if (clipItem.transitionGroupClipIds[gi2] === gLinkedId) {
                                    usesPairMappingSave = true
                                    break
                                }
                            }
                        }

                        if (usesPairMappingSave) {
                            // Audio klip, video párja csoportban -> pair mapping
                            var linkedOrigTrackIdSave = clipItem.transitionGroupStartTracks[gLinkedId]
                            var linkedOrigTrackIdxSave = timeline.getTrackIndexFromId(linkedOrigTrackIdSave)
                            var linkedNewTrackIdxSave = linkedOrigTrackIdxSave + clipItem.finalTrackDelta
                            if (linkedNewTrackIdxSave >= 0 && linkedNewTrackIdxSave < tracks.count) {
                                var linkedNewTrackIdSave = tracks.get(linkedNewTrackIdxSave).trackId
                                newTrackId4 = getPairTrackId(linkedNewTrackIdSave)
                            }
                        } else {
                            // Video klip, vagy audio linked nélkül -> trackDelta
                            var origTrackIdx3 = timeline.getTrackIndexFromId(originalTrackId)
                            if (origTrackIdx3 >= 0) {
                                var newTrackIdx3 = origTrackIdx3 + clipItem.finalTrackDelta
                                if (newTrackIdx3 >= 0 && newTrackIdx3 < tracks.count) {
                                    newTrackId4 = tracks.get(newTrackIdx3).trackId
                                }
                            }
                        }

                        if (newTrackId4) {
                            clips.setProperty(row, "trackId", newTrackId4)
                        }
                    }

                    // Opacity visszaállítása a csoport elemeire - csak az
                    // éppen élő delegate-eken, a többi eleve 0.9-en maradt
                    // (sosem változott az opacity-je, hiszen nem volt
                    // delegate-je, amin változtatni lehetett volna).
                    for (var p = 0; p < clipItem.transitionGroupClipIds.length; p++) {
                        var vItem = findClipVisualItem(clipItem.transitionGroupClipIds[p])
                        if (vItem) vItem.opacity = 0.9
                    }

                    Backend.logOperation("clip_drag_release_group", {
                        draggedClipId: model.clipId, groupSize: clipItem.transitionGroupClipIds.length,
                        groupClipIds: clipItem.transitionGroupClipIds.join(","),
                        finalTrackDelta: clipItem.finalTrackDelta, finalTargetTrackId: clipItem.finalTargetTrackId
                    })

                } else {
                    // === EGYEDI KLIP VAGY LINKED PÁR MENTÉSE (régi logika) ===
                    var finalX = clipItem.x
                    var finalY = clipItem.y

                    // Kiszámítjuk az új sávot és időt a húzott klipnek
                    var finalTrackId = timeline.getTrackIdFromY(finalY)
                    var newStartTime = finalX / timeline.pixelsPerSecond
                    var timeDelta = newStartTime - model.startTime

                    // 1. Frissítjük a HÚZOTT klipet az adatbázisban
                    for (var i = 0; i < clips.count; i++) {
                        if (clips.get(i).clipId === model.clipId) {
                            clips.setProperty(i, "trackId", finalTrackId)
                            clips.setProperty(i, "startTime", newStartTime)
                            break
                        }
                    }

                    // 2. Frissítjük a CSATOLT klipet az adatbázisban
                    if (clipItem.isLinked && clipItem.linkedClipId) {
                        var partnerTrackId = getPairTrackId(finalTrackId)

                        if (partnerTrackId) {
                            for (var j = 0; j < clips.count; j++) {
                                var linkedClip = clips.get(j)
                                if (linkedClip.clipId === clipItem.linkedClipId) {
                                    var linkedNewStartTime = linkedClip.startTime + timeDelta

                                    clips.setProperty(j, "startTime", linkedNewStartTime)
                                    // Sáv frissítése a párosított sávra
                                    clips.setProperty(j, "trackId", partnerTrackId)
                                    break
                                }
                            }
                        }
                    }

                    Backend.logOperation("clip_drag_release_single", {
                        clipId: model.clipId, fromTrack: clipItem.itemStartTrackId, fromStart: clipItem.itemStartTime,
                        toTrack: finalTrackId, toStart: newStartTime,
                        linkedClipId: clipItem.linkedClipId || ""
                    })
                }

                if (timeline.updateTimelineEngine) timeline.updateTimelineEngine()
                Qt.callLater(timeline.checkAllClipNeighbors)
                if (clipItem.undoScopeOpen) timeline.commitUndoableEdit(clipItem.multiSelectDrag ? "Move clips" : "Move clip")
            } else if (clipItem.undoScopeOpen) {
                // Moved but the drop was rejected, or no model write
                // happened for some other reason - nothing to keep.
                timeline.abortUndoableEdit()
            }

            // Binding-ek visszakötése (válaszható drop-nál is, érvénytelen drop-nál is)
            clipItem.rebindPosition()
            if (clipItem.isLinked && clipItem.linkedClipId) {
                var linkedRebindItem = findClipVisualItem(clipItem.linkedClipId)
                if (linkedRebindItem) linkedRebindItem.rebindPosition()
            }

            // Transition csoport binding visszaállítása - egy sosem
            // létezett/már megszűnt delegate-re a findClipVisualItem()
            // null-t ad vissza, nincs mit visszakötni (soha nem is törhetett
            // meg a binding-ja, hiszen sosem íródott felül imperatívan).
            for (var q = 0; q < clipItem.transitionGroupClipIds.length; q++) {
                var groupItem = findClipVisualItem(clipItem.transitionGroupClipIds[q])
                if (groupItem && groupItem !== clipItem) {
                    groupItem.rebindPosition()
                }
            }

            // Transition overlay binding visszaállítása
            for (var r = 0; r < clipItem.transitionGroupOverlayOwners.length; r++) {
                var overlayItem = findTransitionOverlay(clipItem.transitionGroupOverlayOwners[r])
                if (overlayItem) {
                    overlayItem.rebindPosition()
                }
            }

            // Cleanup
            clipItem.linkedTrackId = ""
            clipItem.draggingTransitionGroup = false
            clipItem.multiSelectDrag = false
            clipItem.groupMinDeltaX = 0
            clipItem.groupMaxDeltaX = 0
            clipItem.transitionGroupClipIds = []
            clipItem.transitionGroupStartTimes = {}
            clipItem.transitionGroupStartTracks = {}
            clipItem.transitionGroupVisualX = {}
            clipItem.transitionGroupOverlayX = {}
            clipItem.transitionGroupOverlayOwners = []
            clipItem.transitionGroupLinked = {}
            clipItem.transitionGroupLinkedId = {}
            clipItem.transitionGroupEndX = {}
            clipItem.finalDeltaSeconds = 0
            clipItem.isDropValid = true
            clipItem.actuallyMoved = false
            clipItem.undoScopeOpen = false
        }

        onCanceled: {
            // The mouse grab can be canceled mid-drag (e.g. a modal window
            // - the split-blocked or delete-track dialogs - taking the
            // input grab) without onReleased ever firing. Without this,
            // clipItem.x/width stay detached from the model AND an open
            // undo scope leaks forever, silently swallowing every later
            // edit's undo entry (beginUndoableGesture()'s self-heal is
            // the second line of defence, but this is the first).
            timeline.activeDragItem = null
            timeline.scrollDirection = 0
            clipItem.isDragging = false
            clipItem.pendingSelectOnlyOnRelease = false
            if (clipItem.undoScopeOpen) {
                timeline.abortUndoableEdit()
                clipItem.undoScopeOpen = false
            }
            clipItem.rebindPosition()
            clipItem.linkedTrackId = ""
            clipItem.draggingTransitionGroup = false
            clipItem.multiSelectDrag = false
            clipItem.groupMinDeltaX = 0
            clipItem.groupMaxDeltaX = 0
            clipItem.transitionGroupClipIds = []
            clipItem.transitionGroupStartTimes = {}
            clipItem.transitionGroupStartTracks = {}
            clipItem.transitionGroupVisualX = {}
            clipItem.transitionGroupOverlayX = {}
            clipItem.transitionGroupOverlayOwners = []
            clipItem.transitionGroupLinked = {}
            clipItem.transitionGroupLinkedId = {}
            clipItem.transitionGroupEndX = {}
            clipItem.finalDeltaSeconds = 0
            clipItem.isDropValid = true
            clipItem.actuallyMoved = false
        }
    }

    // === TRIM HANDLES (edge-drag resize) ===
    // Each edge is hidden only when THAT edge is a crossfade boundary,
    // not whenever the clip touches a transition at all:
    //   - rightTrimmable is false while this clip fades OUT into its
    //     neighbor (model.hasTransition), because the crossfade overlap
    //     is anchored at this clip's END, which is exactly what a
    //     right-trim moves.
    //   - leftTrimmable is false while this clip fades IN from its
    //     neighbor (timeline.incomingTransDurById[clipId], i.e. some
    //     other clip's transitionOriginalBId points here), because that
    //     overlap is anchored at this clip's START, which is what a
    //     left-trim moves.
    // The opposite edge is untouched by that drag - the left handle keeps
    // the end time algebraically fixed (newDuration = origStart +
    // origDuration - newStart) and the right handle passes startTime and
    // sourceOffset through to commitTrim() unchanged - so suppressing it
    // too was pure over-hiding. A clip that is both sides of two
    // different dissolves (the middle clip of an A->B->C chain) ends up
    // with neither handle, which is correct: both of its edges really are
    // crossfade boundaries. Trimming into/out of a crossfade is exactly
    // as ambiguous as splitting one there (see TimelinePanel.qml's
    // splitBlockedWindow for the same reasoning), so the constrained
    // handle simply doesn't appear rather than risk corrupting the
    // overlap bookkeeping.
    //
    // These are plain properties updated imperatively (via
    // updateOverlapAmount(), same trigger as overlapAmount above) rather
    // than bindings - the incoming side depends on OTHER rows of the
    // clips ListModel (a clip whose transitionOriginalBId points at this
    // one), reached through ListModel.get(i) inside
    // TimelinePanel.rebuildClipIndex(), and QML does not reliably
    // re-evaluate a binding whose dependency is only reachable that way.
    // A stale `true` here would leave a trim handle live on an edge that
    // has since become a crossfade boundary, exactly the corruption this
    // guard exists to prevent.
    property bool leftTrimmable: true
    property bool rightTrimmable: true
    readonly property real minClipDuration: 0.2

    function findClipRow(id) {
        for (var i = 0; i < clips.count; i++) {
            if (clips.get(i).clipId === id) return i
        }
        return -1
    }

    // Shared commit for both handles - for a right-trim, newStartTime/
    // newSourceOffset are simply passed back unchanged.
    function commitTrim(newStartTime, newDuration, newSourceOffset) {
        var deltaStart = newStartTime - model.startTime
        var row = findClipRow(model.clipId)
        if (row < 0) return

        Backend.logOperation("clip_trim", {
            clipId: model.clipId, trackId: model.trackId,
            fromStart: model.startTime, fromDuration: model.durationSeconds,
            toStart: newStartTime, toDuration: newDuration, toSourceOffset: newSourceOffset
        })

        clips.setProperty(row, "startTime", newStartTime)
        clips.setProperty(row, "durationSeconds", newDuration)
        clips.setProperty(row, "sourceOffset", newSourceOffset)

        // Keep a linked partner (typically the audio half of an A/V pair)
        // trimmed identically so they stay time-aligned - its own visual
        // binding was never broken, so setting its model row is enough.
        if (clipItem.isLinked && clipItem.linkedClipId) {
            var linkedRow = findClipRow(clipItem.linkedClipId)
            if (linkedRow >= 0) {
                var lc = clips.get(linkedRow)
                clips.setProperty(linkedRow, "startTime", lc.startTime + deltaStart)
                clips.setProperty(linkedRow, "durationSeconds", newDuration)
                clips.setProperty(linkedRow, "sourceOffset", newSourceOffset)
            }
        }

        clipItem.rebindPosition()
        if (timeline.updateTimelineEngine) timeline.updateTimelineEngine()
        Qt.callLater(timeline.checkAllClipNeighbors)
    }

    Rectangle {
        id: leftTrimHandle
        // Hidden on narrow (zoomed-out) clips, not just invisible - an
        // invisible Item's children don't receive mouse events in Qt
        // Quick, so this also frees up the whole clip body for the main
        // drag MouseArea underneath. Without this, at small enough zoom
        // the two 12px-hitbox handles alone could cover an entire
        // narrow clip, making it impossible to select/move/delete.
        visible: clipItem.leftTrimmable && clipItem.width > 40
        width: 6
        height: parent.height
        x: 0
        z: 20
        color: "white"
        opacity: leftTrimArea.containsMouse || leftTrimArea.pressed ? 0.6 : 0.0

        property real dragStartMouseX: 0
        property real origStartTime: 0
        property real origDuration: 0
        property real origSourceOffset: 0
        property real leftWallSeconds: 0
        property bool hasLinked: false
        property real linkedOrigStartTime: 0
        property real linkedLeftWallSeconds: 0
        property real liveStartTime: 0
        property real liveDuration: 0
        property real liveSourceOffset: 0

        MouseArea {
            id: leftTrimArea
            anchors.fill: parent
            anchors.leftMargin: -3
            anchors.rightMargin: -3
            hoverEnabled: true
            cursorShape: Qt.SizeHorCursor
            preventStealing: true

            onPressed: function(mouse) {
                leftTrimHandle.origStartTime = model.startTime
                leftTrimHandle.origDuration = model.durationSeconds
                leftTrimHandle.origSourceOffset = model.sourceOffset || 0
                var walls = clipItem.getTrackWalls(model.trackId, clipItem.x + clipItem.width / 2, model.clipId, clipItem.linkedClipId)
                leftTrimHandle.leftWallSeconds = walls.l / timeline.pixelsPerSecond

                // commitTrim() moves the linked partner (e.g. the audio
                // half of an A/V pair) by the same delta, on its OWN
                // track - without also clamping against that track's
                // walls, trimming could silently push the partner into a
                // neighbor there, which GES then just refuses to place
                // (console-only warning, clip stays visible but never
                // plays).
                leftTrimHandle.hasLinked = false
                if (clipItem.isLinked && clipItem.linkedClipId) {
                    var lr = clipItem.findClipRow(clipItem.linkedClipId)
                    if (lr >= 0) {
                        var linkedClip = clips.get(lr)
                        leftTrimHandle.hasLinked = true
                        leftTrimHandle.linkedOrigStartTime = linkedClip.startTime
                        var linkedCenterX = (linkedClip.startTime + linkedClip.durationSeconds / 2) * timeline.pixelsPerSecond
                        var linkedWalls = clipItem.getTrackWalls(linkedClip.trackId, linkedCenterX, linkedClip.clipId, model.clipId)
                        leftTrimHandle.linkedLeftWallSeconds = linkedWalls.l / timeline.pixelsPerSecond
                    }
                }

                leftTrimHandle.dragStartMouseX = leftTrimArea.mapToItem(container, mouse.x, mouse.y).x
                leftTrimHandle.liveStartTime = leftTrimHandle.origStartTime
                leftTrimHandle.liveDuration = leftTrimHandle.origDuration
                leftTrimHandle.liveSourceOffset = leftTrimHandle.origSourceOffset

                // Live waveform preview from here until release/cancel -
                // see trimPreviewActive's declaration for why.
                clipItem.trimPreviewActive = true
                clipItem.trimPreviewSourceOffset = leftTrimHandle.origSourceOffset
                clipItem.trimPreviewDuration = leftTrimHandle.origDuration

                // Suppress eviction while this handle holds the grab -
                // the handles press their OWN MouseAreas and never reach
                // TimelineClip's body onPressed, so activeDragItem is
                // null here. If this delegate were destroyed mid-trim
                // neither onReleased nor onCanceled would fire and
                // commitTrim() would never run: the trim would be
                // silently discarded.
                timeline.trimActiveClipId = model.clipId
                // Pressing a 6px trim handle is already unambiguously a
                // trim intent (unlike the clip body, there's no benign
                // "click to select" case here), so capture at press.
                timeline.beginUndoableGesture()
            }

            onPositionChanged: function(mouse) {
                if (!leftTrimArea.pressed) return
                var mouseX = leftTrimArea.mapToItem(container, mouse.x, mouse.y).x
                var deltaSeconds = (mouseX - leftTrimHandle.dragStartMouseX) / timeline.pixelsPerSecond
                var newStartTime = leftTrimHandle.origStartTime + deltaSeconds

                // Clamp: can't cross the previous clip (on this track OR
                // the linked partner's track), can't reveal source media
                // before its own start (sourceOffset < 0), can't shrink
                // the clip below the minimum duration.
                var minStart = Math.max(leftTrimHandle.leftWallSeconds, leftTrimHandle.origStartTime - leftTrimHandle.origSourceOffset)
                if (leftTrimHandle.hasLinked) {
                    // Translated into this clip's coordinate space: the
                    // delta (newStartTime - origStartTime) must keep the
                    // linked clip's own new start at or after ITS left wall.
                    var minStartFromLinked = leftTrimHandle.origStartTime + (leftTrimHandle.linkedLeftWallSeconds - leftTrimHandle.linkedOrigStartTime)
                    minStart = Math.max(minStart, minStartFromLinked)
                }
                var maxStart = leftTrimHandle.origStartTime + leftTrimHandle.origDuration - clipItem.minClipDuration
                newStartTime = Math.max(minStart, Math.min(newStartTime, maxStart))

                var newDuration = leftTrimHandle.origStartTime + leftTrimHandle.origDuration - newStartTime
                var newSourceOffset = leftTrimHandle.origSourceOffset + (newStartTime - leftTrimHandle.origStartTime)

                clipItem.x = newStartTime * timeline.pixelsPerSecond
                clipItem.width = newDuration * timeline.pixelsPerSecond

                leftTrimHandle.liveStartTime = newStartTime
                leftTrimHandle.liveDuration = newDuration
                leftTrimHandle.liveSourceOffset = newSourceOffset

                clipItem.trimPreviewSourceOffset = newSourceOffset
                clipItem.trimPreviewDuration = newDuration
            }

            onReleased: {
                clipItem.trimPreviewActive = false
                timeline.trimActiveClipId = ""
                if (leftTrimHandle.liveDuration > 0 && leftTrimHandle.liveDuration !== leftTrimHandle.origDuration) {
                    clipItem.commitTrim(leftTrimHandle.liveStartTime, leftTrimHandle.liveDuration, leftTrimHandle.liveSourceOffset)
                    timeline.commitUndoableEdit("Trim clip")
                } else {
                    clipItem.rebindPosition()
                    timeline.abortUndoableEdit()
                }
            }

            onCanceled: {
                // The mouse grab can be canceled mid-drag (e.g. a modal
                // window - like the split-blocked or delete-track dialogs -
                // taking the input grab) without onReleased ever firing.
                // Without this, clipItem.x/width stay at whatever raw
                // pixel values onPositionChanged last wrote, permanently
                // detached from the model (the clip would then ignore
                // zoom changes, neighbor moves, everything).
                clipItem.trimPreviewActive = false
                timeline.trimActiveClipId = ""
                clipItem.rebindPosition()
                timeline.abortUndoableEdit()
            }
        }
    }

    Rectangle {
        id: rightTrimHandle
        visible: clipItem.rightTrimmable && clipItem.width > 40
        width: 6
        height: parent.height
        x: parent.width - width
        z: 20
        color: "white"
        opacity: rightTrimArea.containsMouse || rightTrimArea.pressed ? 0.6 : 0.0

        property real dragStartMouseX: 0
        property real origDuration: 0
        property real rightWallSeconds: 0
        property bool hasLinked: false
        property real linkedOrigStartTime: 0
        property real linkedRightWallSeconds: 0
        property real liveDuration: 0

        MouseArea {
            id: rightTrimArea
            anchors.fill: parent
            anchors.leftMargin: -3
            anchors.rightMargin: -3
            hoverEnabled: true
            cursorShape: Qt.SizeHorCursor
            preventStealing: true

            onPressed: function(mouse) {
                rightTrimHandle.origDuration = model.durationSeconds
                var walls = clipItem.getTrackWalls(model.trackId, clipItem.x + clipItem.width / 2, model.clipId, clipItem.linkedClipId)
                rightTrimHandle.rightWallSeconds = walls.r / timeline.pixelsPerSecond

                // Same reasoning as the left handle - also bound by the
                // linked partner's own track walls.
                rightTrimHandle.hasLinked = false
                if (clipItem.isLinked && clipItem.linkedClipId) {
                    var lr = clipItem.findClipRow(clipItem.linkedClipId)
                    if (lr >= 0) {
                        var linkedClip = clips.get(lr)
                        rightTrimHandle.hasLinked = true
                        rightTrimHandle.linkedOrigStartTime = linkedClip.startTime
                        var linkedCenterX = (linkedClip.startTime + linkedClip.durationSeconds / 2) * timeline.pixelsPerSecond
                        var linkedWalls = clipItem.getTrackWalls(linkedClip.trackId, linkedCenterX, linkedClip.clipId, model.clipId)
                        rightTrimHandle.linkedRightWallSeconds = linkedWalls.r / timeline.pixelsPerSecond
                    }
                }

                rightTrimHandle.dragStartMouseX = rightTrimArea.mapToItem(container, mouse.x, mouse.y).x
                rightTrimHandle.liveDuration = rightTrimHandle.origDuration

                // Live waveform preview from here until release/cancel -
                // see trimPreviewActive's declaration for why. sourceOffset
                // never changes on a right-trim, only duration.
                clipItem.trimPreviewActive = true
                clipItem.trimPreviewSourceOffset = model.sourceOffset || 0
                clipItem.trimPreviewDuration = rightTrimHandle.origDuration

                // Suppress eviction while this handle holds the grab -
                // see the matching comment on the left handle.
                timeline.trimActiveClipId = model.clipId
                timeline.beginUndoableGesture()
            }

            onPositionChanged: function(mouse) {
                if (!rightTrimArea.pressed) return
                var mouseX = rightTrimArea.mapToItem(container, mouse.x, mouse.y).x
                var deltaSeconds = (mouseX - rightTrimHandle.dragStartMouseX) / timeline.pixelsPerSecond
                var newDuration = rightTrimHandle.origDuration + deltaSeconds

                // Clamp: can't cross the next clip on this track OR the
                // linked partner's track, can't shrink below the minimum
                // duration. (Extending past the source media's own length
                // is caught downstream by TimelineEngine's existing
                // asset-length clamp, which corrects clipsModel via the
                // clipDurationClamped signal.)
                var maxDuration = rightTrimHandle.rightWallSeconds - model.startTime
                if (rightTrimHandle.hasLinked) {
                    var maxDurationFromLinked = rightTrimHandle.linkedRightWallSeconds - rightTrimHandle.linkedOrigStartTime
                    maxDuration = Math.min(maxDuration, maxDurationFromLinked)
                }
                newDuration = Math.max(clipItem.minClipDuration, Math.min(newDuration, maxDuration))

                clipItem.width = newDuration * timeline.pixelsPerSecond
                rightTrimHandle.liveDuration = newDuration
                clipItem.trimPreviewDuration = newDuration
            }

            onReleased: {
                clipItem.trimPreviewActive = false
                timeline.trimActiveClipId = ""
                if (rightTrimHandle.liveDuration > 0 && rightTrimHandle.liveDuration !== rightTrimHandle.origDuration) {
                    clipItem.commitTrim(model.startTime, rightTrimHandle.liveDuration, model.sourceOffset || 0)
                    timeline.commitUndoableEdit("Trim clip")
                } else {
                    clipItem.rebindPosition()
                    timeline.abortUndoableEdit()
                }
            }

            onCanceled: {
                clipItem.trimPreviewActive = false
                timeline.trimActiveClipId = ""
                clipItem.rebindPosition()
                timeline.abortUndoableEdit()
            }
        }
    }

    // Delegate-regiszter szinkronizálása a timeline.clipItemsById map-be
    // (lásd TimelinePanel.qml). clipId NEM stabil splitAtPlayhead() után
    // (ugyanaz a delegate instance marad, csak a model.clipId role
    // változik) - ezért ez onClipIdChanged-re is lefut, nem csak
    // Component.onCompleted-ben egyszer.
    property string previousRegisteredClipId: ""
    function syncClipRegistration() {
        if (!timeline) return
        if (previousRegisteredClipId && previousRegisteredClipId !== clipId && timeline.unregisterClipItem) {
            timeline.unregisterClipItem(previousRegisteredClipId, clipItem)
        }
        if (clipId && timeline.registerClipItem) {
            timeline.registerClipItem(clipId, clipItem)
        }
        previousRegisteredClipId = clipId
    }
    onClipIdChanged: syncClipRegistration()

    Component.onCompleted: {
        if (timeline && timeline.devToolsEnabled) timeline.devCreateCount++
        syncClipRegistration()
        updateOverlapAmount()
    }

    Component.onDestruction: {
        if (timeline && timeline.devToolsEnabled) timeline.devDestroyCount++
        if (timeline && timeline.unregisterClipItem && previousRegisteredClipId) {
            timeline.unregisterClipItem(previousRegisteredClipId, clipItem)
        }
        // If this delegate is destroyed (e.g. clipsModel.clear() on
        // project open) while it held a drag/trim grab, nothing else
        // ever clears activeDragItem/trimActiveClipId/scrollDirection -
        // windowAdditiveOnly's "activeDragItem !== null" check stays
        // true for a destroyed wrapper forever, silently disabling the
        // window filter for the rest of the session.
        if (timeline) {
            if (timeline.activeDragItem === clipItem) timeline.activeDragItem = null
            if (timeline.trimActiveClipId === clipId) timeline.trimActiveClipId = ""
            timeline.scrollDirection = 0
        }
    }

    // waveformData is now a direct reactive binding (see its declaration
    // above) - it already re-evaluates on its own whenever waveformPath
    // changes, so no onWaveformPathChanged handler or imperative
    // loadWaveformIfNeeded() call is needed anymore.

    Connections {
        target: Backend ? Backend.cacheManager : null
        enabled: Backend !== null
        function onWaveformReady(itemId: string, path: string) {
            if (model.sourceItemId === itemId) {
                clipItem.waveformPath = path
            }
        }
    }
}
