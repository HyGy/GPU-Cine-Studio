#include "CacheManager.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QDebug>
#include <QRegularExpression>
#include <QCryptographicHash>

CacheManager::CacheManager(QObject *parent)
    : QObject(parent)
    , m_maxConcurrentGenerations(2)
{
}

CacheManager::~CacheManager()
{
    saveRegistry();
}

void CacheManager::initialize(const QString &projectDir, bool isNewProject)
{
    m_projectDir = projectDir;
    m_cacheDir = projectDir + "/.cache";
    m_registryPath = m_cacheDir + "/cache_registry.json";

    // Cache konyvtarak letrehozasa
    QDir dir;
    dir.mkpath(m_cacheDir + "/waveforms");
    dir.mkpath(m_cacheDir + "/proxies");

    emit cacheDirChanged();

    if (isNewProject) {
        // Szandekosan NEM hivjuk loadRegistry()-t, es torljuk, amit ez
        // a CacheManager instance esetleg egy korabban megnyitott
        // projektbol meg a memoriaban tart - egy brand-new projektnek
        // semmi koze a mappa korabbi (akar teljesen fuggetlen) cache
        // allapotahoz. A kovetkezo saveRegistry() hivas (uj item
        // regisztralasakor) felul fogja irni a regi cache_registry.json-t
        // ezzel az ures/uj allapottal.
        m_items.clear();
        m_pendingQueue.clear();
        m_currentlyGenerating.clear();
        m_pendingProxyQueue.clear();
        m_currentlyGeneratingProxy.clear();
        emit pendingCountChanged();
        emit generatingCountChanged();
    } else {
        // Registry betoltese (meglevo projekt megnyitasa/visszatoltese)
        loadRegistry();

        // Validacio: forrasfileok meg leteznek/valtozatlanok?
        validateAllItems();
    }
}

void CacheManager::registerItem(const QString &itemId, const QString &sourcePath)
{
    QFileInfo fileInfo(sourcePath);
    if (!fileInfo.exists()) {
        qWarning() << "CacheManager: Source file does not exist:" << sourcePath;
        // The project now points this item at a path that is missing. A
        // registry entry still holding an older path (e.g. a relink that
        // was not kept, or an older copy of the project file opened) must
        // not stay behind: sourceAvailable()/proxy generation would
        // otherwise treat the item as available and build its proxy from
        // a different file than the one the project uses. Record the
        // project's path; mediaBecameAvailable() re-validates it later.
        auto it = m_items.find(itemId);
        if (it != m_items.end() && it->sourcePath != sourcePath) {
            it->sourcePath = sourcePath;
            m_pendingQueue.removeAll(itemId);
            saveRegistry();
        }
        return;
    }

    if (m_items.contains(itemId)) {
        // Mar letezik, ellenorizzuk hogy valtozott-e
        CacheItemInfo &info = m_items[itemId];
        if (info.sourcePath != sourcePath || !isSourceValid(info)) {
            // Forrasfile valtozott, invalidalas
            info.sourcePath = sourcePath;
            info.sourceModified = fileInfo.lastModified();
            info.sourceSize = fileInfo.size();
            info.waveform.status = "pending";
            info.waveform.path.clear();
            info.waveform.progress = 0;

            if (!m_pendingQueue.contains(itemId)) {
                m_pendingQueue.enqueue(itemId);
            }
            emit itemStatusChanged(itemId, "waveform", "pending", 0);
            emit pendingCountChanged();
        }
    } else {
        // Uj item
        CacheItemInfo info;
        info.itemId = itemId;
        info.sourcePath = sourcePath;
        info.sourceModified = fileInfo.lastModified();
        info.sourceSize = fileInfo.size();
        info.waveform.status = "pending";
        info.waveform.progress = 0;

        m_items[itemId] = info;
        m_pendingQueue.enqueue(itemId);

        emit itemStatusChanged(itemId, "waveform", "pending", 0);
        emit pendingCountChanged();

        qDebug() << "CacheManager: Registered new item" << itemId << "- starting generation";
    }

    saveRegistry();

    // Start generation if not already running
    startPendingGeneration();
}

void CacheManager::relinkItem(const QString &itemId, const QString &newPath)
{
    if (!m_items.contains(itemId)) {
        registerItem(itemId, newPath);
        return;
    }
    QFileInfo fi(newPath);
    if (!fi.exists()) return;
    CacheItemInfo &info = m_items[itemId];
    const bool sameContent = (fi.size() == info.sourceSize);
    info.sourcePath = newPath;
    info.sourceModified = fi.lastModified();
    if (!sameContent) {
        info.sourceSize = fi.size();
        info.waveform.status = "pending";
        info.waveform.path.clear();
        info.waveform.progress = 0;
        for (auto pit = info.proxies.begin(); pit != info.proxies.end(); ++pit) {
            if (pit.value().status == "ready") {
                pit.value().status = "invalid";
                pit.value().progress = 0;
            }
        }
        emit itemStatusChanged(itemId, "waveform", "pending", 0);
    }
    if (info.waveform.status != "ready" && info.waveform.status != "generating"
        && info.waveform.status != "no-audio") {
        info.waveform.status = "pending";
        info.waveform.progress = 0;
        emit itemStatusChanged(itemId, "waveform", "pending", 0);
    }
    if (info.waveform.status == "pending" && !m_pendingQueue.contains(itemId))
        m_pendingQueue.enqueue(itemId);
    emit pendingCountChanged();
    saveRegistry();
    startPendingGeneration();
}

void CacheManager::mediaBecameAvailable(const QString &itemId, const QString &path)
{
    if (!m_items.contains(itemId)) {
        registerItem(itemId, path);
        return;
    }
    CacheItemInfo &info = m_items[itemId];
    if (info.sourcePath != path) {
        relinkItem(itemId, path);
        return;
    }
    registerItem(itemId, path);   // re-validates size against the registry
    if (info.waveform.status != "ready" && info.waveform.status != "generating"
        && info.waveform.status != "no-audio") {
        info.waveform.status = "pending";
        info.waveform.progress = 0;
        if (!m_pendingQueue.contains(itemId)) m_pendingQueue.enqueue(itemId);
        emit itemStatusChanged(itemId, "waveform", "pending", 0);
        emit pendingCountChanged();
        saveRegistry();
        startPendingGeneration();
    }
}

void CacheManager::unregisterItem(const QString &itemId)
{
    if (!m_items.contains(itemId)) return;

    // Waveform file torlese
    CacheItemInfo &info = m_items[itemId];
    if (!info.waveform.path.isEmpty()) {
        QString fullPath = m_cacheDir + "/" + info.waveform.path;
        if (QFile::exists(fullPath)) {
            QFile::remove(fullPath);
        }
    }
    // Proxy fileok torlese (minden felbontas)
    for (auto it = info.proxies.constBegin(); it != info.proxies.constEnd(); ++it) {
        if (it.value().path.isEmpty()) continue;
        QString fullPath = m_cacheDir + "/" + it.value().path;
        if (QFile::exists(fullPath)) {
            QFile::remove(fullPath);
        }
    }

    // Proxy queue bookkeeping - the exact counterpart of the two
    // m_pendingQueue/m_currentlyGenerating lines below, which the proxy
    // queues need just as much. Without this, deleting a bin item while
    // its proxy is generating leaves a stale key in
    // m_currentlyGeneratingProxy forever (setProxyReady/setProxyFailed
    // both early-return once m_items no longer has the item, so neither
    // ever clears it) - and since only ONE concurrent proxy generation is
    // allowed, processNextPendingProxy() would then refuse to start any
    // further proxy for the rest of the session.
    const QString proxyKeyPrefix = itemId + "|";
    for (const QString &running : m_currentlyGeneratingProxy) {
        if (!running.startsWith(proxyKeyPrefix)) continue;
        // Stop the encode: the item is about to stop existing, so finishing
        // it would burn minutes of GPU time for a file nothing can
        // reference. The worker's cancel path also removes its own partial
        // output file (which isn't covered by the deletion loop above -
        // artifact.path is only filled in once generation SUCCEEDS).
        emit requestProxyCancel(itemId, running.mid(proxyKeyPrefix.size()));
    }

    QQueue<QString> remainingProxies;
    while (!m_pendingProxyQueue.isEmpty()) {
        const QString entry = m_pendingProxyQueue.dequeue();
        if (!entry.startsWith(proxyKeyPrefix)) remainingProxies.enqueue(entry);
    }
    m_pendingProxyQueue = remainingProxies;

    QStringList remainingRunning;
    for (const QString &running : m_currentlyGeneratingProxy) {
        if (!running.startsWith(proxyKeyPrefix)) remainingRunning.append(running);
    }
    const bool proxyGeneratingCountChanged = (remainingRunning.size() != m_currentlyGeneratingProxy.size());
    m_currentlyGeneratingProxy = remainingRunning;
    if (proxyGeneratingCountChanged) emit generatingProxyCountChanged();

    m_items.remove(itemId);
    m_pendingQueue.removeAll(itemId);
    m_currentlyGenerating.removeAll(itemId);

    saveRegistry();
    emit pendingCountChanged();
    emit generatingCountChanged();

    // A generation slot may have just been freed - let a queued proxy for
    // some other item take it.
    processNextPendingProxy();
}

void CacheManager::cancelAllProxyGeneration()
{
    // Used by main.qml's shutdown sequence (Backend.forceQuit() is a raw
    // _exit(0) that bypasses every C++ destructor) so closing the app
    // doesn't leave a truncated, half-written proxy file on disk.
    m_pendingProxyQueue.clear();

    for (const QString &running : m_currentlyGeneratingProxy) {
        const int sep = running.indexOf('|');
        if (sep < 0) continue;
        // setProxyFailed() (called once the worker confirms it actually
        // stopped) does the real list cleanup + generatingProxyCountChanged
        // emit - this call just requests the stop.
        emit requestProxyCancel(running.left(sep), running.mid(sep + 1));
    }
}

QString CacheManager::getWaveformStatus(const QString &itemId) const
{
    if (!m_items.contains(itemId)) return "unknown";
    return m_items[itemId].waveform.status;
}

QString CacheManager::getWaveformPath(const QString &itemId) const
{
    if (!m_items.contains(itemId)) return QString();
    const CacheItemInfo &info = m_items[itemId];
    if (info.waveform.status != "ready") return QString();
    return m_cacheDir + "/" + info.waveform.path;
}

int CacheManager::getWaveformProgress(const QString &itemId) const
{
    if (!m_items.contains(itemId)) return 0;
    return m_items[itemId].waveform.progress;
}

bool CacheManager::isWaveformReady(const QString &itemId) const
{
    if (!m_items.contains(itemId)) return false;
    return m_items[itemId].waveform.status == "ready";
}

QString CacheManager::proxyVariantKey(const QString &resolution, const QString &format)
{
    return resolution + "@" + format;
}

bool CacheManager::parseProxyVariantKey(const QString &key, QString *resolution, QString *format)
{
    if (key.isEmpty()) return false;
    const int at = key.indexOf('@');
    if (at < 0) {
        // Legacy (pre-v3) key: the whole thing IS the resolution, no
        // format recorded in the key itself (loadRegistry()'s migration
        // recovers it from the artifact's own `format` field or, failing
        // that, by reverse-matching the proxy filename).
        if (resolution) *resolution = key;
        if (format) *format = QString();
        return true;
    }
    if (resolution) *resolution = key.left(at);
    if (format) *format = key.mid(at + 1);
    return true;
}

QString CacheManager::bestProxyStatus(const QMap<QString, CacheArtifact> &proxies, const QString &resolutionFilter)
{
    // Priority order a caller asking "what's the status" actually wants -
    // e.g. one variant "ready" and a different one "failed" must report
    // "ready", not whichever key happens to sort first.
    static const QStringList priority = {"ready", "generating", "pending", "failed", "invalid"};
    QString best;
    for (auto it = proxies.constBegin(); it != proxies.constEnd(); ++it) {
        if (!resolutionFilter.isEmpty()) {
            QString res;
            parseProxyVariantKey(it.key(), &res, nullptr);
            if (res != resolutionFilter) continue;
        }
        const QString &status = it.value().status;
        if (best.isEmpty()) { best = status; continue; }
        int bestRank = priority.indexOf(best);
        int statusRank = priority.indexOf(status);
        // Unrecognized statuses (shouldn't happen) sort last.
        if (bestRank < 0) bestRank = priority.size();
        if (statusRank < 0) statusRank = priority.size();
        if (statusRank < bestRank) best = status;
    }
    return best.isEmpty() ? "none" : best;
}

QString CacheManager::getProxyStatus(const QString &itemId, const QString &resolution, const QString &format) const
{
    if (!m_items.contains(itemId)) return "none";
    const CacheItemInfo &info = m_items[itemId];
    if (!resolution.isEmpty() && !format.isEmpty()) {
        const QString key = proxyVariantKey(resolution, format);
        return info.proxies.contains(key) ? info.proxies[key].status : "none";
    }
    return bestProxyStatus(info.proxies, resolution);
}

QString CacheManager::getProxyPath(const QString &itemId, const QString &resolution, const QString &format) const
{
    if (!m_items.contains(itemId)) return QString();
    const CacheItemInfo &info = m_items[itemId];
    if (!resolution.isEmpty() && !format.isEmpty()) {
        auto it = info.proxies.constFind(proxyVariantKey(resolution, format));
        if (it == info.proxies.constEnd() || it.value().status != "ready") return QString();
        return m_cacheDir + "/" + it.value().path;
    }
    // "Any variant" mode: first READY one (matching resolution if given) -
    // a pending/failed entry is never a usable path regardless of order.
    for (auto it = info.proxies.constBegin(); it != info.proxies.constEnd(); ++it) {
        if (it.value().status != "ready") continue;
        if (!resolution.isEmpty()) {
            QString res;
            parseProxyVariantKey(it.key(), &res, nullptr);
            if (res != resolution) continue;
        }
        return m_cacheDir + "/" + it.value().path;
    }
    return QString();
}

int CacheManager::getProxyProgress(const QString &itemId, const QString &resolution, const QString &format) const
{
    if (!m_items.contains(itemId)) return 0;
    const CacheItemInfo &info = m_items[itemId];
    if (!resolution.isEmpty() && !format.isEmpty()) {
        const QString key = proxyVariantKey(resolution, format);
        return info.proxies.contains(key) ? info.proxies[key].progress : 0;
    }
    // "Any variant" mode: the progress of whichever variant
    // bestProxyStatus() would report, so the two stay consistent.
    const QString status = bestProxyStatus(info.proxies, resolution);
    for (auto it = info.proxies.constBegin(); it != info.proxies.constEnd(); ++it) {
        if (!resolution.isEmpty()) {
            QString res;
            parseProxyVariantKey(it.key(), &res, nullptr);
            if (res != resolution) continue;
        }
        if (it.value().status == status) return it.value().progress;
    }
    return 0;
}

QStringList CacheManager::getProxyResolutions(const QString &itemId) const
{
    if (!m_items.contains(itemId)) return QStringList();
    QStringList out;
    for (auto it = m_items[itemId].proxies.constBegin(); it != m_items[itemId].proxies.constEnd(); ++it) {
        QString res;
        parseProxyVariantKey(it.key(), &res, nullptr);
        if (!out.contains(res)) out.append(res);
    }
    return out;
}

QStringList CacheManager::getProxyVariants(const QString &itemId) const
{
    if (!m_items.contains(itemId)) return QStringList();
    return m_items[itemId].proxies.keys();
}

QStringList CacheManager::getAvailableProxyVariants() const
{
    QStringList out;
    for (auto iit = m_items.constBegin(); iit != m_items.constEnd(); ++iit) {
        for (auto pit = iit.value().proxies.constBegin(); pit != iit.value().proxies.constEnd(); ++pit) {
            if (pit.value().status != "ready") continue;
            if (!out.contains(pit.key())) out.append(pit.key());
        }
    }
    out.sort();
    return out;
}

void CacheManager::setWaveformGenerating(const QString &itemId, int progress)
{
    if (!m_items.contains(itemId)) return;

    CacheItemInfo &info = m_items[itemId];
    info.waveform.status = "generating";
    info.waveform.progress = progress;

    emit itemStatusChanged(itemId, "waveform", "generating", progress);

    // Periodikusan mentunk (ne minden progress update-nel)
    if (progress % 25 == 0) {
        saveRegistry();
    }
}

void CacheManager::setWaveformReady(const QString &itemId, const QString &path)
{
    if (!m_items.contains(itemId)) return;

    CacheItemInfo &info = m_items[itemId];
    info.waveform.path = "waveforms/" + itemId + ".wfm";

    // The worker's output path was resolved against whatever m_cacheDir
    // was when generation STARTED. If the project's folder changed since
    // then (Save As) - or the cache dir was wiped underneath us - the file
    // is not where this registry entry now claims. Re-queue instead of
    // recording a "ready" entry that points at nothing.
    if (!QFile::exists(m_cacheDir + "/" + info.waveform.path)) {
        qWarning() << "CacheManager: waveform missing after generation (cache dir"
                   << "changed?) - re-queueing" << itemId;
        info.waveform.status = "pending";
        info.waveform.progress = 0;
        m_currentlyGenerating.removeAll(itemId);
        if (!m_pendingQueue.contains(itemId)) m_pendingQueue.enqueue(itemId);
        saveRegistry();
        emit itemStatusChanged(itemId, "waveform", "pending", 0);
        emit pendingCountChanged();
        emit generatingCountChanged();
        processNextPending();
        return;
    }

    info.waveform.status = "ready";
    info.waveform.generatedAt = QDateTime::currentDateTime();
    info.waveform.progress = 100;

    m_currentlyGenerating.removeAll(itemId);

    saveRegistry();

    emit itemStatusChanged(itemId, "waveform", "ready", 100);
    emit waveformReady(itemId, getWaveformPath(itemId));
    emit generatingCountChanged();

    // Kovetkezo pending item feldolgozasa
    processNextPending();
}

void CacheManager::setWaveformFailed(const QString &itemId, const QString &error)
{
    if (!m_items.contains(itemId)) return;

    CacheItemInfo &info = m_items[itemId];
    // "no-audio" is a distinct, TERMINAL status, deliberately not
    // "failed" - a video-only source can never grow an audio track, so
    // unlike a genuine (maybe-transient) failure, this must never be
    // retried. regenerateInvalidItems() only sweeps up "invalid"/
    // "failed"; leaving this out of that set is what makes it terminal.
    // See WaveformGeneratorWorker::extractAudioSamples()'s n-audio
    // pre-check, which is what produces this exact sentinel string.
    const QString status = (error == QLatin1String("NO_AUDIO_STREAM")) ? "no-audio" : "failed";
    info.waveform.status = status;
    info.waveform.progress = 0;

    m_currentlyGenerating.removeAll(itemId);

    saveRegistry();

    emit itemStatusChanged(itemId, "waveform", status, 0);
    emit waveformFailed(itemId, error);
    emit generatingCountChanged();

    processNextPending();
}

void CacheManager::validateAllItems()
{
    int invalidCount = 0;

    for (auto it = m_items.begin(); it != m_items.end(); ++it) {
        CacheItemInfo &info = it.value();

        // Forrasfile ellenorzese
        if (!isSourceValid(info)) {
            // Forrasfile valtozott vagy nem letezik
            if (QFile::exists(info.sourcePath)) {
                // Valtozott, ujrageneralas kell
                info.waveform.status = "invalid";
                info.waveform.progress = 0;
                invalidCount++;
                // Any existing proxy was generated against the OLD
                // content - its fingerprint filename would differ for
                // genuinely different content (proxy_build_plan.md A.4),
                // but the registry entry still points at the stale file
                // until something regenerates it. Mark invalid rather
                // than silently keep serving it as "ready".
                for (auto pit = info.proxies.begin(); pit != info.proxies.end(); ++pit) {
                    if (pit.value().status == "ready") {
                        pit.value().status = "invalid";
                        pit.value().progress = 0;
                    }
                }
            } else {
                // Nem letezik - ezt a ProjectBinModel-nek kell kezelnie
                qWarning() << "CacheManager: Source file missing:" << info.sourcePath;
            }
        }

        // "generating" statuszu item-ek visszaallitasa "pending"-re
        // (ha az app crashelt vagy kilepett generalas kozben)
        if (info.waveform.status == "generating") {
            info.waveform.status = "pending";
            info.waveform.progress = 0;
            if (!m_pendingQueue.contains(it.key())) {
                m_pendingQueue.enqueue(it.key());
            }
        }

        // Waveform file letezesenek ellenorzese "ready" statussznal
        if (info.waveform.status == "ready") {
            QString fullPath = m_cacheDir + "/" + info.waveform.path;
            if (!QFile::exists(fullPath)) {
                info.waveform.status = "pending";
                info.waveform.progress = 0;
                if (!m_pendingQueue.contains(it.key())) {
                    m_pendingQueue.enqueue(it.key());
                }
            }
        }

        // Proxy kronologia: "generating" -> "failed" uj projektmegnyitaskor
        // (crash/kilepes kozben) - MASHOGYAN mint a waveform-nal: "pending"
        // helyett "failed", mert ujraindulas utan nincs automatikus proxy
        // generalas (Phase 6-ig), igy "pending"-ben hagyva orokre ott
        // ragadna, sosem keruIne feldolgozasra a manualis trigger nelkul -
        // "failed" legalabb lathato es a felhasznalo ujraindithatja.
        for (auto pit = info.proxies.begin(); pit != info.proxies.end(); ++pit) {
            if (pit.value().status == "generating" || pit.value().status == "pending") {
                pit.value().status = "failed";
                pit.value().progress = 0;
            } else if (pit.value().status == "ready") {
                QString fullPath = m_cacheDir + "/" + pit.value().path;
                if (!QFile::exists(fullPath)) {
                    pit.value().status = "failed";
                    pit.value().progress = 0;
                }
            }
        }
    }

    saveRegistry();
    emit validationCompleted(invalidCount);
    emit pendingCountChanged();
}

void CacheManager::regenerateInvalidItems()
{
    for (auto it = m_items.begin(); it != m_items.end(); ++it) {
        if (it.value().waveform.status == "invalid" ||
            it.value().waveform.status == "failed") {
            it.value().waveform.status = "pending";
            it.value().waveform.progress = 0;
            if (!m_pendingQueue.contains(it.key())) {
                m_pendingQueue.enqueue(it.key());
            }
        }
    }

    saveRegistry();
    emit pendingCountChanged();
    startPendingGeneration();
}

void CacheManager::startPendingGeneration()
{
    qDebug() << "CacheManager::startPendingGeneration - pending:" << m_pendingQueue.size()
             << "generating:" << m_currentlyGenerating.size();

    while (m_currentlyGenerating.size() < m_maxConcurrentGenerations &&
           !m_pendingQueue.isEmpty()) {
        processNextPending();
    }
}

QStringList CacheManager::getPendingItems() const
{
    return m_pendingQueue.toList();
}

QStringList CacheManager::getGeneratingItems() const
{
    return m_currentlyGenerating;
}

QString CacheManager::getNextPendingItem()
{
    if (m_pendingQueue.isEmpty()) return QString();
    return m_pendingQueue.head();
}

CacheItemInfo CacheManager::getItemInfo(const QString &itemId) const
{
    if (m_items.contains(itemId)) {
        return m_items[itemId];
    }
    return CacheItemInfo();
}

int CacheManager::pendingCount() const
{
    return m_pendingQueue.size();
}

int CacheManager::generatingCount() const
{
    return m_currentlyGenerating.size();
}

void CacheManager::saveRegistry()
{
    if (m_registryPath.isEmpty()) return;

    QJsonObject root;
    root["version"] = 3;
    root["lastUpdated"] = QDateTime::currentDateTime().toString(Qt::ISODate);

    QJsonObject items;
    for (auto it = m_items.constBegin(); it != m_items.constEnd(); ++it) {
        const CacheItemInfo &info = it.value();

        QJsonObject itemObj;
        itemObj["sourcePath"] = info.sourcePath;
        itemObj["sourceModified"] = info.sourceModified.toString(Qt::ISODate);
        itemObj["sourceSize"] = info.sourceSize;

        QJsonObject waveformObj;
        waveformObj["status"] = info.waveform.status;
        waveformObj["path"] = info.waveform.path;
        waveformObj["generatedAt"] = info.waveform.generatedAt.toString(Qt::ISODate);
        waveformObj["progress"] = info.waveform.progress;
        itemObj["waveform"] = waveformObj;

        // v3: VARIANT-keyed ("<WxH>@<format>") proxy artifacts - see
        // proxyVariantKey()/Part J.1. In-memory, info.proxies' keys are
        // already variant keys by the time saveRegistry() runs (loadRegistry()
        // migrates any legacy key on read, before anything else touches
        // m_items), so writing pit.key() verbatim here is always correct;
        // no migration logic belongs on the save side. Omitted entirely
        // when empty rather than writing "proxies": {} - keeps a file with
        // no proxies yet byte-for-byte compatible with what v1 loading
        // code already tolerates (a missing key, not an empty object).
        if (!info.proxies.isEmpty()) {
            QJsonObject proxiesObj;
            for (auto pit = info.proxies.constBegin(); pit != info.proxies.constEnd(); ++pit) {
                const CacheArtifact &artifact = pit.value();
                QJsonObject artifactObj;
                artifactObj["status"] = artifact.status;
                artifactObj["path"] = artifact.path;
                artifactObj["generatedAt"] = artifact.generatedAt.toString(Qt::ISODate);
                artifactObj["progress"] = artifact.progress;
                artifactObj["format"] = artifact.format;
                proxiesObj[pit.key()] = artifactObj;
            }
            itemObj["proxies"] = proxiesObj;
        }

        items[it.key()] = itemObj;
    }

    root["items"] = items;

    QFile file(m_registryPath);
    if (file.open(QIODevice::WriteOnly)) {
        file.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
        file.close();
    } else {
        qWarning() << "CacheManager: Failed to save registry:" << m_registryPath;
    }
}

void CacheManager::loadRegistry()
{
    m_items.clear();
    m_pendingQueue.clear();
    m_currentlyGenerating.clear();
    m_pendingProxyQueue.clear();
    m_currentlyGeneratingProxy.clear();

    QFile file(m_registryPath);
    if (!file.open(QIODevice::ReadOnly)) {
        return;  // Nincs meg registry
    }

    QJsonDocument doc = QJsonDocument::fromJson(file.readAll());
    file.close();

    if (!doc.isObject()) return;

    QJsonObject root = doc.object();
    QJsonObject items = root["items"].toObject();

    for (auto it = items.constBegin(); it != items.constEnd(); ++it) {
        QJsonObject itemObj = it.value().toObject();
        QJsonObject waveformObj = itemObj["waveform"].toObject();

        CacheItemInfo info;
        info.itemId = it.key();
        info.sourcePath = itemObj["sourcePath"].toString();
        info.sourceModified = QDateTime::fromString(itemObj["sourceModified"].toString(), Qt::ISODate);
        info.sourceSize = itemObj["sourceSize"].toVariant().toLongLong();

        info.waveform.status = waveformObj["status"].toString();
        info.waveform.path = waveformObj["path"].toString();
        info.waveform.generatedAt = QDateTime::fromString(waveformObj["generatedAt"].toString(), Qt::ISODate);
        info.waveform.progress = waveformObj["progress"].toInt();

        // v1 registries (no "version" key, or version 1) simply have no
        // "proxies" key - itemObj["proxies"] then default-constructs to
        // QJsonValue::Undefined, .toObject() returns an empty object, and
        // the loop below runs zero times. No explicit version branch
        // needed; this is naturally backward-compatible.
        QJsonObject proxiesObj = itemObj["proxies"].toObject();
        for (auto pit = proxiesObj.constBegin(); pit != proxiesObj.constEnd(); ++pit) {
            QJsonObject artifactObj = pit.value().toObject();
            CacheArtifact artifact;
            artifact.status = artifactObj["status"].toString();
            artifact.path = artifactObj["path"].toString();
            artifact.generatedAt = QDateTime::fromString(artifactObj["generatedAt"].toString(), Qt::ISODate);
            artifact.progress = artifactObj["progress"].toInt();
            artifact.format = artifactObj["format"].toString();

            // Registry v2 -> v3 migration (Part J.1.6): a key with no '@'
            // is a legacy resolution-only key. NOTHING on disk changes
            // here - proxy filenames already hash the format in, so two
            // formats at one resolution are already two distinct files;
            // this only changes how the REGISTRY addresses them. Keyed
            // off the key's own shape, not root["version"], so a hand-
            // edited or partially-migrated file still works.
            QString newKey = pit.key();
            if (!newKey.contains('@')) {
                if (!artifact.format.isEmpty()) {
                    // Normal case since Phase 1: the artifact already
                    // carries its format, just not in the key. Lossless.
                    newKey = proxyVariantKey(pit.key(), artifact.format);
                } else if (!artifact.path.isEmpty()) {
                    // Format missing from BOTH the key and the artifact -
                    // an entry written before Phase 1 stored it. Recover
                    // it by exploiting proxyFileName()'s determinism:
                    // recompute it for each known format token and see
                    // which one matches the actual filename on disk.
                    static const QStringList kKnownFormats = {
                        "h264_intra", "h264_longgop", "h265_intra",
                        "mjpeg", "raw_i420", "dnxhr_lb"
                    };
                    const QString actualFileName = QFileInfo(artifact.path).fileName();
                    QString recoveredFormat;
                    for (const QString &candidate : kKnownFormats) {
                        if (proxyFileName(info, pit.key(), candidate) == actualFileName) {
                            recoveredFormat = candidate;
                            break;
                        }
                    }
                    if (!recoveredFormat.isEmpty()) {
                        artifact.format = recoveredFormat;
                        newKey = proxyVariantKey(pit.key(), recoveredFormat);
                    } else {
                        qWarning() << "CacheManager: registry v3 migration - could not recover"
                                   << "format for" << info.itemId << pit.key()
                                   << "(" << actualFileName << ") - dropping registry entry,"
                                   << "the file on disk is untouched and will show as an orphan"
                                   << "in the cache browser";
                        continue; // drop this artifact entirely, file left alone
                    }
                } else {
                    // No format anywhere AND no path (never finished, or a
                    // hand-edited file) - nothing to recover, nothing to
                    // orphan either since there's no file reference.
                    qWarning() << "CacheManager: registry v3 migration - dropping unrecoverable"
                               << "legacy proxy entry for" << info.itemId << pit.key();
                    continue;
                }
            }

            // Collision (only reachable from a hand-edited registry: two
            // legacy keys recovering to the same variant) - keep whichever
            // still has a file on disk, else the newer one.
            if (info.proxies.contains(newKey)) {
                const CacheArtifact &existing = info.proxies[newKey];
                const bool existingFileExists = !existing.path.isEmpty() && QFile::exists(m_cacheDir + "/" + existing.path);
                const bool newFileExists = !artifact.path.isEmpty() && QFile::exists(m_cacheDir + "/" + artifact.path);
                qWarning() << "CacheManager: registry v3 migration - collision on" << newKey
                           << "for" << info.itemId << "- keeping the entry with a file present"
                           << "(or the newer one)";
                if (existingFileExists && !newFileExists) continue;
                if (!existingFileExists && newFileExists) { /* fall through, overwrite */ }
                else if (existing.generatedAt >= artifact.generatedAt) continue;
            }

            // A "pending"/"generating" artifact persisted to disk means the
            // app closed (crash, or forceQuit()'s _exit(0) after
            // cancelAllProxyGeneration() cleared the in-memory queue
            // without resetting the artifacts it dropped) while this proxy
            // was queued or running. Unlike loadRegistry()'s waveform
            // handling, this is NOT re-enqueued - proxy generation is
            // minutes of GPU work, not seconds, and must never start
            // itself on project open. Reset to "none" so
            // requestProxyGeneration()'s own pending/generating guard
            // doesn't permanently refuse to ever queue this item+variant
            // again. Any partial output file from the killed encode is
            // never referenced (artifact.path is only written on success).
            if (artifact.status == "pending" || artifact.status == "generating") {
                artifact.status = "none";
                artifact.progress = 0;
            }
            info.proxies[newKey] = artifact;
        }

        m_items[it.key()] = info;

        // Pending queue ujratoltese
        if (info.waveform.status == "pending") {
            m_pendingQueue.enqueue(it.key());
        }
    }

    emit pendingCountChanged();
}

bool CacheManager::isSourceValid(const CacheItemInfo &info) const
{
    QFileInfo fileInfo(info.sourcePath);
    if (!fileInfo.exists()) return false;

    // Size-only check - mtime is deliberately NOT consulted. Many
    // ordinary ways of moving a project between machines (zip/unzip,
    // Dropbox/Drive sync, rsync without -t) change mtime without
    // changing a single byte of content; comparing it would mark every
    // such item permanently "invalid" with no path back, since nothing
    // in this app ever calls regenerateInvalidItems() to retry them
    // (confirmed live: every waveform in a real project's registry was
    // stuck "invalid" from exactly this). Same reasoning already
    // documented for ProjectBinModel::sourceFileMTime().
    return fileInfo.size() == info.sourceSize;
}

QStringList CacheManager::getAvailableProxyResolutions() const
{
    QStringList resolutions;
    QDir proxiesDir(m_cacheDir + "/proxies");
    if (!proxiesDir.exists()) return resolutions;

    // "<basename>-<hash12>-<WxH>.<ext>" (proxy_build_plan.md A.4) - the
    // resolution token is always the last hyphen-separated segment
    // before the extension, and always digits-x-digits.
    static const QRegularExpression resRegex(QStringLiteral("-(\\d+x\\d+)\\.[^.]+$"));

    const QStringList files = proxiesDir.entryList(QDir::Files);
    for (const QString &fileName : files) {
        QRegularExpressionMatch m = resRegex.match(fileName);
        if (m.hasMatch()) {
            const QString res = m.captured(1);
            if (!resolutions.contains(res)) resolutions.append(res);
        }
    }

    resolutions.sort();
    return resolutions;
}

QString CacheManager::proxyFileExtension(const QString &format)
{
    if (format == "mjpeg" || format == "raw_i420") return "mkv";
    if (format == "dnxhr_lb") return "mxf";
    return "mov"; // h264_intra, h264_longgop, h265_intra (qtmux)
}

QString CacheManager::proxyFileName(const CacheItemInfo &info, const QString &resolution, const QString &format) const
{
    const QByteArray hashInput = info.sourcePath.toUtf8() + QByteArray::number(info.sourceSize) + format.toUtf8();
    const QByteArray hash = QCryptographicHash::hash(hashInput, QCryptographicHash::Sha1).toHex();
    const QString hash12 = QString::fromLatin1(hash.left(12));
    const QString baseName = QFileInfo(info.sourcePath).completeBaseName();
    return QString("%1-%2-%3.%4").arg(baseName, hash12, resolution, proxyFileExtension(format));
}

bool CacheManager::hasItem(const QString &itemId) const
{
    return m_items.contains(itemId);
}

bool CacheManager::sourceAvailable(const QString &itemId) const
{
    auto it = m_items.constFind(itemId);
    return it != m_items.constEnd() && QFile::exists(it->sourcePath);
}

bool CacheManager::requestProxyGeneration(const QString &itemId, const QString &resolution, const QString &format, const QString &device)
{
    if (!m_items.contains(itemId)) {
        qWarning() << "CacheManager: requestProxyGeneration - unknown item" << itemId;
        return false;
    }
    CacheItemInfo &info = m_items[itemId];
    if (!QFile::exists(info.sourcePath)) {
        qWarning() << "CacheManager: requestProxyGeneration - source file missing:" << info.sourcePath;
        return false;
    }

    const QString variantKey = proxyVariantKey(resolution, format);
    CacheArtifact &artifact = info.proxies[variantKey]; // creates the entry if new
    if (artifact.status == "pending" || artifact.status == "generating") {
        qDebug() << "CacheManager: proxy already in flight for" << itemId << variantKey;
        return false;
    }

    artifact.status = "pending";
    artifact.progress = 0;
    artifact.format = format;

    // 3 fields, not 4 - resolution+format are already combined into
    // variantKey (registry v3), so there's nothing left to split out at
    // processNextPendingProxy() besides the device.
    const QString key = itemId + "|" + variantKey + "|" + device;
    if (!m_pendingProxyQueue.contains(key)) m_pendingProxyQueue.enqueue(key);

    saveRegistry();
    emit itemStatusChanged(itemId, "proxy", "pending", 0);
    emit proxyJobQueued(itemId, resolution, format, device, QFileInfo(info.sourcePath).fileName());

    processNextPendingProxy();
    return true;
}

void CacheManager::cancelProxyGeneration(const QString &itemId, const QString &resolution, const QString &format)
{
    if (!m_items.contains(itemId)) return;
    CacheItemInfo &info = m_items[itemId];

    if (!format.isEmpty()) {
        // Exact variant only.
        const QString variantKey = proxyVariantKey(resolution, format);
        if (!info.proxies.contains(variantKey)) return;

        const QString prefix = itemId + "|" + variantKey + "|";
        QQueue<QString> remaining;
        while (!m_pendingProxyQueue.isEmpty()) {
            QString entry = m_pendingProxyQueue.dequeue();
            if (!entry.startsWith(prefix)) remaining.enqueue(entry);
        }
        m_pendingProxyQueue = remaining;

        if (m_currentlyGeneratingProxy.contains(itemId + "|" + variantKey)) {
            emit requestProxyCancel(itemId, variantKey);
        } else if (info.proxies[variantKey].status == "pending") {
            info.proxies[variantKey].status = "none";
            info.proxies[variantKey].progress = 0;
            saveRegistry();
            emit itemStatusChanged(itemId, "proxy", "none", 0);
            emit proxyJobDequeued(itemId, resolution, format, "Cancelled");
        }
        return;
    }

    // format empty = every format at this resolution (pre-v3 behavior) -
    // collect the matching variant keys first since we're about to mutate
    // info.proxies while iterating would-be stale iterators otherwise.
    QStringList matchingVariants;
    for (auto it = info.proxies.constBegin(); it != info.proxies.constEnd(); ++it) {
        QString res;
        parseProxyVariantKey(it.key(), &res, nullptr);
        if (res == resolution) matchingVariants.append(it.key());
    }
    for (const QString &variantKey : matchingVariants) {
        QString fmt;
        parseProxyVariantKey(variantKey, nullptr, &fmt);

        const QString prefix = itemId + "|" + variantKey + "|";
        QQueue<QString> remaining;
        while (!m_pendingProxyQueue.isEmpty()) {
            QString entry = m_pendingProxyQueue.dequeue();
            if (!entry.startsWith(prefix)) remaining.enqueue(entry);
        }
        m_pendingProxyQueue = remaining;

        if (m_currentlyGeneratingProxy.contains(itemId + "|" + variantKey)) {
            emit requestProxyCancel(itemId, variantKey);
        } else if (info.proxies[variantKey].status == "pending") {
            info.proxies[variantKey].status = "none";
            info.proxies[variantKey].progress = 0;
            saveRegistry();
            emit itemStatusChanged(itemId, "proxy", "none", 0);
            emit proxyJobDequeued(itemId, resolution, fmt, "Cancelled");
        }
    }
}

int CacheManager::cancelPendingProxyGeneration(const QString &reason, const QString &resolution, const QString &format)
{
    int dropped = 0;
    QQueue<QString> remaining;
    while (!m_pendingProxyQueue.isEmpty()) {
        const QString entry = m_pendingProxyQueue.dequeue();
        const QStringList parts = entry.split("|");
        if (parts.size() != 3) { remaining.enqueue(entry); continue; } // malformed, leave alone
        const QString &entryItemId = parts[0];
        const QString &entryVariantKey = parts[1];
        QString entryRes, entryFmt;
        parseProxyVariantKey(entryVariantKey, &entryRes, &entryFmt);

        const bool resMatches = resolution.isEmpty() || entryRes == resolution;
        const bool fmtMatches = format.isEmpty() || entryFmt == format;
        if (!resMatches || !fmtMatches) { remaining.enqueue(entry); continue; }

        if (m_items.contains(entryItemId)) {
            CacheItemInfo &info = m_items[entryItemId];
            if (info.proxies.contains(entryVariantKey)) {
                info.proxies[entryVariantKey].status = "none";
                info.proxies[entryVariantKey].progress = 0;
            }
        }
        emit itemStatusChanged(entryItemId, "proxy", "none", 0);
        emit proxyJobDequeued(entryItemId, entryRes, entryFmt, reason);
        dropped++;
    }
    m_pendingProxyQueue = remaining;

    if (dropped > 0) saveRegistry();
    return dropped;
}

void CacheManager::setProxyGenerating(const QString &itemId, const QString &variantKey, int progress)
{
    if (!m_items.contains(itemId)) return;
    CacheItemInfo &info = m_items[itemId];
    if (!info.proxies.contains(variantKey)) return;

    CacheArtifact &artifact = info.proxies[variantKey];
    artifact.status = "generating";
    artifact.progress = progress;

    emit itemStatusChanged(itemId, "proxy", "generating", progress);

    if (progress % 25 == 0) saveRegistry();
}

void CacheManager::setProxyReady(const QString &itemId, const QString &variantKey, const QString &path)
{
    if (!m_items.contains(itemId)) return;
    CacheItemInfo &info = m_items[itemId];
    if (!info.proxies.contains(variantKey)) return;

    CacheArtifact &artifact = info.proxies[variantKey];
    // Store relative to m_cacheDir, matching the waveform convention
    // (CacheItemInfo.waveform.path), so a later Save-As's directory
    // rebase doesn't have to touch this field at all.
    QFileInfo fi(path);
    artifact.path = "proxies/" + fi.fileName();
    artifact.status = "ready";
    artifact.generatedAt = QDateTime::currentDateTime();
    artifact.progress = 100;

    m_currentlyGeneratingProxy.removeAll(itemId + "|" + variantKey);
    emit generatingProxyCountChanged();

    saveRegistry();
    emit itemStatusChanged(itemId, "proxy", "ready", 100);
    QString resolution, format;
    parseProxyVariantKey(variantKey, &resolution, &format);
    emit proxyReady(itemId, resolution, format, m_cacheDir + "/" + artifact.path);

    processNextPendingProxy();
}

void CacheManager::setProxyBackendResolved(const QString &itemId, const QString &variantKey, const QString &backend)
{
    QString resolution, format;
    parseProxyVariantKey(variantKey, &resolution, &format);
    emit proxyJobBackendResolved(itemId, resolution, format, backend);
}

void CacheManager::setProxyFailed(const QString &itemId, const QString &variantKey, const QString &error)
{
    if (!m_items.contains(itemId)) return;
    CacheItemInfo &info = m_items[itemId];
    if (!info.proxies.contains(variantKey)) return;

    CacheArtifact &artifact = info.proxies[variantKey];
    artifact.status = "failed";
    artifact.progress = 0;

    m_currentlyGeneratingProxy.removeAll(itemId + "|" + variantKey);
    emit generatingProxyCountChanged();

    saveRegistry();
    emit itemStatusChanged(itemId, "proxy", "failed", 0);
    QString resolution, format;
    parseProxyVariantKey(variantKey, &resolution, &format);
    emit proxyFailed(itemId, resolution, format, error);

    processNextPendingProxy();
}

void CacheManager::processNextPendingProxy()
{
    // Deliberately capped at 1 concurrent proxy generation, unlike
    // waveforms' 2 - a proxy encode is minutes of sustained GPU/CPU work
    // (vs. waveforms' few-second audio pass), and there is no real device
    // arbitration yet (that's Phase 4/5's GpuJobQueue) to let two of these
    // share a GPU sanely.
    static const int kMaxConcurrentProxyGenerations = 1;
    if (m_pendingProxyQueue.isEmpty()) return;
    if (m_currentlyGeneratingProxy.size() >= kMaxConcurrentProxyGenerations) return;

    const QString entry = m_pendingProxyQueue.dequeue();
    const QStringList parts = entry.split("|");
    if (parts.size() != 3) return; // malformed, drop it
    const QString itemId = parts[0];
    const QString variantKey = parts[1];
    const QString device = parts[2]; // "" = auto
    QString resolution, format;
    parseProxyVariantKey(variantKey, &resolution, &format);

    if (!m_items.contains(itemId)) { processNextPendingProxy(); return; }
    CacheItemInfo &info = m_items[itemId];
    if (!QFile::exists(info.sourcePath)) {
        qWarning() << "CacheManager: proxy source missing, skipping:" << info.sourcePath;
        info.proxies[variantKey].status = "failed";
        emit itemStatusChanged(itemId, "proxy", "failed", 0);
        processNextPendingProxy();
        return;
    }

    int targetWidth = 0, targetHeight = 0;
    {
        const QStringList dims = resolution.split("x");
        if (dims.size() == 2) {
            targetWidth = dims[0].toInt();
            targetHeight = dims[1].toInt();
        }
    }
    if (targetWidth <= 0 || targetHeight <= 0) {
        qWarning() << "CacheManager: malformed proxy resolution token:" << resolution;
        info.proxies[variantKey].status = "failed";
        emit itemStatusChanged(itemId, "proxy", "failed", 0);
        processNextPendingProxy();
        return;
    }

    info.proxies[variantKey].status = "generating";
    info.proxies[variantKey].progress = 0;
    info.proxies[variantKey].format = format;
    m_currentlyGeneratingProxy.append(itemId + "|" + variantKey);
    emit generatingProxyCountChanged();

    emit itemStatusChanged(itemId, "proxy", "generating", 0);
    emit proxyJobStarted(itemId, resolution, format, device, QFileInfo(info.sourcePath).fileName());

    const QString outputPath = m_cacheDir + "/proxies/" + proxyFileName(info, resolution, format);
    qDebug() << "CacheManager: requesting proxy generation for" << itemId << resolution << format
             << "device:" << (device.isEmpty() ? QStringLiteral("auto") : device);
    qDebug() << "  Source:" << info.sourcePath;
    qDebug() << "  Output:" << outputPath;
    // The 4th positional arg is requestProxyGenerationStart()'s
    // `variantKey` param - ProxyGenerator never parses it, just echoes it
    // back through its own signals so setProxyGenerating/Ready/Failed
    // above can find this exact entry again.
    emit requestProxyGenerationStart(info.sourcePath, outputPath, itemId, variantKey, format, targetWidth, targetHeight, device);
}

void CacheManager::processNextPending()
{
    if (m_pendingQueue.isEmpty()) {
        qDebug() << "CacheManager::processNextPending - queue is empty";
        return;
    }
    if (m_currentlyGenerating.size() >= m_maxConcurrentGenerations) {
        qDebug() << "CacheManager::processNextPending - max concurrent reached";
        return;
    }

    QString itemId = m_pendingQueue.dequeue();

    if (!m_items.contains(itemId)) {
        qDebug() << "CacheManager::processNextPending - item not found:" << itemId;
        return;
    }

    CacheItemInfo &info = m_items[itemId];

    // Ellenorizzuk, hogy a forrasfile letezik-e
    if (!QFile::exists(info.sourcePath)) {
        qWarning() << "CacheManager: Source file not found for generation:" << info.sourcePath;
        info.waveform.status = "failed";
        emit itemStatusChanged(itemId, "waveform", "failed", 0);
        processNextPending();
        return;
    }

    info.waveform.status = "generating";
    info.waveform.progress = 0;

    m_currentlyGenerating.append(itemId);

    emit itemStatusChanged(itemId, "waveform", "generating", 0);
    emit pendingCountChanged();
    emit generatingCountChanged();

    // WaveformGenerator-nak jelzes
    QString outputPath = m_cacheDir + "/waveforms/" + itemId + ".wfm";
    qDebug() << "CacheManager: Requesting waveform generation for" << itemId;
    qDebug() << "  Source:" << info.sourcePath;
    qDebug() << "  Output:" << outputPath;
    emit requestWaveformGeneration(info.sourcePath, outputPath, itemId);
}
