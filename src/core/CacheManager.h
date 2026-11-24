#ifndef CACHEMANAGER_H
#define CACHEMANAGER_H

#include <QObject>
#include <QString>
#include <QVariantMap>
#include <QDateTime>
#include <QQueue>
#include <QMap>

// One generated artifact's state (a waveform, or one resolution's proxy).
// status values for a waveform: pending, generating, ready, failed,
// invalid, no-audio ("no-audio" is TERMINAL: a video-only source has no
// waveform to generate, so regenerateInvalidItems() must never retry it).
// status values for a proxy: none, pending, generating, ready, failed,
// invalid. Generation is manual-trigger only as of Phase 3 (a "Generate
// proxy" context-menu action) - nothing requests it automatically yet
// (that's Phase 6).
struct CacheArtifact {
    QString status = "none";
    QString path;
    QDateTime generatedAt;
    int progress = 0;
    // Proxy artifacts only: which format token (proxy_build_plan.md B.6 -
    // "h264_intra" etc.) this artifact was generated with. Empty for
    // waveforms. Kept per-artifact (not a single project-wide value)
    // because switching the project's format setting must not silently
    // relabel an already-generated file as something it isn't.
    QString format;
};

struct CacheItemInfo {
    QString itemId;
    QString sourcePath;
    QDateTime sourceModified;
    qint64 sourceSize;

    CacheArtifact waveform;
    // Keyed by VARIANT token "<WxH>@<format>" e.g. "960x540@h264_intra"
    // (registry v3, proxy_build_plan.md Part J.1 - previously resolution-
    // only, which made a format-only change invisible to getProxyStatus()).
    // Multiple variants can coexist on disk simultaneously
    // (targetResolution/proxyFormat only affect future generation,
    // proxyActiveVariant picks which already-generated set preview uses),
    // so this is a map, not a single artifact. CacheArtifact::format is
    // kept (not removed) despite now being redundant with the key - that
    // redundancy is what makes a v2->v3 registry migration recoverable
    // without hardcoding the key grammar (see loadRegistry()).
    QMap<QString, CacheArtifact> proxies;
};

class CacheManager : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int pendingCount READ pendingCount NOTIFY pendingCountChanged)
    Q_PROPERTY(int generatingCount READ generatingCount NOTIFY generatingCountChanged)
    // Separate from generatingCount (waveforms) - main.qml's shutdown
    // sequence waits on this specifically before calling forceQuit(),
    // since forceQuit() is a raw _exit(0) that bypasses every C++
    // destructor (including ProxyGenerator's own cancel-on-destruct
    // logic) - confirmed live: closing the app during an in-flight proxy
    // generation left a truncated, half-written file in .cache/proxies/
    // before this existed.
    Q_PROPERTY(int generatingProxyCount READ generatingProxyCount NOTIFY generatingProxyCountChanged)
    Q_PROPERTY(QString cacheDir READ cacheDir NOTIFY cacheDirChanged)

public:
    explicit CacheManager(QObject *parent = nullptr);
    ~CacheManager();

    // Inicializalas projekt betoltesekor. isNewProject=true (a "New
    // Project" dialog, nem egy meglevo .gpucs megnyitasa) szandekosan
    // NEM tolti be a mappa korabbi cache_registry.json-jat, es torli
    // a memoriaban mar esetleg meglevo allapotot is - kulonben egy uj
    // projekt, amit VELETLENUL ugyanabba a mappaba hoztak letre, ahol
    // egy korabbi (akar mar torolt/teljesen fuggetlen) projekt
    // dolgozott, orokolte volna annak befejezetlen generalasi sorat:
    // a regi, mar nem releváns bejegyzesek a generalasi sor ELEJEN
    // allva (max 2 parhuzamos generalas) sokaig eltarthattak az uj
    // projekt sajat fajljainak tenyleges generalasat, ami ugy nezett
    // ki, mintha a waveform sosem jonne elo.
    Q_INVOKABLE void initialize(const QString &projectDir, bool isNewProject = false);

    // Cache konyvtar lekerese
    QString cacheDir() const { return m_cacheDir; }

    // Item regisztracio (amikor file hozzaadodik a project bin-hez)
    Q_INVOKABLE void registerItem(const QString &itemId, const QString &sourcePath);

    // Item eltavolitas
    Q_INVOKABLE void unregisterItem(const QString &itemId);
    // The item's source file moved: point it at newPath. Same file size keeps
    // the waveform and proxies; a different size invalidates them like
    // validateAllItems() does. Unknown item -> registerItem().
    void relinkItem(const QString &itemId, const QString &newPath);
    // The item's source file exists again (it was missing at load): register
    // it if the registry never knew it, and queue the waveform again when it
    // is not ready.
    void mediaBecameAvailable(const QString &itemId, const QString &path);

    // Waveform allapot lekerdezes
    Q_INVOKABLE QString getWaveformStatus(const QString &itemId) const;
    Q_INVOKABLE QString getWaveformPath(const QString &itemId) const;
    Q_INVOKABLE int getWaveformProgress(const QString &itemId) const;
    Q_INVOKABLE bool isWaveformReady(const QString &itemId) const;

    // Waveform allapot frissites (WaveformGenerator hivja)
    void setWaveformGenerating(const QString &itemId, int progress);
    void setWaveformReady(const QString &itemId, const QString &path);
    void setWaveformFailed(const QString &itemId, const QString &error);

    // Proxy allapot lekerdezes. Both resolution and format empty = "any
    // variant" - returns the single best status across every variant for
    // this item, in ready > generating > pending > failed > invalid > none
    // priority order (NOT map-order/alphabetical, which would be
    // arbitrary). format empty, resolution given = best status across
    // every format AT that resolution. Both given = that exact variant,
    // or "none" if it doesn't exist.
    Q_INVOKABLE QString getProxyStatus(const QString &itemId, const QString &resolution = QString(), const QString &format = QString()) const;
    Q_INVOKABLE QString getProxyPath(const QString &itemId, const QString &resolution = QString(), const QString &format = QString()) const;
    Q_INVOKABLE int getProxyProgress(const QString &itemId, const QString &resolution = QString(), const QString &format = QString()) const;
    // Distinct resolutions across every format this item has a proxy
    // artifact for (de-duplicated - two formats at the same resolution
    // report that resolution once). Keeps the "which resolution boxes
    // exist for this item" contract pre-registry-v3 callers already rely
    // on; use getProxyVariants() for the full (resolution, format) list.
    Q_INVOKABLE QStringList getProxyResolutions(const QString &itemId) const;
    // Every "<WxH>@<format>" variant this item has a registry entry for,
    // regardless of status.
    Q_INVOKABLE QStringList getProxyVariants(const QString &itemId) const;
    // Every "<WxH>@<format>" variant with at least one item reporting it
    // "ready", project-wide - feeds the Project Settings "Active proxy"
    // combo (proxy_build_plan.md Part J.1.7). Registry-derived (not a
    // filename scan like getAvailableProxyResolutions() below) because
    // the variant's FORMAT isn't recoverable from a resolution-only
    // filename scan without also knowing which items exist.
    Q_INVOKABLE QStringList getAvailableProxyVariants() const;

    // Scans .cache/proxies/ for every distinct "WxH" resolution token
    // actually present on disk, across ALL items - this is what feeds
    // the project-wide activeResolution combo (proxy_build_plan.md A.4):
    // the registry's per-item `proxies` maps aren't a reliable source by
    // themselves until generation is wired up (Phase 3/6), but once
    // files exist their filenames are self-describing regardless of
    // registry state. Sorted, e.g. {"960x540", "1920x1080"}. Still
    // resolution-only and still filename-derived after registry v3 -
    // Phase 8's cache browser groups by resolution first, format second,
    // and this is cheap to compute without touching the registry at all.
    Q_INVOKABLE QStringList getAvailableProxyResolutions() const;

    // Manual trigger ("Generate proxy" context-menu action) - the only
    // entry point into proxy generation as of Phase 3. Queues the
    // request (its own pending/generating queues, split from the
    // waveform ones) and starts it if a generation slot is free.
    // No-op if this (itemId, resolution) pair is already pending/
    // generating. format is one of proxy_build_plan.md B.6's tokens
    // ("h264_intra" etc.) - stored on the resulting CacheArtifact.
    // device is one of Backend::availableEncoders()'s tokens ("nvidia",
    // "vaapi", "cpu") - the SAME vocabulary RenderEngine's own device
    // picker already uses, deliberately reused rather than inventing a
    // parallel identifier scheme (Phase 4). Empty string = auto (prefer
    // GPU, same as the pre-Phase-4 default).
    // True when the item is registered with the cache (only video/audio bin
    // items are; images, titles, folders never are).
    Q_INVOKABLE bool hasItem(const QString &itemId) const;
    // Registered AND its source file exists on disk (false = offline).
    Q_INVOKABLE bool sourceAvailable(const QString &itemId) const;
    // Returns true only when a NEW job was queued (false: unknown item,
    // missing source, or already pending/generating).
    Q_INVOKABLE bool requestProxyGeneration(const QString &itemId, const QString &resolution, const QString &format, const QString &device = QString());
    // format empty = cancel EVERY format at that resolution (the pre-v3
    // behavior); a specific format cancels only that exact variant - the
    // Proxy Queue tab's per-row Cancel passes the row's exact format so it
    // never touches a sibling job at the same resolution.
    Q_INVOKABLE void cancelProxyGeneration(const QString &itemId, const QString &resolution, const QString &format = QString());
    // Drops every still-QUEUED (not yet started) proxy request matching
    // the optional resolution/format filter (both empty = everything
    // queued), resetting each dropped artifact to "none" and emitting
    // proxyJobDequeued(..., reason) per entry so the Proxy Queue tab
    // closes the row it opened on proxyJobQueued. Deliberately does NOT
    // touch an in-flight generation - only the generator itself knows
    // when it has actually stopped, same asymmetry cancelProxyGeneration()
    // already has. Returns the number of entries dropped. Used by the
    // Project Settings resolution/format-change conflict dialog
    // (proxy_build_plan.md Part J.3) and by disabling proxy editing.
    Q_INVOKABLE int cancelPendingProxyGeneration(const QString &reason, const QString &resolution = QString(), const QString &format = QString());
    // Number of proxy requests still QUEUED (not yet generating) - used by
    // the Part J.3 conflict dialog to tell the user how many jobs are
    // about to be superseded/kept. generatingProxyCount (below) already
    // covers the one currently running.
    Q_INVOKABLE int pendingProxyCount() const { return m_pendingProxyQueue.size(); }
    // Cancels every in-flight AND queued proxy generation - used by
    // main.qml's shutdown sequence so closing the app doesn't leave a
    // truncated file (forceQuit()'s _exit(0) bypasses C++ destructors
    // entirely, so there is no other reliable place to do this).
    Q_INVOKABLE void cancelAllProxyGeneration();
    int generatingProxyCount() const { return m_currentlyGeneratingProxy.size(); }

    // Proxy allapot frissites (ProxyGenerator hivja). `variantKey` is the
    // opaque "<WxH>@<format>" identity CacheManager itself generated when
    // it queued the job (processNextPendingProxy()) and handed to
    // ProxyGenerator as its "resolution" parameter - ProxyGenerator never
    // parses it, just echoes it back through its signals unchanged.
    void setProxyGenerating(const QString &itemId, const QString &variantKey, int progress);
    void setProxyReady(const QString &itemId, const QString &variantKey, const QString &path);
    void setProxyFailed(const QString &itemId, const QString &variantKey, const QString &error);
    // Relays ProxyGenerator::proxyBackendResolved() - purely a pass-
    // through for the Proxy Queue UI, no registry/CacheItemInfo state
    // to touch (the resolved backend isn't persisted, only displayed
    // live while the job runs).
    void setProxyBackendResolved(const QString &itemId, const QString &variantKey, const QString &backend);

    // Validacio es ujrageneralas
    Q_INVOKABLE void validateAllItems();
    Q_INVOKABLE void regenerateInvalidItems();

    // Pending items kezelese
    Q_INVOKABLE void startPendingGeneration();
    Q_INVOKABLE QStringList getPendingItems() const;
    Q_INVOKABLE QStringList getGeneratingItems() const;

    // Kovetkezo pending item lekerese (WaveformGenerator hivja)
    QString getNextPendingItem();
    CacheItemInfo getItemInfo(const QString &itemId) const;

    // Statisztikak
    int pendingCount() const;
    int generatingCount() const;

    // Registry mentes/betoltes
    Q_INVOKABLE void saveRegistry();
    Q_INVOKABLE void loadRegistry();

signals:
    // kind: "waveform" | "proxy" - without it, ProjectBinModel would have
    // to repaint BOTH waveform and proxy roles on every single update,
    // since one shared signal can't otherwise say which artifact changed.
    void itemStatusChanged(const QString &itemId, const QString &kind, const QString &status, int progress);
    void waveformReady(const QString &itemId, const QString &waveformPath);
    void waveformFailed(const QString &itemId, const QString &error);
    void pendingCountChanged();
    void generatingCountChanged();
    void generatingProxyCountChanged();
    void cacheDirChanged();
    void validationCompleted(int invalidCount);
    void requestWaveformGeneration(const QString &sourcePath, const QString &outputPath, const QString &itemId);

    void proxyReady(const QString &itemId, const QString &resolution, const QString &format, const QString &proxyPath);
    void proxyFailed(const QString &itemId, const QString &resolution, const QString &format, const QString &error);
    // Fired once, right when a proxy request is accepted and enqueued -
    // CacheManager runs proxy generation one job at a time, so a batch
    // request (e.g. the Proxy tab's "Generate Proxy for All Bin Items")
    // would otherwise leave every item but the one actively generating
    // invisible in the Proxy Queue tab until its own turn came up. Same
    // identity/payload shape as proxyJobStarted() below, fired earlier in
    // the same item+resolution's lifecycle; the UI row this creates is
    // later updated in place (not re-created) when proxyJobStarted fires
    // for the same itemId+resolution+format.
    void proxyJobQueued(const QString &itemId, const QString &resolution, const QString &format,
                         const QString &device, const QString &sourceFileName);
    // Fired once, when a queued proxy request actually starts generating -
    // purely additive, for the Render workspace's Proxy Queue tab
    // (ProxyJobs.qml) to create a row for it (proxy_build_plan.md Part E,
    // scoped down per user request: a separate queue tab from render jobs,
    // not sharing RenderEngine's actual device-conflict arbitration - that
    // stays two independent systems). itemId+resolution+format is the identity used to match
    // this item's later itemStatusChanged("proxy", ...)/proxyReady/
    // proxyFailed signals back to the row this created. device is the
    // REQUESTED backend, not necessarily what ended up running it (the
    // encoder itself may still fall back - same caveat as RenderJob's own
    // backend selection).
    void proxyJobStarted(const QString &itemId, const QString &resolution, const QString &format,
                          const QString &device, const QString &sourceFileName);
    // Fired when a request that was still QUEUED (never started
    // generating) is dropped - by the user's Cancel on a still-pending
    // Proxy Queue row, or later by a settings-driven bulk dequeue when a
    // resolution/project change makes it obsolete. Counterpart to
    // proxyJobQueued(): closes the UI row that signal created. NOT
    // emitted for an in-flight job - that one still reports through
    // proxyFailed("Cancelled") as before, because only the generator
    // itself knows when it has actually stopped.
    void proxyJobDequeued(const QString &itemId, const QString &resolution, const QString &format, const QString &reason);
    // The ACTUAL backend ("nvidia"/"vaapi"/"cpu") the encoder ended up
    // running on, as opposed to proxyJobStarted()'s `device` (what was
    // REQUESTED, e.g. "auto") - ProxyJobs.qml uses this to correct its
    // "Using: X" display once the generator has actually resolved it.
    // Never fired for raw_i420 (no encoder step exists).
    void proxyJobBackendResolved(const QString &itemId, const QString &resolution, const QString &format,
                                  const QString &backend);
    void requestProxyGenerationStart(const QString &sourcePath, const QString &outputPath,
                                      const QString &itemId, const QString &variantKey,
                                      const QString &format, int targetWidth, int targetHeight,
                                      const QString &device);
    void requestProxyCancel(const QString &itemId, const QString &variantKey);

private:
    bool isSourceValid(const CacheItemInfo &info) const;
    void processNextPending();
    void processNextPendingProxy();
    // "<basename>-<hash12>-<WxH>.<ext>" (proxy_build_plan.md A.4) -
    // hash12 = first 12 hex chars of SHA-1(absolute source path + file
    // size + format token), so switching format or source content for
    // the same resolution naturally produces a different filename
    // instead of silently overwriting a file that's actually different.
    QString proxyFileName(const CacheItemInfo &info, const QString &resolution, const QString &format) const;
    static QString proxyFileExtension(const QString &format);

    // Registry v3 (proxy_build_plan.md Part J.1): CacheItemInfo::proxies
    // is keyed on this composite, not resolution alone, so a format-only
    // change (same resolution, different encode) is a distinct entry
    // instead of silently colliding with/overwriting the old one. "@" is
    // deliberately NOT "|" - "|" is already the pending-queue entry field
    // separator (m_pendingProxyQueue), and this key is embedded inside
    // those entries too ("itemId|variantKey|device").
    static QString proxyVariantKey(const QString &resolution, const QString &format);
    // Tolerant of a legacy (pre-v3) key with no "@" - returns it as-is in
    // *resolution with *format left empty, for loadRegistry()'s migration.
    // Returns false only when key is empty.
    static bool parseProxyVariantKey(const QString &key, QString *resolution, QString *format);
    // Best status across a set of variant keys, in the priority order
    // getProxyStatus()'s "any format/resolution" modes document - NOT
    // map/alphabetical order, which would be arbitrary and would e.g.
    // report "failed" over a perfectly good "ready" variant at another
    // resolution just because its key sorts first.
    static QString bestProxyStatus(const QMap<QString, CacheArtifact> &proxies, const QString &resolutionFilter);

    QString m_projectDir;
    QString m_cacheDir;
    QString m_registryPath;
    QMap<QString, CacheItemInfo> m_items;
    QQueue<QString> m_pendingQueue;
    QStringList m_currentlyGenerating;
    int m_maxConcurrentGenerations;

    // Proxy generation's own pending/generating queues, split from the
    // waveform ones above - a single shared queue would let a backlog of
    // one artifact kind starve the other. Unused until Phase 3/6 wires
    // actual proxy generation (ProxyJob); declared now so that work
    // doesn't need to touch this header again.
    QQueue<QString> m_pendingProxyQueue;
    QStringList m_currentlyGeneratingProxy;
};

#endif // CACHEMANAGER_H
