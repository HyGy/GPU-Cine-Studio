#ifndef TIMELINEENGINE_H
#define TIMELINEENGINE_H

#include <QObject>
#include <QQuickItem>
#include <QString>
#include <QList>
#include <QTimer>
#include <QMap>
#include <QHash>
#include <QSet>
#include <QVariant>
#include <gst/gst.h>
#include <memory>
#include <atomic>
#include <QElapsedTimer>
#include "ScrubAudio.h"
#include <gst/video/videooverlay.h>

// Qt "signals" kulcsszó ütközik a GLib-bel
#ifdef signals
#undef signals
#endif
#include <ges/ges.h>
#define signals Q_SIGNALS

class AssetLoader;

// Project canvas the video track's caps are built from: even-rounded size
// plus the frame-rate fraction. Compared by setClips() to decide whether the
// no-op / incremental fast paths are still valid.
struct CanvasSpec {
    int width = 1920, height = 1080, fpsN = 30, fpsD = 1;
    bool operator==(const CanvasSpec &o) const {
        return width == o.width && height == o.height && fpsN == o.fpsN && fpsD == o.fpsD;
    }
};

class TimelineEngine : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool playing READ isPlaying NOTIFY playingChanged)
    Q_PROPERTY(qint64 position READ position NOTIFY positionChanged)
    Q_PROPERTY(qint64 totalDuration READ totalDuration NOTIFY totalDurationChanged)
    Q_PROPERTY(bool inGap READ inGap NOTIFY inGapChanged)
    // True for the duration of a full GES teardown+rebuild (setClips()'s
    // slow path - the only one reloadAssets() ever takes, since an asset
    // swap always disqualifies the incremental fast path). Lets QML show
    // a "switching..." indicator and block play/seek while it's true,
    // instead of letting the user interact with - or just glance at - the
    // torn-down/partially-rebuilt timeline mid-reload.
    Q_PROPERTY(bool reloadingAssets READ isReloadingAssets NOTIFY reloadingAssetsChanged)
    // qml6glsink spike (feature/qml6-gl-video-sink branch): lets
    // ProjectMonitor.qml pick between the native-window VideoOutput item
    // and the GstGLQt6VideoItem declaratively, instead of QML reading
    // GCS_VIDEO_SINK itself.
    Q_PROPERTY(bool glVideoSink READ isGLVideoSink CONSTANT)
    // Project canvas size of the currently built timeline (0 until built);
    // the Project Monitor uses it to outline the canvas.
    Q_PROPERTY(int canvasWidth READ canvasWidth NOTIFY canvasSizeChanged)
    Q_PROPERTY(int canvasHeight READ canvasHeight NOTIFY canvasSizeChanged)
    // True while the media loader thread has been stuck on one source file for
    // longer than kMediaStallMs (a hung disk/network share); stalledMediaPath
    // is that file. Resolve with skipStalledMedia() or abortMediaLoad().
    Q_PROPERTY(bool mediaLoadStalled READ mediaLoadStalled NOTIFY mediaLoadStalledChanged)
    Q_PROPERTY(QString stalledMediaPath READ stalledMediaPath NOTIFY mediaLoadStalledChanged)
    // Mount point stalledMediaPath lives on (what skipStalledMedia(true) applies to).
    Q_PROPERTY(QString stalledMediaMountRoot READ stalledMediaMountRoot NOTIFY mediaLoadStalledChanged)
    // With mediaLoadStalled: the loader is not stuck on a file of its own but
    // waits behind an already-skipped (abandoned) load that still holds GES's
    // cache lock; skipStalledMedia() has nothing to act on in that state.
    Q_PROPERTY(bool mediaLoadBlockedByAbandoned READ mediaLoadBlockedByAbandoned NOTIFY mediaLoadStalledChanged)

public:
    explicit TimelineEngine(QObject *parent = nullptr);
    ~TimelineEngine();

    Q_INVOKABLE void setClips(const QVariantList &clips);
    // Forces the NEXT setClips() call to fully re-resolve every GES asset
    // from scratch, instead of reusing m_assetCache or taking the no-op/
    // incremental fast paths - the only way an installed GES proxy
    // (ges_asset_set_proxy(), see ProxyAssets.h) can actually reach
    // preview. m_assetCache holds the pre-proxy GESAsset* per path and
    // would otherwise short-circuit the request entirely (the redirect
    // lives in GES's asset-cache lookup/request path, which this skip
    // never re-enters); separately, setClips()'s own byte-identical no-op
    // check and its three incremental add/remove/trim fast paths would
    // all conclude "nothing changed" against the same clip list, since
    // installing a proxy changes nothing about startTime/duration/
    // itemPath/trackId - the fields those paths diff on.
    //
    // Replays m_lastAppliedClips (the last setClips() INPUT, which is
    // exactly the shape setClips() itself expects) through the existing
    // commit-pending gate inside setClips() - no separate guard needed
    // here, that gate already defers safely if a previous commit is
    // still in flight (see setClips()'s own extensive comment on why -
    // this is the exact crash class a live reload must not reintroduce).
    // A one-shot invalidation: does NOT permanently disable the fast
    // paths, only forces the next call past them.
    Q_INVOKABLE void reloadAssets();
    // Only the cache-invalidation half of reloadAssets(): drops m_assetCache
    // and m_assetFailures, no rebuild/replay. For a caller that is about to
    // run a full setClips() anyway and just needs it to resolve every asset
    // fresh (so it sees the current proxy installs).
    Q_INVOKABLE void invalidateAssetCache();
    // Clears the remembered missing/unreadable-media results and runs `clips`
    // (the caller's current clip list: relinked paths have not been through
    // setClips() yet) through the normal path, forcing a full rebuild, so
    // media that has become available again is picked up.
    Q_INVOKABLE void retryUnavailableMedia(const QVariantList &clips);
    // Give up on the file the loader is stuck on (see mediaLoadStalled): it is
    // treated as unreadable. wholeDrive also marks every queued file on the
    // same mount point. Loading continues on a fresh loader thread.
    Q_INVOKABLE void skipStalledMedia(bool wholeDrive);
    // Drop the pending clip list and the queued loads and emit timelineReady()
    // so a waiting loading dialog closes. The in-flight load cannot be cancelled.
    Q_INVOKABLE void abortMediaLoad();
    bool mediaLoadStalled() const { return m_mediaLoadStalled; }
    int canvasWidth() const { return m_builtCanvas.width; }
    int canvasHeight() const { return m_builtCanvas.height; }
    QString stalledMediaPath() const { return m_stalledMediaPath; }
    QString stalledMediaMountRoot() const { return m_stalledMediaMountRoot; }
    bool mediaLoadBlockedByAbandoned() const { return m_mediaLoadBlocked; }
    Q_INVOKABLE void play();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void stop();
    // fast=true uses a KEY_UNIT seek (snaps to the nearest keyframe
    // instead of decoding forward to the exact frame) - much cheaper per
    // seek, meant for live scrubbing where a steady stream of seeks is
    // in flight; fast=false (default) is the normal frame-accurate seek
    // used everywhere else (programmatic nav, release-to-commit).
    Q_INVOKABLE void seek(qint64 positionMs, bool fast = false);
    // A single frame step while paused (frame_back / frame_fwd, key repeat,
    // jog knob): exactly seek(positionMs) - same flags, same busy/queued
    // handling - plus arming the audio scrub tap (ScrubAudio) for that very
    // seek, so a short grain of the audio at the new position is heard. Does
    // nothing extra while playing or when the "audio/scrubOnStep" app setting
    // is off. Every other caller keeps using seek().
    Q_INVOKABLE void stepSeek(qint64 positionMs);
    Q_INVOKABLE void setWindowId(qulonglong windowId);
    // setWindowId() deliberately ignores windowId==0 (a transient QML
    // binding value during startup must never erase a good handle) - this
    // is the explicit counterpart for when the native video window was
    // actually destroyed (VideoOutput::releaseResources()), so the engine
    // doesn't keep handing a dead window handle to the GStreamer overlay.
    Q_INVOKABLE void clearWindowId();
    // qml6glsink spike counterpart to setWindowId()/clearWindowId():
    // item must have Qt6GLVideoItem::itemInitialized === true (its GL
    // context must already exist) or ges_pipeline_preview_set_video_sink()
    // will fail the sink's NULL->READY transition - QML is responsible for
    // only calling this once that's true (see ProjectMonitor.qml's
    // onItemInitializedChanged gate, not Component.onCompleted).
    Q_INVOKABLE void setGLVideoItem(QQuickItem *item);
    Q_INVOKABLE void clearGLVideoItem();
    Q_INVOKABLE void refreshVideo();
    Q_INVOKABLE void setDecoderPreference(const QString &decoder);
    // denominator: 1 = full res, 2 = half, 4 = quarter. Scales the LIVE
    // preview's actual decode/render resolution down via a videoscale +
    // capsfilter inserted into the GESPipeline's (playbin-based)
    // "video-filter" slot - a real performance knob, not just a smaller
    // display widget. Export/render resolution is untouched - that's a
    // separate pipeline (RenderEngine) built fresh per render.
    Q_INVOKABLE void setPreviewScale(int denominator);
    // Saves the CURRENTLY DISPLAYED frame (whatever position the
    // pipeline is paused/seeked to) as a PNG at outputPath, at the
    // project's own resolution - for the Color Key effect's "pick a
    // color from the video" eyedropper (the native video overlay window
    // isn't part of the Qt scene graph, so QQuickWindow::grabWindow()
    // can't see it - this is GES's own purpose-built thumbnail API
    // instead, ges_pipeline_save_thumbnail(), no manual pad-probe/buffer
    // mapping needed). Returns "" on failure.
    Q_INVOKABLE QString captureCurrentFrame(const QString &outputPath);
    // Project directory, used to resolve relative LUT/overlay asset paths
    // stored in a clip's effects JSON (ClipEffects::resolveAssetPath()).
    // Must be set before any clip carrying such a path is applied.
    Q_INVOKABLE void setProjectDir(const QString &dir) { m_projectDir = dir; }
    // Live parameter update for an already-applied effect on an
    // already-live GESClip - e.g. an inspector slider being dragged.
    // Resolves the clip via m_clipObjects (borrowed pointer, see its
    // declaration comment) and calls ClipEffects::setParam() directly.
    // Deliberately NOT gated on m_commitPending/isBusyAsync(): this only
    // sets a property on an object that already exists and is already
    // live in the timeline, it never tears anything down or rebuilds the
    // GES graph - unlike setClips(), which is why THAT path needs the
    // gate. Flagged for live empirical verification per project policy
    // before being trusted under heavy scrubbing load.
    Q_INVOKABLE bool setClipEffectParam(const QString &clipId, const QString &effectId,
                                         const QString &param, const QVariant &value);

    // Same contract as setClipEffectParam() above, for a TITLE clip's
    // GES child properties (text / font-desc / colours / xpos / ypos /
    // ...). Used by the title inspector panel for responsive editing.
    //
    // VERIFIED LIVE (standalone GES probe, GES 1.24.2): the property
    // write itself takes effect immediately on a live GESTitleSource,
    // but on a PAUSED pipeline nothing reaches the screen until a
    // FLUSHING seek - so the QML caller must re-seek to the current
    // position afterwards, exactly like EffectParamSlider.qml does.
    Q_INVOKABLE bool setTitleParam(const QString &clipId, const QString &param,
                                    const QVariant &value);

    // --- Per-track hide (video) / mute (audio) ------------------------
    //
    // Architecture this relies on (verified empirically, see
    // applyTrackActivation()): the pipeline has exactly TWO GESTracks -
    // one video, one audio, created by ges_timeline_new_audio_video().
    // Each UI track row (V1, V2, A1, A2, ...) is a separate GESLayer
    // inside that same pair of tracks. A "linked" A/V pair is two
    // SEPARATE clip rows on two separate layers (a video-only row on
    // V1 and an audio-only row on A1 - see TimelinePanel.qml's comment
    // about findLinkedAudioRow()), so hiding V1 and muting A1 are
    // inherently independent operations: they touch different layers.
    //
    // The mechanism is ges_layer_set_active_for_tracks(), restricted to
    // the ONE GESTrack whose media type this UI track represents - so
    // even a layer that happens to hold a combined A/V clip only loses
    // the side being toggled. Verified live on GES 1.24.2 with a
    // standalone harness: toggling during PLAYING makes the composited
    // video go black (I420 mean 131.98 -> 53.34, i.e. exactly Y=16/UV=128)
    // while the audio peak keeps moving, and muting drives the audio peak
    // to exactly 0.0000 while the video keeps updating. The same harness
    // also confirmed the change does NOT take effect without a following
    // ges_timeline_commit() - hence commitTrackActivation().
    Q_INVOKABLE void setTrackVideoHidden(const QString &trackId, bool hidden);
    Q_INVOKABLE void setTrackAudioMuted(const QString &trackId, bool muted);
    Q_INVOKABLE bool isTrackVideoHidden(const QString &trackId) const
        { return m_hiddenVideoTracks.contains(trackId); }
    Q_INVOKABLE bool isTrackAudioMuted(const QString &trackId) const
        { return m_mutedAudioTracks.contains(trackId); }
    // Track-level gain. Linear (1.0 = unchanged), applied to the "volume"
    // child property of every audio source in the track's layer.
    Q_INVOKABLE void setTrackVolume(const QString &trackId, double volume);
    Q_INVOKABLE double trackVolume(const QString &trackId) const
        { return m_trackVolumes.value(trackId, 1.0); }
    // Test/automation helper: the "volume" child property actually set on the
    // audio sources of this track's layer, read back from GES (one entry per clip).
    Q_INVOKABLE QVariantList trackVolumeDebug(const QString &trackId) const;
    // Same, for audio track mute (true = the sources carry the muted volume).
    Q_INVOKABLE QVariantList trackMuteDebug(const QString &trackId) const;

    // Track pan (-1.0 left ... 0 center ... +1.0 right). Applied to the
    // hidden audiopanorama effect (stage C3) on every clip of the layer.
    Q_INVOKABLE void setTrackPan(const QString &trackId, double pan);
    Q_INVOKABLE double trackPan(const QString &trackId) const
        { return m_trackPans.value(trackId, 0.0); }
    // Test/automation helper: the "panorama" child property of the pan
    // effects in this track's layer, one entry per clip.
    Q_INVOKABLE QVariantList trackPanDebug(const QString &trackId) const;

    // Master gain (linear). Applied by the preview-only "audio-filter" bin
    // (volume + level) installed in createPipeline(); the render folds it
    // into each clip's trackVolume instead.
    Q_INVOKABLE void setMasterVolume(double volume);
    Q_INVOKABLE double masterVolume() const { return m_masterVolume; }
    // Bulk form for project load / track-list rebuild: each entry is a
    // map with "trackId", "hidden" and "muted". Replaces the engine's
    // whole notion of which tracks are hidden/muted in one commit, so a
    // newly loaded project can't inherit the previous one's state.
    Q_INVOKABLE void setTrackStates(const QVariantList &tracks);
    // Reads the activation flags back out of GES itself (not out of this
    // class's own bookkeeping), per layer, for both the video and the
    // audio GESTrack. Exists so a test/automation run can assert what
    // the GES graph ACTUALLY has, rather than what we think we set.
    // Returns { "<trackId>": { "videoActive": bool, "audioActive": bool } }.
    Q_INVOKABLE QVariantMap trackActivationDebug() const;

    // Length (seconds) of the source media behind a timeline clip, from
    // the already-resolved GES asset (m_assetCache - never runs discovery
    // here). Used by the QML transition code to know how much unused
    // source material ("handle") a clip has past its out-point. Returns
    // +infinity for still images (no length limit) and -1 when the asset
    // is not resolved yet / unknown.
    Q_INVOKABLE double sourceDurationSeconds(const QString &path) const;
    // Test/automation read-back of what GES ACTUALLY holds, per layer:
    // [{ layer, kind: "clip"|"transition", start, inpoint, duration }]
    // (seconds), sorted by layer then start.
    Q_INVOKABLE QVariantList gesLayoutDebug() const;

    bool isPlaying() const { return m_playing; }
    qint64 position() const { return m_position; }
    qint64 totalDuration() const { return m_totalDuration; }
    bool inGap() const { return false; }
    bool isGLVideoSink() const;
    bool isReloadingAssets() const { return m_reloadingAssets; }

    qulonglong windowId() const;

signals:
    void playingChanged();
    // Per-channel levels from a GStreamer "level" element (dB). trackId is
    // "master" for the preview master meter (stage C1) or a real track id
    // for the per-track meters (stage C2).
    void audioLevel(const QString &trackId, double peakL, double peakR,
                    double holdL, double holdR);
    void positionChanged();
    void canvasSizeChanged();
    void totalDurationChanged();
    void inGapChanged();
    void reloadingAssetsChanged();
    void mediaLoadStalledChanged();
    void error(const QString &message);
    // A source file failed to negotiate/link inside the pipeline (e.g. a
    // preview proxy GStreamer cannot decode in this chain). failingPath is
    // the file the failing demuxer was reading; the Backend matches it
    // against the installed proxies and reverts that one to its original.
    void proxyPlaybackFailed(const QString &failingPath);
    // A full rebuild never reached its first preroll within the watchdog
    // window: the Backend drops all installed proxies and rebuilds from the
    // originals (once - a second consecutive failure gives up, see
    // onPrerollWatchdog()).
    void proxyRebuildStuck();
    void timelineReady();  // Emitted when timeline commit is complete and pipeline is ready
    // A (re)build has reached the point where a picture is available again:
    // the first ASYNC_DONE (preroll) after the rebuild commit, or - when no
    // preroll will ever come (empty timeline, no layers, aborted media load,
    // watchdog give-up) - the moment that is known. timelineReady() /
    // reloadingAssetsChanged() fire BEFORE the preroll, so UI that must wait
    // for a playable preview (the proxy-switch overlay) uses this instead.
    void previewReady();
    // Emitted after a decoder-preference change rebuilt the pipeline from
    // scratch (destroyPipeline()+createPipeline() wipes the GES layers/
    // clips). The QML side owns the actual clip list, so it must respond
    // by calling updateTimelineEngine() again to repopulate the timeline.
    void decoderPreferenceApplied();
    // Emitted when setClips() had to shorten a clip because inPoint+duration
    // exceeded the source asset's real length - lets QML correct its own
    // clipsModel entry so the timeline draws what will actually play.
    void clipDurationClamped(const QString &clipId, double newDurationSeconds);
    // Emitted once per setClips() call for each clip whose source file
    // doesn't exist on disk right now (e.g. a Kdenlive-imported
    // placeholder for media that hasn't been relinked yet) - lets QML
    // mark that clip's box distinctly instead of silently leaving it
    // blank/unplayable with no visible explanation. QML must clear its
    // own markers before each setClips() call, since a clip that was
    // missing last time may have reappeared (and so gets no signal
    // this time).
    void clipMediaMissing(const QString &clipId);

private slots:
    void onPositionTimer();
    // timelinePtr: identity of the GESTimeline this commit notification
    // belongs to (the raw pointer, never dereferenced - compared only for
    // equality against the CURRENT m_timeline). Needed because
    // Qt::QueuedConnection means a commit notification from a pipeline
    // that setDecoderPreference() has since destroyed and replaced can
    // still be sitting in the event queue when it fires; acting on it
    // would seek/play the wrong (current) pipeline using stale state.
    // An earlier version of this guard used an incrementing generation
    // counter sampled on the GES streaming thread - that sample happened
    // too late (after the rebuild could already have bumped it) and
    // raced on an unsynchronized quint64 read/write across threads.
    // Pointer identity has neither problem: onTimelineCommited() reads
    // the timeline pointer it was handed by GES itself, not a separately
    // tracked counter.
    //
    // quint64, NOT quintptr: quintptr is not a registered Qt meta-type,
    // so QMetaObject::invokeMethod(..., Qt::QueuedConnection, Q_ARG(
    // quintptr, ...)) silently fails at runtime ("Unable to handle
    // unregistered datatype 'quintptr'") and this slot is simply never
    // invoked - which hung project loading entirely (the commit
    // notification that was supposed to finish it never arrived).
    // quint64 is large enough to hold any pointer on a 64-bit build and
    // is registered by Qt automatically.
    void onCommitCompleted(quint64 timelinePtr);

private:
    void createPipeline();
    void destroyPipeline();
    static gboolean busCallback(GstBus *bus, GstMessage *msg, gpointer data);
    static void onTimelineCommited(GESTimeline *timeline, gpointer user_data);

    // Borrowed pointer to the single video / single audio GESTrack the
    // timeline owns. Never unreffed by the caller - the timeline owns it.
    GESTrack *gesTrackOfType(GESTrackType type) const;
    // True when this AUDIO row's layer is deactivated for the audio track.
    bool layerAudioInactive(const QString &trackId) const;
    void flushAfterAudioMuteChange();
    // Pushes m_hiddenVideoTracks / m_mutedAudioTracks onto the GES layer
    // graph. Does NOT commit - callers decide, because setClips() is
    // about to commit anyway.
    void applyTrackActivation(const QString &trackId);
    void reapplyAllTrackActivations();
    // Lightweight commit used only for activation toggles. Deliberately
    // does NOT arm addAsyncTimeout(): an activation-only commit does not
    // reliably produce an ASYNC_DONE on a running pipeline, and the
    // watchdog's recovery path (forcing the pipeline to PAUSED) would
    // then fire in the middle of normal playback.
    void commitTrackActivation();

    void applyTrackVolume(const QString &trackId);
    void reapplyAllTrackVolumes();

    GESPipeline *m_pipeline;
    GESTimeline *m_timeline;
    QMap<QString, GESLayer*> m_layers; // trackId -> GESLayer mapping

    // UI track ids whose VIDEO contribution / AUDIO contribution is
    // switched off. Kept here rather than read back from GES so the
    // state survives ensureLayers() recreating a layer and
    // destroyPipeline()/createPipeline() rebuilding the whole graph.
    QSet<QString> m_hiddenVideoTracks;
    QSet<QString> m_mutedAudioTracks;
    QHash<QString, double> m_trackVolumes;   // track id -> linear gain; missing = 1.0
    QHash<QString, double> m_trackPans;      // track id -> -1..1;        missing = 0.0
    double m_masterVolume = 1.0;             // master gain (preview audio-filter)

    // Read by bus_sync_handler() on a GStreamer streaming thread while the
    // main thread may set/clear it - atomic, not a plain field.
    std::atomic<qulonglong> m_windowId;
    // qml6glsink spike state. m_glVideoItem is retained across
    // destroyPipeline()/createPipeline() (same rationale as m_windowId -
    // see setDecoderPreference()'s comment). m_glSinkBin is the GstBin
    // passed to ges_pipeline_preview_set_video_sink() (owns one ref, for
    // teardown); m_glSinkElement is the actual qml6glsink element inside
    // it - distinct because once wrapped, the bin itself has no "widget"
    // property. m_glSinkInstalled tracks whether the sink is currently
    // installed AND reached GST_STATE_READY (checked explicitly - GES
    // logs a failed activation but does not report it to the caller).
    QQuickItem *m_glVideoItem = nullptr;
    GstElement *m_glSinkBin = nullptr;
    GstElement *m_glSinkElement = nullptr;
    bool m_glSinkInstalled = false;
    bool m_playing;
    qint64 m_position;
    qint64 m_totalDuration;
    // Project frame duration in ms, kept in sync with the fps setClips()
    // applies to the video tracks' restriction caps - used to keep a
    // seek target strictly before the timeline's true last frame (see
    // seek()'s clamp).
    double m_frameDurationMs = 1000.0 / 30.0;
    // Last position a seek's ASYNC_DONE actually confirmed. Used by
    // asyncTimeoutCallback() to recover a wedged pipeline (a seek whose
    // target never prerolls - see TODO.txt's mpegpsdemux dead-zone
    // notes) by falling back to a position already known to work,
    // instead of leaving the pipeline stuck wherever the failed seek
    // left it.
    qint64 m_lastGoodSeekMs = -1;
    // Consecutive asyncTimeoutCallback() seek recoveries without a seek
    // ASYNC_DONE in between; capped so an unplayable "last good" position
    // cannot loop the watchdog forever.
    int m_seekRecoveryAttempts = 0;

    std::unique_ptr<ScrubAudio> m_scrub;   // audio scrub tap + side pipeline (owned)
    QTimer *m_positionTimer;
    QString m_decoderPreference;
    bool m_resumePlayAfterDecoderChange = false;
    // play() was called while a commit was pending and had to be dropped -
    // remembers to actually start playback once that commit completes,
    // instead of silently requiring the user to press play again.
    bool m_playRequestedAfterCommit = false;

    // Dead-reckoning playhead smoothing (continuous smoothing during NLE reconfiguration)
    qint64  m_drAnchorPos;          // Utolsó simított pozíció (ms)
    qint64  m_drAnchorTimeMs;       // m_drClock.elapsed() az anchor rögzítésekor (monoton)
    QElapsedTimer m_drClock;        // Monotonic clock for dead reckoning (wall clock can jump)
    bool    m_drActive;             // Aktív-e a dead reckoning
    qint64  m_drLastPipelinePos;    // Előző pipeline query eredmény (stall detekció)
    int     m_skipSmoothingTicks;   // ASYNC_DONE után ennyi tick-ig pipeline 1:1 követés
    bool    m_isSeeking;            // Seek folyamatban: NE kérdezd a pipeline-t, pure DR

    // Pitivi-style async state management
    qint64 m_nextSeek;              // Elhalasztott seek pozíció (-1 ha nincs)
    bool m_nextSeekFast = false;    // Az elhalasztott seek fast(KEY_UNIT) kérés volt-e
    void seekImpl(qint64 positionMs, bool fast, bool scrub, bool queuedReplay = false);
    bool m_nextSeekScrub = false;   // The queued seek is a frame step (arm the audio scrub tap when it runs)
    bool m_commitWanted;            // Elhalasztott commit flag
    guint m_asyncTimeoutId;         // Async timeout source ID (0 ha nincs)
    bool m_wasEmpty;                // Timeline üres volt-e az utolsó commit-kor
    bool m_commitPending;           // Jelzi, hogy commit folyamatban van
    gulong m_commitedSignalId;      // A "commited" signal ID-ja a lecsatlakozáshoz

    // === Deferred clip-list application (in-flight-commit guard) ===
    // setClips() destroys and rebuilds the ENTIRE GES clip graph. Doing
    // that while a previous commit is still being applied on GStreamer's
    // streaming thread freed GESTrackElements out from under decodebin's
    // still-running autoplug/stream-info callbacks - live SIGSEGV with
    // GES_IS_EXTRACTABLE / GES_IS_URI_SOURCE_ASSET assertion failures
    // inside a libffi closure. m_commitPending (cleared only once GES's
    // "commited" signal has actually fired) is the gate; while it is set,
    // an incoming clip list is only snapshotted here and replayed later.
    // Only the newest snapshot is kept, deliberately: QML owns the full
    // clip list, so a newer list always supersedes an older one.
    QVariantList m_pendingClips;
    bool m_hasPendingClips = false;
    // setClips()'s own reentrancy guard - see the extensive comment at
    // that function's entry (Part J.4.4) for the exact mechanism this
    // defends against: a synchronous GES call made from inside setClips()
    // (ges_uri_clip_asset_request_sync(), no longer called here - discovery
    // runs on the AssetLoader thread) pumped the Qt/GLib event loop,
    // which can let a QTimer fire setClips() again before the outer call
    // returns.
    bool m_inSetClips = false;
    // True between setClips()'s quiesce (pipeline taken PAUSED -> READY before
    // a full teardown, see setClips) and the ASYNC_DONE that follows the
    // rebuild: that ASYNC_DONE is not a seek, and emitPosition() would read
    // ~0 from the freshly re-prerolled pipeline and move the playhead there
    // before the queued m_nextSeek restores it.
    bool m_restoreAfterQuiesce = false;

    // Preroll watchdog for full rebuilds (see startPrerollWatchdog()): armed
    // when a full teardown+rebuild starts, disarmed by the first ASYNC_DONE
    // after its commit. m_awaitingPreroll is set when the commit completes
    // (onCommitCompleted clears m_reloadingAssets BEFORE the pipeline has
    // actually prerolled, so that flag alone cannot tell "rebuilt" from
    // "rebuilt and playable").
    QTimer *m_prerollWatchdog = nullptr;
    bool m_awaitingPreroll = false;
    int m_watchdogStrikes = 0;
    void startPrerollWatchdog();
    void stopPrerollWatchdog();
    void onPrerollWatchdog();
    bool m_reloadingAssets = false;
    // Safety net: m_commitPending can be left set with no async watchdog
    // armed (busCallback's removeAsyncTimeout() on an unrelated ASYNC_DONE
    // disarms it before "commited" ever fires), which would otherwise make
    // the gate above swallow every later edit for the rest of the session.
    QTimer *m_pendingClipsTimer = nullptr;
    void applyPendingClips();   // main thread only

    // No-op short-circuit: if setClips() is called twice in a row with an
    // identical clip list (e.g. resetTimeline() followed immediately by
    // loadProjectJSON() re-applying the same empty list, or a drag that
    // ends exactly where it started), skip the entire teardown/rebuild/
    // commit cycle instead of paying its cost for a no-op result.
    // m_hasAppliedClips guards the very first call, where an empty
    // m_lastAppliedClips must NOT be treated as "already matches".
    QVariantList m_lastAppliedClips;
    bool m_hasAppliedClips = false;
    // Canvas (even-rounded size + fps) the track restriction caps were last
    // built with; a change forces the full rebuild in setClips().
    CanvasSpec m_builtCanvas{0, 0, 0, 0};

    // URI -> GESAsset* cache, local to this engine. GES itself also caches
    // GESUriClipAsset by URI internally, but still pays a request/
    // main-context round-trip per call; this avoids that round-trip when
    // setClips() rebuilds the whole timeline and re-requests the same few
    // source files for every one of hundreds/thousands of clips. The asset
    // pointer is never released (see the INTENTIONALLY NOT UNREFFED comment
    // in setClips()) - caching it just means that leak is now bounded by
    // distinct source file count instead of (clip count x edit count).
    QHash<QString, GESAsset*> m_assetCache;

    // === Off-main-thread asset resolution (see AssetLoader.h) ===
    // setClips() never resolves a URI-clip asset itself: a path that is in
    // neither m_assetCache nor m_assetFailures is handed to m_assetLoader and
    // the clip list is parked in m_assetWaitClips (latest wins, like
    // m_pendingClips) until every result is in.
    struct AssetFailure { bool missing; QString error; };
    AssetLoader *m_assetLoader = nullptr;
    QHash<QString, AssetFailure> m_assetFailures;
    QVariantList m_assetWaitClips;
    bool m_hasAssetWaitClips = false;
    bool m_retryReload = false;       // next loader enqueue asks GES to reload failed assets
    QTimer *m_mediaStallTimer = nullptr;
    bool m_mediaLoadStalled = false;
    QString m_stalledMediaPath;
    QString m_stalledMediaMountRoot;
    bool m_mediaLoadBlocked = false;
    QString m_stallIgnorePath;        // stall dismissed by abortMediaLoad()
    QString m_lastAbandonedPath;
    QSet<QString> m_stallWarned;
    QStringList unresolvedAssetPaths(const QVariantList &clips) const;
    void onAssetLoaded(const QString &path, int status, quintptr asset, const QString &error, bool abandoned);
    void resumeAssetWait();
    void checkMediaStall();
    void setMediaStalled(bool stalled, const QString &path, bool blocked = false);

    // The one GES_TYPE_TITLE_CLIP asset every title clip is extracted
    // from. Requested lazily on the first title, then reused. Never
    // unreffed, same reasoning as m_assetCache above.
    GESAsset *m_titleAsset = nullptr;

    // === Incremental-update scaffolding (Stage 4/5 prep, Step 1) ===
    // clipId -> the GESClip* actually sitting in a layer right now.
    // Borrowed pointers only: the layer owns the clip, we never ref/unref
    // it here (see the asset-ownership scar tissue above - the same
    // caution applies to clip lifetime). Rebuilt in full on every
    // setClips() call for now (behavior is unchanged - this step is pure
    // bookkeeping, no new fast path yet), but kept as its own map rather
    // than inferred from m_lastAppliedClips so a future incremental diff
    // has a ready clipId -> live object lookup.
    // GL timeline mode (see GlTimeline.h) - decided once, in createPipeline(),
    // because GES fixes it per video track at track creation.
    bool m_glMode = false;
    QHash<QString, GESClip*> m_clipObjects;
    // clipId -> the engine-relevant field subset (itemPath/trackId/
    // startTime/durationSeconds/sourceOffset/hasVideo/hasAudio) for a clip
    // that ACTUALLY landed in GES. Deliberately separate from
    // m_lastAppliedClips: that records setClips()'s INPUT list (for the
    // byte-identical no-op short-circuit) and can include clips that were
    // later skipped (missing file, unknown track, refused placement) -
    // this map must only ever reflect what is really sitting in the GES
    // graph, since a future diff built against the wrong base would
    // permanently desync (an input clip recorded as "applied" but never
    // actually created would never be retried).
    QHash<QString, QVariantMap> m_appliedClips;

    // See setProjectDir() - resolves relative effect-asset paths (LUT
    // files, overlay images) embedded in a clip's effects JSON.
    QString m_projectDir;

    // === Incremental-update scaffolding (Stage 4/5 prep, Step 2) ===
    // Master switch for the remove-only fast path in setClips(): when the
    // new clip list is exactly the previous applied set minus some
    // clipIds (no additions, no field changes on survivors), skip the
    // full teardown+rebuild and just ges_layer_remove_clip() the ones
    // that disappeared. Defaults on for live-testing; flip to false to
    // immediately fall back to the always-correct full rebuild if this
    // is ever suspected of causing a problem - see TODO.txt for the
    // staged rollout plan this is Step 2 of.
    bool m_incrementalRemoveEnabled = true;

    // === Incremental-update scaffolding (Stage 4/5 prep, Step 3) ===
    // Master switch for the add-only fast path: when the new clip list is
    // exactly the previous applied set plus some new clips (no removals,
    // no field changes on survivors), skip the full teardown+rebuild and
    // just add the new ones via addClipToGES(), leaving every existing
    // clip/layer untouched. Independent of m_incrementalRemoveEnabled so
    // either can be disabled on its own if one is ever suspected of
    // causing a problem.
    bool m_incrementalAddEnabled = true;

    // === Incremental-update scaffolding (Stage 4/5 prep, Step 4) ===
    // Master switch for in-place timing updates: when a surviving clip's
    // ONLY changes are startTime/durationSeconds/sourceOffset (same
    // itemPath/trackId/hasVideo/hasAudio), skip the full teardown+rebuild
    // and mutate the live GESClip in place via ges_timeline_element_
    // set_start/set_duration/set_inpoint instead of remove+re-add. This
    // is the step the whole "timeline scaling" initiative was actually
    // for - trims/drags no longer need to tear down and rebuild clips
    // they didn't touch. Independent of the other two flags.
    bool m_incrementalTrimEnabled = true;

    // === Incremental-update scaffolding (Stage 4/5 prep, Step 5) ===
    // Master switch for in-place track changes: when a surviving clip's
    // ONLY non-timing change is trackId (itemPath/hasVideo/hasAudio
    // unchanged), skip the full teardown+rebuild and re-parent it to its
    // new (already-existing) layer via ges_clip_move_to_layer_full()
    // instead of remove+re-add. Independent of the other flags.
    bool m_incrementalTrackChangeEnabled = true;

    // Single-clip GES placement, factored out of the full-rebuild add
    // loop so Step 3's add-only fast path can reuse the EXACT same logic
    // (file-exists check, layer lookup, trackType, asset cache/
    // request_sync, duration clamp + clipDurationClamped emit,
    // ges_layer_add_asset, m_clipObjects/m_appliedClips bookkeeping)
    // instead of a second, divergence-prone copy. Updates maxDuration
    // in place (never decreases it) if the added clip's end exceeds it.
    void addClipToGES(const QVariantMap &clipMap, qint64 &maxDuration);

    // Hidden, engine-owned metering effect (stage C2). Not part of the
    // clip's effect list in QML/project files; identified by the metadata
    // key kMeterMetaKey. One per audio clip, always at top-effect index 0
    // (last in the processing chain) so it measures AFTER the user's clip
    // effects. The level element's name encodes the clip id; the message
    // source name is mapped back to the clip's CURRENT track in
    // busCallback().
    void addMeterEffect(GESClip *clip, const QString &clipId);
    // Hidden, engine-owned pan effect (stage C3). Added BEFORE the meter
    // (so the meter measures the panned signal); identified by kPanMetaKey.
    void addPanEffect(GESClip *clip, const QString &clipId);
    // Applies m_trackPans to every clip of the given layer (audiopanorama
    // child property "panorama", a gfloat).
    void applyTrackPan(const QString &trackId);
    void reapplyAllTrackPans();

    // Pitivi-style helper methods
    bool isBusyAsync() const { return m_asyncTimeoutId != 0; }
    void addAsyncTimeout(const char* reason, int timeoutSec = 3);
    // Millisecond-granularity variant for scrub seeks, where measured
    // real-world latency (p99 ~133ms) is far below addAsyncTimeout()'s
    // 1-second floor - a short, sub-second watchdog bounds how long any
    // single stuck scrub tick can freeze the UI.
    void addAsyncTimeoutMs(const char* reason, int timeoutMs);
    void removeAsyncTimeout();
    static gboolean asyncTimeoutCallback(gpointer data);
    void emitPosition();
    // Takes a PAUSED (or mid-async) pipeline to READY before a teardown that
    // cannot wait any longer (watchdog / fallback timer paths): deactivating
    // the pads stops the streaming threads that could still be running
    // decodebin/transition callbacks on the clips about to be destroyed.
    // Sets m_restoreAfterQuiesce on success. Returns true if it changed state.
    bool quiesceToReady(const char *reason);
    // Project canvas for a clip list (see the .cpp): the settings, with an
    // unresolved "auto" frame rate taken from the first video clip's media.
    CanvasSpec canvasFor(const QVariantList &clips) const;
    // pause()-like bookkeeping for paths that force the pipeline to NULL
    // behind play()/pause()'s back (GL sink teardown/reinstall).
    void resetPlaybackStateForForcedStop();
    void drResetAnchor(qint64 posMs);
    void drInvalidate();
    qint64 drExpectedPosition() const;
    void ensureLayers(const QStringList &trackIds);
    static void applyDecoderRanks(const QString &decoder);

    // qml6glsink spike helpers.
    //
    // True once the video output (native window OR GL item, whichever
    // this build is using) is actually ready to receive frames. Replaces
    // the old `m_windowId != 0` check at every gate (play(),
    // onCommitCompleted()) so a GES pipeline built before the GL item
    // exists simply stays parked at GST_STATE_NULL - exactly the state
    // ges_pipeline_preview_set_video_sink() requires - instead of letting
    // GES's own NULL_TO_READY autoplug an autovideosink fallback behind
    // our back.
    bool videoOutputReady() const;
    // Installs m_glSinkBin via ges_pipeline_preview_set_video_sink().
    // Requires: m_pipeline non-null, m_glVideoItem non-null, pipeline in
    // GST_STATE_NULL (forces it there first if not - normally unreachable
    // since videoOutputReady() keeps playback from ever starting without
    // a sink, but a scene-graph invalidation could in principle re-enter
    // here with the pipeline already running), not already installed.
    // Returns false (and leaves m_glSinkInstalled false) if any of that
    // fails, so callers can tell a real failure from "already installed".
    bool installGLSink();
    // The "wake the pipeline up now that video output exists" sequence -
    // extracted from setWindowId() so setGLVideoItem() can reuse it
    // verbatim: refreshVideo() + force PAUSED + m_nextSeek = m_position +
    // addAsyncTimeout(). Also honours m_playRequestedAfterCommit, the same
    // way onCommitCompleted() does.
    void wakeUpForVideoOutput();
};

#endif // TIMELINEENGINE_H
