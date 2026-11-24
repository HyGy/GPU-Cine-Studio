#ifndef WAVEFORMGENERATOR_H
#define WAVEFORMGENERATOR_H

#include <QObject>
#include <QString>
#include <QVector>
#include <QThread>
#include <QMutex>
#include <QHash>
#include <QVariant>
#include <gst/gst.h>

struct WaveformData {
    QVector<float> minValues;
    QVector<float> maxValues;
    int samplesPerSecond;
    double duration;
};

class WaveformGeneratorWorker : public QObject
{
    Q_OBJECT

public:
    explicit WaveformGeneratorWorker(QObject *parent = nullptr);
    ~WaveformGeneratorWorker();

public slots:
    void generateWaveform(const QString &sourceFilePath,
                          const QString &outputPath,
                          const QString &itemId);
    void cancelGeneration(const QString &itemId);

signals:
    void waveformGenerated(const QString &itemId, const QString &waveformPath);
    void waveformProgress(const QString &itemId, int percent);
    void waveformError(const QString &itemId, const QString &error);

private:
    bool extractAudioSamples(const QString &filePath,
                             QVector<float> &samples,
                             int &sampleRate,
                             const QString &itemId,
                             bool *noAudioStream = nullptr);
    WaveformData calculateWaveform(const QVector<float> &samples,
                                   int sampleRate,
                                   int targetSamplesPerSecond);
    bool saveWaveformToFile(const WaveformData &data, const QString &outputPath);

    QStringList m_cancelledItems;
    QMutex m_mutex;
};

class WaveformGenerator : public QObject
{
    Q_OBJECT

public:
    explicit WaveformGenerator(QObject *parent = nullptr);
    ~WaveformGenerator();

    // Waveform generalas inditasa (aszinkron)
    Q_INVOKABLE void generateWaveform(const QString &sourceFilePath,
                                      const QString &outputPath,
                                      const QString &itemId);

    // Generalas megszakitasa
    Q_INVOKABLE void cancelGeneration(const QString &itemId);

    // Waveform betoltese filebol QML-hez
    Q_INVOKABLE QVariantList loadWaveform(const QString &waveformPath);

    // Egy klip SAJÁT szeletét adja vissza a (cache-elt, egyszer parse-olt)
    // teljes waveform-ból, startSeconds-tól durationSeconds hosszan - a
    // visszaadott lista 0 INDEXTŐL kezdődik, a hívónak nem kell semmilyen
    // offsetet alkalmaznia rá (lásd WaveformView.sourceOffset: 0 a
    // TimelineClip.qml hívási helyén). Korábban minden klip delegate a
    // TELJES forrásfájl waveform-ját töltötte be (akár több tíz MB JS heap
    // egyetlen klipre), ráadásul minden alkalommal újra a lemezről olvasva -
    // ez most egyszer parse-olódik fájlonként (m_waveformCache), és csak a
    // klip saját, tényleges szelete kerül a QML oldalra.
    Q_INVOKABLE QVariantList loadWaveformSlice(const QString &waveformPath, double startSeconds, double durationSeconds);

    // Waveform file letezik-e
    Q_INVOKABLE bool waveformExists(const QString &waveformPath);

signals:
    void waveformReady(const QString &itemId, const QString &waveformPath);
    void waveformProgress(const QString &itemId, int percent);
    void waveformFailed(const QString &itemId, const QString &error);

    // Internal signals for thread communication
    void startGeneration(const QString &sourceFilePath,
                         const QString &outputPath,
                         const QString &itemId);
    void requestCancel(const QString &itemId);

private:
    struct CachedWaveform {
        QVariantList samples;
        int samplesPerSecond = 100;
    };
    // Keyed by waveform file path. Waveform files are write-once (never
    // modified after generation finishes), so there is no invalidation
    // logic - a path once parsed stays cached for the app's lifetime.
    QHash<QString, CachedWaveform> m_waveformCache;
    // Returned BY VALUE deliberately (not by reference) - QVariantList's
    // implicit sharing makes the copy cheap, and it sidesteps any
    // reference-lifetime question around a QHash that keeps growing as
    // more files are opened.
    CachedWaveform cachedWaveform(const QString &waveformPath);

    QThread *m_workerThread;
    WaveformGeneratorWorker *m_worker;
};

#endif // WAVEFORMGENERATOR_H
