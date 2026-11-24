#ifndef VIDEOENGINE_H
#define VIDEOENGINE_H

#include <QObject>
#include <QQuickItem>
#include <QString>
#include <QTimer>
#include <gst/gst.h>
#include <gst/video/videooverlay.h>

class VideoEngine : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool playing READ isPlaying NOTIFY playingChanged)
    Q_PROPERTY(qint64 position READ position NOTIFY positionChanged)
    Q_PROPERTY(qint64 duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(QString currentFile READ currentFile NOTIFY currentFileChanged)
    Q_PROPERTY(bool showMetadata READ showMetadata WRITE setShowMetadata NOTIFY showMetadataChanged)
    Q_PROPERTY(QString resolution READ resolution NOTIFY metadataChanged)
    Q_PROPERTY(QString frameRate READ frameRate NOTIFY metadataChanged)
    Q_PROPERTY(QString aspectRatio READ aspectRatio NOTIFY metadataChanged)
    Q_PROPERTY(QString videoCodec READ videoCodec NOTIFY metadataChanged)
    Q_PROPERTY(QString audioCodec READ audioCodec NOTIFY metadataChanged)
    Q_PROPERTY(QString bitrate READ bitrate NOTIFY metadataChanged)
    Q_PROPERTY(QString encoder READ encoder NOTIFY metadataChanged)
    Q_PROPERTY(QString creationTime READ creationTime NOTIFY metadataChanged)
    // qml6glsink spike (feature/qml6-gl-video-sink branch): lets
    // SourceMonitor.qml pick between VideoOutput and GstGLQt6VideoItem
    // declaratively. Gated on GCS_VIDEO_SINK=qml6glsink.
    Q_PROPERTY(bool glVideoSink READ isGLVideoSink CONSTANT)

public:
    explicit VideoEngine(QObject *parent = nullptr);
    ~VideoEngine();

    // autoPlay=false loads the file and prerolls (shows) its first frame
    // PAUSED, instead of starting playback immediately - a single click on
    // a Project Bin item should preview without stealing focus from
    // whatever the user was already listening to/watching.
    Q_INVOKABLE void loadVideo(const QString &filePath, bool autoPlay = true);
    Q_INVOKABLE void play();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void seek(qint64 positionMs);
    Q_INVOKABLE void setWindowId(qulonglong windowId);
    // Mirrors TimelineEngine::clearWindowId() - without this, a
    // destroyed native window (VideoOutput::releaseResources(), which
    // emits windowIdChanged() with windowId==0) left the sink still
    // holding a handle to an already-destroyed XID, since
    // setWindowId(0) deliberately skips re-pushing it to the overlay.
    Q_INVOKABLE void clearWindowId();
    Q_INVOKABLE void refreshVideo();
    Q_INVOKABLE void setDecoderPreference(const QString &decoder);

    // qml6glsink spike: instead of the native-child-window + GstVideoOverlay
    // path (setWindowId), wire the QQuickItem directly as qml6glsink's
    // "widget" GObject property, so the sink renders straight into the QML
    // scene graph. Only takes effect when GCS_VIDEO_SINK=qml6glsink. Must be
    // called before loadVideo() creates the pipeline (setupPipeline() reads
    // m_glVideoItem while building the sink).
    Q_INVOKABLE void setGLVideoItem(QQuickItem *item);

    bool isPlaying() const { return m_playing; }
    bool isGLVideoSink() const;
    qint64 position() const { return m_position; }
    qint64 duration() const { return m_duration; }
    QString currentFile() const { return m_currentFile; }
    bool showMetadata() const { return m_showMetadata; }
    void setShowMetadata(bool show);
    QString resolution() const { return m_resolution; }
    QString frameRate() const { return m_frameRate; }
    QString aspectRatio() const { return m_aspectRatio; }
    QString videoCodec() const { return m_videoCodec; }
    QString audioCodec() const { return m_audioCodec; }
    QString bitrate() const { return m_bitrate; }
    QString encoder() const { return m_encoder; }
    QString creationTime() const { return m_creationTime; }

signals:
    void playingChanged();
    void positionChanged();
    void durationChanged();
    void currentFileChanged();
    void showMetadataChanged();
    void metadataChanged();
    void error(const QString &message);

private slots:
    void updatePosition();

private:
    GstElement *m_pipeline;
    GstElement *m_source;
    GstElement *m_sink;
    qulonglong m_windowId;
    QQuickItem *m_glVideoItem = nullptr;
    // When the qml6glsink spike wraps the actual qml6glsink element inside
    // a small conversion bin (see setupPipeline()), m_sink becomes that
    // bin (it's what playbin's "video-sink" needs) while this keeps
    // pointing at the real qml6glsink element, which is what actually has
    // the "widget" property setGLVideoItem() needs to set.
    GstElement *m_glSinkElement = nullptr;
    bool m_playing;
    qint64 m_position;
    qint64 m_duration;
    QString m_currentFile;
    bool m_showMetadata;
    QTimer *m_positionTimer;
    QString m_decoderPreference;

    // Metadata
    QString m_resolution;
    QString m_frameRate;
    QString m_aspectRatio;
    QString m_videoCodec;
    QString m_audioCodec;
    QString m_bitrate;
    QString m_encoder;
    QString m_creationTime;

    void setupPipeline();
    void updateDuration();
    void updateMetadata();
    static gboolean busCallback(GstBus *bus, GstMessage *msg, gpointer data);
};

#endif // VIDEOENGINE_H
