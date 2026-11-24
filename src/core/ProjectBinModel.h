#ifndef PROJECTBINMODEL_H
#define PROJECTBINMODEL_H

#include <QAbstractItemModel>
#include <QDir>
#include <QList>
#include <QSet>
#include <QString>
#include <QVariantMap>
#include "MetadataExtractor.h"

class CacheManager;

class ProjectBinItem
{
public:
    explicit ProjectBinItem(const QString &id, const QString &name, bool isFolder, const QString &path = QString(), ProjectBinItem *parent = nullptr);
    ~ProjectBinItem();

    // Tree structure
    void appendChild(ProjectBinItem *child);
    void removeChild(ProjectBinItem *child);
    ProjectBinItem *child(int row);
    int childCount() const;
    int row() const;
    ProjectBinItem *parentItem();

    // Data access
    QString id() const { return m_id; }
    QString name() const { return m_name; }
    void setName(const QString &name) { m_name = name; }
    bool isFolder() const { return m_isFolder; }
    QString path() const { return m_path; }
    // Only for a relink (ProjectBinModel::relinkItems()): the bin item keeps
    // its id, name and metadata, it just points at the file's new location.
    void setPath(const QString &path) { m_path = path; }
    QString type() const;

    // Generator ("virtual") items - bin entries that are NOT backed by a
    // file on disk (currently only "title"; colour clips / test patterns
    // / gradients are meant to slot in here later without touching the
    // tree code). An empty kind means an ordinary file/folder item, in
    // which case type() keeps deriving the type from the extension
    // exactly as before.
    QString kind() const { return m_kind; }
    void setKind(const QString &kind) { m_kind = kind; }
    bool isGenerator() const { return !m_kind.isEmpty(); }
    // Generator parameter blob (for "title": the same JSON object shape
    // TitleClips.cpp consumes). Opaque to this class.
    QString generatorParams() const { return m_generatorParams; }
    void setGeneratorParams(const QString &json) { m_generatorParams = json; }

    // True only for the two synthetic top-level grouping folders
    // ("Filesystem" / "Virtual"). They exist purely so the tree has a
    // visible shape; they are never serialized, never created or
    // destroyed by the user, and cannot be renamed.
    bool isPseudo() const { return m_pseudo; }
    void setPseudo(bool pseudo) { m_pseudo = pseudo; }

    // Folder expand state
    bool isExpanded() const { return m_expanded; }
    void setExpanded(bool expanded) { m_expanded = expanded; }

    // Metadata access
    QString duration() const { return m_duration; }
    void setDuration(const QString &duration) { m_duration = duration; }
    QString resolution() const { return m_resolution; }
    void setResolution(const QString &resolution) { m_resolution = resolution; }
    QString frameRate() const { return m_frameRate; }
    void setFrameRate(const QString &frameRate) { m_frameRate = frameRate; }
    QString aspectRatio() const { return m_aspectRatio; }
    void setAspectRatio(const QString &aspectRatio) { m_aspectRatio = aspectRatio; }
    QString videoCodec() const { return m_videoCodec; }
    void setVideoCodec(const QString &videoCodec) { m_videoCodec = videoCodec; }
    QString audioCodec() const { return m_audioCodec; }
    void setAudioCodec(const QString &audioCodec) { m_audioCodec = audioCodec; }
    // Whether the source actually has an audio stream, per playbin's
    // "n-audio" count - NOT derived from m_audioCodec, which can stay
    // empty even for files that do have audio (some codec/container
    // combinations never populate the audio-codec tag). Defaults to
    // true (permissive) until MetadataExtractor's async result arrives,
    // to avoid wrongly suppressing a real audio track while unknown.
    bool hasAudioStream() const { return m_hasAudioStream; }
    void setHasAudioStream(bool hasAudio) { m_hasAudioStream = hasAudio; }

    // Source-file fingerprint, persisted alongside the metadata it
    // describes so a reopened project can tell whether a cached result
    // still applies to the file on disk, instead of unconditionally
    // re-running MetadataExtractor for every item on every load (which
    // spins up one real GStreamer pipeline per item, all at once).
    // -1 means "no cache recorded" (e.g. a project file saved before this
    // existed, or an item whose extraction never completed).
    qint64 sourceFileSize() const { return m_sourceFileSize; }
    void setSourceFileSize(qint64 size) { m_sourceFileSize = size; }
    // Stored for diagnostics/future use only - NOT consulted by the
    // cache-validity check (see ProjectBinModel::isCacheValid()).
    // Deliberately: many ordinary ways of moving a project between
    // machines (zip/unzip, Dropbox/Drive sync, rsync without -t) change
    // mtime without changing a single byte of content, and treating that
    // as "changed" would make the cache never hit on exactly the
    // cross-machine case it's most valuable for.
    qint64 sourceFileMTime() const { return m_sourceFileMTime; }
    void setSourceFileMTime(qint64 mtime) { m_sourceFileMTime = mtime; }
    // True once a successful extraction (fresh or cache-valid) has
    // populated this item's metadata fields - gates whether itemToJson()
    // persists a <metadata> block at all.
    bool hasCachedMetadata() const { return m_sourceFileSize > 0; }

    QString bitrate() const { return m_bitrate; }
    void setBitrate(const QString &bitrate) { m_bitrate = bitrate; }
    QString encoder() const { return m_encoder; }
    void setEncoder(const QString &encoder) { m_encoder = encoder; }
    QString creationTime() const { return m_creationTime; }
    void setCreationTime(const QString &creationTime) { m_creationTime = creationTime; }

    // Find item by ID recursively
    ProjectBinItem *findItemById(const QString &id);

private:
    QString m_id;
    QString m_name;
    bool m_isFolder;
    QString m_path;
    bool m_expanded;
    QList<ProjectBinItem*> m_childItems;
    ProjectBinItem *m_parentItem;

    // Metadata fields
    QString m_duration;
    QString m_resolution;
    QString m_frameRate;
    QString m_aspectRatio;
    QString m_videoCodec;
    QString m_audioCodec;
    bool m_hasAudioStream = true;
    qint64 m_sourceFileSize = -1;
    qint64 m_sourceFileMTime = -1;
    QString m_bitrate;
    QString m_encoder;
    QString m_creationTime;

    QString m_kind;              // "" = ordinary file/folder, "title" = generator
    QString m_generatorParams;   // JSON blob, generator items only
    bool m_pseudo = false;       // "Filesystem"/"Virtual" grouping folders
};

class ProjectBinModel : public QAbstractItemModel
{
    Q_OBJECT

public:
    enum Roles {
        DisplayRole = Qt::DisplayRole,
        DecorationRole = Qt::DecorationRole,
        IdRole = Qt::UserRole + 1,
        NameRole,
        IsFolderRole,
        PathRole,
        TypeRole,
        ExpandedRole,
        ThumbRole,
        DurationRole,
        FrameCountRole,
        ProxyRole,
        AudioRole,
        VideoRole,
        ClipProgressRole,
        // Metadata roles
        ResolutionRole,
        FrameRateRole,
        AspectRatioRole,
        VideoCodecRole,
        AudioCodecRole,
        BitrateRole,
        EncoderRole,
        CreationTimeRole,
        // Waveform roles
        WaveformStatusRole,
        WaveformPathRole,
        WaveformProgressRole,
        // Proxy roles (status itself is ProxyRole, above)
        ProxyPathRole,
        ProxyProgressRole,
        ProxyResolutionsRole,
        // Generator ("virtual") item roles
        TitleParamsRole,
        PseudoRole,
        // True while the item's source file is known not to be on disk
        // (see setMissingItems()).
        MissingRole
    };
    // Without this, "Backend.projectBinModel.DurationRole" etc. are
    // undefined from QML (the enum exists in C++ but was never
    // registered with the meta-object system) - every metadata lookup
    // in SourceMonitor.qml's getMetadata() then silently passed role 0
    // (Qt::DisplayRole) to data(), which returns the item's NAME for
    // every single field. Confirmed live: all "Clip Information" rows
    // showed the filename instead of their actual value.
    Q_ENUM(Roles)

    explicit ProjectBinModel(QObject *parent = nullptr);
    ~ProjectBinModel();

    // QAbstractItemModel interface
    QModelIndex index(int row, int column, const QModelIndex &parent = QModelIndex()) const override;
    QModelIndex parent(const QModelIndex &child) const override;
    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    int columnCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override;
    bool setData(const QModelIndex &index, const QVariant &value, int role = Qt::EditRole) override;
    QHash<int, QByteArray> roleNames() const override;

    // Custom methods
    Q_INVOKABLE void addFile(const QString &filePath, const QString &parentId = QString());
    // Returns the new folder's id (never empty). Used to be void; both
    // existing QML call sites ignore the result, so this is source
    // compatible, it just lets a caller select/expand what it created.
    Q_INVOKABLE QString addFolder(const QString &folderName, const QString &parentId = QString());
    // Recreates `folderPath`'s own subtree as nested bin folders under
    // `parentId` (empty / unknown / anything inside "Virtual" resolves to
    // "Filesystem", exactly like addFile()), and adds every supported
    // media file found into the matching bin folder. Directories whose
    // whole subtree contains no supported media are skipped entirely, so
    // a footage folder doesn't drag in .thumbnails/proxy/cache shells.
    // Returns the id of the created top-level bin folder, or "" if
    // nothing was imported (missing directory / no media anywhere).
    Q_INVOKABLE QString importFolderTree(const QString &folderPath,
                                         const QString &parentId = QString(),
                                         bool recursive = true);
    // Creates a non-file-backed TITLE item under the "Virtual" pseudo
    // folder and returns its id (empty on failure). `titleParamsJson` is
    // stored verbatim - callers normally pass
    // BackendManager::defaultTitleParams().
    Q_INVOKABLE QString addTitleItem(const QString &name, const QString &titleParamsJson);
    // Generator params of `itemId`, or "" if it isn't a generator item.
    Q_INVOKABLE QString itemTitleParams(const QString &itemId) const;
    Q_INVOKABLE void setItemTitleParams(const QString &itemId, const QString &titleParamsJson);
    // True for the "Filesystem"/"Virtual" grouping folders, which the UI
    // must not offer to delete or rename.
    Q_INVOKABLE bool isPseudoItem(const QString &itemId) const;
    // Id of `itemId`'s enclosing folder, or "" when that would be the
    // invisible root or one of the "Filesystem"/"Virtual" pseudo groups
    // (i.e. "" means "the default target", which resolveFileParent()
    // turns back into "Filesystem" for file-backed items). Used by the
    // Project Bin's drag-and-drop: a drop landing on a FILE row imports
    // into that file's own folder.
    Q_INVOKABLE QString parentFolderId(const QString &itemId) const;
    Q_INVOKABLE void removeItem(const QString &itemId);
    Q_INVOKABLE void renameItem(const QString &itemId, const QString &newName);
    Q_INVOKABLE void toggleExpanded(const QString &itemId);
    Q_INVOKABLE QString toJson() const;
    Q_INVOKABLE void loadFromJson(const QString &json);
    Q_INVOKABLE void clear();
    Q_INVOKABLE QModelIndex indexFromItemId(const QString &itemId) const;
    // Live hasAudio/hasVideo lookup by id, for callers (like
    // TimelineDropArea) that need the CURRENT value rather than a
    // snapshot taken earlier - e.g. a drag payload captured at
    // Drag.start() can be stale, since MetadataExtractor's async audio-
    // codec probe may still be running at that point even though it
    // usually finishes well before the user actually drops the clip.
    Q_INVOKABLE bool itemHasAudio(const QString &itemId) const;
    Q_INVOKABLE bool itemHasVideo(const QString &itemId) const;
    // Ids of every "video"-type item anywhere in the tree (any folder
    // depth, both the "Filesystem" and "Virtual" groups) - used by the
    // Proxy settings tab's "Generate proxy for all bin items" action.
    // Folders, audio/image items, and generator items are excluded.
    Q_INVOKABLE QStringList videoItemIds() const;
    // Reverse lookup: the bin item id whose path matches `path` (compared
    // via toLocalPath(), so a percent-encoded file:// URL on either side
    // still matches), or "" if nothing in the tree matches. clipsModel
    // rows (TimelinePanel) carry a timeline clip's itemPath but not its
    // owning bin item's id - this is what main.qml's open-time proxy-
    // backfill check (proxy_build_plan.md Part J.2) uses to bridge that
    // gap and query CacheManager::getProxyStatus() for it.
    Q_INVOKABLE QString itemIdForPath(const QString &path) const;
    // Manual escape hatch for the (rare) case a cached-but-wrong result
    // needs to be forced to re-extract without waiting for the file size
    // to change - e.g. a replaced file that happens to be byte-identical
    // in size to the one it replaced.
    Q_INVOKABLE void refreshMetadata(const QString &itemId);
    // Same, for every video item in the bin at once (the Logging
    // workspace's toolbar "Refresh" button) - reuses the same
    // Interactive-priority queue/dedupe as a single refresh, so a large
    // bin doesn't spin up dozens of concurrent playbin pipelines, it
    // just throttles through them the same way project load does.
    Q_INVOKABLE void refreshAllMetadata();
    // Render dialog's "derive settings from the first clip" needs a
    // one-shot synchronous read of already-extracted metadata (resolution/
    // frameRate/videoCodec, the same display strings MetadataExtractor
    // already produced for the Logging workspace's clip info panel) -
    // returns an empty map if itemId isn't found.
    Q_INVOKABLE QVariantMap getItemMetadata(const QString &itemId) const;

    // Metadata update
    Q_INVOKABLE void updateItemMetadata(const QString &itemId,
                                       const QString &duration,
                                       const QString &resolution,
                                       const QString &frameRate,
                                       const QString &aspectRatio,
                                       const QString &videoCodec,
                                       const QString &audioCodec,
                                       bool hasAudio,
                                       const QString &bitrate,
                                       const QString &encoder,
                                       const QString &creationTime);

    // ---- Missing source media (MediaAvailability / MissingMediaDialog) ----
    // Replaces the set of items flagged as missing (MissingRole); only rows
    // whose state changed get a dataChanged.
    Q_INVOKABLE void setMissingItems(const QStringList &ids);
    // [{itemId, path, size}] for every file-backed item (no folders, no
    // generators/titles, no pseudo groups); size is the persisted source size
    // or -1.
    Q_INVOKABLE QVariantList fileItemsForCheck() const;
    // oldPath -> newPath (plain local paths). Re-points every bin item whose
    // path matches a key; returns the ids of the items that changed.
    Q_INVOKABLE QStringList relinkItems(const QVariantMap &oldToNew);
    // These items' files exist again: register with the cache (waveform etc.)
    // and re-validate their metadata.
    Q_INVOKABLE void mediaBecameAvailable(const QStringList &ids);

    // CacheManager integration
    void setCacheManager(CacheManager *cacheManager);

signals:
    void itemAdded(const QString &itemId);
    void itemRemoved(const QString &itemId);
    void itemExpandedChanged(const QString &itemId, bool expanded);
    void waveformStatusChanged(const QString &itemId);
    void proxyStatusChanged(const QString &itemId);
    // Transient, fire-and-forget: a metadata extraction for this item
    // failed. NOT persisted and NOT reflected in any model role - the
    // item keeps whatever (possibly stale, possibly empty) metadata it
    // had. Consumers (QML) are expected to show a brief indicator and
    // forget, not track this as item state.
    void itemMetadataFailed(const QString &itemId, const QString &error);
    // Fires once per successful extraction, after updateItemMetadata()
    // has applied it - the "other half" of itemMetadataFailed, so QML
    // can track a per-item busy state with exactly two terminal events
    // (it has no other way to observe updateItemMetadata, which is a
    // Q_INVOKABLE slot, not a signal).
    void itemMetadataUpdated(const QString &itemId);
    // The set of items flagged missing changed (setMissingItems()/relink).
    void missingItemsChanged();

private slots:
    void onCacheItemStatusChanged(const QString &itemId, const QString &kind, const QString &status, int progress);
    void onMetadataExtractionFailed(const QString &itemId, const QString &error);

private:
    // Invisible true root. Its ONLY children are the two pseudo folders
    // below - see buildSkeleton().
    ProjectBinItem *m_rootItem;
    // "Filesystem": the real parent of every item that used to live at
    // the top level of the bin. The project JSON's top-level array maps
    // 1:1 onto THIS node's children, so nothing about how real items are
    // stored or nested changed when the pseudo folders were introduced.
    ProjectBinItem *m_fsRoot = nullptr;
    // "Virtual": parent of every generator item (titles today).
    ProjectBinItem *m_virtualRoot = nullptr;
    // Appended to generateId()'s timestamp component to guarantee
    // uniqueness - the millisecond timestamp alone collides for any two
    // items created in the same millisecond, trivially reachable by a
    // bulk multi-file add. The counter alone isn't sufficient either: a
    // reopened project restores ids from its JSON (which encode an
    // earlier session's timestamp+counter), while THIS session's counter
    // restarts at 0, so a collision between a freshly-added item and a
    // just-loaded one is still possible without the timestamp component.
    quint64 m_idCounter = 0;
    MetadataExtractor *m_metadataExtractor;
    CacheManager *m_cacheManager;

    // (Re)creates m_rootItem + the two pseudo folders. Called from the
    // constructor and from every path that throws the tree away
    // (clear(), loadFromJson()).
    void buildSkeleton();
    // Resolves a caller-supplied parentId to a real container, always
    // landing somewhere legal: empty/unknown -> "Filesystem"; anything
    // inside the "Virtual" subtree -> "Filesystem" too (only this class
    // may put items there, so that they round-trip through the JSON as
    // generator entries rather than silently migrating).
    ProjectBinItem *resolveFileParent(const QString &parentId) const;
    bool isUnderVirtual(ProjectBinItem *item) const;

    ProjectBinItem *itemFromIndex(const QModelIndex &index) const;
    QModelIndex indexFromItem(ProjectBinItem *item) const;
    QString generateId(bool isFolder);
    QString extractFileName(const QString &filePath) const;
    QString detectFileType(const QString &fileName) const;
    bool isVideoFile(const QString &fileName) const;
    // True iff detectFileType() classifies the name as video/audio/image -
    // i.e. something worth putting in the bin. Keeps sidecars (.srt,
    // .xmp, .THM, ...) out of a bulk folder import.
    bool isSupportedMediaFile(const QString &fileName) const;
    // Post-insert bookkeeping shared by addFile() and the bulk importer:
    // itemAdded, metadata extraction, waveform/cache registration. Must
    // be called AFTER endInsertRows() (a bulk import inserts many rows in
    // one begin/end pair, then calls this once per new item).
    void registerNewFileItem(ProjectBinItem *item, MetadataExtractor::Priority priority);
    // Cheap pre-pass used to prune empty branches before any bin folder
    // is created for them.
    bool subtreeHasMedia(const QDir &dir, bool recursive, int depth) const;
    // Recursive worker for importFolderTree(). Deliberately takes a real
    // ProjectBinItem* rather than a parentId string: the pseudo-folder
    // guard (resolveFileParent) runs exactly once, in the public entry
    // point, and everything this creates is by construction a descendant
    // of that already-validated container. There is intentionally no
    // QML-facing overload taking a raw item pointer.
    QString importFolderTreeInto(const QDir &dir, ProjectBinItem *parentItem, bool recursive, int depth);
    // Running total for one importFolderTree() call, against the
    // kMaxImportItems safety cap.
    int m_importedCount = 0;
    // True if item's cached metadata still matches the file on disk
    // (same byte size - see ProjectBinItem::sourceFileMTime()'s comment
    // for why mtime isn't part of this check).
    bool isCacheValid(ProjectBinItem *item) const;
    // Walks the tree after a project load, deciding per video item
    // whether to trust the just-restored cache (emits dataChanged so the
    // UI reflects it immediately) or enqueue a real re-extraction.
    void revalidateTree(ProjectBinItem *item);
    // Non-recursive per-item body of revalidateTree().
    void revalidateItem(ProjectBinItem *item);
    QSet<QString> m_missingIds;

    // JSON serialization helpers
    QJsonObject itemToJson(ProjectBinItem *item) const;
    ProjectBinItem *itemFromJson(const QJsonObject &json, ProjectBinItem *parent);
};

#endif // PROJECTBINMODEL_H
