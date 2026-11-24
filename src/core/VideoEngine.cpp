#include "VideoEngine.h"
#include "Qml6GLSink.h"
#include "GstElementDiscovery.h"
#include <QGuiApplication>
#include <QDebug>
#include <QUrl>
#include <QByteArray>

VideoEngine::VideoEngine(QObject *parent)
    : QObject(parent)
    , m_pipeline(nullptr)
    , m_source(nullptr)
    , m_sink(nullptr)
    , m_windowId(0)
    , m_playing(false)
    , m_position(0)
    , m_duration(0)
    , m_showMetadata(false)
    , m_decoderPreference("nvidia") // Default to NVIDIA, will be updated by setDecoderPreference()
    , m_resolution("-")
    , m_frameRate("-")
    , m_aspectRatio("-")
    , m_videoCodec("-")
    , m_audioCodec("-")
    , m_bitrate("-")
    , m_encoder("-")
    , m_creationTime("-")
{
    // Initialize GStreamer
    gst_init(nullptr, nullptr);

    // Setup position update timer
    m_positionTimer = new QTimer(this);
    m_positionTimer->setInterval(100); // Update every 100ms
    connect(m_positionTimer, &QTimer::timeout, this, &VideoEngine::updatePosition);
}

VideoEngine::~VideoEngine() {
    if (m_pipeline) {
        gst_element_set_state(m_pipeline, GST_STATE_NULL);
        gst_object_unref(m_pipeline);
    }
}

void VideoEngine::setupPipeline() {
    if (m_pipeline) {
        gst_element_set_state(m_pipeline, GST_STATE_NULL);
        gst_object_unref(m_pipeline);
        m_pipeline = nullptr;
    }

    // Reset all decoder ranks to default first. Decoder factory names are
    // looked up dynamically (see GstElementDiscovery.h) instead of matched
    // against a hand-maintained list, so a GStreamer release renaming a
    // decoder element can't silently stop this rank-boosting from working.
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

    // Apply decoder preference by boosting ranks
    const QStringList boost = (m_decoderPreference == "nvidia") ? nvDecoders
                             : (m_decoderPreference == "vaapi") ? vaDecoders
                             : QStringList();
    for (const QString &name : boost) {
        GstPluginFeature *feature = gst_registry_lookup_feature(registry, name.toUtf8().constData());
        if (feature) {
            gst_plugin_feature_set_rank(feature, GST_RANK_PRIMARY + 1);
            gst_object_unref(feature);
        }
    }
    // For "cpu", we keep all hardware decoders at MARGINAL rank, so software decoders are preferred

    // Create playbin with hardware acceleration + VideoOverlay + Audio
    m_pipeline = gst_element_factory_make("playbin", "playbin");

    if (!m_pipeline) {
        qCritical() << "Failed to create playbin";
        emit this->error("Failed to create playbin");
        return;
    }

    // Create video sink with aspect ratio preservation.
    //
    // xvimagesink is the preferred (zero-copy, scaled-by-the-server)
    // path, but it needs an XVideo *adaptor*, which plenty of X servers
    // advertise the extension for without actually providing (Xvfb,
    // most X-over-SSH / VNC setups, some headless CI displays). In that
    // case the element only fails late - at the NULL->READY transition,
    // once it is already inside playbin - and the user just gets a
    // "Could not initialise Xv output" error with no video at all.
    // Probe it up front instead and fall back to ximagesink, which
    // needs no adaptor. GCS_VIDEO_SINK overrides the choice entirely.
    const QByteArray sinkOverride = qgetenv("GCS_VIDEO_SINK");
    const bool useGLWidget = Qml6GLSink::enabled();
    // The native-window sinks (xvimagesink/ximagesink) draw into an X11 window
    // handle, which only exists on Qt's xcb platform. Anywhere else (native
    // Wayland) they must never be created: report it and discard video into a
    // fakesink, so playbin does not autoplug its own sink and open a stray window.
    const QString platform = QGuiApplication::platformName();
    const bool x11Only = sinkOverride == "xvimagesink" || sinkOverride == "ximagesink";
    if (!useGLWidget && platform != QLatin1String("xcb") && (sinkOverride.isEmpty() || x11Only)) {
        const QString msg = QStringLiteral("No video output available on the \"%1\" platform: the GStreamer "
            "qml6 plugin is missing or lacks %1 support and the X11 fallback needs the xcb platform. "
            "Start with QT_QPA_PLATFORM=xcb.").arg(platform);
        qCritical().noquote() << "VideoEngine:" << msg;
        m_sink = gst_element_factory_make("fakesink", "videosink");
        if (m_sink) {
            g_object_set(G_OBJECT(m_sink), "sync", TRUE, NULL);
            g_object_set(G_OBJECT(m_pipeline), "video-sink", m_sink, NULL);
        }
        emit this->error(msg);
    } else if (useGLWidget) {
        // qml6glsink spike: it renders straight into a QQuickItem in the
        // scene graph via its "widget" property, not a native window
        // handle - no force-aspect-ratio property, no GstVideoOverlay
        // window-handle plumbing for this one.
        m_sink = Qml6GLSink::makeSinkBin(m_glVideoItem, &m_glSinkElement, Qml6GLSink::Upstream::CudaMemory);
        if (!m_glVideoItem) {
            qWarning() << "VideoEngine: GCS_VIDEO_SINK=qml6glsink but setGLVideoItem() was never called";
        }
        if (m_sink) g_object_set(G_OBJECT(m_pipeline), "video-sink", m_sink, NULL);
    } else if (!sinkOverride.isEmpty()) {
        m_sink = gst_element_factory_make(sinkOverride.constData(), "videosink");
        if (m_sink) {
            g_object_set(G_OBJECT(m_sink), "force-aspect-ratio", TRUE, NULL);
            g_object_set(G_OBJECT(m_pipeline), "video-sink", m_sink, NULL);
        }
    } else {
        m_sink = gst_element_factory_make("xvimagesink", "videosink");
        if (m_sink) {
            // Opening the Xv adaptor happens in NULL->READY; if there is
            // none, this returns FAILURE and we can still swap sinks.
            if (gst_element_set_state(m_sink, GST_STATE_READY) == GST_STATE_CHANGE_FAILURE) {
                qWarning() << "VideoEngine: xvimagesink unusable on this display, falling back to ximagesink";
                gst_element_set_state(m_sink, GST_STATE_NULL);
                gst_object_unref(m_sink);
                m_sink = gst_element_factory_make("ximagesink", "videosink");
            }
        }
        if (m_sink) {
            g_object_set(G_OBJECT(m_sink), "force-aspect-ratio", TRUE, NULL);
            g_object_set(G_OBJECT(m_pipeline), "video-sink", m_sink, NULL);
        }
    }

    // Set playbin flags based on metadata visibility setting
    gint flags;
    g_object_get(G_OBJECT(m_pipeline), "flags", &flags, NULL);
    const gint GST_PLAY_FLAG_TEXT = 0x00000004;
    if (m_showMetadata) {
        flags |= GST_PLAY_FLAG_TEXT;
    } else {
        flags &= ~GST_PLAY_FLAG_TEXT;
    }
    g_object_set(G_OBJECT(m_pipeline), "flags", flags, NULL);

    // Set window ID if already available (not applicable to the
    // qml6glsink "widget" path - it was already wired above).
    if (m_sink && !useGLWidget && m_windowId != 0 && GST_IS_VIDEO_OVERLAY(m_sink)) {
        gst_video_overlay_set_window_handle(GST_VIDEO_OVERLAY(m_sink), m_windowId);
    }

    // Audio sink will be created automatically by playbin (uses PulseAudio/ALSA)

    // Setup bus callback
    GstBus *bus = gst_pipeline_get_bus(GST_PIPELINE(m_pipeline));
    gst_bus_add_watch(bus, busCallback, this);
    gst_object_unref(bus);
}

void VideoEngine::loadVideo(const QString &filePath, bool autoPlay) {
    // Stop current playback
    if (m_pipeline) {
        gst_element_set_state(m_pipeline, GST_STATE_NULL);
    }

    // Reset creation time for new video
    m_creationTime = "-";

    // A new file starts at 0 / unknown duration: a still image (or any
    // file whose duration query fails) must not keep showing the previous
    // clip's time label / Clip Information duration.
    m_duration = 0;
    m_position = 0;
    emit durationChanged();
    emit positionChanged();

    // Setup new pipeline
    setupPipeline();

    if (!m_pipeline) {
        qCritical() << "Pipeline not ready";
        return;
    }

    // Convert file path to proper URI
    QString uri = filePath;
    if (!uri.startsWith("file://")) {
        uri = "file://" + uri;
    }

    // Set URI on playbin
    g_object_set(G_OBJECT(m_pipeline), "uri", uri.toUtf8().constData(), nullptr);

    m_currentFile = filePath;
    emit currentFileChanged();

    // autoPlay=false: PAUSED still prerolls (decodes and displays) the
    // first frame, it just doesn't advance - exactly "loaded, showing
    // frame 1, not playing".
    const GstState targetState = autoPlay ? GST_STATE_PLAYING : GST_STATE_PAUSED;
    GstStateChangeReturn ret = gst_element_set_state(m_pipeline, targetState);
    if (ret == GST_STATE_CHANGE_FAILURE) {
        qCritical() << "Failed to" << (autoPlay ? "start playback" : "preroll first frame");
        emit error(autoPlay ? "Failed to start playback" : "Failed to load clip");
        return;
    }

    m_playing = autoPlay;
    emit playingChanged();
    if (autoPlay) m_positionTimer->start();

    // Update duration after a short delay
    QTimer::singleShot(500, this, &VideoEngine::updateDuration);
}

void VideoEngine::play() {
    if (!m_pipeline) {
        return;
    }

    // Re-set window ID if coming from NULL/READY state (e.g., after stop)
    if (m_sink && m_windowId != 0 && GST_IS_VIDEO_OVERLAY(m_sink)) {
        GstState current_state;
        gst_element_get_state(m_pipeline, &current_state, nullptr, 0);
        if (current_state == GST_STATE_NULL || current_state == GST_STATE_READY) {
            gst_video_overlay_set_window_handle(GST_VIDEO_OVERLAY(m_sink), m_windowId);
        }
    }

    gst_element_set_state(m_pipeline, GST_STATE_PLAYING);
    m_playing = true;
    emit playingChanged();
    m_positionTimer->start();
}

void VideoEngine::pause() {
    if (!m_pipeline) {
        return;
    }

    gst_element_set_state(m_pipeline, GST_STATE_PAUSED);
    m_playing = false;
    emit playingChanged();
    m_positionTimer->stop();
}

void VideoEngine::stop() {
    if (!m_pipeline) {
        return;
    }

    gst_element_set_state(m_pipeline, GST_STATE_NULL);
    m_playing = false;
    m_position = 0;
    emit playingChanged();
    emit positionChanged();
    m_positionTimer->stop();
}

void VideoEngine::seek(qint64 positionMs) {
    if (!m_pipeline) {
        return;
    }

    gint64 position_ns = positionMs * GST_MSECOND;
    if (!gst_element_seek_simple(m_pipeline, GST_FORMAT_TIME,
                                   (GstSeekFlags)(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT),
                                   position_ns)) {
        qWarning() << "Seek failed";
    } else {
        m_position = positionMs;
        emit positionChanged();
    }
}


void VideoEngine::setWindowId(qulonglong windowId) {
    m_windowId = windowId;

    // If we already have a sink, set the window handle now
    if (m_sink && m_windowId != 0 && GST_IS_VIDEO_OVERLAY(m_sink)) {
        gst_video_overlay_set_window_handle(GST_VIDEO_OVERLAY(m_sink), m_windowId);
    }
}

void VideoEngine::clearWindowId() {
    m_windowId = 0;
    if (m_sink && GST_IS_VIDEO_OVERLAY(m_sink)) {
        gst_video_overlay_set_window_handle(GST_VIDEO_OVERLAY(m_sink), 0);
    }
}

void VideoEngine::refreshVideo() {
    if (m_sink && GST_IS_VIDEO_OVERLAY(m_sink)) {
        gst_video_overlay_expose(GST_VIDEO_OVERLAY(m_sink));
    }
}

bool VideoEngine::isGLVideoSink() const {
    return Qml6GLSink::enabled();
}

void VideoEngine::setGLVideoItem(QQuickItem *item) {
    m_glVideoItem = item;
    // If the pipeline/sink already exists (e.g. the item changed after a
    // video was loaded), re-wire immediately rather than waiting for the
    // next setupPipeline() call. m_glSinkElement, not m_sink, is the actual
    // qml6glsink element once it's wrapped in the NV12-downconvert bin.
    if (m_glSinkElement && qgetenv("GCS_VIDEO_SINK") == "qml6glsink") {
        g_object_set(G_OBJECT(m_glSinkElement), "widget", m_glVideoItem, NULL);
    }
}

void VideoEngine::setShowMetadata(bool show) {
    if (m_showMetadata == show) {
        return;
    }

    m_showMetadata = show;
    emit showMetadataChanged();

    if (!m_pipeline) {
        return;
    }

    // Get current playbin flags
    gint flags;
    g_object_get(G_OBJECT(m_pipeline), "flags", &flags, NULL);

    // GST_PLAY_FLAG_TEXT = 0x00000004 (enables text/subtitle rendering)
    const gint GST_PLAY_FLAG_TEXT = 0x00000004;

    if (show) {
        // Enable text overlay
        flags |= GST_PLAY_FLAG_TEXT;
    } else {
        // Disable text overlay
        flags &= ~GST_PLAY_FLAG_TEXT;
    }

    g_object_set(G_OBJECT(m_pipeline), "flags", flags, NULL);
}

void VideoEngine::updatePosition() {
    if (!m_pipeline || !m_playing) {
        return;
    }

    gint64 pos = 0;
    if (gst_element_query_position(m_pipeline, GST_FORMAT_TIME, &pos)) {
        qint64 newPosition = pos / GST_MSECOND;
        if (newPosition != m_position) {
            m_position = newPosition;
            emit positionChanged();
        }
    }
}

void VideoEngine::updateDuration() {
    if (!m_pipeline) {
        return;
    }

    gint64 dur = 0;
    if (gst_element_query_duration(m_pipeline, GST_FORMAT_TIME, &dur)) {
        m_duration = dur / GST_MSECOND;
        emit durationChanged();
    }
}

void VideoEngine::updateMetadata() {
    if (!m_pipeline) {
        return;
    }

    // Reset metadata (but keep creation_time as it comes from TAG messages)
    m_resolution = "-";
    m_frameRate = "-";
    m_aspectRatio = "-";
    m_videoCodec = "-";
    m_audioCodec = "-";
    m_bitrate = "-";
    m_encoder = "-";
    // Don't reset m_creationTime here - it's set via GST_MESSAGE_TAG

    // Get number of video and audio streams
    gint n_video = 0, n_audio = 0;
    g_object_get(G_OBJECT(m_pipeline), "n-video", &n_video, "n-audio", &n_audio, NULL);

    // Get video stream info
    if (n_video > 0) {
        GstPad *videoPad = nullptr;
        g_signal_emit_by_name(m_pipeline, "get-video-pad", 0, &videoPad);

        if (videoPad) {
            GstCaps *caps = gst_pad_get_current_caps(videoPad);
            if (caps) {
                GstStructure *structure = gst_caps_get_structure(caps, 0);
                if (structure) {
                    // Get resolution
                    gint width = 0, height = 0;
                    if (gst_structure_get_int(structure, "width", &width) &&
                        gst_structure_get_int(structure, "height", &height)) {
                        m_resolution = QString("%1x%2").arg(width).arg(height);
                    }

                    // Get frame rate
                    gint fps_num = 0, fps_den = 1;
                    if (gst_structure_get_fraction(structure, "framerate", &fps_num, &fps_den) && fps_den > 0) {
                        double fps = (double)fps_num / fps_den;
                        m_frameRate = QString::number(fps, 'f', 2) + " fps";
                    }

                    // Get aspect ratio
                    gint par_num = 1, par_den = 1;
                    if (gst_structure_get_fraction(structure, "pixel-aspect-ratio", &par_num, &par_den)) {
                        if (width > 0 && height > 0) {
                            double dar = ((double)width / height) * ((double)par_num / par_den);
                            m_aspectRatio = QString::number(dar, 'f', 2) + ":1";
                        }
                    }
                }
                gst_caps_unref(caps);
            }

            // Get video tags (including codec info)
            GstTagList *tags = nullptr;
            g_signal_emit_by_name(m_pipeline, "get-video-tags", 0, &tags);
            if (tags) {
                // Get video codec from tags
                gchar *codec_str = nullptr;
                if (gst_tag_list_get_string(tags, GST_TAG_VIDEO_CODEC, &codec_str)) {
                    m_videoCodec = QString::fromUtf8(codec_str);
                    g_free(codec_str);
                }

                gchar *encoder_str = nullptr;
                if (gst_tag_list_get_string(tags, GST_TAG_ENCODER, &encoder_str)) {
                    m_encoder = QString::fromUtf8(encoder_str);
                    g_free(encoder_str);
                }

                // Try to get creation_time first (common in MP4/MOV containers)
                gchar *datetime_str = nullptr;
                if (gst_tag_list_get_string(tags, "creation_time", &datetime_str)) {
                    m_creationTime = QString::fromUtf8(datetime_str);
                    g_free(datetime_str);
                } else {
                    // GST_TAG_DATE_TIME is GstDateTime, not string
                    GstDateTime *datetime = nullptr;
                    if (gst_tag_list_get_date_time(tags, GST_TAG_DATE_TIME, &datetime)) {
                        if (datetime) {
                            gchar *dt_str = gst_date_time_to_iso8601_string(datetime);
                            if (dt_str) {
                                m_creationTime = QString::fromUtf8(dt_str);
                                g_free(dt_str);
                            }
                            gst_date_time_unref(datetime);
                        }
                    }
                }

                guint bitrate_val = 0;
                if (gst_tag_list_get_uint(tags, GST_TAG_BITRATE, &bitrate_val)) {
                    m_bitrate = QString::number(bitrate_val / 1000) + " kbps";
                } else if (gst_tag_list_get_uint(tags, GST_TAG_NOMINAL_BITRATE, &bitrate_val)) {
                    m_bitrate = QString::number(bitrate_val / 1000) + " kbps";
                }

                gst_tag_list_unref(tags);
            }

            gst_object_unref(videoPad);
        }
    }

    // Get audio codec
    if (n_audio > 0) {
        // Get audio tags (including codec info)
        GstTagList *audioTags = nullptr;
        g_signal_emit_by_name(m_pipeline, "get-audio-tags", 0, &audioTags);
        if (audioTags) {
            gchar *codec_str = nullptr;
            if (gst_tag_list_get_string(audioTags, GST_TAG_AUDIO_CODEC, &codec_str)) {
                m_audioCodec = QString::fromUtf8(codec_str);
                g_free(codec_str);
            }
            gst_tag_list_unref(audioTags);
        }

        // Fallback to checking pad caps if tags didn't have codec
        if (m_audioCodec == "-") {
            GstPad *audioPad = nullptr;
            g_signal_emit_by_name(m_pipeline, "get-audio-pad", 0, &audioPad);
            if (audioPad) {
                GstCaps *caps = gst_pad_get_current_caps(audioPad);
                if (caps) {
                    GstStructure *structure = gst_caps_get_structure(caps, 0);
                    if (structure) {
                        const gchar *codec = gst_structure_get_name(structure);
                        if (codec) {
                            m_audioCodec = QString::fromUtf8(codec);
                        }
                    }
                    gst_caps_unref(caps);
                }
                gst_object_unref(audioPad);
            }
        }
    } else {
        m_audioCodec = "No audio";
    }

    emit metadataChanged();
}

gboolean VideoEngine::busCallback(GstBus *bus, GstMessage *msg, gpointer data) {
    Q_UNUSED(bus);
    VideoEngine *engine = static_cast<VideoEngine*>(data);

    switch (GST_MESSAGE_TYPE(msg)) {
        case GST_MESSAGE_ERROR: {
            GError *err;
            gchar *debug;
            gst_message_parse_error(msg, &err, &debug);
            qCritical() << "GStreamer error:" << err->message;
            emit engine->error(QString::fromUtf8(err->message));
            g_error_free(err);
            g_free(debug);
            break;
        }
        case GST_MESSAGE_EOS:
            engine->stop();
            break;
        case GST_MESSAGE_STATE_CHANGED: {
            if (GST_MESSAGE_SRC(msg) == GST_OBJECT(engine->m_pipeline)) {
                GstState oldState, newState;
                gst_message_parse_state_changed(msg, &oldState, &newState, nullptr);

                // Update duration and metadata when reaching PAUSED or PLAYING state
                if (newState == GST_STATE_PAUSED || newState == GST_STATE_PLAYING) {
                    engine->updateDuration();
                    engine->updateMetadata();
                }
            }
            break;
        }
        case GST_MESSAGE_DURATION_CHANGED:
            engine->updateDuration();
            break;
        case GST_MESSAGE_ASYNC_DONE:
            engine->updateDuration();
            break;
        case GST_MESSAGE_TAG: {
            GstTagList *tags = nullptr;
            gst_message_parse_tag(msg, &tags);
            if (tags) {
                // Look for creation_time in container tags (can be GstDateTime or string)
                GstDateTime *datetime = nullptr;
                if (gst_tag_list_get_date_time(tags, GST_TAG_DATE_TIME, &datetime)) {
                    if (datetime) {
                        gchar *datetime_str = gst_date_time_to_iso8601_string(datetime);
                        if (datetime_str) {
                            engine->m_creationTime = QString::fromUtf8(datetime_str);
                            emit engine->metadataChanged();
                            g_free(datetime_str);
                        }
                        gst_date_time_unref(datetime);
                    }
                } else {
                    // Try as string
                    gchar *creation_time_str = nullptr;
                    if (gst_tag_list_get_string(tags, "creation_time", &creation_time_str)) {
                        engine->m_creationTime = QString::fromUtf8(creation_time_str);
                        emit engine->metadataChanged();
                        g_free(creation_time_str);
                    }
                }

                gst_tag_list_unref(tags);
            }
            break;
        }
        case GST_MESSAGE_WARNING: {
            GError *err;
            gchar *debug;
            gst_message_parse_warning(msg, &err, &debug);
            qWarning() << "GStreamer warning:" << err->message;
            g_error_free(err);
            g_free(debug);
            break;
        }
        default:
            break;
    }

    return TRUE;
}

void VideoEngine::setDecoderPreference(const QString &decoder)
{
    if (m_decoderPreference != decoder) {
        m_decoderPreference = decoder;

        // If we have a pipeline (video loaded), rebuild it with new decoder
        if (m_pipeline && !m_currentFile.isEmpty()) {
            // Save current state
            QString currentVideoFile = m_currentFile;
            qint64 currentPos = m_position;
            bool wasPlaying = m_playing;

            // Stop current pipeline
            gst_element_set_state(m_pipeline, GST_STATE_NULL);
            gst_object_unref(m_pipeline);
            m_pipeline = nullptr;
            m_playing = false;

            // Rebuild pipeline with new decoder preference
            setupPipeline();

            if (!m_pipeline) {
                return;
            }

            // Set URI
            QString uri = currentVideoFile;
            if (!uri.startsWith("file://")) {
                uri = "file://" + uri;
            }
            g_object_set(G_OBJECT(m_pipeline), "uri", uri.toUtf8().constData(), nullptr);

            // Set to PAUSED first to allow seeking
            gst_element_set_state(m_pipeline, GST_STATE_PAUSED);

            // Wait for PAUSED state
            gst_element_get_state(m_pipeline, nullptr, nullptr, GST_CLOCK_TIME_NONE);

            // Restore position if needed
            if (currentPos > 0) {
                gint64 position_ns = currentPos * GST_MSECOND;
                gst_element_seek_simple(m_pipeline, GST_FORMAT_TIME,
                                       (GstSeekFlags)(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT),
                                       position_ns);
            }

            // Resume playback if it was playing
            if (wasPlaying) {
                gst_element_set_state(m_pipeline, GST_STATE_PLAYING);
                m_playing = true;
                emit playingChanged();
                m_positionTimer->start();
            }

            m_position = currentPos;
            emit positionChanged();
        }
    }
}
