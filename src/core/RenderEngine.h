#ifndef RENDERENGINE_H
#define RENDERENGINE_H

#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QCoreApplication>
#include <QTimer>
#include <QDateTime>
#include <QList>
#include <gst/gst.h>
#include <glib.h>

class RenderEngine;

// ---------------------------------------------------------------------------
// RenderJob - ONE export. Owns its own GESTimeline + GESPipeline + bus watch +
// progress timer, so nothing is shared between two simultaneous exports.
//
// This used to be flat state on RenderEngine (a single m_pipeline / m_rendering
// pair), which is what made a second Start Render while one was running
// corrupt the UI's job bookkeeping: startRender() bailed out with
// error("Render already in progress") BEFORE the QML had inserted the new job
// row, so the error landed on the STILL-RUNNING job's row, and the row the QML
// then inserted for the rejected job silently absorbed the running job's
// progress/EOS signals. Now every signal carries a jobId.
// ---------------------------------------------------------------------------
class RenderJob : public QObject {
    Q_OBJECT

public:
    enum State { Queued, Running, Finished, Failed, Cancelled };

    struct Clip {
        QString itemPath;
        QString trackId;
        double startTime;
        double durationSeconds;
        double sourceOffset;
        bool hasVideo;
        bool hasAudio;
        double trackVolume = 1.0;   // linear track gain, 1.0 = unchanged
        double trackPan = 0.0;      // -1 left .. +1 right, 0.0 = unchanged
        bool hasTransition;
        double transitionDuration;
        QString transitionType;
        QString effects;
        // "" / "media" = file-backed clip; "title" = generated text clip
        // (no itemPath at all). titleParams is a JSON object string of
        // GES title-source child properties - see TitleClips.h.
        QString clipKind;
        QString titleParams;
    };

    RenderJob(int id, const QString &outputPath, const QVariantMap &settings, QObject *parent = nullptr);
    ~RenderJob();

    int id() const { return m_id; }
    State state() const { return m_state; }
    const QString &outputPath() const { return m_outputPath; }
    // Which hardware backend this job wants ("nvidia" / "vaapi" / "cpu").
    // Two jobs on the SAME backend are serialised; different backends may run
    // at the same time (see RenderEngine::pumpQueue()).
    QString backendKey() const { return m_backendKey; }
    int progress() const { return m_progress; }

    QList<Clip> clips;
    double totalDuration = 0.0;

    bool start();   // builds + starts the pipeline; false => already failed
    void cancel();

signals:
    void started(int jobId);
    void progressChanged(int jobId, int percent);
    void fpsChanged(int jobId, double currentFps, double avgFps);
    void finished(int jobId, bool success, qint64 fileSize, const QString &errorMessage);

private slots:
    void tick();

private:
    void destroyPipeline();
    void complete(bool success, const QString &errorMessage);
    static gboolean busCallback(GstBus *bus, GstMessage *msg, gpointer data);

    int m_id;
    QString m_outputPath;
    QVariantMap m_settings;
    QString m_projectDir;
    QString m_backendKey;
    State m_state = Queued;

    GstElement *m_pipeline = nullptr;
    QTimer *m_timer = nullptr;

    int m_progress = 0;
    qint64 m_lastRealTime = 0;
    qint64 m_renderStartTime = 0;
    double m_lastPositionSec = 0.0;
    double m_targetFps = 30.0;
};

// ---------------------------------------------------------------------------
// RenderEngine - job manager. A render request is never rejected any more: it
// is either started immediately (if no conflicting job is running) or queued
// FIFO and started automatically when the conflicting job finishes.
// ---------------------------------------------------------------------------
class RenderEngine : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool rendering READ isRendering NOTIFY renderingChanged)
    Q_PROPERTY(int activeJobCount READ activeJobCount NOTIFY renderingChanged)
    Q_PROPERTY(int queuedJobCount READ queuedJobCount NOTIFY renderingChanged)

public:
    explicit RenderEngine(QObject *parent = nullptr);
    ~RenderEngine();

    // Returns the new job's id, or -1 if the request was invalid (no clips /
    // zero duration) - in that case error() is emitted and no job exists.
    Q_INVOKABLE int startRender(const QString &outputPath,
                                const QVariantList &clips,
                                double totalDuration,
                                const QVariantMap &settings);

    Q_INVOKABLE void cancelJob(int jobId);
    // Legacy convenience: cancel everything (used by the old single-job UI).
    Q_INVOKABLE void cancelRender();

    // startRender()'s own conflicts() check only guards two SIMULTANEOUSLY
    // RUNNING jobs from writing the same file - it says nothing about a
    // path that already has a finished render (or any other file) sitting
    // on disk, which startRender() would then silently overwrite. QML
    // calls this before startRender() to ask for confirmation first.
    Q_INVOKABLE bool outputPathExists(const QString &outputPath) const;

    // Speed/quality choices for the encoder element that a render on
    // `backend` ("nvidia"|"vaapi"|"cpu") with `codec` would really use:
    // {family, encoder, options:[{id,label,shortLabel,description,isDefault}],
    //  defaultId}. options is empty when the encoder has no such setting.
    Q_INVOKABLE QVariantMap qualityOptions(const QString &backend, const QString &codec) const;

    bool isRendering() const;
    int activeJobCount() const;
    int queuedJobCount() const;

signals:
    void renderingChanged();
    // startedImmediately == false means the job is sitting in the FIFO queue.
    void jobEnqueued(int jobId, bool startedImmediately, int queuePosition);
    void jobStarted(int jobId);
    void jobProgress(int jobId, int percent);
    void jobFps(int jobId, double currentFps, double avgFps);
    void jobFinished(int jobId, bool success, qint64 fileSize, const QString &errorMessage);
    // Only for requests that never became a job at all.
    void error(const QString &message);

private slots:
    void onJobFinished(int jobId, bool success, qint64 fileSize, const QString &errorMessage);

private:
    void pumpQueue();
    bool conflicts(const RenderJob *candidate) const;

    QList<RenderJob*> m_jobs;   // queued + running, in submission order
    int m_nextJobId = 1;
    // Upper bound on simultaneously running pipelines regardless of backend -
    // two 4K decodes + encodes already saturate memory bandwidth, a third
    // just makes all of them slower.
    int m_maxParallel = 2;
    bool m_pumping = false;
};

#endif // RENDERENGINE_H
