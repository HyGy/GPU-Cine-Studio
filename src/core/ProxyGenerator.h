#ifndef PROXYGENERATOR_H
#define PROXYGENERATOR_H

#include <QObject>
#include <QString>
#include <QThread>
#include <QMutex>
#include <QStringList>
#include <gst/gst.h>

// Generates one proxy file for one (item, resolution) pair, on a worker
// thread - same threading shape as WaveformGenerator (QObject worker moved
// to its own QThread, signal/slot crossing the thread boundary). See
// proxy_build_plan.md Phase 3. Manual trigger only in this phase (a
// "Generate proxy" Project Bin context-menu action) - nothing calls this
// automatically yet (that's Phase 6).
class ProxyGeneratorWorker : public QObject
{
    Q_OBJECT

public:
    explicit ProxyGeneratorWorker(QObject *parent = nullptr);
    ~ProxyGeneratorWorker();

public slots:
    void generateProxy(const QString &sourceFilePath,
                        const QString &outputPath,
                        const QString &itemId,
                        const QString &resolution,
                        const QString &format,
                        int targetWidth,
                        int targetHeight,
                        const QString &device);
    void cancelGeneration(const QString &itemId, const QString &resolution);

signals:
    void proxyGenerated(const QString &itemId, const QString &resolution, const QString &proxyPath);
    void proxyProgress(const QString &itemId, const QString &resolution, int percent);
    void proxyError(const QString &itemId, const QString &resolution, const QString &error);
    // Fired once, right after pickVideoEncoder() resolves which backend
    // actually won (previously only qDebug'd) - lets the Proxy Queue UI
    // show the REAL device ("nvidia"/"vaapi"/"cpu") instead of just the
    // REQUESTED one ("auto"). Empty backend means no encoder step exists
    // for this format (raw_i420).
    void proxyBackendResolved(const QString &itemId, const QString &resolution, const QString &backend);

private:
    static QString cancelKey(const QString &itemId, const QString &resolution);
    bool isCancelled(const QString &key);

    QStringList m_cancelledKeys;
    QMutex m_mutex;
};

class ProxyGenerator : public QObject
{
    Q_OBJECT

public:
    explicit ProxyGenerator(QObject *parent = nullptr);
    ~ProxyGenerator();

    // device: one of Backend::availableEncoders()'s tokens ("nvidia",
    // "vaapi", "cpu"), the same vocabulary RenderEngine's own device
    // picker already uses (Phase 4) - empty string means auto (prefer
    // GPU, same fallback order as before Phase 4).
    // `resolution` (here and throughout this class/its worker) is, since
    // registry v3 (proxy_build_plan.md Part J.1), actually CacheManager's
    // opaque variant key ("<WxH>@<format>", e.g. "960x540@h264_intra") -
    // never parsed here, just echoed back unchanged through this class's
    // signals so CacheManager can match a completion/failure back to the
    // request that started it. Left named "resolution" rather than
    // renamed to "variantKey" throughout this file to avoid a sprawling,
    // purely-cosmetic rename with no behavior change - CacheManager.h's
    // setProxyGenerating/Ready/Failed() already name their own parameter
    // `variantKey` for the same value.
    Q_INVOKABLE void generateProxy(const QString &sourceFilePath,
                                   const QString &outputPath,
                                   const QString &itemId,
                                   const QString &resolution,
                                   const QString &format,
                                   int targetWidth,
                                   int targetHeight,
                                   const QString &device);
    Q_INVOKABLE void cancelGeneration(const QString &itemId, const QString &resolution);

signals:
    void proxyReady(const QString &itemId, const QString &resolution, const QString &proxyPath);
    void proxyProgress(const QString &itemId, const QString &resolution, int percent);
    void proxyFailed(const QString &itemId, const QString &resolution, const QString &error);
    // See ProxyGeneratorWorker::proxyBackendResolved() above - relayed
    // through unchanged.
    void proxyBackendResolved(const QString &itemId, const QString &resolution, const QString &backend);

    // Internal signals for thread communication (mirrors WaveformGenerator)
    void startGeneration(const QString &sourceFilePath,
                         const QString &outputPath,
                         const QString &itemId,
                         const QString &resolution,
                         const QString &format,
                         int targetWidth,
                         int targetHeight,
                         const QString &device);
    // No "requestCancel" signal - cancelGeneration() below calls the
    // worker directly (see ProxyGenerator.cpp's constructor comment for
    // why a queued cross-thread signal cannot interrupt a worker that's
    // blocked inside a synchronous generateProxy() call).

private:
    QThread *m_workerThread;
    ProxyGeneratorWorker *m_worker;
    // Tracks the one job the single worker thread can be running, so the
    // destructor can cancel it on app shutdown instead of blocking for
    // however long the remaining encode takes (minutes, on 4K). Only
    // touched from this (GUI-thread) object's own methods - never read or
    // written from m_workerThread - so no mutex needed here.
    bool m_generating = false;
    QString m_currentItemId;
    QString m_currentResolution;
};

#endif // PROXYGENERATOR_H
