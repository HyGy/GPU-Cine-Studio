#include "WaveformGenerator.h"
#include <QFile>
#include <QDir>
#include <QDataStream>
#include <QDebug>
#include <QFileInfo>
#include <cmath>

#include <gst/gst.h>
#include <gst/app/gstappsink.h>

// === WaveformGeneratorWorker ===

WaveformGeneratorWorker::WaveformGeneratorWorker(QObject *parent)
    : QObject(parent)
{
}

WaveformGeneratorWorker::~WaveformGeneratorWorker()
{
}

void WaveformGeneratorWorker::generateWaveform(const QString &sourceFilePath,
                                                const QString &outputPath,
                                                const QString &itemId)
{
    qDebug() << "WaveformGenerator: Starting generation for" << itemId;
    emit waveformProgress(itemId, 0);

    // Ellenorizzuk, hogy nem lett-e kozben cancel
    {
        QMutexLocker locker(&m_mutex);
        if (m_cancelledItems.contains(itemId)) {
            m_cancelledItems.removeAll(itemId);
            emit waveformError(itemId, "Cancelled");
            return;
        }
    }

    // 1. Audio mintak kinyerese GStreamer-rel
    QVector<float> samples;
    int sampleRate;

    bool noAudioStream = false;
    if (!extractAudioSamples(sourceFilePath, samples, sampleRate, itemId, &noAudioStream)) {
        // Distinct, sentinel message for CacheManager to recognize - a
        // video-only source can never have a waveform, so this must
        // never be treated as a transient/retriable failure (see
        // CacheManager::setWaveformFailed()).
        emit waveformError(itemId, noAudioStream ? "NO_AUDIO_STREAM" : "Failed to extract audio samples");
        return;
    }

    // Ellenorizzuk cancel-t
    {
        QMutexLocker locker(&m_mutex);
        if (m_cancelledItems.contains(itemId)) {
            m_cancelledItems.removeAll(itemId);
            emit waveformError(itemId, "Cancelled");
            return;
        }
    }

    emit waveformProgress(itemId, 70);

    // 2. Waveform szamitasa (100 minta/masodperc)
    WaveformData waveform = calculateWaveform(samples, sampleRate, 100);

    emit waveformProgress(itemId, 90);

    // 3. Mentes fileba
    if (!saveWaveformToFile(waveform, outputPath)) {
        emit waveformError(itemId, "Failed to save waveform file");
        return;
    }

    emit waveformProgress(itemId, 100);
    emit waveformGenerated(itemId, outputPath);

    qDebug() << "WaveformGenerator: Completed generation for" << itemId
             << "- samples:" << waveform.minValues.size()
             << "- duration:" << waveform.duration << "s";
}

void WaveformGeneratorWorker::cancelGeneration(const QString &itemId)
{
    QMutexLocker locker(&m_mutex);
    if (!m_cancelledItems.contains(itemId)) {
        m_cancelledItems.append(itemId);
    }
}

bool WaveformGeneratorWorker::extractAudioSamples(const QString &filePath,
                                                   QVector<float> &samples,
                                                   int &sampleRate,
                                                   const QString &itemId,
                                                   bool *noAudioStream)
{
    if (noAudioStream) *noAudioStream = false;
    // Cheap pre-check: does this source have an audio stream at all?
    // Several of this project's real sources (drone/action-cam footage)
    // are video-only. Without this check, the decodebin pipeline below
    // (statically linked "decodebin ! audioconvert" via gst_parse_launch)
    // fails fast with a clean "not-linked" error for those sources
    // (verified live, not a hang) - but that still lands in the same
    // "failed" status as a genuine extraction problem, which
    // CacheManager::regenerateInvalidItems() retries on every single
    // project open forever, for a condition that can never succeed.
    // playbin's "n-audio" property is the same reliable "does this file
    // actually have audio" signal MetadataExtractor already uses (its
    // own comment explains why GST_TAG_AUDIO_CODEC isn't reliable here).
    {
        GstElement *probe = gst_element_factory_make("playbin", nullptr);
        if (probe) {
            QString cleanProbePath = filePath;
            if (cleanProbePath.startsWith("file://")) cleanProbePath = cleanProbePath.mid(7);
            // gst_filename_to_uri() is (transfer full): it returns a
            // newly-allocated string the caller must g_free() (see
            // gst/gsturi.c). Taking a QByteArray COPY and dropping the
            // original pointer leaked ~48 bytes per call (measured).
            gchar *uriRaw = gst_filename_to_uri(cleanProbePath.toUtf8().constData(), nullptr);
            const QByteArray uri = QByteArray(uriRaw ? uriRaw : "");
            g_free(uriRaw);
            if (!uri.isEmpty()) {
                g_object_set(G_OBJECT(probe), "uri", uri.constData(), NULL);
            } else {
                // Already a URI (e.g. file:// stripped above was a no-op
                // because it wasn't one to begin with - fall back to
                // treating it as already a valid URI string).
                g_object_set(G_OBJECT(probe), "uri", filePath.toUtf8().constData(), NULL);
            }
            GstElement *fakeVideoSink = gst_element_factory_make("fakesink", nullptr);
            GstElement *fakeAudioSink = gst_element_factory_make("fakesink", nullptr);
            if (fakeVideoSink) g_object_set(G_OBJECT(probe), "video-sink", fakeVideoSink, nullptr);
            if (fakeAudioSink) g_object_set(G_OBJECT(probe), "audio-sink", fakeAudioSink, nullptr);

            // PAUSED is enough to negotiate streams without decoding any
            // actual frames - same rationale as MetadataExtractor's own
            // probe pipeline.
            gst_element_set_state(probe, GST_STATE_PAUSED);
            const GstStateChangeReturn probeRet =
                gst_element_get_state(probe, nullptr, nullptr, 5 * GST_SECOND);

            gint nAudio = 0;
            g_object_get(G_OBJECT(probe), "n-audio", &nAudio, NULL);

            gst_element_set_state(probe, GST_STATE_NULL);
            gst_object_unref(probe);

            // n-audio is only MEANINGFUL if the probe actually reached
            // PAUSED. A missing file, a corrupt/unsupported file, a
            // temporarily-unreachable network share, or simply a source
            // too slow to preroll within the 5s timeout all leave the
            // probe in FAILURE/ASYNC with n-audio == 0 (verified live:
            // a nonexistent path and a non-media file both return
            // FAILURE + n-audio 0). Trusting n-audio there would brand
            // a perfectly audio-bearing source with the TERMINAL
            // "no-audio" status and never retry it again. On anything
            // but a clean preroll, fall through to the real extraction
            // pipeline, whose failure is retriable ("failed").
            const bool probePrerolled = (probeRet == GST_STATE_CHANGE_SUCCESS ||
                                         probeRet == GST_STATE_CHANGE_NO_PREROLL);
            if (!probePrerolled) {
                // Unreadable/corrupt/unsupported/too-slow source. Report a
                // GENERIC (retriable "failed") error, not "no-audio" - we
                // have no evidence about audio either way. We also do NOT
                // fall through to the extraction pipeline below, because
                // that pipeline provably blocks forever in
                // gst_app_sink_pull_sample() for a source decodebin cannot
                // produce audio from (verified live with a non-media file:
                // set_state(PLAYING) returns ASYNC, get_state then returns
                // FAILURE, and the pull loop never ends) - which would hang
                // the single waveform worker thread for the whole session.
                qWarning() << "WaveformGenerator: audio pre-check could not preroll"
                           << filePath << "- state change return" << probeRet
                           << "- reporting retriable failure";
                return false;
            }

            if (nAudio == 0) {
                qDebug() << "WaveformGenerator: no audio stream in" << filePath
                         << "- not attempting extraction";
                if (noAudioStream) *noAudioStream = true;
                return false;
            }
        }
    }

    // GStreamer pipeline: file -> decode -> audioconvert -> audioresample -> appsink
    QString cleanPath = filePath;
    if (cleanPath.startsWith("file://")) {
        cleanPath = cleanPath.mid(7);
    }

    // Escape special characters in path
    cleanPath.replace("\"", "\\\"");

    QString pipelineDesc = QString(
        "filesrc location=\"%1\" ! decodebin ! audioconvert ! "
        "audioresample ! audio/x-raw,format=F32LE,channels=1,rate=22050 ! "
        "appsink name=sink emit-signals=false sync=false"
    ).arg(cleanPath);

    GError *error = nullptr;
    GstElement *pipeline = gst_parse_launch(pipelineDesc.toUtf8().constData(), &error);

    if (error) {
        qWarning() << "WaveformGenerator: Pipeline error:" << error->message;
        g_error_free(error);
        return false;
    }

    if (!pipeline) {
        qWarning() << "WaveformGenerator: Failed to create pipeline";
        return false;
    }

    GstElement *appsink = gst_bin_get_by_name(GST_BIN(pipeline), "sink");
    if (!appsink) {
        qWarning() << "WaveformGenerator: Failed to get appsink";
        gst_object_unref(pipeline);
        return false;
    }

    // Pipeline inditasa
    GstStateChangeReturn ret = gst_element_set_state(pipeline, GST_STATE_PLAYING);
    if (ret == GST_STATE_CHANGE_FAILURE) {
        qWarning() << "WaveformGenerator: Failed to start pipeline";
        gst_object_unref(appsink);
        gst_object_unref(pipeline);
        return false;
    }

    // Varunk amig elindul.
    // The return value MUST be checked: set_state(PLAYING) above only
    // reports ASYNC for a file whose decode chain fails later, so a
    // pipeline that will never produce a sample is only detectable here.
    // Ignoring it meant dropping straight into gst_app_sink_pull_sample()
    // below, which then blocks FOREVER (verified live) and wedges the
    // single waveform worker thread for the rest of the session.
    const GstStateChangeReturn playRet =
        gst_element_get_state(pipeline, nullptr, nullptr, 5 * GST_SECOND);
    if (playRet == GST_STATE_CHANGE_FAILURE) {
        qWarning() << "WaveformGenerator: pipeline failed to reach PLAYING for"
                   << filePath << "- aborting extraction";
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(appsink);
        gst_object_unref(pipeline);
        return false;
    }

    // Mintak gyujtese
    sampleRate = 22050;  // Fixed resample rate
    int totalSamplesEstimate = 0;
    int samplesCollected = 0;
    int lastProgressPercent = 0;

    // Megprobaljuk lekerdezni a teljes idotartamot a progress szamitashoz
    gint64 duration = 0;
    if (gst_element_query_duration(pipeline, GST_FORMAT_TIME, &duration)) {
        totalSamplesEstimate = (duration / GST_SECOND) * sampleRate;
    }

    GstSample *sample;
    while ((sample = gst_app_sink_pull_sample(GST_APP_SINK(appsink))) != nullptr) {
        // Ellenorizzuk cancel-t
        {
            QMutexLocker locker(&m_mutex);
            if (m_cancelledItems.contains(itemId)) {
                gst_sample_unref(sample);
                gst_element_set_state(pipeline, GST_STATE_NULL);
                gst_object_unref(appsink);
                gst_object_unref(pipeline);
                return false;
            }
        }

        GstBuffer *buffer = gst_sample_get_buffer(sample);
        GstMapInfo map;

        if (gst_buffer_map(buffer, &map, GST_MAP_READ)) {
            // Float32 mintak
            float *data = (float*)map.data;
            int numSamples = map.size / sizeof(float);

            for (int i = 0; i < numSamples; i++) {
                samples.append(data[i]);
            }

            samplesCollected += numSamples;
            gst_buffer_unmap(buffer, &map);

            // Progress jelentes
            if (totalSamplesEstimate > 0) {
                int progressPercent = qMin(60, (samplesCollected * 60) / totalSamplesEstimate);
                if (progressPercent > lastProgressPercent) {
                    lastProgressPercent = progressPercent;
                    emit waveformProgress(itemId, progressPercent);
                }
            }
        }

        gst_sample_unref(sample);
    }

    // EOS vagy hiba ellenorzese
    GstBus *bus = gst_element_get_bus(pipeline);
    GstMessage *msg = gst_bus_pop_filtered(bus, (GstMessageType)(GST_MESSAGE_ERROR | GST_MESSAGE_EOS));
    if (msg) {
        if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_ERROR) {
            GError *err;
            gchar *debug;
            gst_message_parse_error(msg, &err, &debug);
            qWarning() << "WaveformGenerator: GStreamer error:" << err->message;
            g_error_free(err);
            g_free(debug);
        }
        gst_message_unref(msg);
    }
    gst_object_unref(bus);

    // Cleanup
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(appsink);
    gst_object_unref(pipeline);

    if (samples.isEmpty()) {
        qWarning() << "WaveformGenerator: No audio samples extracted";
        return false;
    }

    qDebug() << "WaveformGenerator: Extracted" << samples.size() << "samples at" << sampleRate << "Hz";
    return true;
}

WaveformData WaveformGeneratorWorker::calculateWaveform(const QVector<float> &samples,
                                                         int sampleRate,
                                                         int targetSamplesPerSecond)
{
    WaveformData result;
    result.samplesPerSecond = targetSamplesPerSecond;
    result.duration = static_cast<double>(samples.size()) / sampleRate;

    if (samples.isEmpty()) {
        return result;
    }

    int samplesPerBucket = sampleRate / targetSamplesPerSecond;
    if (samplesPerBucket < 1) samplesPerBucket = 1;

    int numBuckets = (samples.size() + samplesPerBucket - 1) / samplesPerBucket;

    result.minValues.reserve(numBuckets);
    result.maxValues.reserve(numBuckets);

    for (int i = 0; i < numBuckets; i++) {
        int start = i * samplesPerBucket;
        int end = qMin(start + samplesPerBucket, samples.size());

        float minVal = 0.0f;
        float maxVal = 0.0f;

        for (int j = start; j < end; j++) {
            float val = samples[j];
            if (val < minVal) minVal = val;
            if (val > maxVal) maxVal = val;
        }

        result.minValues.append(minVal);
        result.maxValues.append(maxVal);
    }

    return result;
}

bool WaveformGeneratorWorker::saveWaveformToFile(const WaveformData &data,
                                                  const QString &outputPath)
{
    // Biztositjuk, hogy a konyvtar letezik
    QFileInfo fileInfo(outputPath);
    QDir dir;
    if (!dir.mkpath(fileInfo.absolutePath())) {
        qWarning() << "WaveformGenerator: Failed to create directory:" << fileInfo.absolutePath();
        return false;
    }

    QFile file(outputPath);
    if (!file.open(QIODevice::WriteOnly)) {
        qWarning() << "WaveformGenerator: Failed to open file for writing:" << outputPath;
        return false;
    }

    QDataStream stream(&file);
    stream.setByteOrder(QDataStream::LittleEndian);
    stream.setFloatingPointPrecision(QDataStream::SinglePrecision);

    // Header
    stream.writeRawData("WFM1", 4);  // Magic
    stream << static_cast<quint32>(1);  // Version
    stream << static_cast<quint32>(data.minValues.size());  // Sample count
    stream << static_cast<quint32>(data.samplesPerSecond);  // Samples per second

    // Data
    for (int i = 0; i < data.minValues.size(); i++) {
        stream << data.minValues[i];
        stream << data.maxValues[i];
    }

    file.close();
    return true;
}

// === WaveformGenerator ===

WaveformGenerator::WaveformGenerator(QObject *parent)
    : QObject(parent)
    , m_workerThread(new QThread(this))
    , m_worker(new WaveformGeneratorWorker())
{
    m_worker->moveToThread(m_workerThread);

    // Thread befejezeskor torolni a worker-t
    connect(m_workerThread, &QThread::finished, m_worker, &QObject::deleteLater);

    // Generalas inditasa
    connect(this, &WaveformGenerator::startGeneration,
            m_worker, &WaveformGeneratorWorker::generateWaveform);

    // Cancel
    connect(this, &WaveformGenerator::requestCancel,
            m_worker, &WaveformGeneratorWorker::cancelGeneration);

    // Worker signal-ok tovabbitasa
    connect(m_worker, &WaveformGeneratorWorker::waveformGenerated,
            this, &WaveformGenerator::waveformReady);
    connect(m_worker, &WaveformGeneratorWorker::waveformProgress,
            this, &WaveformGenerator::waveformProgress);
    connect(m_worker, &WaveformGeneratorWorker::waveformError,
            this, &WaveformGenerator::waveformFailed);

    m_workerThread->start();
}

WaveformGenerator::~WaveformGenerator()
{
    m_workerThread->quit();
    m_workerThread->wait();
}

void WaveformGenerator::generateWaveform(const QString &sourceFilePath,
                                          const QString &outputPath,
                                          const QString &itemId)
{
    qDebug() << "WaveformGenerator::generateWaveform called for" << itemId;
    qDebug() << "  Source:" << sourceFilePath;
    qDebug() << "  Output:" << outputPath;
    emit startGeneration(sourceFilePath, outputPath, itemId);
}

void WaveformGenerator::cancelGeneration(const QString &itemId)
{
    emit requestCancel(itemId);
}

WaveformGenerator::CachedWaveform WaveformGenerator::cachedWaveform(const QString &waveformPath)
{
    auto it = m_waveformCache.constFind(waveformPath);
    if (it != m_waveformCache.constEnd()) {
        return it.value();
    }

    CachedWaveform cw;

    QFile file(waveformPath);
    if (!file.open(QIODevice::ReadOnly)) {
        qWarning() << "WaveformGenerator: Failed to open waveform file:" << waveformPath;
        m_waveformCache.insert(waveformPath, cw);
        return cw;
    }

    QDataStream stream(&file);
    stream.setByteOrder(QDataStream::LittleEndian);
    stream.setFloatingPointPrecision(QDataStream::SinglePrecision);

    // Header olvasasa
    char magic[4];
    stream.readRawData(magic, 4);
    if (strncmp(magic, "WFM1", 4) != 0) {
        qWarning() << "WaveformGenerator: Invalid waveform file format";
        file.close();
        m_waveformCache.insert(waveformPath, cw);
        return cw;
    }

    quint32 version, sampleCount, samplesPerSecond;
    stream >> version >> sampleCount >> samplesPerSecond;

    if (version != 1) {
        qWarning() << "WaveformGenerator: Unsupported waveform version:" << version;
        file.close();
        m_waveformCache.insert(waveformPath, cw);
        return cw;
    }

    cw.samplesPerSecond = static_cast<int>(samplesPerSecond);

    // Data olvasasa
    cw.samples.reserve(sampleCount);
    for (quint32 i = 0; i < sampleCount; i++) {
        float minVal, maxVal;
        stream >> minVal >> maxVal;

        QVariantMap sample;
        sample["min"] = minVal;
        sample["max"] = maxVal;
        cw.samples.append(sample);
    }

    file.close();
    m_waveformCache.insert(waveformPath, cw);
    return cw;
}

QVariantList WaveformGenerator::loadWaveform(const QString &waveformPath)
{
    return cachedWaveform(waveformPath).samples;
}

QVariantList WaveformGenerator::loadWaveformSlice(const QString &waveformPath, double startSeconds, double durationSeconds)
{
    CachedWaveform cw = cachedWaveform(waveformPath);
    if (cw.samples.isEmpty() || cw.samplesPerSecond <= 0 || durationSeconds <= 0) {
        return QVariantList();
    }

    int startIdx = qMax(0, static_cast<int>(startSeconds * cw.samplesPerSecond));
    int count = static_cast<int>(std::ceil(durationSeconds * cw.samplesPerSecond));
    int endIdx = qMin(cw.samples.size(), startIdx + count);
    if (startIdx >= endIdx) {
        return QVariantList();
    }

    return cw.samples.mid(startIdx, endIdx - startIdx);
}

bool WaveformGenerator::waveformExists(const QString &waveformPath)
{
    return QFile::exists(waveformPath);
}
