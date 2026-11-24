#include "MetadataExtractor.h"
#include <QDebug>
#include <QUrl>
#include <QFileInfo>
#include <gst/video/video.h>
#include <gst/pbutils/pbutils.h>
#include <thread>

namespace {
// Fire-and-forget teardown for a pipeline we only have evidence is
// wedged (watchdog timeout, or abandoned via cancelAllPending()). Takes
// sole ownership of `pipeline` - the caller must already have removed
// the bus watch and dropped its bus ref, and must never touch
// `pipeline` again after calling this. Touches nothing else (no Qt
// objects, no MetadataExtractor members), so no synchronization is
// needed and this introduces no new data race.
//
// A genuinely stuck source (e.g. blocked in a network-mount read) can
// make gst_element_set_state(..., GST_STATE_NULL) itself block for a
// long time - doing that on the GUI thread would freeze the whole app
// on exactly the path meant to recover from a stuck extraction.
// Deliberately std::thread + detach(), not QThreadPool: QThreadPool's
// destructor calls waitForDone(), which would just relocate the same
// blocking wait to application shutdown.
//
// Known accepted risk: on a normal (non-forced) quit, main.cpp calls
// gst_deinit() after the event loop returns, which could in principle
// run concurrently with a still-detached teardown thread. gst_deinit()
// is a leak-check convenience, not a correctness requirement, and this
// requires a wedged pipeline at the exact moment of a clean quit -
// judged acceptable rather than adding a refcount-and-wait mechanism
// that would defeat the point of detaching in the first place.
void teardownPipelineDetached(GstElement *pipeline) {
    std::thread([pipeline]() {
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(pipeline);
    }).detach();
}
} // namespace

MetadataExtractor::MetadataExtractor(QObject *parent)
    : QObject(parent)
{
    // GStreamer is already initialized by VideoEngine/TimelineEngine
}

MetadataExtractor::~MetadataExtractor()
{
    m_interactiveQueue.clear();
    m_backgroundQueue.clear();

    // Clean up any remaining contexts. The app is quitting, but a
    // blocking teardown here is still the wrong trade - a wedged
    // pipeline (the case this most needs to handle) would freeze the
    // quit sequence with no explanation, and BackendManager::forceQuit()
    // already resorts to _exit(0) because lingering GLib sources were
    // observed preventing a clean exit elsewhere; adding a multi-minute
    // NFS-timeout wait to this path would only make that worse. On the
    // _exit(0) path these detached threads are simply killed, which is
    // fine - nothing downstream depends on their completion.
    for (auto it = m_contexts.begin(); it != m_contexts.end(); ++it) {
        if (it.value() && it.value()->timeout) {
            it.value()->timeout->stop();
            delete it.value()->timeout;
        }
        if (it.value() && it.value()->bus) {
            gst_bus_remove_watch(it.value()->bus);
            gst_object_unref(it.value()->bus);
        }
        delete it.value();
        if (it.key()) {
            teardownPipelineDetached(it.key());
        }
    }
    m_contexts.clear();
}

void MetadataExtractor::extractMetadata(const QString &filePath, const QString &itemId, Priority priority)
{
    // Dedupe: a second request for an itemId that's already running (or
    // already queued) would just duplicate work and burn a concurrency
    // slot for no benefit - the first one's result goes to the same
    // itemId either way. This matters more than it used to: the always-
    // visible refresh icon in ProjectBinPanel.qml gives no "busy"
    // feedback yet, so a user clicking it a few times while waiting is
    // the expected case, not an edge case.
    if (isExtractionActive(itemId)) {
        qDebug() << "MetadataExtractor: extraction already in flight for" << itemId << "- dropping duplicate request";
        return;
    }

    if (priority == Priority::Interactive) {
        // Already queued at Interactive - nothing to do. Without this
        // check, two Interactive requests for the same item arriving
        // while both concurrency slots are busy (so isExtractionActive()
        // above is still false) would both get queued, and the second
        // would run a fully redundant extraction once the first starts.
        for (const PendingExtraction &req : m_interactiveQueue) {
            if (req.itemId == itemId) {
                pumpQueue();
                return;
            }
        }
        // If a lower-priority (Background) request for the same item is
        // still waiting, promote it instead of queuing a second entry -
        // e.g. the user clicks "refresh" on an item while a large
        // project reopen's background revalidation sweep hasn't reached
        // it yet. Without this, the user-initiated request would queue
        // behind the ENTIRE background backlog, defeating the point of
        // having two priority tiers at all.
        QQueue<PendingExtraction> remaining;
        bool found = false;
        for (const PendingExtraction &req : m_backgroundQueue) {
            if (!found && req.itemId == itemId) { found = true; continue; }
            remaining.enqueue(req);
        }
        m_backgroundQueue = remaining;
    } else if (priority == Priority::Background) {
        // Already queued at Interactive (higher) priority - nothing to do,
        // don't add a redundant Background entry behind it.
        for (const PendingExtraction &req : m_interactiveQueue) {
            if (req.itemId == itemId) {
                pumpQueue();
                return;
            }
        }
        // Already queued at Background too - same, avoid a duplicate entry.
        for (const PendingExtraction &req : m_backgroundQueue) {
            if (req.itemId == itemId) {
                pumpQueue();
                return;
            }
        }
    }

    // Only enqueue here - never create a pipeline directly. This is what
    // makes the concurrency limit apply uniformly no matter which caller
    // reaches this (a single ProjectBinModel::addFile(), a bulk multi-file
    // drag calling it once per file back-to-back, or loadFromJson()'s
    // cache-miss sweep): every path funnels through the same queue/limit,
    // with no separate throttling logic anywhere else.
    if (priority == Priority::Interactive) {
        m_interactiveQueue.enqueue({filePath, itemId});
    } else {
        m_backgroundQueue.enqueue({filePath, itemId});
    }
    pumpQueue();
}

void MetadataExtractor::cancelPending(const QString &itemId)
{
    QQueue<PendingExtraction> filteredInteractive;
    for (const PendingExtraction &req : m_interactiveQueue) {
        if (req.itemId != itemId) filteredInteractive.enqueue(req);
    }
    m_interactiveQueue = filteredInteractive;

    QQueue<PendingExtraction> filteredBackground;
    for (const PendingExtraction &req : m_backgroundQueue) {
        if (req.itemId != itemId) filteredBackground.enqueue(req);
    }
    m_backgroundQueue = filteredBackground;
}

void MetadataExtractor::cancelAllPending()
{
    m_interactiveQueue.clear();
    m_backgroundQueue.clear();

    // Also abandon anything already in flight - without this, an
    // extraction for an item belonging to a project/bin that was just
    // torn down (loadFromJson()/clear() replacing m_rootItem) keeps a
    // real pipeline running and keeps occupying one of only
    // m_maxConcurrentExtractions slots, for up to 15s, delaying the
    // freshly-loaded project's own extractions for no benefit (its
    // result will just be dropped by ProjectBinModel::findItemById()
    // missing). Async teardown since an abandoned mid-preroll pipeline
    // is exactly the kind most likely to still be blocked on I/O.
    const QList<GstElement*> live = m_contexts.keys();
    for (GstElement *pipeline : live) {
        finishExtraction(pipeline, /*asyncTeardown=*/true);
    }
}

MetadataExtractor::ExtractionContext *MetadataExtractor::contextForId(quint64 id, GstElement **outPipeline) const
{
    for (auto it = m_contexts.begin(); it != m_contexts.end(); ++it) {
        if (it.value() && it.value()->extractionId == id) {
            if (outPipeline) *outPipeline = it.key();
            return it.value();
        }
    }
    return nullptr;
}

bool MetadataExtractor::isExtractionActive(const QString &itemId) const
{
    for (auto it = m_contexts.begin(); it != m_contexts.end(); ++it) {
        if (it.value() && it.value()->itemId == itemId) return true;
    }
    return false;
}

void MetadataExtractor::pumpQueue()
{
    while (m_contexts.size() < m_maxConcurrentExtractions &&
           (!m_interactiveQueue.isEmpty() || !m_backgroundQueue.isEmpty())) {
        PendingExtraction req = !m_interactiveQueue.isEmpty()
            ? m_interactiveQueue.dequeue()
            : m_backgroundQueue.dequeue();
        startExtraction(req.filePath, req.itemId);
    }
}

void MetadataExtractor::startExtraction(const QString &filePath, const QString &itemId)
{
    // Create temporary pipeline for metadata extraction
    GstElement *pipeline = gst_element_factory_make("playbin", nullptr);
    if (!pipeline) {
        qCritical() << "MetadataExtractor: Failed to create pipeline";
        emit extractionFailed(itemId, "Failed to create pipeline");
        return;
    }

    // Create fake video and audio sinks to avoid displaying video (prevents black flash)
    GstElement *fakeVideoSink = gst_element_factory_make("fakesink", nullptr);
    GstElement *fakeAudioSink = gst_element_factory_make("fakesink", nullptr);

    if (fakeVideoSink && fakeAudioSink) {
        // g_object_set() on these GObject-typed properties sinks each
        // sink's floating ref - that's why there's no unref here on
        // success. The failure branch below has no such sink, so an
        // element that WAS created there must be unreffed explicitly or
        // it leaks with its floating ref intact.
        g_object_set(G_OBJECT(pipeline), "video-sink", fakeVideoSink, nullptr);
        g_object_set(G_OBJECT(pipeline), "audio-sink", fakeAudioSink, nullptr);
    } else {
        qWarning() << "MetadataExtractor: fakesink unavailable; extraction may flash a video window";
        if (fakeVideoSink) gst_object_unref(fakeVideoSink);
        if (fakeAudioSink) gst_object_unref(fakeAudioSink);
    }

    // Create context to track this extraction
    ExtractionContext *context = new ExtractionContext;
    context->itemId = itemId;
    context->filePath = filePath;
    context->extractor = this;
    const quint64 extractionId = m_nextExtractionId++;
    context->extractionId = extractionId;
    m_contexts[pipeline] = context;

    // Set URI. filePath coming from QML (e.g. a FolderListModel fileURL)
    // is already a correctly percent-encoded "file://" URI; a plain
    // filesystem path is not encoded at all, so build one with
    // QUrl::fromLocalFile() rather than hand-concatenating "file://" -
    // the latter produces an invalid, unencoded URI for any path
    // containing a space or non-ASCII character, and playbin then fails
    // to even start (an obscure GStreamer error, not an obviously
    // path-related one).
    // Same "is this already a URI" check as ProjectBinModel.cpp's
    // toLocalPath() (case-insensitive "file:" prefix) - kept consistent
    // so the two don't disagree on an edge case like "FILE:///..." or
    // "file:/one-slash/...".
    QString uri;
    if (filePath.startsWith(QLatin1String("file:"), Qt::CaseInsensitive)) {
        uri = filePath;
    } else {
        uri = QUrl::fromLocalFile(filePath).toString();
    }
    g_object_set(G_OBJECT(pipeline), "uri", uri.toUtf8().constData(), NULL);

    // Setup bus callback. The ref returned by gst_pipeline_get_bus() is
    // kept (not immediately unreffed) and stored in the context so the
    // watch can be explicitly removed before the context is deleted -
    // previously this watch was never removed at all, leaving its
    // GSource alive (and liable to invoke busCallback with a dangling
    // ExtractionContext*) for as long as the pipeline's bus kept emitting
    // messages after extraction had already "finished" - e.g. the
    // state-change messages produced by the pipeline's own GST_STATE_NULL
    // teardown right after processMetadata() ran.
    GstBus *bus = gst_pipeline_get_bus(GST_PIPELINE(pipeline));
    context->bus = bus;
    gst_bus_add_watch(bus, busCallback, context);

    // Watchdog: some failure modes (stalled network mount, an exotic
    // container) leave playbin neither reaching ASYNC_DONE nor posting
    // ERROR. Without this, that request would permanently occupy one of
    // only m_maxConcurrentExtractions slots, eventually stalling every
    // later-queued extraction - a brand new failure mode introduced by
    // adding the bounded queue, which has to be paid for here.
    //
    // Captures extractionId, NOT the pipeline/context pointer: both are
    // freed by finishExtraction() and reliably reused by the very next
    // extraction's allocations (same-size alloc right after a same-size
    // free), so a pointer captured here could, by the time this timer
    // fires, identify a completely different extraction that just
    // happens to have landed at the same address - acting on it would
    // silently corrupt or kill the wrong one. extractionId is never
    // reused, so contextForId() returning non-null is a real liveness
    // guarantee.
    QTimer *timeout = new QTimer(this);
    timeout->setSingleShot(true);
    timeout->setInterval(15000);
    connect(timeout, &QTimer::timeout, this, [this, extractionId]() {
        GstElement *pipeline = nullptr;
        ExtractionContext *ctx = contextForId(extractionId, &pipeline);
        if (!ctx) return; // already finished by another path
        // Copy before finishExtraction() deletes ctx, and emit AFTER
        // teardown - see onExtractionError()'s matching comment.
        const QString itemId = ctx->itemId;
        qWarning() << "MetadataExtractor: extraction timed out for" << itemId;
        finishExtraction(pipeline, /*asyncTeardown=*/true);
        emit extractionFailed(itemId, "Metadata extraction timed out");
    });
    context->timeout = timeout;
    timeout->start();

    // Start pipeline in PAUSED state to extract metadata
    GstStateChangeReturn ret = gst_element_set_state(pipeline, GST_STATE_PAUSED);
    if (ret == GST_STATE_CHANGE_FAILURE) {
        qCritical() << "MetadataExtractor: Failed to set pipeline to PAUSED";
        finishExtraction(pipeline);
        emit extractionFailed(itemId, "Failed to start extraction");
    }
}

void MetadataExtractor::finishExtraction(GstElement *pipeline, bool asyncTeardown)
{
    // No-op if already torn down - the single idempotency check that
    // makes it safe for success, GStreamer-error, PAUSED-failure, and
    // watchdog-timeout paths to all call this without coordinating with
    // each other (GStreamer can e.g. post an ERROR after ASYNC_DONE
    // already completed, or the watchdog can race a just-arrived result).
    if (!m_contexts.contains(pipeline)) return;

    ExtractionContext *context = m_contexts.take(pipeline);

    if (context->timeout) {
        context->timeout->stop();
        context->timeout->deleteLater();
        context->timeout = nullptr;
    }

    // Bus watch removed BEFORE touching pipeline state - removing it
    // after would let the state-change messages produced by the
    // GST_STATE_NULL transition below dispatch into this
    // about-to-be-freed context.
    if (context->bus) {
        gst_bus_remove_watch(context->bus);
        gst_object_unref(context->bus);
        context->bus = nullptr;
    }

    delete context;

    if (asyncTeardown) {
        teardownPipelineDetached(pipeline);
    } else {
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(pipeline);
    }

    // Deferred, not called synchronously here: this function can be
    // invoked from the middle of the ASYNC_DONE handler's reverse lookup
    // over m_contexts (see busCallback), and starting a new extraction
    // (which inserts into m_contexts) from inside that iteration would be
    // fragile even though the current call sites happen to not do it today.
    QMetaObject::invokeMethod(this, [this]() { pumpQueue(); }, Qt::QueuedConnection);
}

void MetadataExtractor::onExtractionError(GstElement *pipeline, const QString &itemId, const QString &error)
{
    // Defensive only: today's single caller (busCallback's ERROR lambda)
    // already resolves `pipeline` from a live m_contexts entry via
    // contextForId() in that same synchronous call, so this can't
    // actually be false right now. It is NOT, and must not be treated
    // as, protection against a stale pointer arriving across an event-
    // loop boundary - pipeline/context addresses are reused by the next
    // extraction (see ExtractionContext::extractionId). Any future
    // caller reached via a queued connection must resolve by
    // extractionId first, the same way busCallback does, not pass a
    // bare GstElement* through.
    if (!m_contexts.contains(pipeline)) return;
    // Copy before finishExtraction() - itemId is a reference into the
    // context it's about to delete, and emitting AFTER teardown (not
    // before) means any handler reacting to the failure (e.g. by
    // requesting a re-extraction) sees isExtractionActive(itemId) as
    // already false, instead of racing the still-"active" old one.
    const QString itemIdCopy = itemId;
    finishExtraction(pipeline);
    emit extractionFailed(itemIdCopy, error);
}

void MetadataExtractor::processMetadata(GstElement *pipeline, const QString &itemId)
{
    VideoMetadata metadata;

    // Extract duration
    gint64 duration = 0;
    qint64 durationMs = 0;
    if (gst_element_query_duration(pipeline, GST_FORMAT_TIME, &duration)) {
        durationMs = duration / GST_MSECOND;
        metadata.duration = formatDuration(durationMs);
    }

    // Extract video properties
    gint width = 0, height = 0;
    gint fps_num = 0, fps_den = 1;

    // Get video sink pad to query capabilities
    GstElement *videoSink = nullptr;
    g_object_get(G_OBJECT(pipeline), "video-sink", &videoSink, NULL);

    if (!videoSink) {
        // If no custom sink, get the auto-created one
        g_signal_emit_by_name(pipeline, "get-video-pad", 0, &videoSink);
    }

    if (videoSink) {
        GstPad *pad = gst_element_get_static_pad(videoSink, "sink");
        if (pad) {
            GstCaps *caps = gst_pad_get_current_caps(pad);
            if (caps) {
                GstStructure *structure = gst_caps_get_structure(caps, 0);
                if (structure) {
                    gst_structure_get_int(structure, "width", &width);
                    gst_structure_get_int(structure, "height", &height);
                    gst_structure_get_fraction(structure, "framerate", &fps_num, &fps_den);
                }
                gst_caps_unref(caps);
            }
            gst_object_unref(pad);
        }
        gst_object_unref(videoSink);
    }

    // Set resolution
    if (width > 0 && height > 0) {
        metadata.resolution = QString("%1x%2").arg(width).arg(height);

        // Calculate aspect ratio using GCD
        auto gcd = [](int a, int b) {
            while (b != 0) {
                int temp = b;
                b = a % b;
                a = temp;
            }
            return a;
        };
        int divisor = gcd(width, height);
        metadata.aspectRatio = QString("%1:%2").arg(width / divisor).arg(height / divisor);
    }

    // Set frame rate
    if (fps_num > 0 && fps_den > 0) {
        double fps = static_cast<double>(fps_num) / fps_den;
        metadata.frameRate = QString::number(fps, 'f', 2) + " fps";
    }

    // Extract codec information and other metadata from tags
    GstTagList *tags = nullptr;
    g_signal_emit_by_name(pipeline, "get-video-tags", 0, &tags);

    if (tags) {
        gchar *codec = nullptr;

        // Video codec
        if (gst_tag_list_get_string(tags, GST_TAG_VIDEO_CODEC, &codec)) {
            metadata.videoCodec = QString::fromUtf8(codec);
            g_free(codec);
            codec = nullptr;
        }

        // Encoder
        if (gst_tag_list_get_string(tags, GST_TAG_ENCODER, &codec)) {
            metadata.encoder = QString::fromUtf8(codec);
            g_free(codec);
            codec = nullptr;
        }

        // Bitrate
        guint bitrate = 0;
        if (gst_tag_list_get_uint(tags, GST_TAG_BITRATE, &bitrate)) {
            metadata.bitrate = QString::number(bitrate / 1000) + " kbps";
        }

        // Creation time
        GDate *date = nullptr;
        if (gst_tag_list_get_date(tags, GST_TAG_DATE, &date)) {
            if (g_date_valid(date)) {
                metadata.creationTime = QString("%1-%2-%3")
                    .arg(g_date_get_year(date))
                    .arg(g_date_get_month(date), 2, 10, QChar('0'))
                    .arg(g_date_get_day(date), 2, 10, QChar('0'));
            }
            g_date_free(date);
        }

        gst_tag_list_unref(tags);
    }

    // Many MP4/MOV files carry no GST_TAG_BITRATE. Fall back to the average
    // over the whole file (size * 8 / duration - includes the audio track, so
    // it slightly overestimates the video stream; good enough as a render
    // bitrate hint). This always runs on the item's own (original) file.
    if (metadata.bitrate.isEmpty() && durationMs > 0
            && !metadata.resolution.isEmpty() && !metadata.frameRate.isEmpty()) {
        const auto ctxIt = m_contexts.constFind(pipeline);
        if (ctxIt != m_contexts.constEnd() && *ctxIt) {
            QString path = (*ctxIt)->filePath;
            if (path.startsWith(QLatin1String("file://"))) path = QUrl(path).toLocalFile();
            const qint64 bytes = QFileInfo(path).size();
            if (bytes > 0) {
                metadata.bitrate = QString::number(qint64(double(bytes) * 8.0 / double(durationMs))) + " kbps";
            }
        }
    }

    // Extract audio codec
    g_signal_emit_by_name(pipeline, "get-audio-tags", 0, &tags);
    if (tags) {
        gchar *codec = nullptr;
        if (gst_tag_list_get_string(tags, GST_TAG_AUDIO_CODEC, &codec)) {
            metadata.audioCodec = QString::fromUtf8(codec);
            g_free(codec);
        }
        gst_tag_list_unref(tags);
    }

    // Whether the file actually has an audio stream. GST_TAG_AUDIO_CODEC
    // (used for metadata.audioCodec above, display-only) is NOT a
    // reliable "has audio" signal - some demuxer/codec combinations
    // (confirmed: HEVC+AAC in an mp4 via qtdemux) never populate that
    // specific tag even though the file genuinely has an audio track.
    // playbin's "n-audio" property reflects the actual number of
    // negotiated audio streams instead, independent of tag presence.
    gint nAudio = 0;
    g_object_get(G_OBJECT(pipeline), "n-audio", &nAudio, NULL);
    metadata.hasAudio = nAudio > 0;

    // Copy before finishExtraction() - itemId is a reference into the
    // context it's about to delete. Emitting AFTER teardown (not before)
    // means a handler reacting to this result (e.g. requesting another
    // extraction for some reason) sees isExtractionActive(itemId) as
    // already false rather than racing the still-"active" old one.
    const QString itemIdCopy = itemId;
    finishExtraction(pipeline);

    // Emit the extracted metadata
    emit metadataExtracted(itemIdCopy,
                          metadata.duration,
                          metadata.resolution,
                          metadata.frameRate,
                          metadata.aspectRatio,
                          metadata.videoCodec,
                          metadata.audioCodec,
                          metadata.hasAudio,
                          metadata.bitrate,
                          metadata.encoder,
                          metadata.creationTime);
}

QString MetadataExtractor::formatDuration(qint64 durationMs)
{
    int hours = durationMs / 3600000;
    int minutes = (durationMs % 3600000) / 60000;
    int seconds = (durationMs % 60000) / 1000;
    int milliseconds = (durationMs % 1000) / 10; // Two decimal places

    return QString("%1:%2:%3.%4")
        .arg(hours, 2, 10, QChar('0'))
        .arg(minutes, 2, 10, QChar('0'))
        .arg(seconds, 2, 10, QChar('0'))
        .arg(milliseconds, 2, 10, QChar('0'));
}

gboolean MetadataExtractor::busCallback(GstBus *bus, GstMessage *msg, gpointer data)
{
    Q_UNUSED(bus);
    ExtractionContext *context = static_cast<ExtractionContext*>(data);
    // Read synchronously here, while context is guaranteed alive (this
    // function only runs while the bus watch is still installed, and the
    // watch is always removed before the context is freed). The deferred
    // lambdas below carry only `extractor` and the opaque `extractionId`
    // - NOT the `context`/pipeline pointers themselves. Pointer identity
    // is not a safe key across a Qt::QueuedConnection: finishExtraction()
    // deletes the context and unrefs the pipeline, and the very next
    // extraction's `new ExtractionContext`/gst_element_factory_make(
    // "playbin") calls reliably get served the same, just-freed
    // addresses (same-size allocation right after a same-size free). A
    // pending lambda holding one of those addresses would then match a
    // DIFFERENT, newer extraction and act on it - wrong item gets wrong
    // metadata/error, or a freshly-started pipeline gets torn down
    // moments after starting. extractionId is assigned once in
    // startExtraction() and never reused, so contextForId() finding it
    // is a real liveness guarantee, unlike a pointer comparison.
    MetadataExtractor *extractor = context->extractor;
    const quint64 extractionId = context->extractionId;

    switch (GST_MESSAGE_TYPE(msg)) {
    case GST_MESSAGE_ASYNC_DONE:
        // Pipeline is ready in PAUSED state, extract metadata
        QMetaObject::invokeMethod(extractor,
                                 [extractor, extractionId]() {
                                     GstElement *pipeline = nullptr;
                                     ExtractionContext *ctx = extractor->contextForId(extractionId, &pipeline);
                                     if (!ctx) return; // already finished by another path
                                     extractor->processMetadata(pipeline, ctx->itemId);
                                 },
                                 Qt::QueuedConnection);
        break;

    case GST_MESSAGE_ERROR: {
        GError *err;
        gchar *debug;
        gst_message_parse_error(msg, &err, &debug);
        qCritical() << "MetadataExtractor Error:" << err->message;

        QString errorMsg = QString::fromUtf8(err->message);
        QMetaObject::invokeMethod(extractor,
                                 [extractor, extractionId, errorMsg]() {
                                     GstElement *pipeline = nullptr;
                                     ExtractionContext *ctx = extractor->contextForId(extractionId, &pipeline);
                                     if (!ctx) return; // already finished by another path
                                     extractor->onExtractionError(pipeline, ctx->itemId, errorMsg);
                                 },
                                 Qt::QueuedConnection);

        g_error_free(err);
        g_free(debug);
        break;
    }

    default:
        break;
    }

    return TRUE;
}
