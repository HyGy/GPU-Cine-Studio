#ifndef METADATAEXTRACTOR_H
#define METADATAEXTRACTOR_H

#include <QObject>
#include <QString>
#include <QMap>
#include <QQueue>
#include <QTimer>
#include <gst/gst.h>

class MetadataExtractor : public QObject
{
    Q_OBJECT

public:
    explicit MetadataExtractor(QObject *parent = nullptr);
    ~MetadataExtractor();

    struct VideoMetadata {
        QString duration;
        QString resolution;
        QString frameRate;
        QString aspectRatio;
        QString videoCodec;
        QString audioCodec;
        bool hasAudio = false;
        QString bitrate;
        QString encoder;
        QString creationTime;
    };

    // Interactive: the file was just explicitly added by the user (single
    // add or part of a bulk drag) - jumps ahead of any still-queued
    // Background work so a drop onto the timeline moments later doesn't
    // race a large backlog (see TimelineDropArea's live itemHasAudio()
    // lookup, which depends on this finishing promptly).
    // Background: re-validating items restored from a saved project.
    enum class Priority { Interactive, Background };
    Q_ENUM(Priority)

    Q_INVOKABLE void extractMetadata(const QString &filePath, const QString &itemId,
                                      Priority priority = Priority::Interactive);

    // Drops queued (not yet started) requests for this item/all items -
    // used when an item is removed from the bin, or the whole bin is
    // about to be torn down (project close/switch), so stale requests
    // don't keep extracting into a bin that no longer exists. In-flight
    // extractions are left to finish; their result is simply ignored by
    // ProjectBinModel if the item is already gone (findItemById() miss).
    void cancelPending(const QString &itemId);
    void cancelAllPending();

signals:
    void metadataExtracted(const QString &itemId,
                          const QString &duration,
                          const QString &resolution,
                          const QString &frameRate,
                          const QString &aspectRatio,
                          const QString &videoCodec,
                          const QString &audioCodec,
                          bool hasAudio,
                          const QString &bitrate,
                          const QString &encoder,
                          const QString &creationTime);
    void extractionFailed(const QString &itemId, const QString &error);

private:
    void startExtraction(const QString &filePath, const QString &itemId);
    void pumpQueue();
    // The one and only teardown path for an ExtractionContext - every
    // exit (success, GStreamer error, PAUSED-failure, watchdog timeout)
    // must go through this, in this order: stop/remove the bus watch
    // BEFORE touching pipeline state (removing it after would let the
    // state-change messages produced by the NULL transition below
    // dispatch into an about-to-be-freed context), then delete the
    // context, then tear down the pipeline, then let the queue advance.
    // A second, independently-written cleanup path is exactly how the
    // GST_MESSAGE_ERROR branch ended up never cleaning up at all before.
    //
    // asyncTeardown: false (default) does the pipeline's GST_STATE_NULL
    // transition synchronously, right here - fine for a pipeline that
    // just normally finished (ASYNC_DONE/ERROR/PAUSED-failure), since it
    // returns promptly. true hands the pipeline off to a detached thread
    // instead - required for the watchdog-timeout and cancel-all-pending
    // paths, where the pipeline is only being torn down BECAUSE we have
    // evidence it's wedged (e.g. a source blocked in a network-mount
    // read): a synchronous GST_STATE_NULL there can itself block for the
    // mount's timeout, freezing the whole UI on the one path meant to
    // recover from exactly that.
    void finishExtraction(GstElement *pipeline, bool asyncTeardown = false);
    void onExtractionError(GstElement *pipeline, const QString &itemId, const QString &error);
    void processMetadata(GstElement *pipeline, const QString &itemId);
    QString formatDuration(qint64 durationMs);
    static gboolean busCallback(GstBus *bus, GstMessage *msg, gpointer data);

    struct ExtractionContext {
        QString itemId;
        QString filePath;
        VideoMetadata metadata;
        MetadataExtractor *extractor;
        // Kept so the bus watch can be explicitly removed before this
        // context is deleted - gst_bus_add_watch() installs a GSource that
        // otherwise keeps running against a freed ExtractionContext*
        // (use-after-free) for as long as the (also leaked) bus/pipeline
        // happen to still emit messages, e.g. the state-change messages
        // produced by the pipeline's own teardown right after extraction.
        GstBus *bus = nullptr;
        // Per-extraction safety net: some failure modes (stalled network
        // mount, an exotic container) leave playbin neither reaching
        // ASYNC_DONE nor posting ERROR. Without this, that one request
        // would permanently occupy a concurrency slot once a bounded
        // queue exists, eventually stalling every later extraction.
        QTimer *timeout = nullptr;
        // Monotonic, assigned in startExtraction(), never reused - see
        // contextForId(). This, not the ExtractionContext* or the
        // GstElement* pipeline pointer, is the only safe way to identify
        // "which extraction is this" across a Qt::QueuedConnection: both
        // of those addresses are freed by finishExtraction() and reliably
        // get reused by the very next extraction's allocations.
        quint64 extractionId = 0;
    };

    struct PendingExtraction { QString filePath; QString itemId; };

    // Resolves a live extraction by id. Returns nullptr if that
    // extraction already finished by any path (normal completion,
    // error, or watchdog timeout) - which for a deferred bus-callback
    // lambda just means "nothing to do", not an error.
    ExtractionContext *contextForId(quint64 id, GstElement **outPipeline) const;
    // True if itemId has a live (in m_contexts) extraction running right
    // now. Used by extractMetadata() to avoid starting a second, fully
    // redundant extraction for the same file.
    bool isExtractionActive(const QString &itemId) const;

    QMap<GstElement*, ExtractionContext*> m_contexts;
    QQueue<PendingExtraction> m_interactiveQueue;
    QQueue<PendingExtraction> m_backgroundQueue;
    int m_maxConcurrentExtractions = 2; // matches CacheManager's m_maxConcurrentGenerations
    // 0 reserved as "no id" - never assigned to a real extraction, so a
    // default-constructed ExtractionContext (which can't actually occur
    // today, but costs nothing to make unambiguous) can't be mistaken
    // for a live one. Wraparound is not a practical concern: at one
    // extraction per millisecond continuously, quint64 lasts ~585
    // million years.
    quint64 m_nextExtractionId = 1;
};

#endif // METADATAEXTRACTOR_H
