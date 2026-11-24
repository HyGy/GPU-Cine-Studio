#ifndef BACKENDMANAGER_H
#define BACKENDMANAGER_H

#include <QObject>
#include <QStringList>
#include <QHash>
#include <QSet>
#include <QList>
#include <QVariantList>
#include <QVariantMap>
#include "ProjectBinModel.h"
#include "MediaAvailability.h"
#include "RenderEngine.h"
#include "CacheManager.h"
#include "WaveformGenerator.h"
#include "ProxyGenerator.h"
#include "ProfileStore.h"

struct _GESAsset;   // GES asset, opaque here (see ProxyAssets.h)
#include "ShortcutManager.h"
#include <QHash>
#include <atomic>
#include <QTimer>
#include <QSet>

// GPU Device structure with detailed capabilities
struct GPUDevice {
    QString id;              // "nvidia-0", "vaapi-0", "cpu"
    QString name;            // "NVIDIA GeForce RTX 3080", "Intel UHD Graphics 630", "Software Encoding"
    QString type;            // "GPU" or "CPU"
    QString vendor;          // "NVIDIA", "Intel", "AMD", "Software"
    QStringList encoders;    // ["H.264", "H.265", "AV1"]
    QStringList decoders;    // ["H.264", "H.265", "VP9", "AV1"]

    // Convert to QVariantMap for QML
    QVariantMap toVariantMap() const {
        QVariantMap map;
        map["id"] = id;
        map["name"] = name;
        map["type"] = type;
        map["vendor"] = vendor;
        map["encoders"] = encoders;
        map["decoders"] = decoders;
        return map;
    }
};

Q_DECLARE_METATYPE(GPUDevice)

class BackendManager : public QObject
{
    Q_OBJECT
    Q_PROPERTY(ProjectBinModel* projectBinModel READ projectBinModel CONSTANT)
    Q_PROPERTY(RenderEngine* renderEngine READ renderEngine CONSTANT)
    Q_PROPERTY(CacheManager* cacheManager READ cacheManager CONSTANT)
    Q_PROPERTY(MediaAvailability* mediaAvailability READ mediaAvailability CONSTANT)
    Q_PROPERTY(ProfileStore* profileStore READ profileStore CONSTANT)
    Q_PROPERTY(WaveformGenerator* waveformGenerator READ waveformGenerator CONSTANT)
    Q_PROPERTY(ProxyGenerator* proxyGenerator READ proxyGenerator CONSTANT)
    // Keyboard shortcut registry + dispatch (plan_shortcuts.md).
    Q_PROPERTY(ShortcutManager* shortcuts READ shortcuts CONSTANT)
    Q_PROPERTY(QString currentProjectDir READ currentProjectDir NOTIFY currentProjectDirChanged)
    Q_PROPERTY(QString selectedProjectBinItemId READ selectedProjectBinItemId WRITE setSelectedProjectBinItemId NOTIFY selectedProjectBinItemIdChanged)
    Q_PROPERTY(QString loggingSelectedBinItemId READ loggingSelectedBinItemId WRITE setLoggingSelectedBinItemId NOTIFY loggingSelectedBinItemIdChanged)
    Q_PROPERTY(QStringList availableDecoders READ availableDecoders NOTIFY availableDecodersChanged)
    Q_PROPERTY(QString preferredDecoder READ preferredDecoder WRITE setPreferredDecoder NOTIFY preferredDecoderChanged)
    Q_PROPERTY(bool hasGPUAcceleration READ hasGPUAcceleration NOTIFY availableDecodersChanged)
    Q_PROPERTY(QStringList availableEncoders READ availableEncoders NOTIFY availableEncodersChanged)
    Q_PROPERTY(QString preferredEncoder READ preferredEncoder WRITE setPreferredEncoder NOTIFY preferredEncoderChanged)
    Q_PROPERTY(QVariantList gpuDevices READ gpuDevices NOTIFY gpuDevicesChanged)
    // Debug action logging: when enabled, every logOperation() call from
    // QML (timeline drags/drops/splits/deletes/transitions/track edits)
    // appends a timestamped, position-exact line to a log file, so a bug
    // report's sequence of UI actions can be reconstructed after the fact
    // instead of having to be guessed from the engine-side setClips() log
    // alone. Persisted via QSettings so it survives a restart; toggled by
    // a QML checkbox (Logging workspace toolbar) - see also setSetting()/
    // getSetting() for the same persistence mechanism used elsewhere.
    Q_PROPERTY(bool debugLoggingEnabled READ debugLoggingEnabled WRITE setDebugLoggingEnabled NOTIFY debugLoggingEnabledChanged)
    
    // --- ÚJ PROPERTY: Legutóbbi projektek listája ---
    Q_PROPERTY(QVariantList recentProjects READ getRecentProjects NOTIFY recentProjectsChanged)
    // About -> Components: the actual GStreamer/Qt build this process is
    // linked against and running with right now, not a hand-maintained
    // string someone forgot to update at the next version bump.
    Q_PROPERTY(QString gstreamerVersion READ gstreamerVersion CONSTANT)
    Q_PROPERTY(QString appVersion READ appVersion CONSTANT)
    // About -> which video-preview architecture this process is actually
    // using (qml6glsink scene-graph item vs. the native-child-X11-window
    // overlay), and whether it's the native path only because qml6glsink
    // wasn't available and we silently fell back to it.
    Q_PROPERTY(QString videoOutputMethod READ videoOutputMethod CONSTANT)
    Q_PROPERTY(bool videoOutputFallback READ videoOutputFallback CONSTANT)
    Q_PROPERTY(QString qtVersion READ qtVersion CONSTANT)
    // Qt platform plugin in use ("xcb", "wayland", ...) and whether the installed
    // GStreamer qml6 plugin can render on Wayland; the preview overlays use these
    // to explain a video item that never initialises.
    Q_PROPERTY(QString platformName READ platformName CONSTANT)
    Q_PROPERTY(bool qml6SupportsWayland READ qml6SupportsWayland CONSTANT)

public:
    QString platformName() const;
    bool qml6SupportsWayland() const;

    explicit BackendManager(QObject *parent = nullptr);
    ~BackendManager();

    ProjectBinModel* projectBinModel() { return &m_projectBinModel; }
    RenderEngine* renderEngine() { return &m_renderEngine; }
    CacheManager* cacheManager() { return &m_cacheManager; }
    MediaAvailability* mediaAvailability() { return &m_mediaAvailability; }
    ProfileStore* profileStore() { return &m_profileStore; }
    WaveformGenerator* waveformGenerator() { return &m_waveformGenerator; }
    ProxyGenerator* proxyGenerator() { return &m_proxyGenerator; }
    ShortcutManager* shortcuts() { return &m_shortcuts; }

    // Projekt konyvtar kezelese
    QString currentProjectDir() const { return m_currentProjectDir; }
    Q_INVOKABLE void setCurrentProjectDir(const QString &dir);
    // isNewProject: forwarded to CacheManager::initialize() - see its
    // own comment for why a brand-new project must not inherit a
    // previous project's leftover cache registry just because it
    // happens to live in the same directory.
    Q_INVOKABLE void initializeCacheForProject(const QString &projectFilePath, bool isNewProject = false);

    // proxy_build_plan.md Part J.4.3: (re-)computes which video items
    // SHOULD have their proxy installed as the GES-level active asset
    // right now - project/proxyEnabled + project/proxyActiveResolution/
    // proxyFormat are the "effective active variant" (see that section;
    // full per-variant active-proxy tracking via a dedicated
    // proxyActiveVariant setting is deferred, same scoping call as the
    // registry-v3 commit's ProjectBinModel role deferral) - and installs/
    // uninstalls via ProxyAssets to match. Called after project load,
    // after every proxyReady, and must ALSO be called explicitly by QML
    // after it changes proxyEnabled/proxyActiveResolution/proxyFormat
    // (Project Settings' Save, the open-time backfill prompt) - plain
    // setSetting() has no change-notification CacheManager/BackendManager
    // could otherwise observe on its own.
    // Uninstalls are immediate; installs are asynchronous: the source and proxy
    // assets are resolved on the shared AssetLoader thread (never on the GUI
    // thread - a GstDiscoverer run on a slow disk takes seconds) and installed
    // as they arrive. While such a pass runs, the timeline engine parks clip
    // lists (AssetLoader::proxyPassActive()), proxyInstallProgress() reports
    // it, and proxyInstallPassFinished() ends it. A call made while a pass is
    // running just makes the pass repeat itself once with the fresh settings.
    // Returns true when a rebuild of the timeline is (now or already) scheduled
    // because of this call, or an install pass was started that may schedule
    // one when it finishes (proxyInstallPassFinished(false) = it did not);
    // false = nothing will follow.
    Q_INVOKABLE bool refreshProxyInstallations();
    // Stops a scheduled (not yet emitted) coalesced proxyInstallationChanged,
    // without emitting. For a caller about to do a full timeline build that
    // already reflects every install made so far.
    // If an install pass is still running, its eventual proxyInstallationChanged
    // is suppressed too (the caller's build waits for the pass to finish).
    Q_INVOKABLE void cancelPendingProxyInstallationChanged();
    // Safety net for a proxy the preview pipeline cannot use (see
    // TimelineEngine::proxyPlaybackFailed / proxyRebuildStuck): uninstalls
    // the failing proxy (or all proxies) so the clip(s) play from the
    // original again, remembers them as bad for this project session so
    // refreshProxyInstallations() does not re-install them, and triggers a
    // rebuild. The proxy files themselves are left alone.
    Q_INVOKABLE void handleProxyPlaybackFailure(const QString &failingFilePath);
    Q_INVOKABLE void handleProxyRebuildStuck();

    QString selectedProjectBinItemId() const { return m_selectedProjectBinItemId; }
    void setSelectedProjectBinItemId(const QString &itemId);

    // The Logging workspace's own bin selection (the Editing bin uses
    // selectedProjectBinItemId); kept here so it survives the workspace
    // Loader destroying/recreating a workspace.
    QString loggingSelectedBinItemId() const { return m_loggingSelectedBinItemId; }
    void setLoggingSelectedBinItemId(const QString &itemId);

    // Per-view bin expand state ("logging" / "editing"): the two bins are
    // independent. Kept here so it survives workspace re-creation.
    Q_INVOKABLE QStringList expandedItemIds(const QString &view) const { return m_expandedItemIds.value(view); }
    Q_INVOKABLE void setItemExpanded(const QString &view, const QString &itemId, bool expanded);
    Q_INVOKABLE bool isItemExpanded(const QString &view, const QString &itemId) const;

    // GPU decoder management
    QStringList availableDecoders() const { return m_availableDecoders; }
    QString preferredDecoder() const { return m_preferredDecoder; }
    void setPreferredDecoder(const QString &decoder);
    bool hasGPUAcceleration() const;
    QString gstreamerVersion() const;
    QString appVersion() const { return QStringLiteral(APP_VERSION); }
    QString videoOutputMethod() const;
    bool videoOutputFallback() const;
    QString qtVersion() const;

    Q_INVOKABLE QString getDecoderDisplayName(const QString &decoderId) const;
    Q_INVOKABLE void detectDecoders();

    // GPU encoder management
    QStringList availableEncoders() const { return m_availableEncoders; }
    QString preferredEncoder() const { return m_preferredEncoder; }
    void setPreferredEncoder(const QString &encoder);

    Q_INVOKABLE QString getEncoderDisplayName(const QString &encoderId) const;
    Q_INVOKABLE void detectEncoders();

    // GPU device detection and management
    QVariantList gpuDevices() const;
    Q_INVOKABLE void detectGPUDevices();
    Q_INVOKABLE QVariantMap getGPUDeviceInfo(const QString &deviceId) const;

    Q_INVOKABLE void setSetting(const QString &key, const QVariant &value);
    Q_INVOKABLE QVariant getSetting(const QString &key, const QVariant &defaultValue = QVariant()) const;
    Q_INVOKABLE void checkStartupWarnings();
    Q_INVOKABLE QString getDefaultVideosPath() const;
    // Set by main.cpp's signal notifier (SIGINT/SIGTERM) just before quit().
    static void markSignalQuit();
    Q_INVOKABLE bool signalQuitRequested() const;

    Q_INVOKABLE bool saveProjectToFile(const QString &filePath, const QString &jsonContent);
    Q_INVOKABLE QString loadProjectFromFile(const QString &filePath);

    // --- Autosave / crash recovery helpers (plan_autosave.md) ---
    Q_INVOKABLE bool fileExists(const QString &filePath) const;
    Q_INVOKABLE bool removeFile(const QString &filePath);
    Q_INVOKABLE QString fileModifiedText(const QString &filePath) const;
    Q_INVOKABLE bool backupProjectFile(const QString &filePath);

    // --- Kdenlive project import (one-shot, one-way) - see
    // src/core/KdenliveImporter.h for the actual logic; these are thin
    // wrappers so QML never needs to know this isn't a QObject itself. ---
    Q_INVOKABLE QVariantMap inspectKdenliveProject(const QString &filePath, const QVariantMap &options) const;
    Q_INVOKABLE QVariantMap convertKdenliveProject(const QString &filePath, const QVariantMap &options) const;
    Q_INVOKABLE bool writeKdenliveImportReport(const QString &projectDir, const QVariantMap &report) const;

    // --- Dedicated project folder (New Project) ---
    // A project's cache lives in <projectDir>/.cache (see
    // CacheManager::initialize()), so two unrelated .gpucs files saved
    // into the SAME folder share one cache_registry.json and one
    // generation queue. The fix is that "New Project" creates its own
    // dedicated folder up front, and project/location points at THAT
    // folder from then on.

    // Filesystem-safe folder name from free-form user text. Never
    // returns an empty string (falls back to "Untitled Project").
    Q_INVOKABLE QString sanitizeFolderName(const QString &name) const;

    // The folder that createProjectFolder() WOULD use, without creating
    // anything - for live preview in the New Project dialog. No
    // collision suffix - a taken name is reported as an error (see
    // projectFolderWouldConflict()) rather than silently renamed.
    Q_INVOKABLE QString resolveProjectFolderPath(const QString &parentDir,
                                                 const QString &projectName) const;

    // True if resolveProjectFolderPath()'s candidate already exists as
    // a file, or as a non-empty directory - i.e. createProjectFolder()
    // would refuse it. False for a path that doesn't exist yet, or that
    // exists as a completely empty directory (which gets reused).
    Q_INVOKABLE bool projectFolderWouldConflict(const QString &parentDir,
                                                const QString &projectName) const;

    // Creates the dedicated folder and returns its absolute path, or an
    // empty string on failure: unwritable/nonexistent parent, OR
    // projectFolderWouldConflict() is true for this name (the caller is
    // expected to have already checked that and surfaced it as an error
    // - this is the last line of defense, not the primary UI path).
    // Reuses the candidate folder if it exists and is completely empty.
    Q_INVOKABLE QString createProjectFolder(const QString &parentDir,
                                            const QString &projectName);

    // --- Save As ---
    // Copies <sourceProjectDir>/.cache into <targetProjectDir>/.cache so a
    // Save As target starts with a WARM cache instead of re-decoding every
    // source file's audio from scratch (WaveformGenerator runs a full
    // GStreamer decode per file, max 2 concurrent, and nothing is keyed by
    // content hash - only by itemId, which IS persisted in the .gpucs, so a
    // copied cache_registry.json stays valid for the same bin). The data is
    // tiny next to the media: 100 buckets/sec * 2 floats = 800 bytes per
    // second of audio.
    //
    // Returns false if the copy could not be completed. Callers should treat
    // that as NON-FATAL: the cache is derived data, and the next
    // CacheManager::initialize()/validateAllItems() re-queues whatever is
    // missing. Never touches the source. Existing files at the destination
    // are left alone (QFile::copy() does not overwrite).
    Q_INVOKABLE bool copyProjectCache(const QString &sourceProjectDir,
                                      const QString &targetProjectDir);

    // Fájl megnyitása külső programmal
    Q_INVOKABLE void openFile(const QString &filePath);

    // Alkalmazás kiléptetése (QML-ből hívható, C++ oldali force quit)
    Q_INVOKABLE void forceQuit();

    // --- ÚJ: Config fájl kezelés ---
    Q_INVOKABLE void addToRecentProjects(const QString &path, const QString &name);
    QVariantList getRecentProjects() const;

    // --- Debug action logging ---
    bool debugLoggingEnabled() const { return m_debugLoggingEnabled; }
    void setDebugLoggingEnabled(bool enabled);
    // action: short identifier (e.g. "clip_drag_release", "track_delete").
    // details: arbitrary key/value pairs, written sorted by key (QVariantMap
    // iteration order) - the caller decides what's relevant to reconstruct
    // that specific action (positions, trackIds, clipIds, before/after
    // values). No-op if debugLoggingEnabled is false, so call sites don't
    // need to guard it themselves.
    Q_INVOKABLE void logOperation(const QString &action, const QVariantMap &details);

    // Default titleParams JSON blob for a new title clip. Lives in C++
    // (TitleClips::defaultParamsJson) so the preview/export application
    // layer and the UI can't drift apart on what a "default title" is.
    Q_INVOKABLE QString defaultTitleParams(const QString &text) const;
    // Absolute path of the append-only operation log, for the Settings
    // dialog to show the user where it lives.
    Q_INVOKABLE QString operationLogPath() const { return getOperationLogPath(); }
    // Human-readable current size ("-" when the file doesn't exist yet).
    Q_INVOKABLE QString operationLogSize() const;
    // Truncates the log to zero length. logOperation() only ever
    // appends, so without this the file grows forever and the only way
    // to reset it was deleting it by hand.
    Q_INVOKABLE bool clearOperationLog();

signals:
    void debugLoggingEnabledChanged();
    void selectedProjectBinItemIdChanged(const QString &itemId);
    void loggingSelectedBinItemIdChanged(const QString &itemId);
    void itemExpandStateChanged(const QString &view, const QString &itemId, bool expanded);
    void availableDecodersChanged();
    void preferredDecoderChanged();
    void availableEncodersChanged();
    void preferredEncoderChanged();
    void gpuDevicesChanged();
    void noGPUWarning();
    void savedDecoderUnavailable(const QString &decoderId);
    
    // --- ÚJ SIGNAL ---
    void recentProjectsChanged();
    void currentProjectDirChanged();

    // proxy_build_plan.md Part J.4.4/D16: fired at most once per ~2s
    // burst of refreshProxyInstallations() calls that actually changed
    // something (see m_proxyInstallCoalesceTimer) - EditingWorkspace.qml
    // reacts by calling TimelineEngine::reloadAssets(). A full timeline
    // rebuild per individually-finished proxy during a large batch would
    // be unusable; one rebuild at the end of a burst is not.
    void proxyInstallationChanged();
    // Install pass progress: `done` of `total` sources prepared; fileName is the
    // source currently being prepared (empty when finished).
    void proxyInstallProgress(int done, int total, const QString &fileName);
    // An install pass (and any repeat requested meanwhile) ended.
    // rebuildScheduled: a proxyInstallationChanged will follow.
    void proxyInstallPassFinished(bool rebuildScheduled);
    // Emitted when a proxy was taken out of use because the preview could
    // not play it - for UI surfacing; reason is a human-readable sentence.
    void proxyRevertedToOriginal(const QString &sourcePath, const QString &reason);

private:
    void loadDecoderPreference();
    void saveDecoderPreference();
    QString selectBestDecoder() const;

    void loadEncoderPreference();
    void saveEncoderPreference();
    QString selectBestEncoder() const;

    // GPU device detection helpers
    QString detectNVIDIAGPUName() const;
    QString detectIntelGPUName() const;
    QString detectAMDGPUName() const;
    // backend is "nvidia" / "vaapi" / "cpu"
    QStringList detectCodecsForElement(const QString &backend, bool isEncoder) const;

    // --- ÚJ: Config helpers ---
    void loadGlobalConfig();
    void saveGlobalConfig();
    QString getGlobalConfigPath() const;

    // --- Debug action logging helpers ---
    QString getOperationLogPath() const;
    bool m_debugLoggingEnabled = false;

    // proxy_build_plan.md Part J.4.3/J.4.4: sourcePath -> proxyPath
    // currently installed via ProxyAssets::install() - lets
    // refreshProxyInstallations() diff against what's ALREADY installed
    // (uninstall what's no longer desired/changed, install what's newly
    // desired) instead of blindly uninstall-then-reinstall-everything on
    // every call, and is what scheduleProxyInstallationChanged() below
    // treats as "did anything actually change" to decide whether a
    // rebuild is even worth emitting.
    QHash<QString, QString> m_installedProxySourcePaths;
    // Proxy files the preview failed to play this session - never
    // re-installed until the project changes (see handleProxyPlaybackFailure()).
    QSet<QString> m_badProxyPaths;

    // --- asynchronous install pass (see refreshProxyInstallations()) ---
    // Original GESAsset per source path whose proxy was ever installed here, so
    // an uninstall / re-install never has to look the asset up again. One extra
    // reference is taken per entry and never released (same policy as
    // TimelineEngine::m_assetCache); GES's cache keeps its own anyway.
    QHash<QString, _GESAsset *> m_originalAssets;
    struct ProxyPassItem { QString source; QString proxy; bool done = false; };
    bool m_proxyChainActive = false;     // a pass (or a queued repeat) is in flight
    bool m_proxyChainChanged = false;    // installs/uninstalls changed during the chain
    bool m_proxyChainCovered = false;    // a timeline build waits for the chain: no rebuild signal
    bool m_proxyAgain = false;           // refresh requested while a pass was running
    QList<ProxyPassItem> m_passItems;
    QSet<QString> m_passWaiting;                       // paths requested, no result yet
    QSet<QString> m_passFailed;                        // paths that did not resolve
    QSet<QString> m_passSkipped;                       // of those: dropped (stuck file skipped)
    QHash<QString, _GESAsset *> m_passDelivered; // path -> asset (loader's transfer-full ref)
    int m_passDone = 0;
    bool m_proxyLoaderConnected = false;
    QHash<QString, QString> computeProxyStep(bool &changed);
    void startProxyPass(const QHash<QString, QString> &toInstall);
    void onProxyResult(const QString &path, int status, quintptr asset, const QString &error, bool abandoned);
    void onProxyPathsDropped(const QStringList &paths, bool stuck);
    void advanceProxyPass();
    void emitProxyProgress();
    void scheduleProxyInstallationChanged();
    QTimer *m_proxyInstallCoalesceTimer = nullptr;

    ProjectBinModel m_projectBinModel;
    RenderEngine m_renderEngine;
    CacheManager m_cacheManager;
    MediaAvailability m_mediaAvailability;
    ProfileStore m_profileStore;
    WaveformGenerator m_waveformGenerator;
    ProxyGenerator m_proxyGenerator;
    ShortcutManager m_shortcuts;
    QString m_currentProjectDir;

    void connectCacheAndWaveform();
    QString m_selectedProjectBinItemId;
    QString m_loggingSelectedBinItemId;
    QHash<QString, QStringList> m_expandedItemIds;
    QStringList m_availableDecoders;
    QString m_preferredDecoder;
    QString m_unavailableDecoder;
    QStringList m_availableEncoders;
    QString m_preferredEncoder;
    QList<GPUDevice> m_gpuDevices;
    
    // --- ÚJ: Tárolt adatok ---
    QVariantList m_recentProjects;
    QVariantMap m_globalConfig;
};

#endif // BACKENDMANAGER_H
