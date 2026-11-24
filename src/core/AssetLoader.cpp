#include "AssetLoader.h"
#include <QCoreApplication>
#include <QDebug>
#include <QMutex>
#include <QMutexLocker>
#include <QMetaObject>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <sys/stat.h>

// Qt "signals" keyword clashes with GLib (same dance as TimelineEngine.h)
#ifdef signals
#undef signals
#endif
#include <ges/ges.h>
#define signals Q_SIGNALS

struct AssetLoader::Gen {
    quint64 id = 0;
    std::mutex m;
    std::condition_variable cv;
    std::deque<std::pair<QString, bool>> queue;   // path, forceReload
    bool stop = false;
    bool abandoned = false;
    bool busy = false;        // canary or a job in progress (not waiting for work)
    bool running = false;     // a job in progress
    QString curPath;
    std::chrono::steady_clock::time_point curStart;
    bool withCanary = false;
    std::thread th;
};

// Lets a loader thread that outlives its AssetLoader (stuck, detached) deliver
// safely: owner is nulled in the destructor under the mutex.
struct AssetLoader::Bridge {
    QMutex m;
    AssetLoader *owner = nullptr;
};

namespace {

struct ReqCtx {
    GMainLoop *loop = nullptr;
    bool done = false;
    GESAsset *asset = nullptr;
    QString err;
};

void requestDone(GObject *, GAsyncResult *res, gpointer ud)
{
    ReqCtx *c = static_cast<ReqCtx *>(ud);
    GError *e = nullptr;
    // Transfer full: this single reference is handed to the main thread and
    // kept forever there.
    c->asset = ges_asset_request_finish(res, &e);
    if (e) {
        c->err = QString::fromUtf8(e->message);
        g_error_free(e);
    }
    if (!c->asset && c->err.isEmpty()) c->err = QStringLiteral("asset request returned no asset");
    c->done = true;
    g_main_loop_quit(c->loop);
}

void runJob(GMainContext *ctx, const QString &path, bool reload,
            int &status, GESAsset *&asset, QString &err)
{
    status = AssetLoader::Failed;
    asset = nullptr;

    // stat on THIS thread: it can hang on a dead disk just like open() can.
    struct stat st;
    const QByteArray p = path.toUtf8();
    if (::stat(p.constData(), &st) != 0) {
        status = AssetLoader::Missing;
        return;
    }
    gchar *uri = gst_filename_to_uri(p.constData(), nullptr);
    if (!uri) {
        err = QStringLiteral("invalid file path");
        return;
    }
    if (reload) ges_asset_needs_reload(GES_TYPE_URI_CLIP, uri);

    ReqCtx c;
    c.loop = g_main_loop_new(ctx, FALSE);
    ges_asset_request_async(GES_TYPE_URI_CLIP, uri, nullptr, requestDone, &c);
    // The callback may already have run inside request_async (cached asset);
    // g_main_loop_quit() before g_main_loop_run() would be lost.
    if (!c.done) g_main_loop_run(c.loop);
    g_main_loop_unref(c.loop);

    if (c.asset) {
        status = AssetLoader::Ok;
        asset = c.asset;
        // ges_asset_request_finish() returns the asset the task was created
        // for, i.e. the ORIGINAL even if a proxy was installed
        // (ges_asset_set_proxy, see ProxyAssets.cpp); the sync request used
        // to return the proxy. ges_asset_request() on this now cached,
        // initialized asset is a pure cache lookup (no discovery, no main
        // context iteration) that follows the proxy chain and returns a new
        // transfer-full reference to the final target - deliver that one.
        // The reference from request_finish is simply kept, never unreffed
        // (project policy: asset references are never released).
        GError *lerr = nullptr;
        GESAsset *resolved = ges_asset_request(GES_TYPE_URI_CLIP, uri, &lerr);
        if (lerr) g_error_free(lerr);
        if (resolved) asset = resolved;
    } else {
        err = c.err;
    }
    g_free(uri);
}

} // namespace

void AssetLoader::workerMain(std::shared_ptr<Gen> gen, std::shared_ptr<Bridge> bridge)
{
    // This thread's own context; never the global default one (see header).
    // Deliberately never unreffed: GES keeps one GstDiscoverer per calling
    // thread (keyed by GThread*) with sources attached to this context, and
    // it must stay valid for as long as that discoverer can be reused.
    GMainContext *ctx = g_main_context_new();
    g_main_context_push_thread_default(ctx);

    if (gen->withCanary) {
        // Takes and releases GES's asset-cache lock (ges_asset_cache_lookup ->
        // LOCK_CACHE) without creating any reference; an unknown id has no
        // side effect. Blocks for as long as an abandoned thread still holds
        // that lock inside a hung open().
        ges_asset_needs_reload(GES_TYPE_URI_CLIP, "file:///__gcs_cache_lock_canary__");
        const quint64 id = gen->id;
        QMutexLocker lk(&bridge->m);
        if (AssetLoader *o = bridge->owner)
            QMetaObject::invokeMethod(o, [o, id]() { o->onCanary(id); }, Qt::QueuedConnection);
    }
    {
        std::lock_guard<std::mutex> lk(gen->m);
        gen->busy = false;
    }

    for (;;) {
        QString path;
        bool reload = false;
        {
            std::unique_lock<std::mutex> lk(gen->m);
            gen->cv.wait(lk, [&] { return gen->stop || gen->abandoned || !gen->queue.empty(); });
            if (gen->stop || gen->abandoned) break;
            path = gen->queue.front().first;
            reload = gen->queue.front().second;
            gen->queue.pop_front();
            gen->busy = true;
            gen->running = true;
            gen->curPath = path;
            gen->curStart = std::chrono::steady_clock::now();
        }

        int status;
        GESAsset *asset;
        QString err;
        runJob(ctx, path, reload, status, asset, err);

        bool abandoned;
        {
            std::lock_guard<std::mutex> lk(gen->m);
            gen->running = false;
            gen->busy = false;
            gen->curPath.clear();
            abandoned = gen->abandoned;
        }
        {
            QMutexLocker lk(&bridge->m);
            if (AssetLoader *o = bridge->owner) {
                const quintptr a = reinterpret_cast<quintptr>(asset);
                QMetaObject::invokeMethod(o, [o, path, status, a, err, abandoned]() {
                    o->onResult(path, status, a, err, abandoned);
                }, Qt::QueuedConnection);
            }
            // owner gone (shutdown): nobody to take the reference, so it is
            // simply left alone (never unreffed, same policy as everywhere).
        }
        if (abandoned) break;
    }

    // An abandoned thread must not exit: its GThread* is the key of the GES
    // discoverer-manager entry bound to ctx; a later thread reusing that
    // address would pick up a discoverer whose context nobody iterates.
    // (Costs one parked thread per abandon; killed with the process.)
    bool park;
    {
        std::lock_guard<std::mutex> lk(gen->m);
        park = gen->abandoned && !gen->stop;
    }
    if (park) {
        std::mutex dummy;
        std::condition_variable never;
        std::unique_lock<std::mutex> lk(dummy);
        never.wait(lk, [] { return false; });
    }
    g_main_context_pop_thread_default(ctx);
}

AssetLoader::AssetLoader(QObject *parent)
    : QObject(parent)
    , m_bridge(std::make_shared<Bridge>())
{
    m_bridge->owner = this;
    // The engine lives in the QML engine, which is destroyed AFTER main()
    // called gst_deinit(); stop the loader thread before that.
    connect(qApp, &QCoreApplication::aboutToQuit, this, &AssetLoader::shutdown);
}

AssetLoader::~AssetLoader()
{
    shutdown();
    QMutexLocker lk(&m_bridge->m);
    m_bridge->owner = nullptr;
}

void AssetLoader::startGeneration(bool withCanary, const std::deque<std::pair<QString, bool>> &initial)
{
    auto gen = std::make_shared<Gen>();
    gen->id = m_nextGenId++;
    gen->queue = initial;
    gen->withCanary = withCanary;
    gen->busy = true;   // until the worker reaches its wait (covers the canary)
    m_gen = gen;
    if (withCanary) {
        m_cacheLockFree = false;
        m_canaryClock.start();
    }
    gen->th = std::thread(&AssetLoader::workerMain, gen, m_bridge);
}

AssetLoader *AssetLoader::shared()
{
    static AssetLoader *s = new AssetLoader(qApp);
    return s;
}

void AssetLoader::beginProxyPass()
{
    if (m_proxyPassActive) return;
    m_proxyPassActive = true;
    emit proxyPassStarted();
}

void AssetLoader::endProxyPass(bool changed)
{
    if (!m_proxyPassActive) return;
    m_proxyPassActive = false;
    emit proxyPassEnded(changed);
}

void AssetLoader::enqueue(const QStringList &paths, bool forceReload, int consumers)
{
    std::deque<std::pair<QString, bool>> fresh;
    for (const QString &p : paths) {
        if (m_outstanding.contains(p)) {
            m_interest[p] |= consumers;
            continue;
        }
        m_outstanding.insert(p);
        m_interest[p] = consumers;
        fresh.emplace_back(p, forceReload);
    }
    if (fresh.empty()) return;
    if (!m_gen) {
        startGeneration(false, fresh);
        return;
    }
    {
        std::lock_guard<std::mutex> lk(m_gen->m);
        for (auto &j : fresh) m_gen->queue.push_back(j);
    }
    m_gen->cv.notify_one();
}

AssetLoader::CurrentJob AssetLoader::currentJob() const
{
    CurrentJob j;
    if (!m_gen) return j;
    std::lock_guard<std::mutex> lk(m_gen->m);
    if (!m_gen->running) return j;
    j.valid = true;
    j.path = m_gen->curPath;
    j.runningMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::steady_clock::now() - m_gen->curStart).count();
    return j;
}

QStringList AssetLoader::queuedPaths() const
{
    QStringList out;
    if (!m_gen) return out;
    std::lock_guard<std::mutex> lk(m_gen->m);
    for (const auto &j : m_gen->queue) out << j.first;
    return out;
}

void AssetLoader::dropQueued()
{
    if (!m_gen) return;
    std::lock_guard<std::mutex> lk(m_gen->m);
    QStringList dropped;
    for (const auto &j : m_gen->queue) {
        m_outstanding.remove(j.first);
        m_interest.remove(j.first);
        dropped << j.first;
    }
    m_gen->queue.clear();
    if (!dropped.isEmpty())
        QMetaObject::invokeMethod(this, [this, dropped]() { emit pathsDropped(dropped, false); }, Qt::QueuedConnection);
}

void AssetLoader::abandonCurrentAndRestart(const QStringList &dropQueued)
{
    if (!m_gen) return;
    std::shared_ptr<Gen> old = m_gen;
    std::deque<std::pair<QString, bool>> remaining;
    QStringList dropped;
    {
        std::lock_guard<std::mutex> lk(old->m);
        old->abandoned = true;
        if (old->running) {
            m_outstanding.remove(old->curPath);
            m_interest.remove(old->curPath);
            dropped << old->curPath;
        }
        for (const auto &j : old->queue) {
            if (dropQueued.contains(j.first)) {
                m_outstanding.remove(j.first);
                m_interest.remove(j.first);
                dropped << j.first;
            } else remaining.push_back(j);
        }
        old->queue.clear();
    }
    old->cv.notify_all();
    if (old->th.joinable()) old->th.detach();
    qWarning() << "AssetLoader: abandoning loader thread" << old->id
               << "- continuing with" << remaining.size() << "queued path(s) on a fresh thread";
    startGeneration(true, remaining);
    if (!dropped.isEmpty())
        QMetaObject::invokeMethod(this, [this, dropped]() { emit pathsDropped(dropped, true); }, Qt::QueuedConnection);
}

void AssetLoader::shutdown()
{
    if (!m_gen) return;
    std::shared_ptr<Gen> g = m_gen;
    m_gen.reset();
    bool idle;
    {
        std::lock_guard<std::mutex> lk(g->m);
        g->stop = true;
        idle = !g->busy;
    }
    g->cv.notify_all();
    if (!g->th.joinable()) return;
    if (idle) g->th.join();
    else {
        qWarning() << "AssetLoader: loader thread still busy at shutdown - detaching it";
        g->th.detach();
    }
}

void AssetLoader::onResult(const QString &path, int status, quintptr asset, const QString &error, bool abandoned)
{
    // A late result of an abandoned load keeps the old behaviour (Engine only):
    // its path left the outstanding set (and the interest map) when abandoned,
    // and may meanwhile have been enqueued again.
    int mask = Engine;
    if (!abandoned) {
        m_outstanding.remove(path);
        mask = m_interest.take(path);
        if (mask == 0) mask = Engine;
    }
    // Proxy consumer first: its installs complete before the engine can resume.
    if (mask & Proxy) emit proxyResultReady(path, status, asset, error, abandoned);
    if (mask & Engine) emit resultReady(path, status, asset, error, abandoned);
}

void AssetLoader::onCanary(quint64 genId)
{
    if (!m_gen || m_gen->id != genId) return;
    m_cacheLockFree = true;
    qDebug() << "AssetLoader: cache-lock canary returned after" << m_canaryClock.elapsed() << "ms";
    emit cacheLockFreed();
}
