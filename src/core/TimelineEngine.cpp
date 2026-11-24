//===== core/TimelineEngine.cpp =====
#include "TimelineEngine.h"
#include "MediaAvailability.h"
#include "FrameRate.h"
#include "ClipEffects.h"
#include "TitleClips.h"
#include "GesTransitions.h"
#include "TimeConv.h"
#include "AssetLoader.h"
#include "Qml6GLSink.h"
#include "GlTimeline.h"
#include "GstElementDiscovery.h"
#include <QDebug>
#include <QVariantMap>
#include <algorithm>
#include <cmath>
#include <limits>
#include <QSettings>
#include "ProjectSettings.h"
#include <QFileInfo>
#include <QDateTime>
#include <QElapsedTimer>
#include <QSet>
#include <QUrl>
#include <QFile>


// Dead-reckoning: ha a pipeline és a DR eltérése meghaladja ezt a küszöböt,
// azonnali anchor reset történik. A seekek már külön kezelve vannak
// (m_isSeeking flag), ezért itt csak valódi loop/EOS ugrásokat kell
// elkapni. Az NLE transition határoknál a pipeline ~200-300ms-os
// hamis pozíció-ugrásokat jelent — ezeket a smoothing nyeli el.
static constexpr qint64 DR_SEEK_THRESHOLD_MS = 500;

// Hidden, engine-owned metering effect metadata key (stage C2). Effects
// carrying this key are NOT part of the clip's effect list in QML/project
// files; anything enumerating a clip's top effects must skip them.
static constexpr const char *kMeterMetaKey = "gcs-internal-meter";
// Hidden, engine-owned pan effect metadata key (stage C3).
static constexpr const char *kPanMetaKey = "gcs-internal-pan";

// A GStreamer element name (and GES parse-description token) may only
// contain letters, digits, '_' and '-'. App-generated clip ids
// ("clip_a_<ms>", "clip_v_<ms>", "title_<ms>", "syn_<ms>_<i>") already
// comply; a hand-edited project file could contain anything, so sanitize
// and map the name back to the real id in busCallback().
static QString meterElementName(const QString &clipId)
{
    QString s = clipId;
    for (int i = 0; i < s.size(); ++i) {
        const QChar c = s.at(i);
        if (!(c.isLetterOrNumber() || c == QLatin1Char('_') || c == QLatin1Char('-')))
            s[i] = QLatin1Char('_');
    }
    return QStringLiteral("gcslvl_") + s;
}

static QString panElementName(const QString &clipId)
{
    return QStringLiteral("gcspan_") + meterElementName(clipId).mid(7);
}

// Reads one of the "level" message's per-channel arrays (GValueArray of
// doubles, dBFS). Missing/short arrays fall back to the left value.
static bool readLevelArray(const GstStructure *s, const gchar *field, double &l, double &r)
{
    const GValue *v = gst_structure_get_value(s, field);
    if (!v) return false;
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    GValueArray *va = (GValueArray *) g_value_get_boxed(v);
    G_GNUC_END_IGNORE_DEPRECATIONS
    if (!va || va->n_values == 0) return false;
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    l = g_value_get_double(g_value_array_get_nth(va, 0));
    r = (va->n_values > 1) ? g_value_get_double(g_value_array_get_nth(va, 1)) : l;
    G_GNUC_END_IGNORE_DEPRECATIONS
    return true;
}

// The project canvas the video track's restriction caps are built from
// (even-rounded size + frame-rate fraction). Shared by setClips()'s caps
// code and its "did the canvas change?" check so the two can never differ.
static CanvasSpec canvasFromSettings(bool *fpsFromSettings = nullptr)
{
    CanvasSpec c;
    c.width = ProjectSettings::value("project/width", 1920).toInt();
    c.height = ProjectSettings::value("project/height", 1080).toInt();
    if (c.width <= 0) c.width = 1920;
    if (c.height <= 0) c.height = 1080;
    // 4:2:0 video needs even dimensions; nothing more. (Rounding up to a
    // multiple of 16 was tested unnecessary for the preview, in both GL and
    // CPU mode, for the original and the proxy media, down to 1918x818.)
    // Profile sizes are validated even, so this only matters for odd values
    // coming from an old/hand-edited project.
    c.width = (c.width + 1) & ~1;
    c.height = (c.height + 1) & ~1;
    QString fpsStr = ProjectSettings::value("project/fps", "30").toString();
    const bool parsed = FrameRate::parse(fpsStr, c.fpsN, c.fpsD);
    if (!parsed) { c.fpsN = 30; c.fpsD = 1; } // "auto"/unparsable: see TimelineEngine::canvasFor()
    if (fpsFromSettings) *fpsFromSettings = parsed;
    return c;
}

// The project canvas for this clip list: canvasFromSettings(), except that an
// unresolved "auto" (or unparsable) project frame rate is taken from the
// earliest video clip's discovered media (its asset is already resolved -
// setClips() only gets here after the asset gate) instead of a blanket 30 fps.
// QML normally resolves "auto" itself from the bin metadata once a video
// clip lands (TimelinePanel.maybeResolveAutoProfile()); this covers the
// cases where that could not happen (missing/odd metadata).
CanvasSpec TimelineEngine::canvasFor(const QVariantList &clips) const
{
    bool fpsKnown = false;
    CanvasSpec c = canvasFromSettings(&fpsKnown);
    if (fpsKnown) return c;
    double bestStart = 0;
    GESAsset *best = nullptr;
    for (const QVariant &v : clips) {
        const QVariantMap m = v.toMap();
        if (m.value("clipKind", "").toString() == QLatin1String("title")) continue;
        if (!m.value("hasVideo", true).toBool()) continue;
        QString path = m.value("itemPath").toString();
        if (path.startsWith("file://")) path = path.mid(7);
        GESAsset *a = m_assetCache.value(path, nullptr);
        if (!a || !GES_IS_URI_CLIP_ASSET(a)) continue;
        const double st = m.value("startTime").toDouble();
        if (!best || st < bestStart) { best = a; bestStart = st; }
    }
    if (!best) return c;
    GstDiscovererInfo *info = ges_uri_clip_asset_get_info(GES_URI_CLIP_ASSET(best));   // transfer none
    if (!info) return c;
    GList *vids = gst_discoverer_info_get_video_streams(info);                         // transfer full
    if (vids) {
        GstDiscovererVideoInfo *vi = GST_DISCOVERER_VIDEO_INFO(vids->data);
        const guint n = gst_discoverer_video_info_get_framerate_num(vi);
        const guint d = gst_discoverer_video_info_get_framerate_denom(vi);
        if (n > 0 && d > 0 && n <= 1000000 && d <= 1000000) { c.fpsN = int(n); c.fpsD = int(d); }
    }
    gst_discoverer_stream_info_list_free(vids);
    return c;
}

static GstBusSyncReply bus_sync_handler(GstBus *bus, GstMessage *message, gpointer user_data)
{
    Q_UNUSED(bus);
    TimelineEngine *engine = static_cast<TimelineEngine *>(user_data);

    if (gst_is_video_overlay_prepare_window_handle_message(message)) {
        GstVideoOverlay *overlay = GST_VIDEO_OVERLAY(GST_MESSAGE_SRC(message));

        // Confirmed by log timestamps: loading a saved project commits a
        // timeline full of clips immediately, and GES's preroll can ask
        // for a window handle before the QML VideoOutput has finished
        // creating its native window and reporting one back via
        // setWindowId(). Merely dropping this message without supplying a
        // handle does NOT stop the sink from creating its own fallback
        // top-level window - confirmed by testing; these X11 video sinks
        // only skip that if they actually receive a handle during this
        // synchronous callback. So actually wait here (on the GStreamer
        // streaming thread, not the Qt main thread - the main thread is
        // exactly what needs to run freely for setWindowId() to ever
        // arrive) for windowId to become available, up to a short bound in
        // case something is genuinely wrong, rather than ever letting the
        // sink proceed handle-less.
        // qml6glsink is not a GstVideoOverlay, so this message never fires
        // for it - but guard the busy-wait anyway rather than leave a
        // streaming-thread-blocking loop that could only ever time out on
        // that path.
        int waited_ms = 0;
        const int kStepMs = 5;
        const int kMaxWaitMs = 2000;
        while (!engine->isGLVideoSink() && engine->windowId() == 0 && waited_ms < kMaxWaitMs) {
            g_usleep(kStepMs * 1000);
            waited_ms += kStepMs;
        }

        if (engine->isGLVideoSink()) {
            qWarning() << "bus_sync_handler: prepare-window-handle arrived from"
                       << GST_OBJECT_NAME(GST_MESSAGE_SRC(message))
                       << "on the GL video path - a native video sink (stray window) was autoplugged "
                          "instead of qml6glsink; the pipeline was probably set to PAUSED before the sink was installed";
        }
        const qulonglong wid = engine->windowId();
        if (wid != 0) {
            gst_video_overlay_set_window_handle(overlay, wid);
        } else {
            qWarning() << "bus_sync_handler: windowId still 0 after" << kMaxWaitMs
                       << "ms wait - sink may fall back to its own window";
        }
        return GST_BUS_DROP;
    }
    return GST_BUS_PASS;
}

TimelineEngine::TimelineEngine(QObject *parent)
    : QObject(parent)
    , m_pipeline(nullptr)
    , m_timeline(nullptr)
    , m_windowId(0)
    , m_playing(false)
    , m_position(0)
    , m_totalDuration(0)
    , m_decoderPreference("nvidia")
    , m_nextSeek(-1)
    , m_commitWanted(false)
    , m_asyncTimeoutId(0)
    , m_wasEmpty(true)
    , m_commitPending(false)
    , m_commitedSignalId(0)
    , m_drAnchorPos(0)
    , m_drAnchorTimeMs(0)
    , m_drActive(false)
    , m_drLastPipelinePos(-1)
    , m_skipSmoothingTicks(0)
    , m_isSeeking(false)
{
    gst_init(nullptr, nullptr);
    ges_init();

    m_drClock.start();
    m_positionTimer = new QTimer(this);
    m_positionTimer->setInterval(10);  // Pitivi: DEFAULT_POSITION_LISTENING_INTERVAL = 10
    connect(m_positionTimer, &QTimer::timeout, this, &TimelineEngine::onPositionTimer);

    // Process-wide loader, shared with BackendManager's proxy installation (a
    // single thread, a single stuck-file handling).
    m_assetLoader = AssetLoader::shared();
    connect(m_assetLoader, &AssetLoader::resultReady, this, &TimelineEngine::onAssetLoaded);
    connect(m_assetLoader, &AssetLoader::cacheLockFreed, this, &TimelineEngine::resumeAssetWait);
    m_mediaStallTimer = new QTimer(this);
    m_mediaStallTimer->setInterval(1000);
    connect(m_mediaStallTimer, &QTimer::timeout, this, &TimelineEngine::checkMediaStall);
    // A proxy installation pass is loading files on the loader thread: watch it
    // for a stuck file exactly like the engine's own loads (stall dialog), and
    // once it ends replay the clip list that was parked behind it.
    connect(m_assetLoader, &AssetLoader::proxyPassStarted, this, [this]() {
        if (!m_mediaStallTimer->isActive()) m_mediaStallTimer->start();
    });
    connect(m_assetLoader, &AssetLoader::proxyPassEnded, this, [this](bool changed) {
        // Anything resolved before the installs/uninstalls took effect is stale.
        // Only the cache: m_assetFailures also holds files the user chose to skip.
        if (changed && m_hasAssetWaitClips) m_assetCache.clear();
        checkMediaStall();
        resumeAssetWait();
    });

    m_pendingClipsTimer = new QTimer(this);
    m_pendingClipsTimer->setSingleShot(true);
    m_pendingClipsTimer->setInterval(3000);
    connect(m_pendingClipsTimer, &QTimer::timeout, this, [this]() {
        if (!m_hasPendingClips) return;
        // Still mid-flight: applying now would reintroduce exactly the
        // use-after-free this deferral exists to prevent (teardown while a
        // decodebin is still prerolling). Wait another round instead - this
        // cannot postpone forever, because every async operation is backed
        // by addAsyncTimeout()'s own watchdog, and asyncTimeoutCallback()
        // applies the pending clip list itself once it fires.
        if (isBusyAsync()) {
            qWarning() << "setClips: deferred clip list still waiting - pipeline async op "
                          "in flight, retrying later";
            m_pendingClipsTimer->start();
            return;
        }
        // The pipeline being PLAYING is a normal, possibly long-lived state
        // (the user watching a clip), NOT a stuck operation - unlike the
        // commit-confirmation-never-arrived case below, there is no
        // watchdog that will ever force this to resolve on its own, so
        // this branch must keep deferring indefinitely rather than ever
        // force-applying. Confirmed live (2026-11-04): a reload that forced
        // its way through while the pipeline was actively PLAYING crashed
        // with a SIGSEGV deep inside libges/libgstreamer - this 3s retry
        // existing at all must never become a backdoor around that.
        GstState state = GST_STATE_NULL, pending = GST_STATE_VOID_PENDING;
        if (m_pipeline) gst_element_get_state(GST_ELEMENT(m_pipeline), &state, &pending, 0);
        if (state == GST_STATE_PLAYING || pending == GST_STATE_PLAYING || m_playing) {
            qDebug() << "setClips: deferred clip list still waiting - pipeline is playing, "
                        "retrying later";
            m_pendingClipsTimer->start();
            return;
        }
        qWarning() << "setClips: commit confirmation never arrived - applying "
                      "deferred clip list anyway to keep engine and UI in sync";
        // The commit may in fact still be running on a streaming thread (a
        // slow disk can take longer than this timer): take the pipeline to
        // READY first so no streaming thread is inside the clips the
        // replayed list is about to tear down.
        if (m_commitPending) quiesceToReady("forced replay after missing commit confirmation");
        m_commitPending = false;
        applyPendingClips();
    });

    m_scrub = std::make_unique<ScrubAudio>();
    createPipeline();
}

TimelineEngine::~TimelineEngine()
{
    destroyPipeline();
    m_scrub->shutdown();
}

qulonglong TimelineEngine::windowId() const {
    return m_windowId;
}

bool TimelineEngine::isGLVideoSink() const {
    return Qml6GLSink::enabled();
}

bool TimelineEngine::videoOutputReady() const {
    return isGLVideoSink() ? m_glSinkInstalled : (m_windowId != 0);
}

void TimelineEngine::createPipeline()
{
    if (m_pipeline) return;

    m_pipeline = ges_pipeline_new();
    // GES reads GES_GL_MODE when the video track is created, so it has to be
    // set before the timeline exists. Only worth it when the GL sink path is
    // in use (the native-window sink cannot take GLMemory).
    m_glMode = Qml6GLSink::enabled() && GlTimeline::enabled();
    GlTimeline::setGesGlMode(m_glMode);
    qDebug() << "TimelineEngine: GL timeline mode" << (m_glMode ? "ON" : "off");
    m_timeline = ges_timeline_new_audio_video();

    ges_pipeline_set_mode(m_pipeline, GES_PIPELINE_MODE_PREVIEW);

    // Auto-transition bekapcsolása a TIMELINE szinten (mint Pitivi-ben)
    g_object_set(m_timeline, "auto-transition", TRUE, NULL);

    // Mixing engedélyezése minden track-on (audio crossfade-hez szükséges)
    GList *tracks = ges_timeline_get_tracks(m_timeline);
    for (GList *tmp = tracks; tmp; tmp = tmp->next) {
        GESTrack *track = GES_TRACK(tmp->data);
        g_object_set(track, "mixing", TRUE, NULL);
        qDebug() << "Track mixing enabled for track type:" << track->type;
    }
    g_list_free_full(tracks, gst_object_unref);

    // Layereket a setClips() hozza létre dinamikusan a trackId-k alapján.
    // Alapértelmezett V1, V2, A1, A2 layerek, ha nincs még klip.
    ensureLayers({"V2", "V1", "A1", "A2"});

    if (!ges_pipeline_set_timeline(m_pipeline, m_timeline)) {
        qCritical() << "createPipeline: ges_pipeline_set_timeline failed";
        emit error("Failed to attach timeline to pipeline");
    }

    GstBus *bus = gst_pipeline_get_bus(GST_PIPELINE(m_pipeline));
    gst_bus_set_sync_handler(bus, bus_sync_handler, this, NULL);
    gst_bus_add_watch(bus, busCallback, this);
    gst_object_unref(bus);

    // Preview-only master audio chain: volume (master fader) + level (master
    // meter), installed through playbin's "audio-filter" property. The bin is
    // passed WITHOUT an extra unref after g_object_set - exactly like the
    // "video-filter" install in setPreviewScale() (see the long comment
    // there: an added unref caused a use-after-free because playbin owns it).
    {
        GError *ferr = nullptr;
        GstElement *afilter = gst_parse_bin_from_description(
            "volume name=gcsmastervol ! level name=gcsmaster interval=50000000 post-messages=true",
            TRUE, &ferr);
        if (afilter) {
            GstElement *mv = gst_bin_get_by_name(GST_BIN(afilter), "gcsmastervol");   // new ref
            if (mv) { g_object_set(mv, "volume", m_masterVolume, nullptr); gst_object_unref(mv); }
            // Never let GAP-flagged buffers reach the audio sink. While no
            // audio source is audible at the playhead the mixer outputs
            // GAP-only data (an empty audio row, a hole, only muted
            // sources); when real audio then starts, the sink's position
            // jumps to the end of the clip and the playhead races through
            // the next clips and stalls. Measured with the sink alone -
            // independent of our effects and of this filter's elements.
            // The buffers carry silence, so only the flag is cleared.
            if (GstElement *lv = gst_bin_get_by_name(GST_BIN(afilter), "gcsmaster")) {
                GstPad *sp = gst_element_get_static_pad(lv, "src");
                if (sp) {
                    gst_pad_add_probe(sp, GST_PAD_PROBE_TYPE_BUFFER,
                        [](GstPad *, GstPadProbeInfo *info, gpointer) -> GstPadProbeReturn {
                            GstBuffer *b = GST_PAD_PROBE_INFO_BUFFER(info);
                            if (b && GST_BUFFER_FLAG_IS_SET(b, GST_BUFFER_FLAG_GAP)) {
                                b = gst_buffer_make_writable(b);
                                GST_BUFFER_FLAG_UNSET(b, GST_BUFFER_FLAG_GAP);
                                GST_PAD_PROBE_INFO_DATA(info) = b;
                            }
                            return GST_PAD_PROBE_OK;
                        }, nullptr, nullptr);
                    gst_object_unref(sp);
                }
                // Audio scrub tap: its own probe on the same pad, added AFTER
                // the GAP-clearing one above (probes run in insertion order).
                // ScrubAudio keeps its own pad ref; destroyPipeline() detaches
                // it before the pipeline goes away.
                if (m_scrub) m_scrub->attach(lv);
                gst_object_unref(lv);
            }
            g_object_set(m_pipeline, "audio-filter", afilter, nullptr);
        } else {
            qWarning() << "createPipeline: audio filter failed:" << (ferr ? ferr->message : "?");
        }
        if (ferr) g_error_free(ferr);
    }

    gst_element_set_state(GST_ELEMENT(m_pipeline), GST_STATE_NULL);

    // qml6glsink spike: re-install the GL sink on every rebuild (decoder
    // preference change, etc.) exactly the way m_windowId is retained and
    // re-embedded for the native-window path - see setDecoderPreference()'s
    // comment on m_windowId. If the GL item doesn't exist yet (app still
    // starting up), this is a no-op; setGLVideoItem() installs it once the
    // item becomes ready, and videoOutputReady() keeps the pipeline parked
    // at NULL/dormant until then.
    if (isGLVideoSink() && m_glVideoItem) {
        installGLSink();
    }
}

void TimelineEngine::destroyPipeline()
{
    // Pitivi pattern: töröljük az async timeout-ot
    removeAsyncTimeout();
    drInvalidate();
    m_restoreAfterQuiesce = false;
    m_awaitingPreroll = false;
    stopPrerollWatchdog();

    // Lecsatlakozás a "commited" signal-ról
    if (m_timeline && m_commitedSignalId != 0) {
        g_signal_handler_disconnect(m_timeline, m_commitedSignalId);
        m_commitedSignalId = 0;
    }

    // The scrub probe sits inside the pipeline's audio-filter bin: remove it
    // and stop the side pipeline before the pipeline is torn down.
    if (m_scrub) { m_scrub->detach(); m_scrub->shutdown(); }

    if (m_pipeline) {
        // Bus watch és sync handler eltávolítása ELŐBB, különben
        // a GSource referenciát tart a GLib main context-ben
        // és megakadályozza a clean exit-et.
        GstBus *bus = gst_pipeline_get_bus(GST_PIPELINE(m_pipeline));
        if (bus) {
            gst_bus_remove_watch(bus);
            gst_bus_set_sync_handler(bus, NULL, NULL, NULL);
            gst_object_unref(bus);
        }
        gst_element_set_state(GST_ELEMENT(m_pipeline), GST_STATE_NULL);
        gst_object_unref(m_pipeline);
        m_pipeline = nullptr;
    }
    // installGLSink() keeps its own sunk ref in m_glSinkBin (playsink only
    // took an extra one), so the pipeline's teardown above does NOT free
    // the sink bin: measured live, the bin is still alive with refcount 1
    // (ours) after the pipeline has been finalized. Drop it here, or every
    // rebuild (setDecoderPreference()) leaks a whole qml6glsink bin.
    // clearGLVideoItem() already unref'd and nulled it if it ran first.
    // m_glSinkElement is a borrowed pointer into that bin. m_glVideoItem is
    // retained, same rationale as m_windowId above: the next
    // createPipeline() re-installs a fresh sink bin against the same QML
    // item.
    if (m_glSinkBin) {
        gst_object_unref(m_glSinkBin);
        m_glSinkBin = nullptr;
    }
    m_glSinkElement = nullptr;
    m_glSinkInstalled = false;
    m_timeline = nullptr;
    m_layers.clear();
    m_commitPending = false;
    m_commitWanted = false;
    m_nextSeek = -1;
    m_nextSeekScrub = false;
    m_wasEmpty = true;
    // A pending decoder-rebuild "resume playback once the rebuild commits"
    // intent is meaningless once the pipeline it was waiting on is gone -
    // without this it could survive into a later, unrelated edit and fire
    // play() out of nowhere.
    m_resumePlayAfterDecoderChange = false;
    m_playRequestedAfterCommit = false;

    // A snapshot taken against the OLD pipeline must never be replayed into
    // a new one. setDecoderPreference() emits decoderPreferenceApplied(),
    // and QML responds by calling updateTimelineEngine() with the current
    // model anyway, so nothing is lost by discarding it here.
    m_hasPendingClips = false;
    m_pendingClips.clear();
    if (m_pendingClipsTimer) m_pendingClipsTimer->stop();

    // The old pipeline's GES clips are gone - a clip list identical to the
    // last one applied is no longer actually reflected in any live object,
    // so the no-op short-circuit below must not skip the next real rebuild.
    m_hasAppliedClips = false;
    m_lastAppliedClips.clear();

    // Every cached GESClip* below belonged to the pipeline just torn down -
    // the pointers are already dangling, so drop them rather than carry
    // them into whatever pipeline createPipeline() builds next.
    m_clipObjects.clear();
    m_appliedClips.clear();
}

// Extracted verbatim from setClips()'s former inline add loop (Stage 4/5
// prep, Step 3) so the add-only fast path below can place a single clip
// using the exact same logic as a full rebuild, instead of a second,
// divergence-prone copy.
void TimelineEngine::addPanEffect(GESClip *clip, const QString &clipId)
{
    if (!clip || clipId.isEmpty()) return;

    const QByteArray desc = "audiopanorama name=" + panElementName(clipId).toUtf8()
                            + " method=simple";
    GESEffect *fx = ges_effect_new(desc.constData());   // floating ref
    if (!fx) {
        qWarning() << "addPanEffect: ges_effect_new failed for" << clipId;
        return;
    }
    ges_meta_container_set_boolean(GES_META_CONTAINER(fx), kPanMetaKey, TRUE);

    // Same index rule as the meter: 0 = last link of the chain. The pan is
    // added BEFORE the meter, so the meter (also inserted at 0 afterwards)
    // ends up after the pan and measures the panned signal.
    GError *err = nullptr;
    if (!ges_clip_add_top_effect(clip, GES_BASE_EFFECT(fx), 0, &err)) {
        qWarning() << "addPanEffect: ges_clip_add_top_effect failed for" << clipId
                   << ":" << (err ? err->message : "unknown error");
        if (err) g_error_free(err);
        // fx is already finalized by GES here - see addMeterEffect().
        return;
    }
    // INTENTIONALLY NOT UNREFFED (add_top_effect sinks the floating ref).
}

void TimelineEngine::addMeterEffect(GESClip *clip, const QString &clipId)
{
    if (!clip || clipId.isEmpty()) return;

    const QString name = meterElementName(clipId);
    const QByteArray desc = "level name=" + name.toUtf8()
                            + " interval=50000000 post-messages=true";
    GESEffect *fx = ges_effect_new(desc.constData());   // floating ref
    if (!fx) {
        qWarning() << "addMeterEffect: ges_effect_new failed for" << clipId;
        return;
    }
    ges_meta_container_set_boolean(GES_META_CONTAINER(fx), kMeterMetaKey, TRUE);

    // Index 0 = the LAST link of the effect chain (measured: an effect at
    // index 0 sees the output of the effects at higher indices; adding
    // there matches ClipEffects::applyToClip()'s ordering rule), i.e. the
    // meter sees the signal after every user effect on the clip.
    GError *err = nullptr;
    if (!ges_clip_add_top_effect(clip, GES_BASE_EFFECT(fx), 0, &err)) {
        qWarning() << "addMeterEffect: ges_clip_add_top_effect failed for" << clipId
                   << ":" << (err ? err->message : "unknown error");
        if (err) g_error_free(err);
        // Do NOT touch fx: ges_container_add() ref_sinks it and unrefs it
        // again on failure, so it is already finalized (verified live on
        // GES 1.28.8 - the former ref_sink+unref cleanup here hit freed
        // memory: "g_object_ref_sink: assertion 'G_IS_OBJECT' failed" for
        // a clip whose file has no audio stream).
        return;
    }
    // INTENTIONALLY NOT UNREFFED: ges_clip_add_top_effect() sinks the
    // floating ref (same ownership pattern as ClipEffects::applyToClip()).
}

// The wipe shape this clip asks GesTransitions::applyTransitionTypes() to
// put on the GES auto-transition at its end - empty means "leave GES's
// default crossfade alone". Same filter as the pending-list builder in
// setClips(). Recorded in m_appliedClips so the incremental fast path can
// see a transition-type change: that path never re-runs
// applyTransitionTypes(), so such a change must take the full rebuild.
static QString wipeNickFor(const QVariantMap &clipMap)
{
    if (!clipMap.value("hasTransition", false).toBool()) return QString();
    const QString type = clipMap.value("transitionType").toString();
    if (type == QLatin1String("crossfade") || type == QLatin1String("dissolve")) return QString();
    return type;
}

void TimelineEngine::addClipToGES(const QVariantMap &clipMap, qint64 &maxDuration)
{
    QString clipId = clipMap["clipId"].toString();
    QString path = clipMap["itemPath"].toString();
    QString trackId = clipMap["trackId"].toString();
    double start = clipMap["startTime"].toDouble();
    double duration = clipMap["durationSeconds"].toDouble();
    double inPoint = clipMap["sourceOffset"].toDouble();

    bool hasVideo = clipMap.value("hasVideo", true).toBool();
    bool hasAudio = clipMap.value("hasAudio", true).toBool();
    bool hasTransition = clipMap.value("hasTransition", false).toBool();
    double transitionDuration = clipMap.value("transitionDuration", 0.0).toDouble();
    QString transitionType = clipMap.value("transitionType", "").toString();

    const QString clipKind = clipMap.value("clipKind", "").toString();

    // TITLE CLIPS - no source file at all, so this branch MUST come
    // before the media lookup below (which would otherwise reject every
    // title as "missing media").
    //
    // ges_asset_request(GES_TYPE_TITLE_CLIP, NULL) + ges_layer_add_asset()
    // was VERIFIED LIVE against GES 1.24.2 in a standalone probe before
    // being written here (project policy: never assume a GES contract):
    // the asset is returned non-NULL, the clip lands on the layer with
    // the requested start/duration, child properties apply, and 50
    // add-then-remove cycles on a PAUSED pipeline ran clean (no crash,
    // no GLib criticals). The asset itself is deliberately NOT unreffed,
    // for exactly the reason spelled out in the "INTENTIONALLY NOT
    // UNREFFED" block further down - and unlike the URI assets there,
    // this one is a single process-wide GES-internal title asset, so it
    // is requested once and cached here rather than per clip.
    if (clipKind == QLatin1String("title")) {
        GESLayer *titleLayer = m_layers.value(trackId, nullptr);
        if (!titleLayer) {
            qWarning() << "TimelineEngine: unknown trackId for title clip:" << trackId;
            return;
        }
        if (duration <= 0) return;

        GError *titleErr = nullptr;
        if (!m_titleAsset) {
            m_titleAsset = ges_asset_request(GES_TYPE_TITLE_CLIP, nullptr, &titleErr);
        }
        if (!m_titleAsset) {
            qWarning() << "TimelineEngine: could not request title asset:"
                       << (titleErr ? titleErr->message : "unknown error");
            if (titleErr) g_error_free(titleErr);
            emit error("Could not create title clip");
            return;
        }
        if (titleErr) g_error_free(titleErr);

        const TimeConv::Span titleSpan = TimeConv::span(start, duration);
        GESClip *titleClip = ges_layer_add_asset(titleLayer, m_titleAsset,
                                titleSpan.start, 0, titleSpan.duration,
                                GES_TRACK_TYPE_VIDEO);
        if (!titleClip) {
            qWarning() << "TimelineEngine: layer refused title clip placement on" << trackId;
            emit error("Could not place title clip");
            return;
        }

        const QString titleParams = clipMap.value("titleParams", "").toString();
        TitleClips::applyToClip(titleClip, titleParams);

        qint64 titleEndMs = (start + duration) * 1000;
        if (titleEndMs > maxDuration) maxDuration = titleEndMs;

        if (!clipId.isEmpty()) {
            m_clipObjects.insert(clipId, titleClip);
            QVariantMap appliedFields;
            appliedFields["itemPath"] = QString();
            appliedFields["trackId"] = trackId;
            appliedFields["startTime"] = start;
            appliedFields["durationSeconds"] = duration;
            appliedFields["sourceOffset"] = 0.0;
            // The input flags (same defaults as below), so setClips()'s
            // fast-path diff compares like with like; a title itself is
            // always video-only regardless.
            appliedFields["hasVideo"] = hasVideo;
            appliedFields["hasAudio"] = hasAudio;
            appliedFields["effects"] = QString();
            appliedFields["clipKind"] = clipKind;
            appliedFields["titleParams"] = titleParams;
            appliedFields["wipeNick"] = wipeNickFor(clipMap);
            m_appliedClips.insert(clipId, appliedFields);
        }
        return;
    }

    if (path.startsWith("file://")) {
        path = path.mid(7);
    }

    // The asset must already have been resolved off the main thread by
    // the AssetLoader (setClips()'s gate guarantees that); this function
    // NEVER runs discovery itself - it can hang on an unresponsive disk.
    QFileInfo fi(path);   // only used for fileName() (no I/O)
    GESAsset *asset = m_assetCache.value(path, nullptr);
    if (!asset) {
        const auto failure = m_assetFailures.constFind(path);
        if (failure == m_assetFailures.constEnd()) {
            // Not expected: e.g. reloadAssets() cleared the cache mid-call.
            qWarning() << "TimelineEngine: asset not resolved yet, skipping clip:" << path;
            return;
        }
        if (failure->missing) {
            qWarning() << "TimelineEngine: File missing, skipping clip:" << path;
            emit error("Missing file: " + fi.fileName());
        } else {
            qWarning() << "TimelineEngine: media could not be read, skipping clip:" << path
                       << failure->error;
            emit error("Media could not be read: " + fi.fileName());
        }
        if (!clipId.isEmpty()) emit clipMediaMissing(clipId);
        return; // Kihagyjuk ezt a klipet, hogy ne omoljon össze a GES
    }

    // Megfelelő layer kiválasztása trackId alapján
    GESLayer *targetLayer = m_layers.value(trackId, nullptr);
    if (!targetLayer) {
        qWarning() << "Unknown trackId:" << trackId << "- skipping clip";
        return;
    }

    GESTrackType trackType;
    if (hasVideo && hasAudio) {
        trackType = (GESTrackType)(GES_TRACK_TYPE_VIDEO | GES_TRACK_TYPE_AUDIO);
    } else if (hasVideo) {
        trackType = GES_TRACK_TYPE_VIDEO;
    } else if (hasAudio) {
        trackType = GES_TRACK_TYPE_AUDIO;
    } else {
        return;
    }

    if (path.startsWith("file://")) path = path.mid(7);

    // m_assetCache (filled by the AssetLoader results) is keyed by file
    // path; the returned asset pointer is never released (see the
    // INTENTIONALLY NOT UNREFFED comment below).
    GError *err = NULL;

    if (asset && !err) {
        // Keep the originally requested duration; don't pre-clamp here.
        // GstDiscoverer can slightly under-report a source's real duration
        // for some proxy files (e.g. certain MPEG-PS proxies), which used
        // to cause this function to silently shrink a clip that actually
        // requests its source's full length - visibly correct next to it
        // (still starting where it should), but ending early and leaving
        // a gap before the following clip. GES itself will still clamp
        // the add below if the shortfall is real; the recovery step after
        // ges_layer_add_asset() handles small, spurious shortfalls.
        //
        // A fixed safety-margin clamp was tried here (see TODO.txt,
        // "FIXED (partial, with a known tradeoff)") to dodge a
        // mpegpsdemux seek-accuracy dead zone near some clips' tails -
        // rejected: the margin needed varies per file/pipeline (measured
        // up to ~880ms in the full GES pipeline, wider than any one fixed
        // guess), it still reintroduces a visible gap Kdenlive doesn't
        // have, and it only band-aids this one proxy format rather than
        // actually making seeking safe in general. The real mitigation
        // for that dead zone now lives in seek() (clamp the SEEK TARGET
        // to one frame before the true end, never the clip's placed
        // duration) and the async watchdog (bounded, self-recovering).
        double requestedDuration = duration;

        if (duration > 0) {
            qDebug() << "Adding clip:" << path << "trackId:" << trackId << "start:" << start
                     << "duration:" << duration << "inPoint:" << inPoint << "hasTransition:" << hasTransition
                     << "transitionDuration:" << transitionDuration << "transitionType:" << transitionType;

            const TimeConv::Span clipSpan = TimeConv::span(start, duration);
            GESClip *addedClip = ges_layer_add_asset(targetLayer, asset,
                                clipSpan.start,
                                TimeConv::secToNs(inPoint),
                                clipSpan.duration,
                                trackType);

            if (!addedClip) {
                // The layer refused the placement (e.g. a conflicting
                // clip already there) - without checking this, the
                // clip stays visible in the QML model but never
                // actually plays, with no feedback to the user.
                qWarning() << "TimelineEngine: layer refused clip placement:" << path;
                emit error("Could not place clip: " + fi.fileName());
            } else {
                // GES may have clamped the clip shorter than requested
                // (e.g. the asset's discovered duration coming in a
                // touch short of what was asked for). For small
                // shortfalls, try to recover the full requested
                // duration by raising max-duration and re-asserting it -
                // verified empirically to succeed for the sub-second
                // GstDiscoverer under-reporting case this guards
                // against. Only fall back to visibly shrinking the
                // clip (and telling QML about it) if that recovery
                // doesn't work or the shortfall is too large to be
                // this kind of rounding/metadata noise.
                GstClockTime actualDuration = ges_timeline_element_get_duration(GES_TIMELINE_ELEMENT(addedClip));
                double actualDurationSec = (double)actualDuration / GST_SECOND;
                double shortfall = requestedDuration - actualDurationSec;
                if (shortfall > 0.001) {
                    if (shortfall <= 0.5) {
                        GstClockTime reqEnd = TimeConv::secToNs(inPoint) + clipSpan.duration;
                        ges_timeline_element_set_max_duration(GES_TIMELINE_ELEMENT(addedClip), reqEnd);
                        ges_timeline_element_set_duration(GES_TIMELINE_ELEMENT(addedClip), clipSpan.duration);
                        actualDuration = ges_timeline_element_get_duration(GES_TIMELINE_ELEMENT(addedClip));
                        actualDurationSec = (double)actualDuration / GST_SECOND;
                        shortfall = requestedDuration - actualDurationSec;
                    }
                    if (shortfall > 0.001 && !clipId.isEmpty()) {
                        emit clipDurationClamped(clipId, actualDurationSec);
                    }
                }
                duration = actualDurationSec;

                qint64 endMs = (start + duration) * 1000;
                if (endMs > maxDuration) maxDuration = endMs;

                // Record what actually landed in GES - deliberately
                // AFTER the success check above, so a skipped/refused
                // clip (missing file, unknown track, no A/V, placement
                // refused) is never recorded as "applied" (see the
                // m_appliedClips declaration comment in the header for
                // why that distinction matters for a future diff).
                // Borrowed pointer only - see m_clipObjects' comment.
                if (!clipId.isEmpty()) {
                    m_clipObjects.insert(clipId, addedClip);
                    QVariantMap appliedFields;
                    appliedFields["itemPath"] = path;
                    appliedFields["trackId"] = trackId;
                    appliedFields["startTime"] = start;
                    appliedFields["durationSeconds"] = duration;
                    appliedFields["sourceOffset"] = inPoint;
                    appliedFields["hasVideo"] = hasVideo;
                    appliedFields["hasAudio"] = hasAudio;
                    QString effectsJson = clipMap.value("effects", "").toString();
                    appliedFields["effects"] = effectsJson;
                    appliedFields["wipeNick"] = wipeNickFor(clipMap);
                    m_appliedClips.insert(clipId, appliedFields);

                    // Effects are applied to the just-created GESClip, not
                    // before it exists - ClipEffects::applyToClip() looks
                    // up track elements via ges_clip_find_track_element(),
                    // which needs the clip to already be sitting in a
                    // layer belonging to a timeline.
                    ClipEffects::applyToClip(addedClip, effectsJson, m_projectDir, m_glMode);

                    // Stage C2/C3: hidden per-track metering and panning.
                    // Pan is added first (so the meter measures its output);
                    // both are added AFTER the user's effects. Video-only
                    // rows and title clips get none.
                    if (hasAudio) {
                        if (!qEnvironmentVariableIsSet("GCS_DISABLE_PAN"))
                            addPanEffect(addedClip, clipId);
                        if (!qEnvironmentVariableIsSet("GCS_DISABLE_METER"))
                            addMeterEffect(addedClip, clipId);
                    }
                }
            }

            // AUTO-TRANSITION: A klipek átfedése miatt automatikusan létrejön a transition
        }

        // INTENTIONALLY NOT UNREFFED. The asset request (now
        // ges_asset_request_finish() on the AssetLoader thread, previously
        // ges_uri_clip_asset_request_sync()) is transfer-full, so this
        // leaks one GESAsset reference per DISTINCT SOURCE FILE (bounded
        // by m_assetCache above, which holds one reference per path -
        // previously this leaked once per clip on every drag/drop/split/delete/
        // decoder-rebuild, now it leaks once per path, ever).
        // An earlier attempt to fix that leak here (first with
        // gst_object_unref(), then "corrected" to g_object_unref())
        // was reverted after two separate live crashes on this same
        // day while testing other, unrelated changes - close enough
        // in the sequence of events that this unref could not be
        // ruled out as a contributing cause (GES's asset cache
        // lifecycle around ges_layer_add_asset() was never actually
        // confirmed, just assumed). A leak is recoverable; a
        // use-after-free is not. Do not re-add this unref without
        // first confirming GES's actual ownership contract here
        // (e.g. by testing under valgrind/ASan in isolation), not by
        // reasoning about it from documentation alone.
    } else {
        if (err) g_error_free(err);
    }
}

void TimelineEngine::invalidateAssetCache()
{
    // m_titleAsset is deliberately NOT cleared - title clips are never
    // URI-asset-backed (ges_asset_request(GES_TYPE_TITLE_CLIP, ...), not
    // ges_uri_clip_asset_request_sync()) and can never be proxied, so
    // there is nothing for this reload to pick up for them.
    qDebug() << "TimelineEngine::invalidateAssetCache: dropping" << m_assetCache.size()
             << "cached assets (no rebuild)";
    m_assetCache.clear();
    m_assetFailures.clear();
}

void TimelineEngine::reloadAssets()
{
    invalidateAssetCache();

    // A setClips() call is already in flight (this is the reentrant case
    // setClips()'s own guard comment describes - a synchronous GES call
    // it made pumped the event loop, letting this reload fire mid-call).
    // Clearing m_assetCache above is still correct and sufficient here:
    // any clip the in-flight call hasn't added YET will see a cache miss
    // and re-resolve fresh (picking up whatever GES proxy was just
    // installed), and the in-flight call will itself set a correct, fully
    // up to date m_lastAppliedClips when it finishes.
    //
    // Do NOT also call setClips(m_lastAppliedClips) here - that was
    // confirmed live to be actively harmful, not just redundant: this
    // function reads m_lastAppliedClips as it stood BEFORE the in-flight
    // call started, so the request would route through setClips()'s
    // reentrancy guard and get snapshotted into m_pendingClips as STALE
    // data. That stale snapshot would then be replayed later (once the
    // in-flight call's "commited" signal fires), potentially overwriting
    // the in-flight call's own, newer, CORRECT result with it - observed
    // live as a spurious "replaying deferred clip list with 0 clips"
    // immediately after a real 60-clip rebuild had just completed
    // successfully. The only clips this skip can't freshen are ones the
    // in-flight call already added before this point ran - an accepted,
    // minor limitation (that one rebuild pass may not reflect a proxy
    // that finished installing mid-pass), far preferable to clobbering
    // an already-correct timeline.
    if (m_inSetClips) {
        qDebug() << "TimelineEngine::reloadAssets: setClips already in flight - "
                    "asset cache cleared, not re-queuing a (possibly stale) replay";
        return;
    }

    qDebug() << "TimelineEngine::reloadAssets: invalidating asset cache, forcing full rebuild"
             << "(" << m_lastAppliedClips.size() << "clips to replay)";
    m_hasAppliedClips = false;
    m_appliedClips.clear();
    m_clipObjects.clear();
    setClips(m_lastAppliedClips);
}

// Same derivation of the source path as addClipToGES(); title clips have none.
QStringList TimelineEngine::unresolvedAssetPaths(const QVariantList &clips) const
{
    QStringList out;
    QSet<QString> seen;
    for (const QVariant &v : clips) {
        const QVariantMap m = v.toMap();
        if (m.value("clipKind", "").toString() == QLatin1String("title")) continue;
        QString path = m["itemPath"].toString();
        if (path.startsWith("file://")) path = path.mid(7);
        if (m_assetCache.contains(path) || m_assetFailures.contains(path) || seen.contains(path)) continue;
        seen.insert(path);
        out << path;
    }
    return out;
}

void TimelineEngine::onAssetLoaded(const QString &path, int status, quintptr asset,
                                   const QString &error, bool abandoned)
{
    if (status == AssetLoader::Ok && asset) {
        // Keep the one transfer-full reference per path, forever (never
        // unreffed). A late result from an abandoned thread is cached too, but
        // an existing entry is never replaced.
        if (!m_assetCache.contains(path)) {
            m_assetCache.insert(path, reinterpret_cast<GESAsset *>(asset));
            qDebug() << "TimelineEngine: asset resolved for" << path << "->"
                     << ges_asset_get_id(reinterpret_cast<GESAsset *>(asset));
        }
    } else if (!abandoned) {
        m_assetFailures.insert(path, { status == AssetLoader::Missing, error });
        if (status != AssetLoader::Missing)
            qWarning() << "TimelineEngine: media could not be loaded:" << path << error;
    }
    if (abandoned) {
        qWarning() << "TimelineEngine: abandoned load of" << path << "finished late, status" << status;
        return;
    }
    if (m_stallIgnorePath == path) m_stallIgnorePath.clear();
    checkMediaStall();
    resumeAssetWait();
}

void TimelineEngine::resumeAssetWait()
{
    if (!m_hasAssetWaitClips) return;
    if (!m_assetLoader->isIdle() || !m_assetLoader->cacheLockFree() || m_assetLoader->proxyPassActive()) return;
    // Copy out BEFORE clearing, like applyPendingClips(). setClips() re-gates
    // by itself (it can still find unresolved paths, e.g. after a reload).
    const QVariantList stash = m_assetWaitClips;
    m_assetWaitClips.clear();
    m_hasAssetWaitClips = false;
    setClips(stash);
}

static constexpr qint64 kMediaStallMs = 5000;

void TimelineEngine::setMediaStalled(bool stalled, const QString &path, bool blocked)
{
    if (m_mediaLoadStalled == stalled && m_stalledMediaPath == path && m_mediaLoadBlocked == blocked) return;
    m_mediaLoadStalled = stalled;
    m_stalledMediaPath = path;
    m_mediaLoadBlocked = blocked;
    m_stalledMediaMountRoot = path.isEmpty() ? QString() : MediaPaths::mountRootFor(path);
    emit mediaLoadStalledChanged();
}

void TimelineEngine::checkMediaStall()
{
    const AssetLoader::CurrentJob job = m_assetLoader->currentJob();
    QString stalledPath;
    bool blocked = false;
    if (job.valid && job.runningMs > kMediaStallMs && job.path != m_stallIgnorePath) {
        stalledPath = job.path;
    } else if (!job.valid && m_assetLoader->canaryPendingMs() > kMediaStallMs
               && m_lastAbandonedPath != m_stallIgnorePath) {
        // The fresh loader thread is blocked in GES's cache lock, still held by
        // the abandoned (hung) load.
        stalledPath = m_lastAbandonedPath;
        blocked = true;
    }
    if (!stalledPath.isEmpty()) {
        if (!m_stallWarned.contains(stalledPath)) {
            m_stallWarned.insert(stalledPath);
            qWarning() << "TimelineEngine: media load stalled for more than" << kMediaStallMs / 1000
                       << "s on" << stalledPath;
        }
        setMediaStalled(true, stalledPath, blocked);
    } else {
        setMediaStalled(false, QString());
        if (m_assetLoader->isIdle() && m_assetLoader->cacheLockFree() && !m_assetLoader->proxyPassActive())
            m_mediaStallTimer->stop();
    }
}

void TimelineEngine::skipStalledMedia(bool wholeDrive)
{
    const AssetLoader::CurrentJob job = m_assetLoader->currentJob();
    if (!job.valid) {
        qWarning() << "TimelineEngine::skipStalledMedia: no load in progress";
        return;
    }
    const QString path = job.path;
    const AssetFailure unreadable{ false, QStringLiteral("media did not respond and was skipped") };
    m_assetFailures.insert(path, unreadable);
    QStringList drop;
    if (wholeDrive) {
        const QString root = MediaPaths::mountRootFor(path);
        for (const QString &q : m_assetLoader->queuedPaths()) {
            if (MediaPaths::mountRootFor(q) == root) {
                drop << q;
                m_assetFailures.insert(q, unreadable);
            }
        }
        qWarning() << "TimelineEngine: skipping" << drop.size() << "more queued file(s) on" << root;
    }
    qWarning() << "TimelineEngine: skipping stalled media" << path;
    m_lastAbandonedPath = path;
    setMediaStalled(false, QString());
    m_assetLoader->abandonCurrentAndRestart(drop);
    if (!m_mediaStallTimer->isActive()) m_mediaStallTimer->start();
    // If nothing remains queued, resumeAssetWait() proceeds once the canary
    // reports the cache lock free (cacheLockFreed).
}

void TimelineEngine::abortMediaLoad()
{
    qWarning() << "TimelineEngine::abortMediaLoad: dropping parked clip list and queued loads";
    m_hasAssetWaitClips = false;
    m_assetWaitClips.clear();
    m_assetLoader->dropQueued();
    const AssetLoader::CurrentJob job = m_assetLoader->currentJob();
    m_stallIgnorePath = job.valid ? job.path : m_lastAbandonedPath;
    setMediaStalled(false, QString());
    // onCommitCompleted() skipped its ready work while the list was parked.
    if (m_reloadingAssets) {
        m_reloadingAssets = false;
        emit reloadingAssetsChanged();
    }
    emit timelineReady();
    emit previewReady();
}

void TimelineEngine::retryUnavailableMedia(const QVariantList &clips)
{
    // A setClips() call is in flight (a nested event-loop pump): try again
    // once it has returned instead of silently dropping the request.
    if (m_inSetClips) {
        QTimer::singleShot(0, this, [this, clips]() { retryUnavailableMedia(clips); });
        return;
    }
    m_assetFailures.clear();
    m_retryReload = true;
    // Same forced-rebuild preparation as reloadAssets() (skip the identical-
    // list short-circuit and the incremental fast paths).
    m_hasAppliedClips = false;
    m_appliedClips.clear();
    m_clipObjects.clear();
    setClips(clips);
}

// 15 s is far above a healthy rebuild+preroll of this project (~0.1 s rebuild,
// ~1 s preroll) and below the point where a user would give up and kill the app.
static constexpr int kPrerollWatchdogMs = 15000;

void TimelineEngine::startPrerollWatchdog()
{
    if (!m_prerollWatchdog) {
        m_prerollWatchdog = new QTimer(this);
        m_prerollWatchdog->setSingleShot(true);
        connect(m_prerollWatchdog, &QTimer::timeout, this, &TimelineEngine::onPrerollWatchdog);
    }
    m_prerollWatchdog->start(kPrerollWatchdogMs);
}

void TimelineEngine::stopPrerollWatchdog()
{
    if (m_prerollWatchdog) m_prerollWatchdog->stop();
}

void TimelineEngine::onPrerollWatchdog()
{
    if (!m_reloadingAssets && !m_awaitingPreroll) return; // nothing pending any more
    qWarning() << "Preroll watchdog: rebuilt timeline did not preroll within"
               << kPrerollWatchdogMs / 1000 << "s (strike" << m_watchdogStrikes + 1 << ")";
    m_awaitingPreroll = false;
    if (m_watchdogStrikes++ == 0) {
        // First strike: most likely a preview proxy the pipeline cannot use.
        // The Backend drops all proxies and re-triggers reloadAssets(), which
        // re-arms this watchdog for the rebuild from the originals.
        emit proxyRebuildStuck();
        // If nothing re-triggered a rebuild (no proxies were installed), the
        // timer below makes sure the UI is not left blocked.
        m_prerollWatchdog->start(kPrerollWatchdogMs);
        m_awaitingPreroll = true;
        return;
    }
    // Second consecutive strike, even without proxies: give up rather than
    // keep Play disabled behind a "switching..." indicator forever.
    m_watchdogStrikes = 0;
    if (m_reloadingAssets) {
        m_reloadingAssets = false;
        emit reloadingAssetsChanged();
    }
    emit error(QStringLiteral("The timeline preview could not be rebuilt (the pipeline did not start). "
                              "Try reopening the project; check the log for stream errors."));
    emit previewReady(); // gave up: nothing more to wait for
}

// Upper bound for any clip time field (seconds). Far above any real edit
// (~115 days), far below where seconds * GST_SECOND would overflow.
static constexpr double kMaxClipTimeSec = 1.0e7;

// The clip list can come from a hand-edited or corrupt project file. Every
// time field is later cast to GstClockTime (unsigned): a negative or NaN
// value would turn into a ~1.8e19 ns start/duration (and casting a negative
// double to an unsigned type is undefined behaviour). Clamp start/inpoint to
// [0, kMaxClipTimeSec]; a non-finite or out-of-range duration becomes 0,
// which addClipToGES() already skips. Returns the number of clips changed.
static int sanitizeClipTimes(QVariantList &clips)
{
    int fixed = 0;
    for (QVariant &v : clips) {
        QVariantMap m = v.toMap();
        bool changed = false;
        auto clampField = [&](const char *key, bool isDuration) {
            if (!m.contains(QLatin1String(key))) return;
            const double x = m.value(QLatin1String(key)).toDouble();
            double y = x;
            if (!std::isfinite(x)) y = 0.0;
            else if (isDuration) { if (x < 0.0 || x > kMaxClipTimeSec) y = 0.0; }
            else y = qBound(0.0, x, kMaxClipTimeSec);
            if (y != x || !std::isfinite(x)) { m.insert(QLatin1String(key), y); changed = true; }
        };
        clampField("startTime", false);
        clampField("sourceOffset", false);
        clampField("durationSeconds", true);
        if (changed) { v = m; ++fixed; }
    }
    return fixed;
}

void TimelineEngine::setClips(const QVariantList &clipsIn)
{
    QVariantList clipsSanitized = clipsIn;
    if (const int fixed = sanitizeClipTimes(clipsSanitized)) {
        qWarning() << "setClips:" << fixed << "clip(s) had a negative, non-finite or out-of-range "
                      "startTime/sourceOffset/durationSeconds - clamped (corrupt project data?)";
    }
    const QVariantList &clips = clipsSanitized;

    if (m_scrub) m_scrub->disarm();   // a clip edit must not leave a scrub grain pending
    // Reentrancy guard. Found empirically (proxy_build_plan.md Part J.4.4
    // live verification, 2026-11-04): ges_uri_clip_asset_request_sync()
    // (then called from the add loop below) pumped the Qt/GLib event loop
    // internally while it synchronously waited for asset discovery - so a
    // QTimer firing during that nested pump (here: BackendManager's proxy-
    // install coalescing timer -> reloadAssets() -> setClips() again) can
    // re-enter this function WHILE an outer call is still mid-teardown/
    // mid-add-loop. Confirmed live: reloadAssets() was observed reading
    // m_lastAppliedClips (and therefore replaying 0 clips) from INSIDE an
    // outer 60-clip setClips() call that hadn't reached its own
    // `m_lastAppliedClips = clips` assignment yet. Recursing into the
    // teardown/rebuild below here would risk the exact same class of
    // mid-rebuild GES structural corruption m_commitPending's deferral
    // exists to prevent (see that member's own comment) - so a reentrant
    // call is deferred through that SAME existing, already-trusted
    // mechanism instead of proceeding.
    // (That particular trigger is gone: asset discovery now runs on the
    // AssetLoader thread, so nothing in the add loop pumps the event loop
    // any more. The guard stays as a safety net for any other nested pump.)
    if (m_inSetClips) {
        qWarning() << "TimelineEngine::setClips: reentrant call detected (a synchronous "
                      "GES call pumped the event loop mid-call) - deferring instead of "
                      "recursing into the teardown/rebuild below.";
        m_pendingClips = clips;
        m_hasPendingClips = true;
        m_hasAssetWaitClips = false;   // older than this list
        m_assetWaitClips.clear();
        m_pendingClipsTimer->start();
        return;
    }
    struct ReentrancyGuard {
        bool &flag;
        explicit ReentrancyGuard(bool &f) : flag(f) { flag = true; }
        ~ReentrancyGuard() { flag = false; }
    } reentrancyGuard(m_inSetClips);

    qDebug() << "setClips called with" << clips.size() << "clips";

    // Perf instrumentation only (Stage 4/5 prep, Step 0-lite) - no behavior
    // change. Phase boundaries are logged at the end, once we know whether
    // this call actually reaches the teardown/rebuild below or returns
    // early via one of the guards above.
    QElapsedTimer perfTimer;
    perfTimer.start();
    qint64 tTeardownStart = 0, tAddStart = 0, tCommitCallStart = 0, tCommitCallEnd = 0;

    if (!m_pipeline) {
        qDebug() << "setClips: No pipeline - emitting timelineReady anyway";
        m_resumePlayAfterDecoderChange = false;
        m_playRequestedAfterCommit = false;
        emit timelineReady();
        return;
    }

    // ASSET GATE. addClipToGES() never discovers media itself (discovery can
    // hang for minutes on a dead disk), so every URI-clip source in this
    // list must already be resolved - cached in m_assetCache or remembered
    // as unavailable in m_assetFailures. Anything else goes to the
    // AssetLoader thread and this list is parked (latest wins, same
    // semantics as m_pendingClips) until the results are in; resumeAssetWait()
    // replays it. While the loader is busy at all, or right after a stuck
    // thread was abandoned and its GES cache-lock canary has not returned,
    // ANY list waits: other GES asset requests (title/effect/transition
    // assets) would block on GES's global cache lock, which a hung load can
    // hold. No timelineReady is emitted for a parked list.
    if (clips.isEmpty()) {
        // Project load/new project starts with an empty list: forget old
        // missing/unreadable results and any parked list.
        m_assetFailures.clear();
        m_hasAssetWaitClips = false;
        m_assetWaitClips.clear();
    } else {
        const QStringList unresolved = unresolvedAssetPaths(clips);
        // A proxy installation pass is in flight: resolving an original's asset
        // now would cache it before its proxy is installed, so nothing is
        // requested until the pass ends (proxyPassEnded replays this list).
        const bool proxyPass = m_assetLoader->proxyPassActive();
        if (!unresolved.isEmpty() || !m_assetLoader->isIdle() || !m_assetLoader->cacheLockFree() || proxyPass) {
            qDebug() << "setClips: waiting for" << unresolved.size()
                     << "asset(s) from the loader" << (proxyPass ? "(proxy installation pass running)" : "")
                     << "- parking this clip list (" << clips.size() << "clips)";
            if (!proxyPass) {
                m_assetLoader->enqueue(unresolved, m_retryReload);
                m_retryReload = false;
            }
            m_assetWaitClips = clips;
            m_hasAssetWaitClips = true;
            m_stallIgnorePath.clear();   // a new request waits again: report a stall again
            // This list supersedes any older list deferred into m_pendingClips
            // (latest wins - the old deferral block overwrote it the same way).
            // Left in place, a stale list (e.g. the empty one project switching
            // sends first) would be replayed by applyPendingClips() and clear a
            // timeline the new project is about to fill - live SIGSEGV in libges.
            // The parked list itself is replayed through setClips() by
            // resumeAssetWait(), which re-runs the deferral checks.
            m_hasPendingClips = false;
            m_pendingClips.clear();
            m_pendingClipsTimer->stop();
            if (!m_mediaStallTimer->isActive()) m_mediaStallTimer->start();
            return;
        }
        m_hasAssetWaitClips = false;
        m_assetWaitClips.clear();
        m_retryReload = false;
    }

    // A previous commit has NOT been confirmed by GES yet (its "commited"
    // signal has not fired on the streaming thread). Everything below this
    // point tears down the live GES clip graph and rebuilds it - including
    // ensureLayers(), which removes clips and whole layers. Doing that
    // mid-commit freed GESTrackElements while decodebin was still driving
    // signal callbacks into them, which is the confirmed cause of a live
    // SIGSEGV (GES_IS_EXTRACTABLE / GES_IS_URI_SOURCE_ASSET assertion
    // failures followed by a crash deep inside a playbin signal handler).
    // Snapshot the request and replay it from onCommitCompleted() once
    // that confirmation arrives.
    //
    // isBusyAsync() (an async watchdog is armed: a seek, a pause/state
    // change, or a previous commit has NOT reported ASYNC_DONE yet) is
    // exactly the same hazard and must be deferred the same way. Confirmed
    // live on 2026-10-13 under gdb: previously only the ges_timeline_commit()
    // at the END of this function was deferred in that case ("Pipeline busy,
    // deferring commit"), while the teardown+rebuild above it still ran
    // immediately - so ges_layer_remove_clip() disposed GESTrackElements
    // (and with them the GESUriSource structs that GES passes as user_data
    // to the signal handlers it connects on each clip's uridecodebin) while
    // those decodebins were still prerolling the in-flight operation on
    // their own streaming threads. The decodebin/typefind thread then
    // invoked that handler with the freed GESUriSource: self->element read
    // back as 0xb, ges_extractable_get_asset(0xb) dereferenced it and
    // SIGSEGV'd in the "typefind:sink" thread (GES-CRITICAL
    // GES_IS_EXTRACTABLE assertion first, then the crash).
    bool asyncInFlight = isBusyAsync();

    // Found empirically (proxy_build_plan.md Part J.4.4, live crash
    // 2026-11-04): neither m_commitPending nor isBusyAsync() (an async
    // *watchdog timer* flag - seek/pause/commit-confirmation specific)
    // says anything about whether the pipeline is actually mid-PLAYBACK
    // right now. A user who clicked Play, with no seek/commit watchdog
    // currently armed, hit a live SIGSEGV when a reloadAssets()-triggered
    // full rebuild tore down 66 real GES clips' underlying GstElements
    // while the pipeline was actively streaming data through their
    // decoders on the streaming thread - crash deep inside libges/
    // libgstreamer during gst_element_add_pad's signal emission for a
    // decoder that was mid-autoplug. Exactly the same class of hazard
    // m_commitPending's own deferral exists to prevent (see that
    // member's comment), just not one either existing flag covered.
    GstState pipelineState = GST_STATE_NULL;
    GstState pipelinePending = GST_STATE_VOID_PENDING;
    gst_element_get_state(GST_ELEMENT(m_pipeline), &pipelineState, &pipelinePending, 0);
    // Not just the CURRENT state: right after play() the pipeline sits at
    // PAUSED with PLAYING pending (play() arms no async watchdog), and a
    // teardown in that window races the streaming threads exactly like a
    // teardown while PLAYING (reproduced 2026-11-18: play() immediately
    // followed by reloadAssets() reached the live teardown with
    // state=PAUSED pending=PLAYING m_playing=true). m_playing covers the
    // user-facing "playing" intent as well.
    bool pipelinePlaying = (pipelineState == GST_STATE_PLAYING)
                           || (pipelinePending == GST_STATE_PLAYING)
                           || m_playing;

    if (asyncInFlight || pipelinePlaying) {
        // ...but only if there is actually something live to tear down. With
        // an empty GES timeline no decodebin exists that a streaming thread
        // could still be using, so applying immediately is safe - and it
        // keeps project load (whose first real setClips() lands while the
        // startup wake-up/seek watchdog is still armed, with nothing to
        // report ASYNC_DONE for an empty composition) from having to wait
        // out that watchdog before the project appears.
        guint liveClips = 0;
        for (GESLayer *layer : m_layers.values()) {
            GList *l = ges_layer_get_clips(layer);
            liveClips += g_list_length(l);
            g_list_free_full(l, gst_object_unref);
        }
        if (liveClips == 0) {
            qDebug() << "setClips: async op in flight or pipeline playing, but the GES "
                        "timeline is empty - nothing to tear down, applying immediately";
            asyncInFlight = false;
            pipelinePlaying = false;
        }
    }

    if (m_commitPending || asyncInFlight || pipelinePlaying) {
        qDebug() << "setClips:" << (m_commitPending ? "commit still in flight"
                                    : asyncInFlight ? "pipeline async op still in flight"
                                    : "pipeline is actively PLAYING")
                 << "- deferring this clip list (" << clips.size() << "clips)";
        m_pendingClips = clips;
        m_hasPendingClips = true;
        m_pendingClipsTimer->start();
        return;
    }

    // No-op short-circuit: an identical clip list to what's already live
    // needs no teardown/rebuild/commit at all. Guarded by m_hasAppliedClips
    // so the very first call (m_lastAppliedClips still default-empty) is
    // never mistaken for "already matches".
    // The canvas (size/fps) the track caps were last built with must be
    // unchanged too: re-loading a project with another frame size would
    // otherwise keep the old canvas. A difference takes the full rebuild
    // below, which is the only path that sets the restriction caps.
    const bool canvasUnchanged = (canvasFor(clips) == m_builtCanvas);
    if (m_hasAppliedClips && !canvasUnchanged) {
        qDebug() << "setClips: canvas changed since the last build - full rebuild";
    }
    if (m_hasAppliedClips && canvasUnchanged && clips == m_lastAppliedClips) {
        qDebug() << "setClips: identical to last applied clip list - skipping rebuild";
        emit timelineReady();
        return;
    }

    // === Stage 4/5 prep, Steps 2+3+4: add/remove/trim incremental fast path ===
    // If the new list differs from the previous applied set ONLY by
    // clips disappearing (Step 2), clips appearing (Step 3), and/or
    // surviving clips whose ONLY changes are timing (startTime/
    // durationSeconds/sourceOffset - Step 4), skip the full teardown+
    // rebuild below and apply exactly that delta: remove, add, and
    // mutate the timing clips in place via ges_timeline_element_
    // set_start/set_duration/set_inpoint. A survivor whose itemPath/
    // trackId/hasVideo/hasAudio changed (asset swap or track switch) is
    // NOT handled here - that falls straight through to the existing
    // full rebuild (Steps 5+ territory).
    bool tookIncrementalFastPath = false;
    qint64 fastPathMaxDuration = 0;
    if ((m_incrementalRemoveEnabled || m_incrementalAddEnabled || m_incrementalTrimEnabled) && m_hasAppliedClips && canvasUnchanged) {
        QSet<QString> newClipIds;
        bool allHaveId = true;
        for (const QVariant &clipVar : clips) {
            QString cid = clipVar.toMap().value("clipId").toString();
            if (cid.isEmpty()) { allHaveId = false; break; }
            newClipIds.insert(cid);
        }

        if (!allHaveId) {
            qDebug() << "setClips: [fast path diag] bailing - a clip in the new list has no clipId";
        }

        if (allHaveId) {
            QStringList removedIds;
            for (auto it = m_appliedClips.constBegin(); it != m_appliedClips.constEnd(); ++it) {
                if (!newClipIds.contains(it.key())) removedIds.append(it.key());
            }
            QList<QVariant> addedClipVars;
            for (const QVariant &clipVar : clips) {
                QString cid = clipVar.toMap().value("clipId").toString();
                if (!m_appliedClips.contains(cid)) addedClipVars.append(clipVar);
            }
            // clipId -> new clip map, filled in during the classification
            // pass below for survivors whose only changes are timing.
            QHash<QString, QVariantMap> timingChangedClips;
            // clipId -> new trackId, for survivors whose ONLY non-timing
            // change is trackId (a drag onto a different, already-
            // existing track). May overlap with timingChangedClips (a
            // clip can move in time AND track in the same edit).
            QHash<QString, QString> trackChangedClips;

            bool disqualified = false;
            if (!removedIds.isEmpty() && !m_incrementalRemoveEnabled) {
                qDebug() << "setClips: [fast path diag] bailing - removals present but"
                         << "m_incrementalRemoveEnabled is false";
                disqualified = true;
            }
            if (!disqualified && !addedClipVars.isEmpty() && !m_incrementalAddEnabled) {
                qDebug() << "setClips: [fast path diag] bailing - additions present but"
                         << "m_incrementalAddEnabled is false";
                disqualified = true;
            }

            // Classify every SURVIVING clip (present in both old and
            // new): "core" fields (itemPath/trackId/hasVideo/hasAudio)
            // changing disqualifies the whole call (asset swap/track
            // switch is Steps 5+ territory, not handled here). "timing"
            // fields (startTime/durationSeconds/sourceOffset) changing
            // alone is Step 4's job - collected for in-place mutation
            // below instead of disqualifying.
            if (!disqualified) {
                for (const QVariant &clipVar : clips) {
                    QVariantMap m = clipVar.toMap();
                    QString cid = m.value("clipId").toString();
                    if (!m_appliedClips.contains(cid)) continue; // addition, handled separately
                    const QVariantMap &applied = m_appliedClips.value(cid);

                    // Normalize to match what addClipToGES() actually
                    // stores in m_appliedClips: the itemPath there is
                    // the file:// PREFIX-STRIPPED value, and numeric
                    // fields can arrive as either int or double
                    // QVariants depending on how QML happened to box a
                    // whole number - comparing the raw QVariants
                    // directly made "/x.mp4" != "file:///x.mp4" and
                    // double(0) != int(0), so the fast path never
                    // actually matched on any real edit. Compare the
                    // semantic value instead.
                    QString newPath = m.value("itemPath").toString();
                    if (newPath.startsWith("file://")) newPath = newPath.mid(7);

                    // effects folded into "core" rather than its own
                    // category: an effects-only change forces the full
                    // teardown+rebuild path below, which is the only path
                    // that calls ClipEffects::applyToClip() (right after
                    // ges_layer_add_asset() recreates the clip) - there is
                    // no in-place "re-apply effects to a live clip" step
                    // in the fast path, so disqualifying here is simpler
                    // and safer than adding one just for this.
                    bool coreChanged =
                        applied.value("itemPath").toString() != newPath ||
                        // Same defaults as addClipToGES() (missing = true).
                        applied.value("hasVideo").toBool() != m.value("hasVideo", true).toBool() ||
                        applied.value("hasAudio").toBool() != m.value("hasAudio", true).toBool() ||
                        applied.value("effects").toString() != m.value("effects", "").toString() ||
                        // titleParams/clipKind for exactly the same reason
                        // as effects above: the fast path never re-applies
                        // child properties, and a clipKind flip changes
                        // which GES asset the clip is built from at all.
                        applied.value("clipKind").toString() != m.value("clipKind", "").toString() ||
                        applied.value("titleParams").toString() != m.value("titleParams", "").toString() ||
                        // A transition wipe-shape change: the vtype is
                        // only ever set by applyTransitionTypes() on the
                        // full-rebuild path below, so a fast-path apply
                        // would leave the live transition at its old shape.
                        applied.value("wipeNick").toString() != wipeNickFor(m);
                    if (coreChanged) {
                        qDebug() << "setClips: [fast path diag] bailing - clipId" << cid
                                 << "core field mismatch. applied:" << applied
                                 << "vs new:" << m;
                        disqualified = true;
                        break;
                    }

                    QString newTrackId = m.value("trackId").toString();
                    if (applied.value("trackId").toString() != newTrackId) {
                        if (!m_incrementalTrackChangeEnabled) {
                            qDebug() << "setClips: [fast path diag] bailing - clipId" << cid
                                     << "track changed but m_incrementalTrackChangeEnabled is false";
                            disqualified = true;
                            break;
                        }
                        trackChangedClips.insert(cid, newTrackId);
                    }

                    // Compared with a 1 us tolerance, not exactly: the
                    // recorded durationSeconds is read back from GES
                    // (whole nanoseconds), so for any non-ns-aligned
                    // duration (e.g. a Kdenlive import at 29.97 fps) an
                    // exact compare flagged EVERY clip as timing-changed
                    // on every edit. 1 us is far below one frame.
                    auto timeDiffers = [](double a, double b) { return qAbs(a - b) > 1e-6; };
                    bool sourceOffsetChanged =
                        timeDiffers(applied.value("sourceOffset").toDouble(), m.value("sourceOffset").toDouble());
                    bool timingChanged =
                        timeDiffers(applied.value("startTime").toDouble(), m.value("startTime").toDouble()) ||
                        timeDiffers(applied.value("durationSeconds").toDouble(), m.value("durationSeconds").toDouble()) ||
                        sourceOffsetChanged;
                    // A keyframed top-effect param's control-source time
                    // base is CLIP-START-relative (see ClipEffects.cpp's
                    // applyAnimation()), derived from the clip's inpoint
                    // at the moment the effect is applied - the fast path
                    // below only calls ges_timeline_element_set_inpoint()
                    // on the live element, it never re-applies effects,
                    // so a head trim (inpoint change) on a clip with
                    // keyframed effects would leave the automation
                    // mis-anchored against the new cut point. Force the
                    // full rebuild instead, which re-derives the offset
                    // correctly via applyToClip(). Only a sourceOffset
                    // (inpoint) change matters here - a plain move/tail-
                    // trim never touches inpoint, so it stays on the fast
                    // path. "\"kf\"" is a cheap, sufficient substring
                    // check: that exact sequence can't appear anywhere
                    // else in this JSON (keys/types are fixed, drawn from
                    // the registry).
                    if (sourceOffsetChanged && m.value("effects", "").toString().contains(QLatin1String("\"kf\""))) {
                        qDebug() << "setClips: [fast path diag] bailing - clipId" << cid
                                 << "sourceOffset changed with keyframed effects present";
                        disqualified = true;
                        break;
                    }
                    if (timingChanged) {
                        if (!m_incrementalTrimEnabled) {
                            qDebug() << "setClips: [fast path diag] bailing - clipId" << cid
                                     << "timing changed but m_incrementalTrimEnabled is false";
                            disqualified = true;
                            break;
                        }
                        timingChangedClips.insert(cid, m);
                    }
                }
            }
            // Escape hatch: every removed/timing-changed clipId needs a
            // live cached object, or this bails to the full rebuild
            // rather than guessing.
            if (!disqualified && !removedIds.isEmpty()) {
                for (const QString &cid : removedIds) {
                    if (!m_clipObjects.value(cid, nullptr)) {
                        qDebug() << "setClips: [fast path diag] bailing - removed clipId" << cid
                                 << "has no cached GESClip*";
                        disqualified = true;
                        break;
                    }
                    QString trackId = m_appliedClips.value(cid).value("trackId").toString();
                    if (!m_layers.contains(trackId)) {
                        qDebug() << "setClips: [fast path diag] bailing - removed clipId" << cid
                                 << "has unresolvable trackId" << trackId;
                        disqualified = true;
                        break;
                    }
                }
            }
            if (!disqualified && !timingChangedClips.isEmpty()) {
                for (auto it = timingChangedClips.constBegin(); it != timingChangedClips.constEnd(); ++it) {
                    if (!m_clipObjects.value(it.key(), nullptr)) {
                        qDebug() << "setClips: [fast path diag] bailing - timing-changed clipId"
                                 << it.key() << "has no cached GESClip*";
                        disqualified = true;
                        break;
                    }
                }
            }
            // Track-changed clips need a live cached object AND the
            // target layer to already exist (the fast path never calls
            // ensureLayers() - a drag onto a brand-new track must go
            // through the full rebuild instead).
            if (!disqualified && !trackChangedClips.isEmpty()) {
                for (auto it = trackChangedClips.constBegin(); it != trackChangedClips.constEnd(); ++it) {
                    if (!m_clipObjects.value(it.key(), nullptr)) {
                        qDebug() << "setClips: [fast path diag] bailing - track-changed clipId"
                                 << it.key() << "has no cached GESClip*";
                        disqualified = true;
                        break;
                    }
                    if (!m_layers.contains(it.value())) {
                        qDebug() << "setClips: [fast path diag] bailing - track-changed clipId"
                                 << it.key() << "target trackId" << it.value() << "has no existing layer";
                        disqualified = true;
                        break;
                    }
                }
            }
            // Additions need their target layer to already exist (the
            // fast path never calls ensureLayers()) - a clip destined
            // for a brand-new track must go through the full rebuild.
            if (!disqualified && !addedClipVars.isEmpty()) {
                for (const QVariant &clipVar : addedClipVars) {
                    QString trackId = clipVar.toMap().value("trackId").toString();
                    if (!m_layers.contains(trackId)) {
                        qDebug() << "setClips: [fast path diag] bailing - added clip's trackId"
                                 << trackId << "has no existing layer";
                        disqualified = true;
                        break;
                    }
                }
            }
            // Stage 4/5 prep, Step 6 hardening: a removal or addition
            // can involve a transition boundary without any SURVIVING
            // clip's own fields changing at all - confirmed live via a
            // split of a dissolve-participating clip (2 removed, 4
            // added, 0 timing/track-changed): GES's auto-transition did
            // NOT recompute correctly (the transition clip list stayed
            // byte-identical before/after per the Step 6 diagnostic
            // log), leaving a stale transition and visibly overlapping
            // clips - while a full rebuild handles the exact same edit
            // correctly (it always has). Per the staged plan's own
            // fallback for this situation: force a full rebuild whenever
            // a transition boundary might be involved, rather than try
            // to characterize exactly which adds/removes are "safe" -
            // scoped to adds/removes only, since Step 4/5's timing/
            // track-change-only deltas were separately live-tested
            // clean even with unrelated transitions elsewhere.
            if (!disqualified && (!removedIds.isEmpty() || !addedClipVars.isEmpty())) {
                for (const QVariant &clipVar : clips) {
                    if (clipVar.toMap().value("hasTransition", false).toBool()) {
                        qDebug() << "setClips: [fast path diag] bailing - a removal/addition is present"
                                 << "alongside a clip with hasTransition=true - forcing full rebuild"
                                 << "(Step 6: auto-transition not confirmed correct for this combination;"
                                 << "GesTransitions::applyTransitionTypes() below also only runs on this"
                                 << "full-rebuild path, so relaxing this guard needs re-plumbing that too)";
                        disqualified = true;
                        break;
                    }
                }
            }

            if (removedIds.isEmpty() && addedClipVars.isEmpty() && timingChangedClips.isEmpty()
                    && trackChangedClips.isEmpty() && !disqualified) {
                qDebug() << "setClips: [fast path diag] no delta detected -"
                         << "falling through to full rebuild (expected if nothing actually changed)";
            }

            if (!disqualified && (!removedIds.isEmpty() || !addedClipVars.isEmpty() || !timingChangedClips.isEmpty()
                    || !trackChangedClips.isEmpty())) {
                qDebug() << "setClips: incremental fast path -" << removedIds.size()
                         << "removed," << addedClipVars.size() << "added," << timingChangedClips.size()
                         << "timing-changed," << trackChangedClips.size() << "track-changed";

                // Stage 4/5 prep, Step 6: auto-transition verification.
                // No new behavior - just logs every GES_IS_TRANSITION_CLIP()
                // in every layer before and after this delta, so it's
                // visible from the log whether GES's own auto-transition
                // created/removed/resized the right ones in response to
                // an in-place Step 4/5 mutation (which has never been
                // exercised before this stage - every prior edit always
                // went through a full teardown+rebuild, where auto-
                // transition is already known to work correctly).
                auto logTransitionClips = [this](const char *label) {
                    int total = 0;
                    QStringList details;
                    for (auto layerIt = m_layers.constBegin(); layerIt != m_layers.constEnd(); ++layerIt) {
                        GList *layerClips = ges_layer_get_clips(layerIt.value());
                        for (GList *l = layerClips; l != NULL; l = l->next) {
                            if (GES_IS_TRANSITION_CLIP(l->data)) {
                                total++;
                                GESTimelineElement *elem = GES_TIMELINE_ELEMENT(l->data);
                                double s = (double)GES_TIMELINE_ELEMENT_START(elem) / GST_SECOND;
                                double d = (double)GES_TIMELINE_ELEMENT_DURATION(elem) / GST_SECOND;
                                details << QString("%1@%2+%3").arg(layerIt.key()).arg(s).arg(d);
                            }
                        }
                        g_list_free_full(layerClips, gst_object_unref);
                    }
                    qDebug() << "setClips: [fast path][Step 6 diag]" << label
                             << "- transition clip count:" << total << "details:" << details;
                };
                logTransitionClips("BEFORE this delta");

                // Same hang as the full-rebuild quiesce below (see its
                // comment): an in-place timing change that shrinks an
                // overlap to nothing makes GES dispose the auto-transition
                // right here (ges_video_transition_dispose -> _release_pad
                // -> gst_pad_set_active), and while the pipeline sits
                // PAUSED with the playhead inside that overlap the call
                // blocks forever on the parked mixer pad's stream lock.
                // Reproduced live (2026-11-20) by removing a dissolve with
                // the playhead parked in it. Quiesce to READY first whenever
                // a clip this delta touches currently overlaps a GES
                // transition on its layer; onCommitCompleted's dormant
                // branch re-prerolls and m_nextSeek restores the position,
                // exactly as on the full path. Edits away from transitions
                // keep the cheap path.
                if (m_pipeline && !m_playing) {
                    QSet<QString> touched;
                    for (auto it = timingChangedClips.constBegin(); it != timingChangedClips.constEnd(); ++it) touched.insert(it.key());
                    for (auto it = trackChangedClips.constBegin(); it != trackChangedClips.constEnd(); ++it) touched.insert(it.key());
                    for (const QString &cid : removedIds) touched.insert(cid);
                    bool touchesTransition = false;
                    for (auto layerIt = m_layers.constBegin(); layerIt != m_layers.constEnd() && !touchesTransition; ++layerIt) {
                        GList *layerClips = ges_layer_get_clips(layerIt.value());   // new refs
                        for (GList *l = layerClips; l && !touchesTransition; l = l->next) {
                            if (!GES_IS_TRANSITION_CLIP(l->data)) continue;
                            GESTimelineElement *te = GES_TIMELINE_ELEMENT(l->data);
                            const double ts = (double)GES_TIMELINE_ELEMENT_START(te) / GST_SECOND;
                            const double tend = ts + (double)GES_TIMELINE_ELEMENT_DURATION(te) / GST_SECOND;
                            for (const QString &cid : touched) {
                                const QVariantMap &a = m_appliedClips.value(cid);
                                if (a.value("trackId").toString() != layerIt.key()) continue;
                                const double cs = a.value("startTime").toDouble();
                                const double ce = cs + a.value("durationSeconds").toDouble();
                                if (cs < tend - 1e-6 && ce > ts + 1e-6) { touchesTransition = true; break; }
                            }
                        }
                        g_list_free_full(layerClips, gst_object_unref);
                    }
                    if (touchesTransition) {
                        GstState curState = GST_STATE_NULL, pendState = GST_STATE_VOID_PENDING;
                        gst_element_get_state(GST_ELEMENT(m_pipeline), &curState, &pendState, 0);
                        if (curState == GST_STATE_PAUSED && pendState == GST_STATE_VOID_PENDING) {
                            qDebug() << "setClips: [fast path] quiesce - PAUSED -> READY (delta touches a transition)";
                            removeAsyncTimeout();
                            drInvalidate();
                            if (gst_element_set_state(GST_ELEMENT(m_pipeline), GST_STATE_READY) == GST_STATE_CHANGE_FAILURE)
                                qWarning() << "setClips: [fast path] quiesce to READY failed (may hang)";
                            else
                                m_restoreAfterQuiesce = true;
                        } else {
                            qWarning() << "setClips: [fast path] delta touches a transition but pipeline state is"
                                       << curState << "pending" << pendState << "- not quiescing";
                        }
                    }
                }

                tTeardownStart = perfTimer.elapsed();
                for (const QString &cid : removedIds) {
                    GESClip *clip = m_clipObjects.take(cid);
                    QString trackId = m_appliedClips.value(cid).value("trackId").toString();
                    GESLayer *layer = m_layers.value(trackId, nullptr);
                    if (layer && clip) ges_layer_remove_clip(layer, clip);
                    m_appliedClips.remove(cid);
                }

                bool anyMutationRefused = false;

                // In-place track change (Step 5), applied BEFORE timing
                // changes: a clip moving to a different track needs to
                // be re-parented first so any subsequent set_start()/
                // set_duration() on it is validated against its NEW
                // layer's neighbors, not its old one's.
                for (auto it = trackChangedClips.constBegin(); it != trackChangedClips.constEnd(); ++it) {
                    const QString &cid = it.key();
                    const QString &newTrackId = it.value();
                    GESClip *clip = m_clipObjects.value(cid);
                    GESLayer *newLayer = m_layers.value(newTrackId, nullptr);
                    GError *moveErr = nullptr;
                    qDebug() << "setClips: [fast path] in-place track change for clipId" << cid
                             << "->" << newTrackId;
                    if (!ges_clip_move_to_layer_full(clip, newLayer, &moveErr)) {
                        // Same reasoning as a refused timing update
                        // (see below): GES correctly refused an invalid
                        // placement on the new layer (e.g. an overlap
                        // that only resolves once a linked partner also
                        // moves). Abort the whole fast path for this
                        // call - m_appliedClips must not advance to a
                        // trackId GES never actually applied.
                        qWarning() << "setClips: [fast path] in-place track change REFUSED by GES for clipId"
                                   << cid << "-" << (moveErr ? moveErr->message : "no error message")
                                   << "- aborting fast path for this call, falling back to full rebuild";
                        if (moveErr) g_error_free(moveErr);
                        anyMutationRefused = true;
                        continue;
                    }
                    m_appliedClips[cid]["trackId"] = newTrackId;
                }

                // In-place timing mutation (Step 4). Per-clip ordering:
                // shrink duration BEFORE moving start (a smaller span at
                // the OLD start can only be a subset of both the old and
                // new span, so it can never newly overlap a neighbor);
                // grow duration AFTER moving start (same reasoning,
                // applied to the new start). A plain move (duration
                // unchanged) or a plain resize (start unchanged) takes
                // either branch harmlessly since the other setter call
                // is just a same-value no-op. Cross-clip ordering between
                // DIFFERENT clips changing in the same call is NOT
                // specially sequenced - today's QML edit paths never
                // ripple-resize multiple clips at once, only ripple-MOVE
                // (same duration, shifted start), which this ordering
                // already covers regardless of inter-clip sequencing.
                for (auto it = timingChangedClips.constBegin(); !anyMutationRefused && it != timingChangedClips.constEnd(); ++it) {
                    const QString &cid = it.key();
                    const QVariantMap &m = it.value();
                    GESClip *clip = m_clipObjects.value(cid);
                    GESTimelineElement *elem = GES_TIMELINE_ELEMENT(clip);
                    QVariantMap &applied = m_appliedClips[cid];

                    double oldDuration = applied.value("durationSeconds").toDouble();
                    double newStart = m.value("startTime").toDouble();
                    double newDuration = m.value("durationSeconds").toDouble();
                    double newInPoint = m.value("sourceOffset").toDouble();

                    // Don't pre-clamp newDuration against the asset's
                    // discovered duration here - same reasoning as
                    // addClipToGES(): GstDiscoverer can slightly under-
                    // report a source's real duration, which used to
                    // cause a spurious shrink even when the requested
                    // duration is genuinely playable. Raise max-duration
                    // up front so the set_duration() calls below aren't
                    // refused outright by GES's own (correct) current
                    // max-duration, then verify/recover afterwards.
                    QString clipId = cid;
                    double requestedNewDuration = newDuration;
                    const TimeConv::Span newSpan = TimeConv::span(newStart, newDuration);
                    const GstClockTime newInPointNs = TimeConv::secToNs(newInPoint);
                    ges_timeline_element_set_max_duration(elem, newInPointNs + newSpan.duration);

                    qDebug() << "setClips: [fast path] in-place timing update for clipId" << cid
                             << "start" << applied.value("startTime").toDouble() << "->" << newStart
                             << "duration" << oldDuration << "->" << newDuration
                             << "inpoint" << applied.value("sourceOffset").toDouble() << "->" << newInPoint;

                    gboolean ok = TRUE;
                    // A head EXTENSION (transition made from B's handle,
                    // left-trim outward) lowers the inpoint while the
                    // duration grows: with the old, higher inpoint still in
                    // place, inpoint + new duration exceeds the max-duration
                    // set above and GES refuses the duration - every such
                    // edit fell back to a full rebuild. Lowering the
                    // inpoint first can never exceed it (inpoint only
                    // decreases, duration unchanged at that moment); a
                    // RAISED inpoint keeps the original "after" order,
                    // which is valid for the same reason in reverse.
                    const double oldInPoint = applied.value("sourceOffset").toDouble();
                    const bool inpointFirst = newInPoint < oldInPoint;
                    if (inpointFirst)
                        ok = ges_timeline_element_set_inpoint(elem, newInPointNs) && ok;
                    if (newDuration <= oldDuration) {
                        ok = ges_timeline_element_set_duration(elem, newSpan.duration) && ok;
                        ok = ges_timeline_element_set_start(elem, newSpan.start) && ok;
                    } else {
                        ok = ges_timeline_element_set_start(elem, newSpan.start) && ok;
                        ok = ges_timeline_element_set_duration(elem, newSpan.duration) && ok;
                    }
                    if (!inpointFirst)
                        ok = ges_timeline_element_set_inpoint(elem, newInPointNs) && ok;

                    if (!ok) {
                        // GES correctly refused an invalid intermediate
                        // placement (e.g. a ripple-move where multiple
                        // clips' new positions only become non-
                        // overlapping once ALL of them have moved, but
                        // this one was applied before a neighbor still
                        // sitting at its old position vacated the
                        // target span - iteration order here is
                        // QHash's, not time-sorted). This is NOT a
                        // crash and not corruption - but m_appliedClips
                        // must NOT be advanced to the refused value, or
                        // its bookkeeping would silently diverge from
                        // the real (unchanged) GES state forever. Abort
                        // the whole fast path for THIS call instead and
                        // let it fall through to the full rebuild below,
                        // which tears down and rebuilds every clip from
                        // `clips` regardless of whatever partial state
                        // this loop left GES in - self-healing by
                        // construction, no special-case recovery needed.
                        qWarning() << "setClips: [fast path] in-place timing update REFUSED by GES for clipId"
                                   << cid << "- aborting fast path for this call, falling back to full rebuild";
                        anyMutationRefused = true;
                        continue;
                    }

                    // Same small-shortfall recovery as addClipToGES(): if
                    // GES still ended up with a shorter duration than
                    // requested (its own max-duration, derived from the
                    // asset's discovered length, refused the full set
                    // above), try to recover it before falling back to
                    // the visible clamp.
                    GstClockTime actualDuration = ges_timeline_element_get_duration(elem);
                    double actualDurationSec = (double)actualDuration / GST_SECOND;
                    double shortfall = requestedNewDuration - actualDurationSec;
                    if (shortfall > 0.001) {
                        if (shortfall <= 0.5) {
                            ges_timeline_element_set_max_duration(elem, newInPointNs + newSpan.duration);
                            ges_timeline_element_set_duration(elem, newSpan.duration);
                            actualDuration = ges_timeline_element_get_duration(elem);
                            actualDurationSec = (double)actualDuration / GST_SECOND;
                            shortfall = requestedNewDuration - actualDurationSec;
                        }
                        if (shortfall > 0.001) {
                            emit clipDurationClamped(clipId, actualDurationSec);
                        }
                    }
                    newDuration = actualDurationSec;

                    applied["startTime"] = newStart;
                    applied["durationSeconds"] = newDuration;
                    applied["sourceOffset"] = newInPoint;
                }

                if (anyMutationRefused) {
                    // At least one in-place update was refused above -
                    // GES and m_appliedClips may now disagree about some
                    // clip's position (the refused one definitely still
                    // has its OLD position in GES, correctly left
                    // un-advanced in m_appliedClips). Don't attempt
                    // additions on top of this uncertain state, and
                    // don't claim the fast path - fall through to the
                    // full rebuild below, which tears down and rebuilds
                    // every clip fresh from `clips` and so corrects
                    // everything regardless of this loop's partial
                    // effects.
                    qDebug() << "setClips: [fast path] aborted due to a refused timing update -"
                             << "falling through to full rebuild";
                } else {
                tAddStart = perfTimer.elapsed();
                for (const QVariant &clipVar : addedClipVars) {
                    addClipToGES(clipVar.toMap(), fastPathMaxDuration);
                }
                // Clips untouched by this delta still contribute to the
                // total duration - fold them in too (addClipToGES only
                // ever grows fastPathMaxDuration from the clips it adds).
                for (auto it = m_appliedClips.constBegin(); it != m_appliedClips.constEnd(); ++it) {
                    double s = it.value().value("startTime").toDouble();
                    double d = it.value().value("durationSeconds").toDouble();
                    qint64 endMs = (qint64)((s + d) * 1000.0);
                    if (endMs > fastPathMaxDuration) fastPathMaxDuration = endMs;
                }
                tookIncrementalFastPath = true;

                logTransitionClips("AFTER this delta");

                // Same consistency audit as the full-rebuild path (see
                // its comment below) - run it here too so a Step 2/3/4-
                // specific bookkeeping bug surfaces immediately rather
                // than only on some later full rebuild.
                int realNonTransitionClips = 0;
                for (GESLayer *layer : m_layers.values()) {
                    GList *layerClips = ges_layer_get_clips(layer);
                    for (GList *l = layerClips; l != NULL; l = l->next) {
                        if (!GES_IS_TRANSITION_CLIP(l->data)) realNonTransitionClips++;
                    }
                    g_list_free_full(layerClips, gst_object_unref);
                }
                if (realNonTransitionClips != m_clipObjects.size()) {
                    qWarning() << "setClips: [fast path] clip-object audit MISMATCH - real non-transition clips:"
                               << realNonTransitionClips << "vs m_clipObjects:" << m_clipObjects.size();
                }
                } // end else (!anyMutationRefused)
            }
        }
    }

    qint64 maxDuration = 0;

    if (!tookIncrementalFastPath) {
    // Flagged for the entire full teardown+rebuild below, so QML can show
    // a "switching..." indicator and block play/seek instead of letting
    // the user interact with - or glance at - a torn-down/partially-
    // rebuilt timeline. Every exit from this block (both the early
    // "no layers" return right below and the normal end-of-function path)
    // must clear it again.
    if (!m_reloadingAssets) {
        m_reloadingAssets = true;
        emit reloadingAssetsChanged();
    }
    startPrerollWatchdog();

    // Quiesce before tearing down a timeline that has transitions, if the
    // pipeline is sitting PAUSED. Disposing a GESTransitionClip releases the
    // request pads on the transition's own mixer synchronously on this
    // thread (ges_video_transition_dispose -> _release_pad -> gst_pad_set_
    // active), but clip removal is only applied to the nlecomposition at the
    // next commit - so while PAUSED/prerolled the transition is still live:
    // its input streaming threads sit parked inside the mixer's aggregator
    // pad holding the pad's stream lock, and set_active blocks on that lock
    // forever (main thread frozen, 0% CPU). Reproduced deterministically by
    // parking inside a crossfade overlap and calling reloadAssets(), in both
    // GL and CPU timeline mode; parking outside any overlap never hangs.
    // READY (not NULL - that would throw away the decoder/GL sink state)
    // deactivates the streaming pads and wakes those waits; nle keeps its
    // task alive in READY so the commit below still completes, and
    // onCommitCompleted's dormant branch brings it back to PAUSED, after
    // which the m_nextSeek set below restores the position.
    if (m_pipeline && !m_playing) {
        GstState curState = GST_STATE_NULL, pendState = GST_STATE_VOID_PENDING;
        gst_element_get_state(GST_ELEMENT(m_pipeline), &curState, &pendState, 0);
        bool hasTransition = false;
        for (GESLayer *layer : m_layers.values()) {
            GList *layerClips = ges_layer_get_clips(layer);
            for (GList *l = layerClips; l && !hasTransition; l = l->next)
                if (GES_IS_TRANSITION_CLIP(l->data)) hasTransition = true;
            g_list_free_full(layerClips, gst_object_unref);
            if (hasTransition) break;
        }
        if (hasTransition && curState == GST_STATE_PAUSED && pendState == GST_STATE_VOID_PENDING) {
            qDebug() << "setClips: quiesce - PAUSED -> READY before teardown (transitions present)";
            removeAsyncTimeout();
            drInvalidate();
            GstStateChangeReturn qret = gst_element_set_state(GST_ELEMENT(m_pipeline), GST_STATE_READY);
            if (qret == GST_STATE_CHANGE_FAILURE) {
                qWarning() << "setClips: quiesce to READY failed - tearing down live (may hang)";
            } else {
                m_restoreAfterQuiesce = true;
            }
        } else if (hasTransition) {
            qWarning() << "setClips: transitions present but pipeline state is" << curState
                       << "pending" << pendState << "- not quiescing";
        }
    }

    // Dinamikus layer kezelés: összegyűjtjük az összes trackId-t a klipekből
    QStringList neededTrackIds;
    for (const QVariant &clipVar : clips) {
        QString trackId = clipVar.toMap()["trackId"].toString();
        if (!trackId.isEmpty() && !neededTrackIds.contains(trackId))
            neededTrackIds.append(trackId);
    }
    // Ha nincsenek klipek, megtartjuk a meglévő layereket
    if (!neededTrackIds.isEmpty())
        ensureLayers(neededTrackIds);

    if (m_layers.isEmpty()) {
        qDebug() << "setClips: No layers - emitting timelineReady anyway";
        m_resumePlayAfterDecoderChange = false;
        m_playRequestedAfterCommit = false;
        m_reloadingAssets = false;
        emit reloadingAssetsChanged();
        emit timelineReady();
        emit previewReady();
        return;
    }

    // Beállítások betöltése
    const CanvasSpec canvas = canvasFor(clips);
    const int width = canvas.width, height = canvas.height;
    const int fpsN = canvas.fpsN, fpsD = canvas.fpsD;

    if (fpsN > 0) m_frameDurationMs = 1000.0 * fpsD / fpsN;

    // Track beállítások
    GList *tracks = ges_timeline_get_tracks(m_timeline);
    for (GList *tmp = tracks; tmp; tmp = tmp->next) {
        GESTrack *track = GES_TRACK(tmp->data);
        if (track->type == GES_TRACK_TYPE_VIDEO) {
            GstCaps *caps = gst_caps_new_simple("video/x-raw",
                                                "width", G_TYPE_INT, width,
                                                "height", G_TYPE_INT, height,
                                                "framerate", GST_TYPE_FRACTION, fpsN, fpsD,
                                                NULL);
            if (m_glMode) {
                // Frames stay in GLMemory from the decoder to the sink.
                gst_caps_set_features_simple(caps, gst_caps_features_new("memory:GLMemory", NULL));
                gst_caps_set_simple(caps, "format", G_TYPE_STRING, "RGBA", NULL);
            }
            ges_track_set_restriction_caps(track, caps);
            gst_caps_unref(caps);
        }
    }
    g_list_free_full(tracks, gst_object_unref);

    // Meglévő klipek törlése minden layer-ből
    tTeardownStart = perfTimer.elapsed();
    qDebug() << "setClips: starting teardown of" << m_layers.size() << "layers";
    for (GESLayer *layer : m_layers.values()) {
        GList *currentClips = ges_layer_get_clips(layer);
        guint numCurrentClips = g_list_length(currentClips);
        qDebug() << "setClips: teardown - layer has" << numCurrentClips << "clips, removing...";
        if (numCurrentClips > 0) {
            for (GList *l = currentClips; l != NULL; l = l->next) {
                ges_layer_remove_clip(layer, GES_CLIP(l->data));
            }
        }
        g_list_free_full(currentClips, gst_object_unref);
        qDebug() << "setClips: teardown - layer cleared";
    }
    qDebug() << "setClips: teardown of all layers done";

    // Every cached clip record below referred to a clip that the teardown
    // loop above just destroyed (every layer was just fully cleared) -
    // drop them together rather than one at a time. Rebuilt fully in the
    // add loop below; this is still a full rebuild every call, same as
    // today (Stage 4/5 prep, Step 1 - bookkeeping only, no new fast path).
    m_clipObjects.clear();
    m_appliedClips.clear();

    tAddStart = perfTimer.elapsed();

    qDebug() << "setClips: entering add loop for" << clips.size() << "clips";
    // Klipek hozzáadása
    for (const QVariant &clipVar : clips) {
        qDebug() << "setClips: add loop - processing clip" << clipVar.toMap().value("clipId").toString();
        addClipToGES(clipVar.toMap(), maxDuration);
    }

    // Consistency audit (Stage 4/5 prep, Step 1) - purely diagnostic, no
    // behavior depends on this. Every layer is still being fully rebuilt
    // every call right now, so m_clipObjects.size() must equal the real
    // non-transition clip count across all layers; a mismatch here would
    // mean the bookkeeping above has a bug BEFORE any future incremental
    // fast path ever gets to rely on it. Auto-created transition clips
    // (GES_IS_TRANSITION_CLIP()) are GES's own and were never recorded in
    // m_clipObjects, so they must be excluded from the real count too.
    {
        int realNonTransitionClips = 0;
        for (GESLayer *layer : m_layers.values()) {
            GList *layerClips = ges_layer_get_clips(layer);
            for (GList *l = layerClips; l != NULL; l = l->next) {
                if (!GES_IS_TRANSITION_CLIP(l->data)) realNonTransitionClips++;
            }
            g_list_free_full(layerClips, gst_object_unref);
        }
        if (realNonTransitionClips != m_clipObjects.size()) {
            qWarning() << "setClips: clip-object audit MISMATCH - real non-transition clips:"
                       << realNonTransitionClips << "vs m_clipObjects:" << m_clipObjects.size();
        }
    }

    // AUTO-TRANSITION: GES automatikusan létrehozza a transition klipeket
    // az átfedő klipek között - de alapértelmezetten mindig crossfade
    // típussal. Ha egy klip transitionType mezője ettől eltérő GES
    // nick-et hordoz (pl. Kdenlive luma wipe importból, lásd
    // KdenliveImporter.cpp gesWipeNickForLumaResource()), itt állítjuk át
    // a már létrehozott auto-transition klip "vtype" property-jét - ez
    // EGYETLEN g_object_set hívással a transition asset-jét is cseréli
    // (GES 1.24 ges_transition_clip_update_vtype_internal() ellenőrizve),
    // nincs szükség külön asset-keresésre/beállításra.
    {
        QVector<GesTransitions::PendingTransition> pending;
        for (const QVariant &clipVar : clips) {
            QVariantMap cm = clipVar.toMap();
            if (!cm.value("hasTransition").toBool()) continue;
            QString type = cm.value("transitionType").toString();
            if (type.isEmpty() || type == QLatin1String("crossfade") || type == QLatin1String("dissolve")) continue;
            double startSec = cm.value("startTime").toDouble();
            double durSec = cm.value("durationSeconds").toDouble();
            GstClockTime endNs = TimeConv::secToNs(startSec + durSec);
            pending.append({ cm.value("trackId").toString(), endNs, type });
        }
        GesTransitions::applyTransitionTypes(m_layers, pending);
    }

    } // end if (!tookIncrementalFastPath) - full teardown+rebuild path

    m_totalDuration = tookIncrementalFastPath ? fastPathMaxDuration : maxDuration;
    emit totalDurationChanged();

    // Record what's actually being applied now, for the no-op
    // short-circuit above on the NEXT call.
    m_lastAppliedClips = clips;
    m_hasAppliedClips = true;
    {
        const CanvasSpec newCanvas = canvasFor(clips);
        const bool sizeChanged = (newCanvas.width != m_builtCanvas.width
                                  || newCanvas.height != m_builtCanvas.height);
        m_builtCanvas = newCanvas;
        if (sizeChanged)
            emit canvasSizeChanged();
    }

    qDebug() << "setClips: Total duration:" << m_totalDuration << "ms, connecting commited signal";

    // A "commited" signal-ra iratkozunk fel
    if (m_commitedSignalId == 0) {
        m_commitedSignalId = g_signal_connect(m_timeline, "commited",
                                               G_CALLBACK(onTimelineCommited), this);
        qDebug() << "setClips: Connected to commited signal, id:" << m_commitedSignalId;
    }

    // Re-assert per-track hide/mute. Clips (and sometimes whole layers)
    // were just torn down and rebuilt above, and the incremental fast
    // path doesn't go through ensureLayers() at all - rather than rely on
    // GES carrying a layer's active-for-track flag across that, just push
    // the authoritative state again. It rides along on the commit below.
    reapplyAllTrackActivations();
    reapplyAllTrackVolumes();
    reapplyAllTrackPans();

    m_commitPending = true;

    // Pitivi pattern: mentjük az aktuális pozíciót a seek-hez
    m_nextSeek = m_position;
    m_nextSeekScrub = false;

    // Pitivi pattern: Számoljuk meg a klipeket (was_empty check)
    guint numClips = 0;
    for (GESLayer *layer : m_layers.values()) {
        GList *clipList = ges_layer_get_clips(layer);
        numClips += g_list_length(clipList);
        g_list_free_full(clipList, gst_object_unref);
    }
    bool isEmpty = (numClips == 0);

    // Pitivi pattern: Ha busy és nem üres a timeline, elhalasztjuk a commit-ot
    tCommitCallStart = perfTimer.elapsed();
    if (isBusyAsync() && !m_wasEmpty && !isEmpty) {
        qDebug() << "setClips: Pipeline busy, deferring commit";
        m_commitWanted = true;
        m_wasEmpty = false;
    } else {
        qDebug() << "setClips: Calling ges_timeline_commit...";
        addAsyncTimeout("setClips commit", 5);
        gboolean commitResult = ges_timeline_commit(m_timeline);
        qDebug() << "setClips: ges_timeline_commit returned:" << commitResult;
        m_wasEmpty = isEmpty;

        if (!commitResult) {
            qDebug() << "setClips: No changes to commit, calling onCommitCompleted directly";
            removeAsyncTimeout();
            m_commitPending = false;
            QMetaObject::invokeMethod(this, "onCommitCompleted", Qt::QueuedConnection,
                                       Q_ARG(quint64, reinterpret_cast<quint64>(m_timeline)));
        }
    }
    tCommitCallEnd = perfTimer.elapsed();

    // Perf instrumentation (Stage 4/5 prep) - note this measures only the
    // SYNCHRONOUS cost of this call (teardown + rebuild + the
    // ges_timeline_commit() call itself returning); the actual commit
    // apply happens asynchronously on the streaming thread and finishes
    // later in onCommitCompleted(), which is not included here.
    qDebug() << "setClips perf:" << clips.size() << "clips -"
             << "teardown:" << (tAddStart - tTeardownStart) << "ms,"
             << "rebuild:" << (tCommitCallStart - tAddStart) << "ms,"
             << "commit call:" << (tCommitCallEnd - tCommitCallStart) << "ms,"
             << "total:" << tCommitCallEnd << "ms";
}

void TimelineEngine::play() {
    if (!m_pipeline) return;
    if (!videoOutputReady()) {
        // Remember the request - onCommitCompleted() and setGLVideoItem()
        // both honour this flag once video output actually becomes
        // available, same pattern already used for a commit-pending
        // play(). (The native-window path's setWindowId() does not
        // consume it directly - a window normally arrives well before any
        // play() attempt, so this mainly matters for the GL path, where
        // the item can genuinely still be missing.)
        m_playRequestedAfterCommit = true;
        return;
    }

    // Nothing to play on an empty composition - without this, the
    // dead-reckoned playhead would advance indefinitely (m_totalDuration
    // is 0, so none of onPositionTimer's duration clamps engage) despite
    // nothing actually being rendered.
    if (m_totalDuration <= 0) {
        qDebug() << "play(): timeline is empty (totalDuration <= 0), nothing to play";
        return;
    }

    if (m_commitPending || m_hasPendingClips) {
        qDebug() << "play(): commit pending, will resume once it completes";
        m_playRequestedAfterCommit = true;
        return;
    }
    m_playRequestedAfterCommit = false;
    if (m_scrub) m_scrub->disarm();   // no scrub grain over the start of playback

    GstState current;
    gst_element_get_state(GST_ELEMENT(m_pipeline), &current, NULL, 0);

    qDebug() << "play(): Current pipeline state:" << current << "position:" << m_position;

    if (current == GST_STATE_NULL) {
        qDebug() << "play(): Pipeline is NULL, setting to PAUSED first";
        gst_element_set_state(GST_ELEMENT(m_pipeline), GST_STATE_PAUSED);
        gst_element_get_state(GST_ELEMENT(m_pipeline), &current, NULL, 1 * GST_SECOND);
    }

    qDebug() << "play(): Setting pipeline to PLAYING";
    GstStateChangeReturn ret = gst_element_set_state(GST_ELEMENT(m_pipeline), GST_STATE_PLAYING);
    if (ret == GST_STATE_CHANGE_FAILURE) {
        qCritical() << "Failed to start playback";
        return;
    }

    m_playing = true;
    drResetAnchor(m_position);
    m_positionTimer->start();
    emit playingChanged();
    qDebug() << "play(): Playback started successfully";
}

void TimelineEngine::pause() {
    if (!m_pipeline) return;
    qDebug() << "pause(): Pausing playback at position:" << m_position;
    if (!videoOutputReady()) {
        // No video output yet (GL item not installed / no native window).
        // Taking the pipeline to PAUSED now would make GES/playsink
        // autoplug its own video sink in a window of its own (a stray
        // "OpenGL Renderer" toplevel). Only update the engine's own state;
        // wakeUpForVideoOutput() brings the pipeline up once the output exists.
        qDebug() << "pause(): video output not ready - not touching the pipeline state";
        m_playing = false;
        m_positionTimer->stop();
        drInvalidate();
        emit playingChanged();
        return;
    }
    GstStateChangeReturn ret = gst_element_set_state(GST_ELEMENT(m_pipeline), GST_STATE_PAUSED);
    m_playing = false;
    m_positionTimer->stop();
    drInvalidate();
    emit playingChanged();
    // Ha a state-change async, jelezzük hogy ASYNC_DONE várható.
    // Ezzel a seek() tudni fogja, hogy isBusyAsync() és defer-eli magát,
    // így a pause ASYNC_DONE nem írja felül a seek célpozícióját.
    if (ret == GST_STATE_CHANGE_ASYNC) {
        addAsyncTimeout("pause", 2);
    }
}

void TimelineEngine::stop() {
    qDebug() << "stop(): Stopping and seeking to 0";
    pause();
    seek(0);
}

void TimelineEngine::seek(qint64 positionMs, bool fast) {
    seekImpl(positionMs, fast, false);
}

void TimelineEngine::stepSeek(qint64 positionMs) {
    seekImpl(positionMs, false, true);
}

void TimelineEngine::seekImpl(qint64 positionMs, bool fast, bool scrub, bool queuedReplay) {
    if (!m_pipeline) return;
    // Any seek that is not a (still eligible) frame step cancels a pending
    // or half-collected scrub grain.
    if (scrub && (m_playing || fast
                  || !QSettings().value("audio/scrubOnStep", true).toBool()))
        scrub = false;
    if (!scrub && m_scrub) m_scrub->disarm();

    // Clamp to valid range. The upper bound is one frame before the
    // timeline's end, not the end itself - you can never display a
    // frame that begins AT or AFTER the last frame's start, so this
    // can only ever land on the same final frame the caller meant,
    // never a different one. This also keeps a seek strictly off the
    // exact boundary where a clip's declared duration can exceed what
    // its demuxer can actually preroll a frame for (see TODO.txt's
    // mpegpsdemux dead-zone notes) - derived from the project's own
    // frame rate, not a guessed margin.
    if (positionMs < 0) positionMs = 0;
    if (m_totalDuration > 0) {
        qint64 maxSeekMs = m_totalDuration - (qint64)std::ceil(m_frameDurationMs);
        if (maxSeekMs < 0) maxSeekMs = 0;
        if (positionMs > maxSeekMs) positionMs = maxSeekMs;
    }

    // A step that does not move the playhead (already at 0 / the last frame)
    // is silent instead of replaying the same grain.
    // (Not for a queued step being replayed from ASYNC_DONE: its m_position
    // was already set to the target when it was queued.)
    if (scrub && !queuedReplay && positionMs == m_position) scrub = false;

    qDebug() << "seek(): target:" << positionMs << "ms, current:" << m_position
             << "isBusyAsync:" << isBusyAsync() << "fast:" << fast;

    // A felhasználói seek AZONNAL "ground truth" → pozíció és anchor reset ELŐRE
    m_position = positionMs;
    drResetAnchor(positionMs);
    m_drLastPipelinePos = -1;      // Stall detekció invalidálás
    m_isSeeking = true;            // Pipeline query tiltás ASYNC_DONE-ig
    m_skipSmoothingTicks = 0;      // ASYNC_DONE fogja beállítani
    emit positionChanged();

    GstState state;
    gst_element_get_state(GST_ELEMENT(m_pipeline), &state, NULL, 0);

    // Pitivi pattern: Ha busy VAGY state < PAUSED, halasztjuk el a GStreamer seek-et
    if (isBusyAsync() || state < GST_STATE_PAUSED) {
        qDebug() << "seek(): Pipeline busy or not ready, queuing GStreamer seek";
        m_nextSeek = positionMs;
        m_nextSeekFast = fast;
        m_nextSeekScrub = scrub;   // a newer queued seek replaces (and silences) an older one

        if (state < GST_STATE_PAUSED && !videoOutputReady()) {
            // No video output yet (GL item not installed / no native
            // window): waking the pipeline now would make GES/playsink
            // autoplug a fallback video sink in a window of its own. Leave
            // it parked; wakeUpForVideoOutput() seeks to m_position once
            // the output exists.
            qDebug() << "seek(): video output not ready - keeping the pipeline parked";
            m_isSeeking = false;
            return;
        }
        if (state < GST_STATE_PAUSED) {
            addAsyncTimeout("seek: waking up pipeline", 5);
            GstStateChangeReturn ret = gst_element_set_state(GST_ELEMENT(m_pipeline), GST_STATE_PAUSED);
            if (ret == GST_STATE_CHANGE_FAILURE) {
                qWarning() << "seek: Failed to change state to PAUSED";
                removeAsyncTimeout();
                m_nextSeek = -1;
            }
        }
        return;
    }

    // Közvetlen seek végrehajtás
    m_nextSeek = -1;
    m_nextSeekScrub = false;
    // SNAP_BEFORE (not SNAP_NEAREST) for fast/scrub seeks: a clip's
    // placed duration can extend slightly past the last actually
    // decodable position of its source media (confirmed live - some
    // proxy files report/claim more duration than they can really
    // preroll a frame for, by anywhere from ~0.1s to 65s depending on
    // the file). SNAP_NEAREST can round FORWARD into that dead zone,
    // where preroll never completes and ASYNC_DONE never arrives;
    // SNAP_BEFORE only ever rounds backward, into media already known
    // to be decodable.
    GstSeekFlags flags = fast
        ? (GstSeekFlags)(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT | GST_SEEK_FLAG_SNAP_BEFORE)
        : (GstSeekFlags)(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE);

    bool seekOk;
    if (scrub && m_scrub) {
        // Same event gst_element_seek_simple() builds (gstutils.c: rate 1.0,
        // the same format and flags, start SET, stop SET to
        // GST_CLOCK_TIME_NONE), created by hand only to learn its
        // seqnum, which is what the scrub tap matches the resulting
        // SEGMENT event against. Armed BEFORE sending: the probe can see
        // the segment before send_event returns.
        GstEvent *sev = gst_event_new_seek(1.0, GST_FORMAT_TIME, flags,
                                           GST_SEEK_TYPE_SET, positionMs * GST_MSECOND,
                                           GST_SEEK_TYPE_SET, GST_CLOCK_TIME_NONE);
        m_scrub->arm(gst_event_get_seqnum(sev));
        seekOk = gst_element_send_event(GST_ELEMENT(m_pipeline), sev);   // takes sev
        if (!seekOk) m_scrub->disarm();
    } else {
        seekOk = gst_element_seek_simple(GST_ELEMENT(m_pipeline),
                            GST_FORMAT_TIME, flags,
                            positionMs * GST_MSECOND);
    }
    if (!seekOk) {
        qWarning() << "Seek failed to position" << positionMs << "ms";
        // The seek never actually started, so no ASYNC_DONE will ever
        // arrive to clear m_isSeeking - without this, onPositionTimer's
        // "m_isSeeking" gate would freeze the playhead for the rest of
        // the session. drInvalidate() also clears the DR anchor so the
        // next position tick re-bootstraps from the pipeline's real
        // (unchanged) position instead of the failed seek target.
        drInvalidate();
    } else {
        // A scrub (fast) seek landing in a dead zone (see above) still
        // never gets ASYNC_DONE even with SNAP_BEFORE if the target
        // itself sits past the last decodable frame - SNAP_BEFORE only
        // protects against rounding INTO one, not a target that's
        // already there. A much shorter watchdog bounds how long a
        // single stuck scrub tick can freeze the UI (measured p99
        // real-world seek latency is ~133ms; 3s was tuned for the
        // rarer, legitimately-slower non-scrub seeks).
        if (fast) addAsyncTimeoutMs("seek", 300);
        else addAsyncTimeout("seek", 3);
        qDebug() << "seek(): GStreamer seek successful to" << positionMs << "ms";
    }
}

void TimelineEngine::onPositionTimer() {
    if (!m_pipeline || !m_playing) return;

    // === SEEKING: pipeline stale adatot jelenthet, TILOS lekérdezni ===
    // A playhead a seek célpozíciónál marad (m_position-t a seek() már beállította).
    // NE léptessük DR-rel, mert a pipeline még nem játszik — ha DR-rel
    // léptetjük, ASYNC_DONE után a pipeline tényleges pozíciója elmarad
    // a DR-től és "large jump" reset-et okoz (látható visszaugrás).
    if (m_isSeeking) {
        // Nem kell semmit sem csinálni: m_position már a célpozíción van,
        // a QML ezt már megkapta a seek()-ben emitált positionChanged()-ből.
        return;
    }

    // === ASYNC BUSY (nem seek): pure dead reckoning ===
    if (isBusyAsync()) {
        if (m_drActive) {
            qint64 expected = drExpectedPosition();
            if (m_totalDuration > 0 && expected > m_totalDuration) expected = m_totalDuration;
            if (expected >= 0) {
                m_position = expected;
                emit positionChanged();
            }
        }
        return;
    }

    // === Pipeline pozíció lekérdezés ===
    gint64 pos = 0;
    if (!gst_element_query_position(GST_ELEMENT(m_pipeline), GST_FORMAT_TIME, &pos)) {
        // Query sikertelen: dead reckoning fallback
        if (m_drActive) {
            qint64 expected = drExpectedPosition();
            if (m_totalDuration > 0 && expected > m_totalDuration) expected = m_totalDuration;
            if (expected >= 0) {
                m_position = expected;
                emit positionChanged();
            }
        }
        return;
    }

    qint64 pipelineMs = pos / GST_MSECOND;
    if (pipelineMs < 0) return;

    // === SMOOTHING BYPASS: seek után pipeline 1:1 követés, nincs blend/DR ===
    if (m_skipSmoothingTicks > 0) {
        m_skipSmoothingTicks--;
        drResetAnchor(pipelineMs);
        m_drLastPipelinePos = pipelineMs;
        m_position = pipelineMs;
        emit positionChanged();
        return;
    }

    // === Bootstrap: első érvényes query indítja a DR-t ===
    if (!m_drActive) {
        drResetAnchor(pipelineMs);
        m_drLastPipelinePos = pipelineMs;
        m_position = pipelineMs;
        emit positionChanged();
        return;
    }

    qint64 expected = drExpectedPosition();

    // === Stall detekció (ELSŐ!): pipeline PONTOSAN ugyanazt jelenti mint előzőleg ===
    // Ezt a large-jump ellenőrzés ELŐTT kell vizsgálni, mert stall esetén
    // a DR-expected messzire eltávolodhat a stalled pipeline pozíciótól,
    // de ez NEM valódi ugrás — csak lassú pipeline (pl. seek utáni dekódolás).
    bool isStall = (m_drLastPipelinePos >= 0 && pipelineMs == m_drLastPipelinePos);

    // === Nagy ugrás: CSAK ha a pipeline NEM stallt és AKTÍVAN új pozíciót jelent ===
    // Stall esetén a DR-eltérés természetes (pipeline lemaradt), nem valódi ugrás.
    if (!isStall && qAbs(pipelineMs - expected) > DR_SEEK_THRESHOLD_MS) {
        qDebug() << "POS_DR: Large jump (seek/loop), resetting. pipeline:" << pipelineMs
                 << "expected:" << expected << "diff:" << (pipelineMs - expected);
        drResetAnchor(pipelineMs);
        m_drLastPipelinePos = pipelineMs;
        m_position = pipelineMs;
        emit positionChanged();
        return;
    }

    // === Backward jitter: pipeline a kijelzett pozíció MÖGÖTT van ===
    bool isBackward = (pipelineMs < m_position);

    qint64 newPos;

    if (isStall || isBackward) {
        // Pipeline megállt vagy hátraugrott → dead reckoning, de korlátozzuk
        // mennyivel mehetünk a pipeline elé. Ha a pipeline lassú (pl. NLE
        // transition újrakonfigurálás, dekódolás), a playhead NE szaladjon
        // messze előre — inkább lassítson le és várja be a pipeline-t.
        newPos = expected;
        qint64 maxLead = pipelineMs + 200;  // Max 200ms előny a pipeline felett
        if (newPos > maxLead) {
            newPos = maxLead;
            drResetAnchor(newPos);  // Anchor frissítés a korlátozott pozícióra
        }
    } else {
        // Normál eset: pipeline és DR közel → súlyozott átlag (95% DR, 5% pipeline)
        // A DR (wall clock) a sebességgazda — a pipeline csak korrekció.
        // Túl nagy pipeline súly (pl. 20%) sebességingadozást okoz
        // ha a GStreamer belső órája eltér a rendszerórától.
        newPos = (expected * 19 + pipelineMs) / 20;
    }

    // === Backward védelem: CSAK kis jitter ellen, NEM nagy ugrások ellen ===
    if (newPos < m_position && (m_position - newPos) < 50) {
        newPos = m_position;
    }

    // Clamp
    if (m_totalDuration > 0 && newPos > m_totalDuration) {
        newPos = m_totalDuration;
    }

    // Anchor frissítés a simított pozícióra (DR követi a blend-et)
    drResetAnchor(newPos);
    m_drLastPipelinePos = pipelineMs;
    m_position = newPos;
    emit positionChanged();
}

void TimelineEngine::clearWindowId() {
    if (m_windowId == 0) return;
    qDebug() << "clearWindowId: native video window was destroyed, dropping stale handle" << m_windowId.load();
    m_windowId = 0;
}

void TimelineEngine::wakeUpForVideoOutput() {
    if (!m_pipeline || m_layers.isEmpty()) return;

    GstState currentState, pendingState;
    GstStateChangeReturn stateRet = gst_element_get_state(
        GST_ELEMENT(m_pipeline), &currentState, &pendingState, 0);

    if (currentState >= GST_STATE_PAUSED ||
        pendingState >= GST_STATE_PAUSED ||
        stateRet == GST_STATE_CHANGE_ASYNC) {
        refreshVideo();
        return;
    }

    // Klipek számolása az összes layer-ből
    guint numClips = 0;
    for (GESLayer *layer : m_layers.values()) {
        GList *clips = ges_layer_get_clips(layer);
        numClips += g_list_length(clips);
        g_list_free_full(clips, gst_object_unref);
    }

    if (numClips > 0 && currentState <= GST_STATE_READY) {
        refreshVideo();
        if (gst_element_set_state(GST_ELEMENT(m_pipeline), GST_STATE_PAUSED) != GST_STATE_CHANGE_FAILURE) {
            // Pitivi pattern: mentjük az aktuális pozíciót seek-hez
            m_nextSeek = m_position;
            m_nextSeekScrub = false;
            addAsyncTimeout("wakeUpForVideoOutput: waking up", 5);
        }
    }
}

void TimelineEngine::setWindowId(qulonglong windowId) {
    if (isGLVideoSink()) return; // native-window path only
    if (m_windowId != windowId && windowId != 0) {
        m_windowId = windowId;

        if (m_commitPending) {
            qDebug() << "setWindowId: commit pending, skipping state change";
            return;
        }

        wakeUpForVideoOutput();
    }
}

bool TimelineEngine::installGLSink() {
    if (!m_pipeline || !m_glVideoItem || m_glSinkInstalled) return false;

    GstState current;
    gst_element_get_state(GST_ELEMENT(m_pipeline), &current, NULL, 0);
    if (current != GST_STATE_NULL) {
        // Not the normal path (videoOutputReady() keeps the pipeline
        // parked at NULL until a sink exists) - only reachable via a
        // scene-graph invalidation re-initializing the GL item while the
        // pipeline was already running. ges_pipeline_preview_set_video_
        // sink() requires GST_STATE_NULL, so force it there first.
        qWarning() << "installGLSink: pipeline not in NULL state (" << current << "), forcing it there";
        resetPlaybackStateForForcedStop();
        gst_element_set_state(GST_ELEMENT(m_pipeline), GST_STATE_NULL);
    }

    GstElement *sinkElement = nullptr;
    GstElement *sinkBin = Qml6GLSink::makeSinkBin(m_glVideoItem, &sinkElement, m_glMode ? Qml6GLSink::Upstream::GLMemory : Qml6GLSink::Upstream::SystemMemory);
    if (!sinkBin) {
        qWarning() << "installGLSink: Qml6GLSink::makeSinkBin() failed";
        return false;
    }
    // gst_bin_new() returns a floating ref; ges_pipeline_preview_set_video_
    // sink() is (transfer none) and only gst_object_ref()s it - it does NOT
    // sink the floating ref, same reason GES's own autovideosink fallback
    // (ges-pipeline.c) does gst_object_ref_sink() before handing a sink
    // over. Keep our own sunk ref in m_glSinkBin for teardown.
    gst_object_ref_sink(sinkBin);
    ges_pipeline_preview_set_video_sink(m_pipeline, sinkBin);

    // Verify GES really adopted our sink by reading the property back,
    // rather than by sampling the bin's state. An earlier version checked
    // for GST_STATE_READY here and so failed 100% of the time: GES's
    // ges_pipeline_preview_set_video_sink() only forwards the element to
    // playsink's "video-sink" property, and playsink merely stores it - it
    // does NOT pre-roll or even READY the sink. The sink's state follows
    // the pipeline's, so while we're parked at NULL (the normal path -
    // videoOutputReady() holds us here until a sink exists) the bin is
    // legitimately at NULL and there is nothing to wait for. Verified
    // against GES 1.24.2 with a standalone GESPipeline: the bin reads back
    // GST_STATE_NULL / GST_STATE_CHANGE_SUCCESS right after installation
    // and only reaches PAUSED once the pipeline itself does.
    GstElement *installed = nullptr;
    g_object_get(m_pipeline, "video-sink", &installed, NULL);
    const bool adopted = (installed == sinkBin);
    if (installed) gst_object_unref(installed);
    if (!adopted) {
        qWarning() << "installGLSink: GES did not adopt our sink bin - falling back to its own autovideosink";
        gst_object_unref(sinkBin);
        return false;
    }

    m_glSinkBin = sinkBin;
    m_glSinkElement = sinkElement;
    m_glSinkInstalled = true;
    return true;
}

void TimelineEngine::setGLVideoItem(QQuickItem *item) {
    if (!isGLVideoSink()) return;
    if (m_glVideoItem == item && m_glSinkInstalled) return;

    m_glVideoItem = item;
    if (!item) return;

    if (!installGLSink()) {
        qWarning() << "setGLVideoItem: installGLSink() failed - video output unavailable this session";
        return;
    }

    if (m_commitPending) {
        qDebug() << "setGLVideoItem: commit pending, skipping wake-up";
        return;
    }
    wakeUpForVideoOutput();

    // Mirrors onCommitCompleted()'s m_playRequestedAfterCommit handling -
    // a play() that arrived while the GL item didn't exist yet is honoured
    // now that video output is finally ready.
    if (m_playRequestedAfterCommit) {
        m_playRequestedAfterCommit = false;
        qDebug() << "setGLVideoItem: starting playback requested while video output was unavailable";
        play();
    }
}

void TimelineEngine::clearGLVideoItem() {
    if (!isGLVideoSink()) return;
    m_glVideoItem = nullptr;
    if (!m_glSinkInstalled) return;

    qDebug() << "clearGLVideoItem: GL video item destroyed, tearing down the pipeline's video output";
    m_glSinkInstalled = false;
    m_glSinkElement = nullptr;
    // The pipeline is forced to NULL below behind play()/pause()'s back:
    // keep the UI state (playing flag, position timer, watchdog) in step,
    // or the playhead keeps dead-reckoning on a stopped pipeline and an
    // armed watchdog later re-PAUSEs it without any video sink.
    resetPlaybackStateForForcedStop();
    if (m_pipeline) {
        gst_element_set_state(GST_ELEMENT(m_pipeline), GST_STATE_NULL);
        ges_pipeline_preview_set_video_sink(m_pipeline, nullptr);
    }
    if (m_glSinkBin) {
        gst_object_unref(m_glSinkBin);
        m_glSinkBin = nullptr;
    }
}

void TimelineEngine::refreshVideo() {
    if (!m_pipeline) return;
    if (isGLVideoSink()) return; // qml6glsink repaints via QQuickItem::update() - no expose() needed

    GstElement *video_sink = NULL;
    g_object_get(m_pipeline, "video-sink", &video_sink, NULL);

    if (video_sink) {
        if (GST_IS_VIDEO_OVERLAY(video_sink)) {
            if (m_windowId != 0) {
                gst_video_overlay_set_window_handle(GST_VIDEO_OVERLAY(video_sink), m_windowId.load());
            }
            gst_video_overlay_expose(GST_VIDEO_OVERLAY(video_sink));
        }
        gst_object_unref(video_sink);
    }
}

QString TimelineEngine::captureCurrentFrame(const QString &outputPath) {
    if (!m_pipeline) return QString();

    int width = ProjectSettings::value("project/width", 1920).toInt();
    int height = ProjectSettings::value("project/height", 1080).toInt();
    if (width <= 0) width = 1920;
    if (height <= 0) height = 1080;

    // KNOWN NOT WORKING YET: ges_pipeline_save_thumbnail()/
    // ges_pipeline_get_thumbnail_rgb24() reliably fail here. Diagnosed so
    // far (not yet root-caused): gst_element_get_state() on m_pipeline
    // reports state=READY, pending=PAUSED, return=ASYNC and never
    // resolves - even blocking for 2 real seconds - DESPITE the native
    // video overlay visibly rendering correct frames at the same moment
    // (confirmed by screenshotting the actual X11 overlay window). So
    // the top-level GESPipeline's own async state-change handshake is
    // stuck even though playback genuinely works - GES's thumbnail API
    // apparently requires that top-level handshake to have completed and
    // bails out otherwise. Root cause not yet found; see TODO.txt.
    GError *err = nullptr;
    gboolean ok = ges_pipeline_save_thumbnail(m_pipeline, width, height, "jpeg",
                                               outputPath.toUtf8().constData(), &err);
    if (!ok) {
        qWarning() << "captureCurrentFrame: ges_pipeline_save_thumbnail failed:"
                   << (err ? err->message : "unknown error");
        if (err) g_error_free(err);
        return QString();
    }
    return outputPath;
}

void TimelineEngine::applyDecoderRanks(const QString &decoder) {
    // Same technique VideoEngine uses for the Source Monitor: GStreamer
    // registry ranks are process-global, so boosting the preferred
    // decoder's rank here also governs which element decodebin picks the
    // NEXT time it autoplugs a video stream - including inside this
    // engine's GESPipeline.
    // Decoder factory names are looked up dynamically (see
    // GstElementDiscovery.h) instead of matched against a hand-maintained
    // list, so a GStreamer release renaming a decoder element can't silently
    // stop this rank-boosting from working.
    GstRegistry *registry = gst_registry_get();

    const QStringList nvDecoders = GstElementDiscovery::allDecoderFactories("nvidia");
    const QStringList vaDecoders = GstElementDiscovery::allDecoderFactories("vaapi");

    for (const QString &name : nvDecoders + vaDecoders) {
        GstPluginFeature *feature = gst_registry_lookup_feature(registry, name.toUtf8().constData());
        if (feature) {
            gst_plugin_feature_set_rank(feature, GST_RANK_MARGINAL);
            gst_object_unref(feature);
        }
    }

    const QStringList boost = (decoder == "nvidia") ? nvDecoders
                             : (decoder == "vaapi") ? vaDecoders
                             : QStringList();
    for (const QString &name : boost) {
        GstPluginFeature *feature = gst_registry_lookup_feature(registry, name.toUtf8().constData());
        if (feature) {
            gst_plugin_feature_set_rank(feature, GST_RANK_PRIMARY + 1);
            gst_object_unref(feature);
        }
    }
    // For "cpu", every hardware decoder stays at MARGINAL, so software
    // decoders win the autoplug.
}

void TimelineEngine::setDecoderPreference(const QString &decoder) {
    bool changed = (m_decoderPreference != decoder);
    m_decoderPreference = decoder;

    // Re-applying the ranks even when unchanged is cheap and harmless -
    // it's what actually makes the preference take effect for whichever
    // clip decodebin autoplugs next.
    applyDecoderRanks(decoder);

    if (!changed || !m_pipeline) return;

    // The ranks above only affect NEW decoder elements - a decodebin that
    // already autoplugged a clip with the old decoder won't swap it live.
    // The only reliable way to actually switch the live preview's decoder
    // is to tear down and rebuild the whole GESPipeline/GESTimeline, the
    // same way VideoEngine rebuilds playbin for the Source Monitor.
    qDebug() << "setDecoderPreference: rebuilding pipeline for decoder" << decoder;

    bool wasPlaying = m_playing;
    qint64 resumePos = m_position;

    m_positionTimer->stop();
    m_playing = false;
    emit playingChanged();

    destroyPipeline();
    createPipeline();

    // destroyPipeline() wiped the GES layers/clips - m_windowId is untouched
    // (the QML VideoOutput widget itself was never destroyed), so the new
    // pipeline's bus_sync_handler can embed into it immediately once a clip
    // is loaded again.
    m_nextSeek = resumePos;
    m_nextSeekScrub = false;
    m_resumePlayAfterDecoderChange = wasPlaying;

    // QML owns the actual clip list (TimelineEngine doesn't retain it after
    // setClips() converts it into GES objects), so ask it to repopulate the
    // freshly-created, empty timeline.
    emit decoderPreferenceApplied();
}

void TimelineEngine::setPreviewScale(int denominator) {
    if (!m_pipeline) return;
    if (denominator < 1) denominator = 1;

    // playbin (which GESPipeline wraps) supports changing "video-filter"
    // at runtime and relinks its internal video path itself - no need to
    // force the pipeline through READY first (an earlier attempt at that
    // "to be safe" bypassed play()/pause()/seek()'s ASYNC_DONE and
    // dead-reckoning bookkeeping and caused its own glitches).

    if (denominator == 1) {
        g_object_set(m_pipeline, "video-filter", nullptr, nullptr);
        qDebug() << "setPreviewScale: full resolution (filter cleared)";
        return;
    }

    int baseWidth = ProjectSettings::value("project/width", 1920).toInt();
    int baseHeight = ProjectSettings::value("project/height", 1080).toInt();
    // "Automatic" profile projects store width/height as "auto" -
    // QVariant::toInt() on that is 0, so fall back to a sane default
    // rather than asking videoscale to target a 0x0 frame.
    if (baseWidth <= 0) baseWidth = 1920;
    if (baseHeight <= 0) baseHeight = 1080;
    // Even dimensions (4:2:0): round the divided size down to even.
    int width = qMax(16, (baseWidth / denominator) & ~1);
    int height = qMax(16, (baseHeight / denominator) & ~1);

    GstElement *filterBin = gst_bin_new("preview-scale-bin");
    GstElement *scale = gst_element_factory_make(m_glMode ? "glcolorscale" : "videoscale", nullptr);
    GstElement *capsfilter = gst_element_factory_make("capsfilter", nullptr);
    if (!filterBin || !scale || !capsfilter) {
        qWarning() << "setPreviewScale: failed to create videoscale/capsfilter elements";
        // Nothing has been added to the bin yet at this point, so each
        // successfully-created element/bin still owns its own standalone
        // ref and must be unreffed individually - previously these were
        // just leaked on this path.
        if (filterBin) gst_object_unref(filterBin);
        if (scale) gst_object_unref(scale);
        if (capsfilter) gst_object_unref(capsfilter);
        return;
    }

    GstCaps *caps = gst_caps_new_simple(
        "video/x-raw",
        "width", G_TYPE_INT, width,
        "height", G_TYPE_INT, height,
        nullptr
    );
    if (m_glMode)
        gst_caps_set_features_simple(caps, gst_caps_features_new("memory:GLMemory", NULL));
    g_object_set(capsfilter, "caps", caps, nullptr);
    gst_caps_unref(caps);

    gst_bin_add_many(GST_BIN(filterBin), scale, capsfilter, nullptr);
    // gst_bin_add_many() above already took ownership of scale/capsfilter -
    // from here on, cleanup on failure only needs to unref filterBin
    // itself (which releases its children too), never scale/capsfilter
    // directly.
    if (!gst_element_link(scale, capsfilter)) {
        qWarning() << "setPreviewScale: failed to link videoscale to capsfilter";
        gst_object_unref(filterBin);
        return;
    }

    GstPad *sinkPad = gst_element_get_static_pad(scale, "sink");
    GstPad *srcPad = gst_element_get_static_pad(capsfilter, "src");
    GstPad *sinkGhost = sinkPad ? gst_ghost_pad_new("sink", sinkPad) : nullptr;
    GstPad *srcGhost = srcPad ? gst_ghost_pad_new("src", srcPad) : nullptr;
    if (sinkPad) gst_object_unref(sinkPad);
    if (srcPad) gst_object_unref(srcPad);

    if (!sinkGhost || !srcGhost || !gst_element_add_pad(filterBin, sinkGhost)
        || !gst_element_add_pad(filterBin, srcGhost)) {
        qWarning() << "setPreviewScale: failed to create/add ghost pads - installing a bin "
                      "without working pads would just produce a GStreamer bus error, not scale anything";
        // gst_element_add_pad() takes ownership of the pad only on
        // success - a ghost pad that failed to be added (or was never
        // created) must be unreffed ourselves to avoid leaking it.
        if (sinkGhost && GST_OBJECT_PARENT(sinkGhost) != GST_OBJECT(filterBin)) gst_object_unref(sinkGhost);
        if (srcGhost && GST_OBJECT_PARENT(srcGhost) != GST_OBJECT(filterBin)) gst_object_unref(srcGhost);
        gst_object_unref(filterBin);
        return;
    }

    // Do NOT unref filterBin after this. An earlier attempt to "fix" an
    // assumed leak here (assuming playbin's video-filter setter dups its
    // own reference the way g_value_dup_object would) added an
    // unref right after this call - that was wrong and caused a
    // use-after-free: the SECOND time the preview scale was changed,
    // playbin's internal replacement of the OLD filter bin crashed deep
    // inside a nested g_object_set()/g_object_unref() call, because our
    // extra unref had already dropped the bin to refcount 0 and freed it
    // while playbin was still the only thing meant to hold it. Confirmed
    // by a live crash with this exact backtrace after switching Full ->
    // Quarter -> another scale. This one-bin-per-change reference is a
    // bounded, minor leak (at most one bin per manual scale change by the
    // user) and is far safer than risking a use-after-free in a hot
    // GStreamer property path - do not "fix" it again without first
    // confirming (not assuming) playbin's actual ownership semantics for
    // this property in this exact GStreamer version.
    g_object_set(m_pipeline, "video-filter", filterBin, nullptr);
    qDebug() << "setPreviewScale: 1/" << denominator << "->" << width << "x" << height;
}

bool TimelineEngine::setClipEffectParam(const QString &clipId, const QString &effectId,
                                         const QString &param, const QVariant &value) {
    GESClip *clip = m_clipObjects.value(clipId, nullptr);
    if (!clip) {
        qWarning() << "setClipEffectParam: no live clip for" << clipId;
        return false;
    }
    return ClipEffects::setParam(clip, effectId, param, value, m_projectDir);
}

bool TimelineEngine::setTitleParam(const QString &clipId, const QString &param,
                                    const QVariant &value) {
    GESClip *clip = m_clipObjects.value(clipId, nullptr);
    if (!clip) {
        qWarning() << "setTitleParam: no live clip for" << clipId;
        return false;
    }
    return TitleClips::setParam(clip, param, value);
}

gboolean TimelineEngine::busCallback(GstBus *bus, GstMessage *msg, gpointer data) {
    Q_UNUSED(bus);
    TimelineEngine *engine = static_cast<TimelineEngine*>(data);

    switch (GST_MESSAGE_TYPE(msg)) {
    case GST_MESSAGE_EOS:
        engine->pause();
        break;
    
    case GST_MESSAGE_ASYNC_DONE:
        qDebug() << "ASYNC_DONE received, m_nextSeek:" << engine->m_nextSeek
                 << "m_isSeeking:" << engine->m_isSeeking;

        // Pitivi pattern: töröljük a timeout-ot
        engine->removeAsyncTimeout();

        // First preroll after a full rebuild: it works, disarm the watchdog.
        if (engine->m_awaitingPreroll) {
            engine->m_awaitingPreroll = false;
            engine->m_watchdogStrikes = 0;
            engine->stopPrerollWatchdog();
            emit engine->previewReady();
        }

        {
            bool wasSeeking = engine->m_isSeeking;
            engine->m_isSeeking = false;

            if (wasSeeking) {
                // Seek ASYNC_DONE: NE hívjuk emitPosition()-t.
                // A seek() már beállította a helyes m_position-t.
                // Remember this as the last position a seek actually
                // confirmed - asyncTimeoutCallback() uses it to recover
                // if a LATER seek never completes (see its comment).
                engine->m_lastGoodSeekMs = engine->m_position;
                engine->m_seekRecoveryAttempts = 0;
                if (engine->m_playing) {
                    engine->drResetAnchor(engine->m_position);
                    engine->m_drLastPipelinePos = -1;
                }
            } else {
                // Nem seek ASYNC_DONE (pause/commit/state-change)
                if (engine->m_restoreAfterQuiesce) {
                    // Re-preroll after the quiesce in setClips(): the pipeline
                    // reads ~0 here; the queued m_nextSeek below restores the
                    // real position, so keep the playhead where it is.
                    engine->m_restoreAfterQuiesce = false;
                } else {
                    engine->emitPosition();
                }
                if (engine->m_playing) {
                    engine->drResetAnchor(engine->m_position);
                    engine->m_skipSmoothingTicks = 10;
                }
            }
        }

        // Pitivi pattern: Ha van elhalasztott seek, hajtsuk végre
        if (engine->m_nextSeek >= 0) {
            qDebug() << "ASYNC_DONE: Performing queued seek to" << engine->m_nextSeek;
            qint64 seekPos = engine->m_nextSeek;
            bool seekFast = engine->m_nextSeekFast;
            bool seekScrub = engine->m_nextSeekScrub;
            engine->m_nextSeek = -1;  // Töröljük ELŐTTE, hogy ne legyen végtelen ciklus
            engine->m_nextSeekScrub = false;
            engine->seekImpl(seekPos, seekFast, seekScrub, true);
        }

        // Pitivi pattern: Ha van elhalasztott commit, hajtsuk végre
        if (engine->m_commitWanted && engine->m_timeline) {
            qDebug() << "ASYNC_DONE: Performing deferred commit";
            engine->m_commitWanted = false;
            engine->addAsyncTimeout("deferred commit", 3);
            ges_timeline_commit(engine->m_timeline);
        }

        // A clip list that setClips() held back because an async operation
        // was in flight can now be applied - the pipeline just reported
        // ASYNC_DONE, so no decodebin is mid-preroll for the clips we are
        // about to tear down (see the deferral comment in setClips()).
        // Only if nothing NEW was started just above (queued seek /
        // deferred commit): in that case the next ASYNC_DONE retries, and
        // m_pendingClipsTimer is the final fallback either way. Queued
        // rather than called inline so the GES teardown/rebuild does not
        // run inside GStreamer's bus-message dispatch.
        if (engine->m_hasPendingClips && !engine->m_commitPending && !engine->isBusyAsync()) {
            qDebug() << "ASYNC_DONE: pipeline idle again - replaying deferred clip list";
            QMetaObject::invokeMethod(engine, [engine]() {
                if (engine->m_hasPendingClips && !engine->m_commitPending && !engine->isBusyAsync())
                    engine->applyPendingClips();
            }, Qt::QueuedConnection);
        }
        break;

    case GST_MESSAGE_ERROR: {
        GError *err;
        gchar *debug;
        gst_message_parse_error(msg, &err, &debug);
        
        if (QString(err->message) != "Internal data stream error.") {
            emit engine->error(QString::fromUtf8(err->message));
        } else {
            qWarning() << "GStreamer internal data stream error (ignoring if transient)";
            // A stream that cannot negotiate/link never recovers (unlike a
            // flush-time transient) and keeps the pipeline from prerolling
            // forever. If it is one of our preview proxies, name the file so
            // the Backend can revert just that proxy to its original.
            const QString dbg = debug ? QString::fromUtf8(debug) : QString();
            if (dbg.contains("not-negotiated") || dbg.contains("not-linked")) {
                QString failingPath;
                for (GstObject *o = GST_MESSAGE_SRC(msg); o && failingPath.isEmpty(); o = GST_OBJECT_PARENT(o)) {
                    if (!G_IS_OBJECT(o) ||
                        !g_object_class_find_property(G_OBJECT_GET_CLASS(o), "uri"))
                        continue;
                    gchar *uri = nullptr;
                    g_object_get(o, "uri", &uri, NULL);
                    if (uri) {
                        failingPath = QUrl::fromEncoded(QByteArray(uri)).toLocalFile();
                        g_free(uri);
                    }
                }
                qWarning() << "Stream negotiation failed for" << (failingPath.isEmpty() ? QString("<unknown source>") : failingPath);
                if (!failingPath.isEmpty())
                    emit engine->proxyPlaybackFailed(failingPath);
            }
        }
        
        g_error_free(err);
        g_free(debug);
        break;
    }

    case GST_MESSAGE_ELEMENT: {
        const GstStructure *s = gst_message_get_structure(msg);
        if (s && gst_structure_has_name(s, "level")) {
            const gchar *srcRaw = GST_OBJECT_NAME(GST_MESSAGE_SRC(msg));
            const QString src = srcRaw ? QString::fromUtf8(srcRaw) : QString();
            double pl = -90, pr = -90, hl = -90, hr = -90;
            readLevelArray(s, "peak", pl, pr);
            readLevelArray(s, "decay", hl, hr);
            auto clampDb = [](double x) { return std::isfinite(x) ? qBound(-90.0, x, 6.0) : -90.0; };
            const double cpl = clampDb(pl), cpr = clampDb(pr);
            const double chl = clampDb(hl), chr = clampDb(hr);

            if (src == QLatin1String("gcsmaster")) {
                emit engine->audioLevel(QStringLiteral("master"), cpl, cpr, chl, chr);
            } else if (src.startsWith(QLatin1String("gcslvl_"))) {
                // Stage C2: per-clip meter. The element name is the
                // sanitized clip id; resolve it (directly first, then via
                // the rare sanitized-id scan) and look up the clip's
                // CURRENT track in m_appliedClips (a moved clip updates it).
                QString clipId = src.mid(7);
                if (!engine->m_appliedClips.contains(clipId)) {
                    clipId.clear();
                    for (auto it = engine->m_appliedClips.constBegin();
                         it != engine->m_appliedClips.constEnd(); ++it) {
                        if (meterElementName(it.key()) == src) { clipId = it.key(); break; }
                    }
                }
                if (!clipId.isEmpty()) {
                    const QString trackId = engine->m_appliedClips.value(clipId)
                                                .value("trackId").toString();
                    if (!trackId.isEmpty())
                        emit engine->audioLevel(trackId, cpl, cpr, chl, chr);
                }
                // Unknown clip id: ignore silently (a removed clip's last
                // messages can still be in flight).
            }
        }
        break;
    }
    default: break;
    }
    return TRUE;
}

void TimelineEngine::onTimelineCommited(GESTimeline *timeline, gpointer user_data)
{
    TimelineEngine *engine = static_cast<TimelineEngine*>(user_data);
    // Identity of the timeline GES itself just told us committed - read
    // directly from this callback's own argument, not from any separately
    // tracked counter, so there's no window where the "current" value
    // could have already moved on by the time this fires.
    qDebug() << "GES Timeline commit completed (streaming thread), timeline:" << timeline;
    QMetaObject::invokeMethod(engine, "onCommitCompleted", Qt::QueuedConnection,
                               Q_ARG(quint64, reinterpret_cast<quint64>(timeline)));
}

void TimelineEngine::onCommitCompleted(quint64 timelinePtr)
{
    if (reinterpret_cast<quint64>(m_timeline) != timelinePtr) {
        // Stale notification from a pipeline/timeline that
        // setDecoderPreference() already destroyed and replaced while
        // this was queued - acting on it would seek/play the WRONG
        // (current) pipeline using state that belonged to the old one.
        // timelinePtr is never dereferenced, only compared, so this is
        // safe even though the object it once pointed to may already be
        // freed.
        qDebug() << "onCommitCompleted: ignoring stale commit for a timeline that is no longer current";
        return;
    }

    qDebug() << "onCommitCompleted: Processing commit on main thread, windowId:" << m_windowId.load()
             << "m_nextSeek:" << m_nextSeek;

    m_commitPending = false;

    if (m_hasPendingClips) {
        // A setClips() that arrived while this commit was in flight was held
        // back; GES has now confirmed the commit, so the graph is safe to
        // rebuild. That setClips() runs its own full commit cycle and will
        // emit timelineReady() from its own onCommitCompleted(), so this
        // now-superseded cycle's seek/refresh/ready work is skipped on
        // purpose. m_nextSeek is intentionally left untouched - setClips()
        // re-samples it from the current m_position.
        applyPendingClips();
        return;
    }

    if (videoOutputReady() && m_pipeline) {
        GstState current, pending;
        gst_element_get_state(GST_ELEMENT(m_pipeline), &current, &pending, 0);

        if (current < GST_STATE_PAUSED && pending < GST_STATE_PAUSED) {
            // Pipeline alszik, ébresztjük fel
            qDebug() << "onCommitCompleted: Pipeline is dormant, waking up to PAUSED";

            addAsyncTimeout("onCommitCompleted: waking up", 5);
            GstStateChangeReturn ret = gst_element_set_state(GST_ELEMENT(m_pipeline), GST_STATE_PAUSED);
            if (ret == GST_STATE_CHANGE_FAILURE) {
                qWarning() << "Failed to set pipeline to PAUSED after commit";
                removeAsyncTimeout();
            } else {
                qDebug() << "Pipeline set to PAUSED, waiting for ASYNC_DONE";
                // Az ASYNC_DONE fogja végrehajtani a m_nextSeek-et
            }
        } else {
            // Már fut, frissítjük a nézetet és seek-elünk
            qDebug() << "onCommitCompleted: Pipeline active (state" << current << "), refreshing view";
            refreshVideo();

            // Pitivi pattern: ha van elhalasztott seek, hajtsuk végre
            // Ez kiváltja az ASYNC_DONE-t, ami frissíti a pozíciót
            if (m_nextSeek >= 0) {
                qDebug() << "onCommitCompleted: Performing seek to" << m_nextSeek;
                qint64 seekPos = m_nextSeek;
                m_nextSeek = -1;

                // This is a real seek on the live pipeline, so it needs
                // the exact same DR/seek bookkeeping seek() itself does -
                // otherwise onPositionTimer keeps blending stale pipeline
                // positions during the flush, and the resulting
                // ASYNC_DONE gets misclassified as "not a seek" (emits
                // emitPosition() instead of skipping it), reproducing the
                // keyframe-snap flash this bookkeeping exists to avoid.
                m_position = seekPos;
                drResetAnchor(seekPos);
                m_drLastPipelinePos = -1;
                m_isSeeking = true;
                m_skipSmoothingTicks = 0;
                emit positionChanged();

                addAsyncTimeout("onCommitCompleted seek", 3);
                GstSeekFlags flags = (GstSeekFlags)(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE);
                if (!gst_element_seek_simple(GST_ELEMENT(m_pipeline),
                                        GST_FORMAT_TIME,
                                        flags,
                                        seekPos * GST_MSECOND)) {
                    qWarning() << "onCommitCompleted: seek failed";
                    removeAsyncTimeout();
                    drInvalidate();
                }
            }
        }
    } else {
        qDebug() << "onCommitCompleted: Skipping state change (video output not ready yet, or no pipeline)";
    }

    if (m_hasAssetWaitClips) {
        // A clip list is parked by setClips()'s asset gate (waiting for the
        // AssetLoader): it will run its own full commit cycle and emit
        // timelineReady() itself (abortMediaLoad() emits it for the abort
        // case), so ready/reloading/resume-play are left for that cycle.
        // The wake-up/seek work above still ran: loading can take
        // arbitrarily long, and a dormant pipeline would leave the seek
        // watchdogs looping.
        qDebug() << "onCommitCompleted: a clip list is waiting for media loading - not signalling ready yet";
        // An empty composition never prerolls, and loading can take
        // arbitrarily long: disarm the preroll watchdog the rebuild armed so it
        // cannot report a bogus "pipeline did not start" while we wait. The
        // parked list's own rebuild re-arms it.
        stopPrerollWatchdog();
        m_awaitingPreroll = false;
        return;
    }

    if (m_reloadingAssets) {
        m_reloadingAssets = false;
        emit reloadingAssetsChanged();
        // Rebuilt, but not yet known to be playable: the first ASYNC_DONE
        // (preroll) disarms the watchdog started with the rebuild.
        m_awaitingPreroll = true;
    }

    qDebug() << "Emitting timelineReady signal";
    emit timelineReady();
    // An empty composition never prerolls - nothing more to wait for.
    if (m_lastAppliedClips.isEmpty()) emit previewReady();

    if (m_resumePlayAfterDecoderChange) {
        m_resumePlayAfterDecoderChange = false;
        qDebug() << "onCommitCompleted: resuming playback after decoder rebuild";
        play();
    } else if (m_playRequestedAfterCommit) {
        m_playRequestedAfterCommit = false;
        qDebug() << "onCommitCompleted: starting playback requested while commit was pending";
        play();
    }

    // A track hide/unhide that arrived while this commit was in flight was
    // parked in m_commitWanted (commitTrackActivation()). ASYNC_DONE also
    // services it, but during playback a commit often produces none, which
    // left the toggle unapplied until some later seek.
    if (m_commitWanted && !m_commitPending) {
        qDebug() << "onCommitCompleted: performing commit deferred during the previous one";
        m_commitWanted = false;
        commitTrackActivation();   // re-defers itself if the pipeline is busy
    }
}

// =============================================================================
// Pitivi-style async state management
// =============================================================================

void TimelineEngine::addAsyncTimeout(const char* reason, int timeoutSec)
{
    removeAsyncTimeout();
    qDebug() << "addAsyncTimeout:" << reason << "timeout:" << timeoutSec << "sec";
    m_asyncTimeoutId = g_timeout_add_seconds(timeoutSec, asyncTimeoutCallback, this);
}

void TimelineEngine::addAsyncTimeoutMs(const char* reason, int timeoutMs)
{
    removeAsyncTimeout();
    qDebug() << "addAsyncTimeoutMs:" << reason << "timeout:" << timeoutMs << "ms";
    m_asyncTimeoutId = g_timeout_add(timeoutMs, asyncTimeoutCallback, this);
}

void TimelineEngine::removeAsyncTimeout()
{
    if (m_asyncTimeoutId != 0) {
        g_source_remove(m_asyncTimeoutId);
        m_asyncTimeoutId = 0;
        qDebug() << "removeAsyncTimeout: Async timeout removed";
    }
}

gboolean TimelineEngine::asyncTimeoutCallback(gpointer data)
{
    TimelineEngine *engine = static_cast<TimelineEngine*>(data);
    qWarning() << "Async operation timed out! Pipeline may be stuck.";
    engine->m_asyncTimeoutId = 0;
    engine->m_restoreAfterQuiesce = false;

    // Recovery: Reset async state so we don't stay stuck
    engine->m_nextSeek = -1;

    bool wasSeeking = engine->m_isSeeking;

    // A commit whose confirmation never came, with a clip list waiting
    // behind it: that list's full teardown runs below. The commit may still
    // be in flight on a streaming thread, so the pipeline goes to READY
    // first (quiesceToReady()), and the seek/commit recovery steps below are
    // skipped - the rebuild commits and restores the position itself.
    const bool forcedTeardown = engine->m_commitPending && engine->m_hasPendingClips
                                && !engine->m_playing;

    // drInvalidate() clears m_isSeeking/m_drActive/m_drLastPipelinePos/
    // m_skipSmoothingTicks. Without this, a seek whose ASYNC_DONE never
    // arrives (the exact case this timeout exists for) would leave
    // m_isSeeking stuck true forever - onPositionTimer unconditionally
    // skips position updates while it's set, so the playhead would freeze
    // for the rest of the session.
    engine->drInvalidate();

    // A seek that never got ASYNC_DONE can leave the pipeline wedged
    // mid-flush (confirmed live: a seek landing past the last
    // decodable frame of a clip's source never prerolls - see
    // TODO.txt's mpegpsdemux dead-zone notes). Without recovery here,
    // every subsequent seek keeps landing on the same wedged state and
    // times out again too - one bad target turns into a cascade of
    // repeated freezes for the rest of a drag/scrub gesture. Re-seek
    // to m_lastGoodSeekMs - the last position a seek actually
    // confirmed via ASYNC_DONE - which is known-playable and pulls the
    // pipeline away from whatever position just failed (measured
    // live: this recovers in single-digit milliseconds). Falls back to
    // just re-asserting PAUSED (the same idempotent resync used
    // elsewhere in this file, e.g. "seek: waking up pipeline") only
    // when there's no known-good position yet to return to.
    // Capped: if the "last good" position itself no longer prerolls (the
    // timeline changed under it), re-seeking there would just time out
    // again, forever - after kMaxSeekRecoveries consecutive attempts fall
    // back to the plain PAUSED resync. A seek ASYNC_DONE resets the count.
    static constexpr int kMaxSeekRecoveries = 2;
    if (wasSeeking && engine->m_pipeline && !forcedTeardown) {
        if (engine->m_lastGoodSeekMs >= 0 && engine->m_seekRecoveryAttempts < kMaxSeekRecoveries) {
            ++engine->m_seekRecoveryAttempts;
            qDebug() << "asyncTimeoutCallback: seek never completed - recovering to last known-good position"
                      << engine->m_lastGoodSeekMs << "(attempt" << engine->m_seekRecoveryAttempts << ")";
            engine->seek(engine->m_lastGoodSeekMs);
        } else {
            if (engine->videoOutputReady()) {
                qDebug() << "asyncTimeoutCallback: seek never completed - forcing pipeline resync to PAUSED";
                gst_element_set_state(GST_ELEMENT(engine->m_pipeline), GST_STATE_PAUSED);
            } else {
                // PAUSED without a video sink would make GES autoplug its own
                // (stray window) - leave the pipeline parked.
                qDebug() << "asyncTimeoutCallback: seek never completed - video output not ready, not resyncing to PAUSED";
            }
        }
    }

    // A deferred commit must not simply be discarded here - retry it now
    // instead of silently dropping an edit that's already been applied to
    // the GES object graph (the UI would otherwise show a change the
    // pipeline never actually committed).
    if (engine->m_commitWanted && engine->m_timeline && !forcedTeardown) {
        qDebug() << "asyncTimeoutCallback: retrying deferred commit instead of dropping it";
        engine->m_commitWanted = false;
        engine->addAsyncTimeout("deferred commit (retry after timeout)", 3);
        ges_timeline_commit(engine->m_timeline);
    }

    // A decoder-rebuild's pending "resume playback" intent must not
    // survive an aborted rebuild - otherwise it can fire play() later on
    // a completely unrelated edit.
    engine->m_resumePlayAfterDecoderChange = false;
    engine->m_playRequestedAfterCommit = false;

    // If a commit was pending, complete it anyway so UI can proceed
    if (engine->m_commitPending) {
        qDebug() << "asyncTimeoutCallback: Commit was pending, emitting timelineReady for recovery";
        if (forcedTeardown) {
            engine->quiesceToReady("forced replay after commit watchdog");
            engine->m_commitWanted = false;   // the replayed rebuild commits everything
        }
        engine->m_commitPending = false;
        emit engine->timelineReady();
    }

    // A clip list deferred while waiting for that commit must not be
    // dropped on the floor - the QML model would then permanently disagree
    // with what the engine actually has. Safe to call from this GLib
    // timeout: m_asyncTimeoutId is already zeroed above, so the nested
    // addAsyncTimeout()/removeAsyncTimeout() inside the replayed setClips()
    // won't g_source_remove() the currently-executing source.
    engine->applyPendingClips();

    return FALSE;  // Ne ismétlődjön
}

void TimelineEngine::applyPendingClips()
{
    if (!m_hasPendingClips) return;
    m_hasPendingClips = false;
    m_pendingClipsTimer->stop();
    // Copy out BEFORE clearing the member: setClips() takes a
    // const QVariantList&, so passing m_pendingClips directly would hand
    // it a reference to the very member being cleared.
    const QVariantList pending = m_pendingClips;
    m_pendingClips.clear();
    qDebug() << "applyPendingClips: replaying deferred clip list with"
             << pending.size() << "clips";
    setClips(pending);
}

bool TimelineEngine::quiesceToReady(const char *reason)
{
    if (!m_pipeline) return false;
    GstState cur = GST_STATE_NULL, pend = GST_STATE_VOID_PENDING;
    gst_element_get_state(GST_ELEMENT(m_pipeline), &cur, &pend, 0);
    if (cur < GST_STATE_PAUSED && pend == GST_STATE_VOID_PENDING) return false;   // nothing streaming
    qWarning() << "quiesceToReady:" << reason << "- state" << cur << "pending" << pend << "-> READY";
    removeAsyncTimeout();
    drInvalidate();
    if (gst_element_set_state(GST_ELEMENT(m_pipeline), GST_STATE_READY) == GST_STATE_CHANGE_FAILURE) {
        qWarning() << "quiesceToReady: READY failed";
        return false;
    }
    m_restoreAfterQuiesce = true;
    return true;
}

void TimelineEngine::resetPlaybackStateForForcedStop()
{
    removeAsyncTimeout();
    drInvalidate();
    m_restoreAfterQuiesce = false;
    if (m_scrub) m_scrub->disarm();
    if (m_playing) {
        m_playing = false;
        m_positionTimer->stop();
        emit playingChanged();
    }
}

void TimelineEngine::emitPosition()
{
    // Pitivi pattern: ASYNC_DONE után frissíti a pozíciót
    if (!m_pipeline) return;

    gint64 pos = 0;
    if (gst_element_query_position(GST_ELEMENT(m_pipeline), GST_FORMAT_TIME, &pos)) {
        qint64 newPos = pos / GST_MSECOND;
        if (newPos >= 0) {
            m_position = newPos;
            emit positionChanged();
            qDebug() << "emitPosition: Position updated to" << m_position << "ms";
        }
    }
}

// =============================================================================
// Dead-reckoning playhead smoothing
// =============================================================================

void TimelineEngine::drResetAnchor(qint64 posMs)
{
    m_drAnchorPos = posMs;
    m_drAnchorTimeMs = m_drClock.elapsed();
    m_drActive = true;
}

void TimelineEngine::drInvalidate()
{
    m_drActive = false;
    m_drLastPipelinePos = -1;
    m_isSeeking = false;
    m_skipSmoothingTicks = 0;
}

qint64 TimelineEngine::drExpectedPosition() const
{
    if (!m_drActive) return m_position;
    qint64 elapsed = m_drClock.elapsed() - m_drAnchorTimeMs;
    return m_drAnchorPos + elapsed;  // rate = 1.0x
}

// =============================================================================
// Dynamic layer management
// =============================================================================

GESTrack *TimelineEngine::gesTrackOfType(GESTrackType type) const
{
    if (!m_timeline) return nullptr;
    GESTrack *found = nullptr;
    GList *tracks = ges_timeline_get_tracks(m_timeline);
    for (GList *t = tracks; t; t = t->next) {
        GESTrack *tr = GES_TRACK(t->data);
        if (tr->type == type) { found = tr; break; }
    }
    // The list holds a ref per track; the TIMELINE still owns every one
    // of them, so the borrowed pointer stays valid after this - same
    // pattern createPipeline() already uses when it sets "mixing".
    g_list_free_full(tracks, gst_object_unref);
    return found;
}

bool TimelineEngine::layerAudioInactive(const QString &trackId) const
{
    GESLayer *layer = m_layers.value(trackId, nullptr);
    GESTrack *at = gesTrackOfType(GES_TRACK_TYPE_AUDIO);
    if (!layer || !at || !trackId.startsWith(QLatin1Char('A'))) return false;
    return !ges_layer_get_active_for_track(layer, at);
}

void TimelineEngine::applyTrackActivation(const QString &trackId)
{
    GESLayer *layer = m_layers.value(trackId, nullptr);
    if (!layer) return;

    // Track id naming is the same convention ensureLayers() already
    // relies on for layer ordering: "V<n>" = video row, "A<n>" = audio row.
    const bool isVideo = trackId.startsWith(QLatin1Char('V'));
    const bool isAudio = trackId.startsWith(QLatin1Char('A'));
    if (!isVideo && !isAudio) return;

    GESTrack *track = gesTrackOfType(isVideo ? GES_TRACK_TYPE_VIDEO : GES_TRACK_TYPE_AUDIO);
    if (!track) return;

    // Audio rows are NEVER deactivated: a deactivated layer leaves its
    // clips' effect chains without a source in the NLE composition, and
    // with >= 2 top effects (every audio clip has the hidden pan + meter
    // pair) GStreamer fails with "NleComposition structure is not valid"
    // and the audio dies. Audio mute is done at the source instead, via
    // a (near-)zero source volume in applyTrackVolume().
    const bool active = isVideo ? !m_hiddenVideoTracks.contains(trackId) : true;

    // Restricted to this ONE track on purpose: passing NULL would mean
    // "all tracks", which would couple a video row's hide to the audio
    // of any combined A/V clip that happened to live on the same layer.
    GList *one = g_list_append(nullptr, track);
    // A hidden layer has to be pushed through an active -> inactive
    // TRANSITION every time, not just set to "inactive" again. GES only
    // propagates a layer's activeness to its track elements (sources AND
    // top effects) from the layer's "active-changed" signal, or for the
    // children a clip already has when ges_layer_add_asset() adds it. The
    // clip effects (ClipEffects::applyToClip) are added AFTER the clip is
    // in the layer, so on a rebuild of an already-hidden layer they keep
    // their default layer-active = TRUE while the source is inactive: the
    // orphaned effect then processes the track below it (a brightness 0
    // turns the visible track black), or, with no input left for it, the
    // composition fails with "NleComposition structure is not valid" and
    // the preview stops. Setting the same value again emits nothing, so
    // re-activate first; nothing is committed in between, so the
    // intermediate state never reaches the NLE composition.
    if (!active && !ges_layer_get_active_for_track(layer, track))
        ges_layer_set_active_for_tracks(layer, TRUE, one);
    gboolean ok = ges_layer_set_active_for_tracks(layer, active ? TRUE : FALSE, one);
    g_list_free(one);

    qDebug() << "applyTrackActivation:" << trackId
             << (isVideo ? "video" : "audio") << "active:" << active
             << "result:" << ok;
}

void TimelineEngine::reapplyAllTrackActivations()
{
    for (auto it = m_layers.constBegin(); it != m_layers.constEnd(); ++it)
        applyTrackActivation(it.key());
}

// Source volume of a muted audio track, see applyTrackVolume().
static constexpr double kMutedSourceVolume = 1e-6;

void TimelineEngine::applyTrackVolume(const QString &trackId)
{
    if (!trackId.startsWith(QLatin1Char('A'))) return;
    GESLayer *layer = m_layers.value(trackId, nullptr);
    if (!layer) return;
    // A muted track is NOT set to volume 0 / mute=true: GstVolume then flags
    // every buffer as GAP, and when every input of the audio mixer is GAP
    // (nothing audible at the playhead, e.g. a hole on the only unmuted
    // audio track) the audio path misbehaves as soon as real audio starts -
    // the position races through the next clips and the playhead stalls.
    // A level this low (-120 dB) is still real (non-GAP) data and inaudible.
    const double vol = m_mutedAudioTracks.contains(trackId)
        ? kMutedSourceVolume
        : qBound(0.0, m_trackVolumes.value(trackId, 1.0), 4.0);

    GList *clips = ges_layer_get_clips(layer);            // list of new refs
    for (GList *c = clips; c; c = c->next) {
        GESClip *clip = GES_CLIP(c->data);
        // Returns a new list of new refs. NULL track = any track.
        GList *elems = ges_clip_find_track_elements(clip, NULL, GES_TRACK_TYPE_AUDIO, GES_TYPE_AUDIO_SOURCE);
        for (GList *e = elems; e; e = e->next) {
            ges_timeline_element_set_child_properties(GES_TIMELINE_ELEMENT(e->data),
                                                      "volume", vol, "mute", FALSE, NULL);
        }
        g_list_free_full(elems, gst_object_unref);
    }
    g_list_free_full(clips, gst_object_unref);
}

void TimelineEngine::reapplyAllTrackVolumes()
{
    for (auto it = m_layers.constBegin(); it != m_layers.constEnd(); ++it)
        applyTrackVolume(it.key());
}

void TimelineEngine::setTrackVolume(const QString &trackId, double volume)
{
    volume = qBound(0.0, volume, 4.0);
    if (qFuzzyCompare(1.0 + m_trackVolumes.value(trackId, 1.0), 1.0 + volume)) return;
    m_trackVolumes.insert(trackId, volume);
    applyTrackVolume(trackId);
}

QVariantList TimelineEngine::trackMuteDebug(const QString &trackId) const
{
    QVariantList out;
    GESLayer *layer = m_layers.value(trackId, nullptr);
    if (!layer) return out;
    GList *clips = ges_layer_get_clips(layer);
    for (GList *c = clips; c; c = c->next) {
        GESClip *clip = GES_CLIP(c->data);
        GList *elems = ges_clip_find_track_elements(clip, NULL, GES_TRACK_TYPE_AUDIO, GES_TYPE_AUDIO_SOURCE);
        for (GList *e = elems; e; e = e->next) {
            gdouble v = 1.0;
            ges_timeline_element_get_child_properties(GES_TIMELINE_ELEMENT(e->data), "volume", &v, NULL);
            out.append(v <= kMutedSourceVolume * 2);
        }
        g_list_free_full(elems, gst_object_unref);
    }
    g_list_free_full(clips, gst_object_unref);
    return out;
}

double TimelineEngine::sourceDurationSeconds(const QString &path) const
{
    QString p = path;
    if (p.startsWith("file://")) p = p.mid(7);
    GESAsset *a = m_assetCache.value(p, nullptr);          // cache keeps its own ref
    if (!a || !GES_IS_URI_CLIP_ASSET(a)) return -1.0;
    GESUriClipAsset *ua = GES_URI_CLIP_ASSET(a);
    if (ges_uri_clip_asset_is_image(ua)) return std::numeric_limits<double>::infinity();
    GstClockTime d = ges_uri_clip_asset_get_max_duration(ua);
    if (!GST_CLOCK_TIME_IS_VALID(d) || d == 0) d = ges_uri_clip_asset_get_duration(ua);
    if (!GST_CLOCK_TIME_IS_VALID(d) || d == 0) return -1.0;
    return (double)d / GST_SECOND;
}

QVariantList TimelineEngine::gesLayoutDebug() const
{
    QVariantList out;
    for (auto it = m_layers.constBegin(); it != m_layers.constEnd(); ++it) {
        GList *clips = ges_layer_get_clips(it.value());   // new refs
        for (GList *c = clips; c; c = c->next) {
            GESTimelineElement *e = GES_TIMELINE_ELEMENT(c->data);
            QVariantMap m;
            m["layer"] = it.key();
            m["kind"] = GES_IS_TRANSITION_CLIP(c->data) ? "transition" : "clip";
            m["start"] = (double)GES_TIMELINE_ELEMENT_START(e) / GST_SECOND;
            m["inpoint"] = (double)GES_TIMELINE_ELEMENT_INPOINT(e) / GST_SECOND;
            m["duration"] = (double)GES_TIMELINE_ELEMENT_DURATION(e) / GST_SECOND;
            m["startNs"] = (qlonglong)GES_TIMELINE_ELEMENT_START(e);
            m["inpointNs"] = (qlonglong)GES_TIMELINE_ELEMENT_INPOINT(e);
            m["durationNs"] = (qlonglong)GES_TIMELINE_ELEMENT_DURATION(e);
            out.append(m);
        }
        g_list_free_full(clips, gst_object_unref);
    }
    std::sort(out.begin(), out.end(), [](const QVariant &a, const QVariant &b) {
        const QVariantMap x = a.toMap(), y = b.toMap();
        if (x["layer"].toString() != y["layer"].toString()) return x["layer"].toString() < y["layer"].toString();
        return x["start"].toDouble() < y["start"].toDouble();
    });
    return out;
}

QVariantList TimelineEngine::trackVolumeDebug(const QString &trackId) const
{
    QVariantList out;
    GESLayer *layer = m_layers.value(trackId, nullptr);
    if (!layer) return out;
    GList *clips = ges_layer_get_clips(layer);
    for (GList *c = clips; c; c = c->next) {
        GESClip *clip = GES_CLIP(c->data);
        GList *elems = ges_clip_find_track_elements(clip, NULL, GES_TRACK_TYPE_AUDIO, GES_TYPE_AUDIO_SOURCE);
        for (GList *e = elems; e; e = e->next) {
            gdouble v = 1.0;
            ges_timeline_element_get_child_properties(GES_TIMELINE_ELEMENT(e->data), "volume", &v, NULL);
            out.append(v);
        }
        g_list_free_full(elems, gst_object_unref);
    }
    g_list_free_full(clips, gst_object_unref);
    return out;
}

void TimelineEngine::applyTrackPan(const QString &trackId)
{
    if (!trackId.startsWith(QLatin1Char('A'))) return;
    GESLayer *layer = m_layers.value(trackId, nullptr);
    if (!layer) return;
    const gfloat pan = (gfloat) qBound(-1.0, m_trackPans.value(trackId, 0.0), 1.0);

    GList *clips = ges_layer_get_clips(layer);            // new refs
    for (GList *c = clips; c; c = c->next) {
        GESClip *clip = GES_CLIP(c->data);
        // ges_clip_get_top_effects() is (transfer full): every element is
        // a new reference, so the list has to be freed WITH unref (unlike
        // ClipEffects::findEffectById(), which only frees the container).
        GList *effects = ges_clip_get_top_effects(clip);
        for (GList *e = effects; e; e = e->next) {
            GESTimelineElement *el = GES_TIMELINE_ELEMENT(e->data);
            gboolean isPan = FALSE;
            if (!ges_meta_container_get_boolean(GES_META_CONTAINER(el), kPanMetaKey, &isPan)
                    || !isPan)
                continue;
            // "panorama" is a gfloat property (g_param_spec_float in
            // audiopanorama.c); GObject varargs collect a float from a double.
            ges_timeline_element_set_child_properties(el, "panorama", pan, NULL);
        }
        g_list_free_full(effects, gst_object_unref);
    }
    g_list_free_full(clips, gst_object_unref);
}

void TimelineEngine::reapplyAllTrackPans()
{
    for (auto it = m_layers.constBegin(); it != m_layers.constEnd(); ++it)
        applyTrackPan(it.key());
}

void TimelineEngine::setTrackPan(const QString &trackId, double pan)
{
    pan = qBound(-1.0, pan, 1.0);
    if (qFuzzyCompare(1.0 + m_trackPans.value(trackId, 0.0), 1.0 + pan)) return;
    m_trackPans.insert(trackId, pan);
    applyTrackPan(trackId);
}

QVariantList TimelineEngine::trackPanDebug(const QString &trackId) const
{
    QVariantList out;
    GESLayer *layer = m_layers.value(trackId, nullptr);
    if (!layer) return out;
    GList *clips = ges_layer_get_clips(layer);
    for (GList *c = clips; c; c = c->next) {
        GESClip *clip = GES_CLIP(c->data);
        GList *effects = ges_clip_get_top_effects(clip);   // transfer full
        for (GList *e = effects; e; e = e->next) {
            GESTimelineElement *el = GES_TIMELINE_ELEMENT(e->data);
            gboolean isPan = FALSE;
            if (!ges_meta_container_get_boolean(GES_META_CONTAINER(el), kPanMetaKey, &isPan)
                    || !isPan)
                continue;
            gfloat pan = 0.0f;
            ges_timeline_element_get_child_properties(el, "panorama", &pan, NULL);
            out.append((double) pan);
        }
        g_list_free_full(effects, gst_object_unref);
    }
    g_list_free_full(clips, gst_object_unref);
    return out;
}

void TimelineEngine::setMasterVolume(double volume)
{
    volume = qBound(0.0, volume, 4.0);
    m_masterVolume = volume;
    if (!m_pipeline) return;
    GstElement *af = nullptr;
    g_object_get(m_pipeline, "audio-filter", &af, nullptr);   // new ref or NULL
    if (!af) return;
    GstElement *mv = gst_bin_get_by_name(GST_BIN(af), "gcsmastervol");
    if (mv) { g_object_set(mv, "volume", volume, nullptr); gst_object_unref(mv); }
    gst_object_unref(af);
}

void TimelineEngine::commitTrackActivation()
{
    if (!m_timeline) return;

    // A commit is already in flight (or the pipeline is mid-async) -
    // piggyback on the engine's existing deferred-commit slot instead of
    // racing it; ASYNC_DONE / asyncTimeoutCallback() both honour it.
    if (m_commitPending || isBusyAsync()) {
        qDebug() << "commitTrackActivation: busy, deferring commit";
        m_commitWanted = true;
        return;
    }

    // While PAUSED nothing is pulling new frames, so the recomposed
    // output would only become visible at the next seek. Queue one at
    // the current position; onCommitCompleted() performs it.
    const bool wantRefreshSeek = !m_playing && m_totalDuration > 0
                                 && m_commitedSignalId != 0 && m_nextSeek < 0;
    if (wantRefreshSeek) { m_nextSeek = m_position; m_nextSeekScrub = false; }

    gboolean ok = ges_timeline_commit(m_timeline);
    qDebug() << "commitTrackActivation: ges_timeline_commit returned" << ok;

    if (!ok) {
        // Nothing actually changed in the GES graph, so no "commited"
        // signal is coming and the queued refresh seek would be stranded.
        if (wantRefreshSeek) {
            qint64 p = m_nextSeek;
            m_nextSeek = -1;
            if (p >= 0) seek(p);
        }
    }
}

void TimelineEngine::setTrackVideoHidden(const QString &trackId, bool hidden)
{
    if (hidden == m_hiddenVideoTracks.contains(trackId)) return;
    if (hidden) m_hiddenVideoTracks.insert(trackId);
    else        m_hiddenVideoTracks.remove(trackId);
    applyTrackActivation(trackId);
    commitTrackActivation();
}

// The mute property changes audio at the SOURCE, but up to ~1 s of already
// rendered audio sits in the pipeline's queues and would still be heard (or,
// when paused, played on resume). A flushing seek to the current position
// (what the old layer-deactivation commit did implicitly) drops it.
void TimelineEngine::flushAfterAudioMuteChange()
{
    if (!m_pipeline || m_totalDuration <= 0 || m_commitPending || isBusyAsync()) return;
    seek(m_position);
}

void TimelineEngine::setTrackAudioMuted(const QString &trackId, bool muted)
{
    if (muted == m_mutedAudioTracks.contains(trackId)) return;
    if (muted) m_mutedAudioTracks.insert(trackId);
    else       m_mutedAudioTracks.remove(trackId);
    // Live element property on the audio sources: no timeline commit needed.
    // applyTrackActivation() re-activates a layer that an older build /
    // earlier state had deactivated (and commits only in that case).
    const bool wasInactive = layerAudioInactive(trackId);
    if (wasInactive) {
        applyTrackActivation(trackId);
        commitTrackActivation();
    }
    applyTrackVolume(trackId);
    if (!wasInactive) flushAfterAudioMuteChange();
}

void TimelineEngine::setTrackStates(const QVariantList &tracks)
{
    QSet<QString> hidden, muted;
    QHash<QString, double> volumes, pans;
    for (const QVariant &v : tracks) {
        const QVariantMap m = v.toMap();
        const QString id = m.value("trackId").toString();
        if (id.isEmpty()) continue;
        if (m.value("hidden").toBool()) hidden.insert(id);
        if (m.value("muted").toBool())  muted.insert(id);
        volumes.insert(id, m.contains("volume") ? m.value("volume").toDouble() : 1.0);
        pans.insert(id, m.contains("pan") ? m.value("pan").toDouble() : 0.0);
    }

    const bool hiddenChanged = !(hidden == m_hiddenVideoTracks);
    const bool muteChanged   = !(muted == m_mutedAudioTracks);
    if (hiddenChanged || muteChanged) {
        m_hiddenVideoTracks = hidden;
        m_mutedAudioTracks  = muted;
        qDebug() << "setTrackStates: hidden video tracks:" << hidden
                 << "muted audio tracks:" << muted;
    }
    // Audio mute is a live source volume (applyTrackVolume below) and
    // needs no commit. Layer activation only changes for hidden VIDEO
    // rows - or when an audio layer is still deactivated and must be
    // re-activated (audio rows are always active now).
    bool audioLayerToReactivate = false;
    for (auto it = m_layers.constBegin(); it != m_layers.constEnd(); ++it)
        if (layerAudioInactive(it.key())) { audioLayerToReactivate = true; break; }
    if (hiddenChanged || audioLayerToReactivate) {
        reapplyAllTrackActivations();
        commitTrackActivation();
    }

    // Volume/pan are applied regardless of whether hide/mute changed (a
    // load with unchanged activation flags still has to restore them).
    m_trackVolumes = volumes;
    reapplyAllTrackVolumes();
    m_trackPans = pans;
    reapplyAllTrackPans();

    if (muteChanged && !hiddenChanged && !audioLayerToReactivate)
        flushAfterAudioMuteChange();
}

QVariantMap TimelineEngine::trackActivationDebug() const
{
    QVariantMap out;
    GESTrack *vt = gesTrackOfType(GES_TRACK_TYPE_VIDEO);
    GESTrack *at = gesTrackOfType(GES_TRACK_TYPE_AUDIO);
    for (auto it = m_layers.constBegin(); it != m_layers.constEnd(); ++it) {
        QVariantMap one;
        one["priority"] = (int)ges_layer_get_priority(it.value());
        if (vt) one["videoActive"] = (bool)ges_layer_get_active_for_track(it.value(), vt);
        if (at) {
            const bool layerFlag = (bool)ges_layer_get_active_for_track(it.value(), at);
            one["audioLayerActive"] = layerFlag;   // real GES layer flag
            // "audible": audio rows are muted at the source, not deactivated
            one["audioActive"] = it.key().startsWith(QLatin1Char('A'))
                                     ? (layerFlag && !m_mutedAudioTracks.contains(it.key()))
                                     : layerFlag;
        }
        out[it.key()] = one;
    }
    return out;
}

void TimelineEngine::ensureLayers(const QStringList &trackIds)
{
    if (!m_timeline) return;

    // Szétválogatjuk video (V*) és audio (A*) trackId-kat
    QStringList videoIds, audioIds;
    for (const QString &id : trackIds) {
        if (id.startsWith("V")) videoIds.append(id);
        else if (id.startsWith("A")) audioIds.append(id);
    }

    // Video: csökkenő szám = alacsonyabb priority (felül van)
    // pl. V3(pri=0), V2(pri=1), V1(pri=2)
    std::sort(videoIds.begin(), videoIds.end(), [](const QString &a, const QString &b) {
        return a.mid(1).toInt() > b.mid(1).toInt();
    });
    // Audio: növekvő szám = növekvő priority (video alatt)
    // pl. A1(pri=3), A2(pri=4), A3(pri=5)
    std::sort(audioIds.begin(), audioIds.end(), [](const QString &a, const QString &b) {
        return a.mid(1).toInt() < b.mid(1).toInt();
    });

    QStringList orderedIds = videoIds + audioIds;

    // Felesleges layerek törlése (amelyek nincsenek az orderedIds-ben)
    QStringList toRemove;
    for (auto it = m_layers.begin(); it != m_layers.end(); ++it) {
        if (!orderedIds.contains(it.key())) {
            toRemove.append(it.key());
        }
    }
    for (const QString &id : toRemove) {
        GESLayer *layer = m_layers.take(id);
        // Klipek törlése a layerről mielőtt eltávolítjuk
        GList *layerClips = ges_layer_get_clips(layer);
        for (GList *l = layerClips; l != NULL; l = l->next) {
            ges_layer_remove_clip(layer, GES_CLIP(l->data));
        }
        g_list_free_full(layerClips, gst_object_unref);
        ges_timeline_remove_layer(m_timeline, layer);
        qDebug() << "ensureLayers: Removed layer" << id;
    }

    // Hiányzó layerek létrehozása
    for (const QString &id : orderedIds) {
        if (!m_layers.contains(id)) {
            GESLayer *layer = ges_timeline_append_layer(m_timeline);
            m_layers[id] = layer;
            qDebug() << "ensureLayers: Created layer" << id;
        }
    }

    // Prioritások újraszámolása az aktuális sorrend alapján
    for (int i = 0; i < orderedIds.size(); i++) {
        GESLayer *layer = m_layers.value(orderedIds[i]);
        if (layer) {
            ges_layer_set_priority(layer, i);
        }
    }

    // A layer created just now starts out active for every track, so the
    // remembered hide/mute state has to be pushed back onto it. No commit
    // here on purpose: ensureLayers() is only ever called from
    // createPipeline() (no timeline attached yet) and from setClips()
    // (which commits a few lines later anyway).
    reapplyAllTrackActivations();
    reapplyAllTrackVolumes();
    reapplyAllTrackPans();

    qDebug() << "ensureLayers: Active layers:" << orderedIds << "total:" << m_layers.size();
}
