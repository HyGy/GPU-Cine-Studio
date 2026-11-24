#ifndef ASSETLOADER_H
#define ASSETLOADER_H

#include <QObject>
#include <QHash>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QElapsedTimer>
#include <deque>
#include <memory>
#include <utility>

// Resolves URI-clip assets (GESUriClipAsset) off the GUI thread, on ONE
// dedicated loader thread, so a source file whose disk stopped answering can
// only stall that thread, never the UI.
//
// Why a private GMainContext + ges_asset_request_async() instead of
// ges_uri_clip_asset_request_sync() on a worker: request_sync() runs a
// GMainLoop on the GLOBAL DEFAULT context, which in this app is the GUI
// thread's own Qt event dispatcher context - a worker calling it would iterate
// (and could dispatch Qt's sources on) the wrong thread. GstDiscoverer also
// attaches its timeout/bus sources to the creating thread's default context,
// so the discovery timeout cleanup (which blocks while a streaming thread is
// stuck in read()) now runs on the loader thread, not the GUI thread.
//
// Result assets are transfer-full GES references; ownership passes to the
// receiver (TimelineEngine keeps them forever in m_assetCache, never unreffed
// - see the INTENTIONALLY NOT UNREFFED comment in TimelineEngine.cpp).
//
// ONE instance is shared by everything that needs assets off the GUI thread
// (shared()): the timeline engine (Engine consumer) and BackendManager's proxy
// installation (Proxy consumer). A single thread keeps a hung file and GES's
// cache lock under one stuck-file handling (the engine's stall dialog). Each
// enqueued path remembers which consumers asked for it; its result is emitted
// as resultReady (Engine) and/or proxyResultReady (Proxy), so the engine never
// caches an original's asset that a still-pending proxy installation is about
// to replace. Both signals carry the same transfer-full reference: whoever
// keeps it keeps it forever, nobody unrefs.
//
// While a proxy pass is active (beginProxyPass()..endProxyPass()) the engine
// parks every clip list instead of resolving assets.
//
// All public methods are main-thread only.
class AssetLoader : public QObject {
    Q_OBJECT
public:
    enum Status { Ok = 0, Missing = 1, Failed = 2 };
    enum Consumer { Engine = 1, Proxy = 2 };

    explicit AssetLoader(QObject *parent = nullptr);
    ~AssetLoader() override;

    // The process-wide instance (created on first use, main thread, parent qApp).
    static AssetLoader *shared();

    // Queue paths (skips ones already queued/in flight). forceReload makes the
    // loader call ges_asset_needs_reload() first (GES caches a failed asset's
    // error, so a retry would otherwise just return the cached error).
    // consumers = OR of Consumer bits; a path already outstanding just gains the bits.
    void enqueue(const QStringList &paths, bool forceReload = false, int consumers = Engine);

    // A proxy installation pass (BackendManager) is running: the engine must
    // not resolve assets (it would consume an original's asset before its proxy
    // is installed). endProxyPass(changed) says whether installs/uninstalls changed.
    bool proxyPassActive() const { return m_proxyPassActive; }
    void beginProxyPass();
    void endProxyPass(bool changed);

    // True when every enqueued path has been delivered (or dropped).
    bool isIdle() const { return m_outstanding.isEmpty(); }
    bool isOutstanding(const QString &path) const { return m_outstanding.contains(path); }
    // False after abandonCurrentAndRestart() until the fresh thread's cache-lock
    // canary returned.
    bool cacheLockFree() const { return m_cacheLockFree; }
    // ms since the canary was started, -1 if not pending.
    qint64 canaryPendingMs() const { return m_cacheLockFree ? -1 : m_canaryClock.elapsed(); }

    struct CurrentJob { bool valid = false; QString path; qint64 runningMs = 0; };
    CurrentJob currentJob() const;
    // Paths queued but not yet started.
    QStringList queuedPaths() const;

    // The in-flight job cannot be cancelled: mark its thread abandoned (its
    // result is still delivered, flagged abandoned), remove dropQueued from the
    // queue, and continue the remaining queue on a FRESH thread (new private
    // context) that first runs the cache-lock canary. The in-flight path is
    // removed from the outstanding set.
    void abandonCurrentAndRestart(const QStringList &dropQueued);
    // Remove everything not yet started from the queue. The in-flight job stays.
    void dropQueued();

    // Stop an idle loader thread and join it; detach a stuck one. Idempotent.
    void shutdown();

signals:
    // asset is a GESAsset* (transfer full) when status == Ok, else 0.
    void resultReady(const QString &path, int status, quintptr asset,
                     const QString &error, bool abandoned);
    // Same payload as resultReady, for paths a Proxy consumer asked for.
    void proxyResultReady(const QString &path, int status, quintptr asset,
                          const QString &error, bool abandoned);
    // Paths removed from the loader without a result: dropQueued() (stuck =
    // false: loading was cancelled) or the in-flight path + dropped queued ones
    // of abandonCurrentAndRestart() (stuck = true: the file never answered).
    // Emitted queued (never from inside the caller).
    void pathsDropped(const QStringList &paths, bool stuck);
    void proxyPassStarted();
    void proxyPassEnded(bool changed);
    void cacheLockFreed();

private:
    struct Gen;
    struct Bridge;
    static void workerMain(std::shared_ptr<Gen> gen, std::shared_ptr<Bridge> bridge);
    void startGeneration(bool withCanary, const std::deque<std::pair<QString, bool>> &initial);
    void onResult(const QString &path, int status, quintptr asset, const QString &error, bool abandoned);
    void onCanary(quint64 genId);

    std::shared_ptr<Bridge> m_bridge;
    std::shared_ptr<Gen> m_gen;
    quint64 m_nextGenId = 1;
    QSet<QString> m_outstanding;   // enqueued, result not yet delivered to the main thread
    QHash<QString, int> m_interest;   // outstanding path -> Consumer bits
    bool m_proxyPassActive = false;
    bool m_cacheLockFree = true;
    QElapsedTimer m_canaryClock;
};

#endif
