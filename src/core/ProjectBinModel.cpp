#include "ProjectBinModel.h"
#include "CacheManager.h"
#include "MediaAvailability.h"
#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <QUrl>
#include <QElapsedTimer>
#include <functional>

namespace {
// Safety rails for importFolderTree(): a user who accidentally imports
// their home directory should get a truncated import and a warning, not
// a hung app with tens of thousands of bin items. Symlink cycles are
// separately ruled out by QDir::NoSymLinks on every traversal.
const int kMaxImportDepth = 16;
const int kMaxImportItems = 5000;

// Shared by ProjectBinItem::type() and ProjectBinModel::isVideoFile() -
// previously each had its own hand-maintained copy of a short video-only
// list ({"mp4","avi","mkv","mov","wmv","flv","webm","m4v","mpg","mpeg"})
// with no audio list at all. Consequences: a video file saved in a
// container not on that list (.ts/.m2ts/.mts/.vob/.ogv/.3gp/...) fell
// through to type() "file", making itemHasVideo() false - it could no
// longer be dropped onto a video track at all (only onto an audio
// track, mislabeled as video-less). And since type() never returned
// "audio", a genuine audio file's AudioRole/itemHasAudio() fell through
// to the same "file" catch-all instead of the always-true "audio" case.
const QStringList &videoExtensions() {
    static const QStringList exts = {
        "mp4", "avi", "mkv", "mov", "wmv", "flv", "webm", "m4v", "mpg", "mpeg",
        "ts", "m2ts", "mts", "vob", "ogv", "3gp", "3g2", "asf", "rm", "divx", "mxf"
    };
    return exts;
}

const QStringList &audioExtensions() {
    static const QStringList exts = {
        "mp3", "wav", "flac", "aac", "ogg", "m4a", "wma", "opus", "aiff", "aif", "ac3"
    };
    return exts;
}

const QStringList &imageExtensions() {
    static const QStringList exts = {
        "png", "jpg", "jpeg", "bmp", "gif", "tif", "tiff", "webp"
    };
    return exts;
}

// Converts a "file://" URI to a plain local filesystem path, safe to
// hand to QFileInfo. Uses QUrl::toLocalFile() rather than just stripping
// the 7-char prefix, because a path handed in from QML (e.g. a
// FolderListModel "fileURL") is percent-ENCODED - "my%20video.mp4" for
// "my video.mp4" - and QFileInfo on a still-encoded path silently
// reports exists() == false. That used to make caching permanently
// never engage (no error, indistinguishable from a genuinely missing
// file) for any filename containing a space or non-ASCII character.
//
// Deliberately gated on a literal "file:" prefix rather than
// QUrl(path).isLocalFile() - for a plain absolute path with no scheme
// at all (e.g. one that was never a URL to begin with, used verbatim by
// older code paths), QUrl::isLocalFile() is ALSO true, which would route
// plain paths through QUrl's percent-decoding too. That would corrupt a
// real filename containing a literal "%" (e.g. "100%.mp4" is valid on
// POSIX) and can mis-parse a path containing a colon as a URL scheme.
// The "file:" prefix check guarantees a path that was never a URL comes
// back byte-identical.
using MediaPaths::toLocalPath;
} // namespace

// ============================================================================
// ProjectBinItem Implementation
// ============================================================================

ProjectBinItem::ProjectBinItem(const QString &id, const QString &name, bool isFolder, const QString &path, ProjectBinItem *parent)
    : m_id(id)
    , m_name(name)
    , m_isFolder(isFolder)
    , m_path(path)
    , m_expanded(false)
    , m_parentItem(parent)
{
}

ProjectBinItem::~ProjectBinItem()
{
    qDeleteAll(m_childItems);
}

void ProjectBinItem::appendChild(ProjectBinItem *child)
{
    m_childItems.append(child);
}

void ProjectBinItem::removeChild(ProjectBinItem *child)
{
    m_childItems.removeOne(child);
    delete child;
}

ProjectBinItem *ProjectBinItem::child(int row)
{
    if (row < 0 || row >= m_childItems.size())
        return nullptr;
    return m_childItems.at(row);
}

int ProjectBinItem::childCount() const
{
    return m_childItems.count();
}

int ProjectBinItem::row() const
{
    if (m_parentItem)
        return m_parentItem->m_childItems.indexOf(const_cast<ProjectBinItem*>(this));
    return 0;
}

ProjectBinItem *ProjectBinItem::parentItem()
{
    return m_parentItem;
}

QString ProjectBinItem::type() const
{
    if (m_isFolder)
        return "folder";

    // Generator items (currently only "title") are not backed by a file,
    // so there is no extension to classify - the stored kind IS the type.
    if (!m_kind.isEmpty())
        return m_kind;

    // Detect file type based on extension
    QString fileName = m_path.split('/').last();
    QString ext = fileName.toLower().split('.').last();

    if (videoExtensions().contains(ext))
        return "video";
    if (audioExtensions().contains(ext))
        return "audio";
    if (imageExtensions().contains(ext))
        return "image";

    return "file";
}

ProjectBinItem *ProjectBinItem::findItemById(const QString &id)
{
    if (m_id == id)
        return this;

    for (ProjectBinItem *child : m_childItems) {
        ProjectBinItem *found = child->findItemById(id);
        if (found)
            return found;
    }

    return nullptr;
}

// ============================================================================
// ProjectBinModel Implementation
// ============================================================================

ProjectBinModel::ProjectBinModel(QObject *parent)
    : QAbstractItemModel(parent)
    , m_rootItem(nullptr)
    , m_metadataExtractor(new MetadataExtractor(this))
    , m_cacheManager(nullptr)
{
    buildSkeleton();

    // Connect metadata extractor signals
    connect(m_metadataExtractor, &MetadataExtractor::metadataExtracted,
            this, &ProjectBinModel::updateItemMetadata);
    // Previously connected nowhere at all - every extraction failure
    // (bad file, timeout, PAUSED-state-change failure) was completely
    // silent, for both the original add-file flow and the refresh icon.
    connect(m_metadataExtractor, &MetadataExtractor::extractionFailed,
            this, &ProjectBinModel::onMetadataExtractionFailed);
}

ProjectBinModel::~ProjectBinModel()
{
    delete m_rootItem;
}

// The two pseudo folders are REAL ProjectBinItem nodes (children of the
// invisible true root), not faked-up QModelIndexes: index()/parent()/
// rowCount()/data() are therefore completely unchanged and keep walking
// one single, ordinary tree - which is what makes this safe. Everything
// "pseudo" about them lives in exactly three places:
//   1. only this function ever creates them, and removeItem()/
//      renameItem()/setData() refuse to touch them;
//   2. toJson() never writes them out - it writes m_fsRoot's children as
//      the top-level array (byte-for-byte the same shape as before the
//      pseudo folders existed) followed by m_virtualRoot's generator
//      entries, all at the same top level;
//   3. loadFromJson() routes each top-level entry back into m_fsRoot or
//      m_virtualRoot by its "type".
// Consequence: a real file/folder's stored parent relationship is
// untouched - "top level of the project JSON" still means exactly what
// it always did, it is just DISPLAYED one level in, under "Filesystem".
void ProjectBinModel::buildSkeleton()
{
    delete m_rootItem;
    m_rootItem = new ProjectBinItem("root", "Root", true);

    m_fsRoot = new ProjectBinItem(QStringLiteral("__filesystem__"), QStringLiteral("Filesystem"), true, QString(), m_rootItem);
    m_fsRoot->setPseudo(true);
    m_fsRoot->setExpanded(true);
    m_rootItem->appendChild(m_fsRoot);

    m_virtualRoot = new ProjectBinItem(QStringLiteral("__virtual__"), QStringLiteral("Virtual"), true, QString(), m_rootItem);
    m_virtualRoot->setPseudo(true);
    m_virtualRoot->setExpanded(true);
    m_rootItem->appendChild(m_virtualRoot);
}

bool ProjectBinModel::isUnderVirtual(ProjectBinItem *item) const
{
    for (ProjectBinItem *p = item; p; p = p->parentItem()) {
        if (p == m_virtualRoot) return true;
    }
    return false;
}

ProjectBinItem *ProjectBinModel::resolveFileParent(const QString &parentId) const
{
    if (parentId.isEmpty())
        return m_fsRoot;

    ProjectBinItem *parentItem = m_rootItem->findItemById(parentId);
    if (!parentItem || !parentItem->isFolder()) {
        qWarning() << "Parent item not found or not a folder:" << parentId;
        return m_fsRoot;
    }
    if (parentItem == m_rootItem)
        return m_fsRoot;
    if (isUnderVirtual(parentItem)) {
        // "Virtual" holds generator items only; a file dropped onto it
        // goes to "Filesystem" instead (see resolveFileParent()'s doc).
        qWarning() << "ProjectBinModel: refusing to add a file item under Virtual, using Filesystem instead";
        return m_fsRoot;
    }
    return parentItem;
}

QModelIndex ProjectBinModel::index(int row, int column, const QModelIndex &parent) const
{
    if (!hasIndex(row, column, parent))
        return QModelIndex();

    ProjectBinItem *parentItem = itemFromIndex(parent);
    if (!parentItem)
        return QModelIndex();

    ProjectBinItem *childItem = parentItem->child(row);
    if (childItem)
        return createIndex(row, column, childItem);

    return QModelIndex();
}

QModelIndex ProjectBinModel::parent(const QModelIndex &child) const
{
    if (!child.isValid())
        return QModelIndex();

    ProjectBinItem *childItem = itemFromIndex(child);
    ProjectBinItem *parentItem = childItem ? childItem->parentItem() : nullptr;

    if (!parentItem || parentItem == m_rootItem)
        return QModelIndex();

    return createIndex(parentItem->row(), 0, parentItem);
}

int ProjectBinModel::rowCount(const QModelIndex &parent) const
{
    ProjectBinItem *parentItem = itemFromIndex(parent);
    return parentItem ? parentItem->childCount() : 0;
}

int ProjectBinModel::columnCount(const QModelIndex &parent) const
{
    Q_UNUSED(parent)
    return 1;  // Single column tree
}

QVariant ProjectBinModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid())
        return QVariant();

    ProjectBinItem *item = itemFromIndex(index);
    if (!item)
        return QVariant();

    switch (role) {
    case IdRole:
        return item->id();
    case NameRole:
    case Qt::DisplayRole:
        return item->name();
    case IsFolderRole:
        return item->isFolder();
    case PathRole:
        return item->path();
    case TypeRole:
        return item->type();
    case ExpandedRole:
        return item->isExpanded();
    case TitleParamsRole:
        return item->generatorParams();
    case MissingRole:
        return !item->isFolder() && m_missingIds.contains(item->id());
    case PseudoRole:
        return item->isPseudo();
    case Qt::DecorationRole:
        // Return icon path based on type
        if (item->isFolder())
            return "qrc:/icons/folder.svg";
        else if (item->type() == "video")
            return "qrc:/icons/video-file.svg";
        else
            return "qrc:/icons/file.svg";
    case ThumbRole:
        // TODO: Return thumbnail path when implemented
        return QString();
    case DurationRole:
        return item->duration();
    case ResolutionRole:
        return item->resolution();
    case FrameRateRole:
        return item->frameRate();
    case AspectRatioRole:
        return item->aspectRatio();
    case VideoCodecRole:
        return item->videoCodec();
    case AudioCodecRole:
        return item->audioCodec();
    case BitrateRole:
        return item->bitrate();
    case EncoderRole:
        return item->encoder();
    case CreationTimeRole:
        return item->creationTime();
    case FrameCountRole:
        // TODO: Return frame count from metadata
        return 0;
    case ProxyRole:
        if (m_cacheManager) {
            return m_cacheManager->getProxyStatus(item->id());
        }
        return "none";
    case ProxyPathRole:
        if (m_cacheManager) {
            return m_cacheManager->getProxyPath(item->id());
        }
        return QString();
    case ProxyProgressRole:
        if (m_cacheManager) {
            return m_cacheManager->getProxyProgress(item->id());
        }
        return 0;
    case ProxyResolutionsRole:
        if (m_cacheManager) {
            return m_cacheManager->getProxyResolutions(item->id());
        }
        return QStringList();
    case AudioRole:
        // Audio-type items always have audio. For video files, trust
        // hasAudioStream() (playbin's actual "n-audio" stream count),
        // NOT audioCodec() - the GST_TAG_AUDIO_CODEC tag audioCodec is
        // based on is display-only metadata that some codec/container
        // combinations never populate even when a real audio stream
        // exists (confirmed: HEVC+AAC in mp4 via qtdemux never sets it),
        // which previously made every such file wrongly look audio-less.
        // hasAudioStream() defaults to true until MetadataExtractor's
        // async result arrives, to avoid wrongly suppressing a real
        // audio track while unknown.
        if (item->type() == "audio") return true;
        if (item->type() == "video") return item->hasAudioStream();
        return false;
    case VideoRole:
        // A title generator produces video (and only video) - it has to
        // report hasVideo so TimelineDropArea accepts it onto a video
        // track and rejects it on an audio one. A still image behaves the
        // same way (video-only, no audio stream).
        return item->type() == "video" || item->type() == "title"
            || item->type() == "image";
    case ClipProgressRole:
        return 0;
    case WaveformStatusRole:
        if (m_cacheManager) {
            return m_cacheManager->getWaveformStatus(item->id());
        }
        return "unknown";
    case WaveformPathRole:
        if (m_cacheManager) {
            return m_cacheManager->getWaveformPath(item->id());
        }
        return QString();
    case WaveformProgressRole:
        if (m_cacheManager) {
            return m_cacheManager->getWaveformProgress(item->id());
        }
        return 0;
    default:
        return QVariant();
    }
}

bool ProjectBinModel::setData(const QModelIndex &index, const QVariant &value, int role)
{
    if (!index.isValid())
        return false;

    ProjectBinItem *item = itemFromIndex(index);
    if (!item)
        return false;

    switch (role) {
    case ExpandedRole:
        item->setExpanded(value.toBool());
        emit dataChanged(index, index, {ExpandedRole});
        emit itemExpandedChanged(item->id(), value.toBool());
        return true;
    case NameRole:
    case Qt::DisplayRole:
        if (item->isPseudo()) return false;
        item->setName(value.toString());
        emit dataChanged(index, index, {NameRole, Qt::DisplayRole});
        return true;
    default:
        return false;
    }
}

QHash<int, QByteArray> ProjectBinModel::roleNames() const
{
    QHash<int, QByteArray> roles;
    roles[Qt::DisplayRole] = "display";
    roles[Qt::DecorationRole] = "icon";
    roles[IdRole] = "itemId";
    roles[NameRole] = "itemName";
    roles[IsFolderRole] = "itemIsFolder";
    roles[PathRole] = "itemPath";
    roles[TypeRole] = "itemType";
    roles[ExpandedRole] = "itemExpanded";
    roles[ThumbRole] = "thumb";
    roles[DurationRole] = "duration";
    roles[ResolutionRole] = "resolution";
    roles[FrameRateRole] = "frameRate";
    roles[AspectRatioRole] = "aspectRatio";
    roles[VideoCodecRole] = "videoCodec";
    roles[AudioCodecRole] = "audioCodec";
    roles[BitrateRole] = "bitrate";
    roles[EncoderRole] = "encoder";
    roles[CreationTimeRole] = "creationTime";
    roles[FrameCountRole] = "frameCount";
    roles[ProxyRole] = "proxyStatus";
    roles[ProxyPathRole] = "proxyPath";
    roles[ProxyProgressRole] = "proxyProgress";
    roles[ProxyResolutionsRole] = "proxyResolutions";
    roles[AudioRole] = "hasAudio";
    roles[VideoRole] = "hasVideo";
    roles[ClipProgressRole] = "clipProgress";
    roles[WaveformStatusRole] = "waveformStatus";
    roles[WaveformPathRole] = "waveformPath";
    roles[WaveformProgressRole] = "waveformProgress";
    roles[TitleParamsRole] = "titleParams";
    roles[PseudoRole] = "itemIsPseudo";
    roles[MissingRole] = "itemMissing";
    return roles;
}

void ProjectBinModel::registerNewFileItem(ProjectBinItem *item, MetadataExtractor::Priority priority)
{
    if (!item)
        return;

    emit itemAdded(item->id());

    // Extract metadata for anything MetadataExtractor can actually probe
    // (its GstDiscoverer-based pipeline is format-agnostic, not video-
    // only) - restricting this to "video" left audio and image bin items
    // permanently blank in the Clip Information panel.
    const QString type = item->type();
    if (type == "video" || type == "audio" || type == "image") {
        m_metadataExtractor->extractMetadata(item->path(), item->id(), priority);
    }

    // Waveform generation only makes sense where there's actually audio.
    if (type == "video" || type == "audio") {
        if (m_cacheManager) {
            m_cacheManager->registerItem(item->id(), toLocalPath(item->path()));
        }
    }
}

void ProjectBinModel::addFile(const QString &filePath, const QString &parentId)
{
    QString fileName = extractFileName(filePath);
    QString id = generateId(false);

    ProjectBinItem *parentItem = resolveFileParent(parentId);

    QModelIndex parentIndex = indexFromItem(parentItem);
    int row = parentItem->childCount();

    beginInsertRows(parentIndex, row, row);
    ProjectBinItem *newItem = new ProjectBinItem(id, fileName, false, filePath, parentItem);
    parentItem->appendChild(newItem);
    endInsertRows();
    // Qt 6.4's TreeView does not re-read a (collapsed) row's hasChildren
    // when its first child is inserted/last child removed; poke the parent.
    if (row == 0 && parentIndex.isValid())
        emit dataChanged(parentIndex, parentIndex);

    // A single user-initiated add is what the user is about to look at,
    // so it jumps the queue ahead of any bulk folder import in flight.
    registerNewFileItem(newItem, MetadataExtractor::Priority::Interactive);
}

QString ProjectBinModel::addFolder(const QString &folderName, const QString &parentId)
{
    QString id = generateId(true);

    ProjectBinItem *parentItem = resolveFileParent(parentId);

    QModelIndex parentIndex = indexFromItem(parentItem);
    int row = parentItem->childCount();

    beginInsertRows(parentIndex, row, row);
    ProjectBinItem *newItem = new ProjectBinItem(id, folderName, true, QString(), parentItem);
    parentItem->appendChild(newItem);
    endInsertRows();
    // Qt 6.4's TreeView does not re-read a (collapsed) row's hasChildren
    // when its first child is inserted/last child removed; poke the parent.
    if (row == 0 && parentIndex.isValid())
        emit dataChanged(parentIndex, parentIndex);

    emit itemAdded(id);
    return id;
}

bool ProjectBinModel::isSupportedMediaFile(const QString &fileName) const
{
    return detectFileType(fileName) != QLatin1String("file");
}

bool ProjectBinModel::subtreeHasMedia(const QDir &dir, bool recursive, int depth) const
{
    if (depth > kMaxImportDepth)
        return false;

    const QFileInfoList files =
        dir.entryInfoList(QDir::Files | QDir::NoSymLinks | QDir::Readable, QDir::Name);
    for (const QFileInfo &fi : files) {
        if (isSupportedMediaFile(fi.fileName()))
            return true;
    }
    if (!recursive)
        return false;

    const QFileInfoList subDirs =
        dir.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::NoSymLinks | QDir::Readable,
                          QDir::Name);
    for (const QFileInfo &sub : subDirs) {
        if (subtreeHasMedia(QDir(sub.absoluteFilePath()), true, depth + 1))
            return true;
    }
    return false;
}

QString ProjectBinModel::importFolderTree(const QString &folderPath, const QString &parentId, bool recursive)
{
    // QML hands this a percent-encoded "file://" URL (same shape addFile()
    // already receives), so go through toLocalPath() rather than a naive
    // 7-char prefix strip - otherwise any folder with a space or non-ASCII
    // character in its name simply "doesn't exist" as far as QDir is
    // concerned.
    const QString localPath = toLocalPath(folderPath);
    QDir dir(localPath);
    if (!dir.exists()) {
        qWarning() << "ProjectBinModel::importFolderTree: not a directory:" << folderPath;
        return QString();
    }
    if (!subtreeHasMedia(dir, recursive, 0)) {
        qWarning() << "ProjectBinModel::importFolderTree: no supported media under" << localPath;
        return QString();
    }

    // The ONLY pseudo-folder guard in the whole import: everything the
    // recursion creates hangs off this already-validated container.
    ProjectBinItem *parentItem = resolveFileParent(parentId);
    m_importedCount = 0;
    return importFolderTreeInto(dir, parentItem, recursive, 0);
}

QString ProjectBinModel::importFolderTreeInto(const QDir &dir, ProjectBinItem *parentItem, bool recursive, int depth)
{
    if (!parentItem)
        return QString();
    if (depth > kMaxImportDepth) {
        qWarning() << "ProjectBinModel: import depth cap" << kMaxImportDepth
                   << "reached, skipping" << dir.absolutePath();
        return QString();
    }

    // dir.dirName() is empty for a filesystem root ("/"); fall back to
    // something the user can actually recognise in the bin.
    QString folderName = dir.dirName();
    if (folderName.isEmpty())
        folderName = dir.absolutePath();

    const QString folderId = generateId(true);
    const QModelIndex parentIndex = indexFromItem(parentItem);
    const int folderRow = parentItem->childCount();

    beginInsertRows(parentIndex, folderRow, folderRow);
    ProjectBinItem *folderItem = new ProjectBinItem(folderId, folderName, true, QString(), parentItem);
    // Expanded, so the structure that was just recreated is actually
    // visible instead of collapsing into a single opaque row.
    folderItem->setExpanded(true);
    parentItem->appendChild(folderItem);
    endInsertRows();
    // Qt 6.4's TreeView does not re-read a (collapsed) row's hasChildren
    // when its first child is inserted/last child removed; poke the parent.
    if (folderRow == 0 && parentIndex.isValid())
        emit dataChanged(parentIndex, parentIndex);
    emit itemAdded(folderId);

    // --- files in this directory, inserted as ONE batch ---
    QFileInfoList media;
    const QFileInfoList files =
        dir.entryInfoList(QDir::Files | QDir::NoSymLinks | QDir::Readable, QDir::Name);
    for (const QFileInfo &fi : files) {
        if (!isSupportedMediaFile(fi.fileName()))
            continue;
        if (m_importedCount + media.size() >= kMaxImportItems) {
            qWarning() << "ProjectBinModel: import item cap" << kMaxImportItems
                       << "reached, truncating import at" << dir.absolutePath();
            break;
        }
        media.append(fi);
    }

    if (!media.isEmpty()) {
        const QModelIndex folderIndex = indexFromItem(folderItem);
        const int firstRow = folderItem->childCount();
        QList<ProjectBinItem*> created;
        created.reserve(media.size());

        beginInsertRows(folderIndex, firstRow, firstRow + media.size() - 1);
        for (const QFileInfo &fi : std::as_const(media)) {
            // Store the path in exactly the format addFile() stores (a
            // percent-encoded file:// URL) - several consumers
            // (TimelineEngine, RenderEngine) parse itemPath with their own
            // assumptions, so bulk-imported items must be byte-compatible
            // with hand-added ones.
            const QString url = QUrl::fromLocalFile(fi.absoluteFilePath()).toString();
            ProjectBinItem *item = new ProjectBinItem(generateId(false), fi.fileName(), false, url, folderItem);
            folderItem->appendChild(item);
            created.append(item);
        }
        endInsertRows();

        for (ProjectBinItem *item : std::as_const(created)) {
            // Background, NOT Interactive: a 200-file folder enqueued at
            // Interactive priority would starve whatever the user clicks
            // on next.
            registerNewFileItem(item, MetadataExtractor::Priority::Background);
        }
        m_importedCount += created.size();
    }

    // --- subdirectories ---
    if (recursive) {
        const QFileInfoList subDirs =
            dir.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::NoSymLinks | QDir::Readable,
                              QDir::Name);
        for (const QFileInfo &sub : subDirs) {
            if (m_importedCount >= kMaxImportItems)
                break;
            QDir subDir(sub.absoluteFilePath());
            // Prune: no bin folder at all for a branch with no media in it.
            if (!subtreeHasMedia(subDir, true, depth + 1))
                continue;
            importFolderTreeInto(subDir, folderItem, true, depth + 1);
        }
    }

    return folderId;
}

QString ProjectBinModel::addTitleItem(const QString &name, const QString &titleParamsJson)
{
    const QString id = QStringLiteral("title_")
                     + QString::number(QDateTime::currentMSecsSinceEpoch())
                     + "_" + QString::number(++m_idCounter);

    QModelIndex parentIndex = indexFromItem(m_virtualRoot);
    int row = m_virtualRoot->childCount();

    beginInsertRows(parentIndex, row, row);
    ProjectBinItem *newItem = new ProjectBinItem(id, name.isEmpty() ? QStringLiteral("Title") : name,
                                                 false, QString(), m_virtualRoot);
    newItem->setKind(QStringLiteral("title"));
    newItem->setGeneratorParams(titleParamsJson);
    // Drives the length of the clip created when this item is dragged
    // onto the timeline (TimelineDropArea reads the drag payload's
    // "duration" exactly like it does for a real file) and is what the
    // bin row displays under the name.
    newItem->setDuration(QStringLiteral("00:00:05.00"));
    m_virtualRoot->appendChild(newItem);
    endInsertRows();
    // Qt 6.4's TreeView does not re-read a (collapsed) row's hasChildren
    // when its first child is inserted/last child removed; poke the parent.
    if (row == 0 && parentIndex.isValid())
        emit dataChanged(parentIndex, parentIndex);

    emit itemAdded(id);
    return id;
}

QString ProjectBinModel::itemTitleParams(const QString &itemId) const
{
    if (itemId.isEmpty()) return QString();
    ProjectBinItem *item = m_rootItem->findItemById(itemId);
    if (!item || item->kind() != QLatin1String("title")) return QString();
    return item->generatorParams();
}

void ProjectBinModel::setItemTitleParams(const QString &itemId, const QString &titleParamsJson)
{
    ProjectBinItem *item = m_rootItem->findItemById(itemId);
    if (!item || item->kind() != QLatin1String("title")) {
        qWarning() << "setItemTitleParams: not a title bin item:" << itemId;
        return;
    }
    item->setGeneratorParams(titleParamsJson);
    QModelIndex idx = indexFromItem(item);
    emit dataChanged(idx, idx, {TitleParamsRole});
}

bool ProjectBinModel::isPseudoItem(const QString &itemId) const
{
    if (itemId.isEmpty()) return false;
    ProjectBinItem *item = m_rootItem->findItemById(itemId);
    return item && item->isPseudo();
}

QString ProjectBinModel::parentFolderId(const QString &itemId) const
{
    if (itemId.isEmpty()) return QString();
    ProjectBinItem *item = m_rootItem->findItemById(itemId);
    if (!item) return QString();
    ProjectBinItem *parent = item->parentItem();
    if (!parent || parent == m_rootItem || parent->isPseudo()) return QString();
    return parent->id();
}

void ProjectBinModel::removeItem(const QString &itemId)
{
    ProjectBinItem *item = m_rootItem->findItemById(itemId);
    if (!item) {
        qWarning() << "Item not found:" << itemId;
        return;
    }

    if (item->isPseudo()) {
        qWarning() << "Cannot remove the" << item->name() << "group";
        return;
    }

    ProjectBinItem *parentItem = item->parentItem();
    if (!parentItem) {
        qWarning() << "Cannot remove root item";
        return;
    }

    // Unregister from CacheManager
    if (m_cacheManager) {
        m_cacheManager->unregisterItem(itemId);
    }
    // Drop any still-queued (not yet started) extraction for this item -
    // it's about to stop existing, so there's no point starting a real
    // playbin pipeline for it.
    m_metadataExtractor->cancelPending(itemId);

    QModelIndex parentIndex = indexFromItem(parentItem);
    int row = item->row();

    beginRemoveRows(parentIndex, row, row);
    parentItem->removeChild(item);
    endRemoveRows();
    // Qt 6.4's TreeView does not re-read a (collapsed) row's hasChildren
    // when its first child is inserted/last child removed; poke the parent.
    if (parentItem->childCount() == 0 && parentIndex.isValid())
        emit dataChanged(parentIndex, parentIndex);

    emit itemRemoved(itemId);
}

void ProjectBinModel::renameItem(const QString &itemId, const QString &newName)
{
    ProjectBinItem *item = m_rootItem->findItemById(itemId);
    if (!item) {
        qWarning() << "Item not found:" << itemId;
        return;
    }
    if (item->isPseudo()) {
        qWarning() << "Cannot rename the" << item->name() << "group";
        return;
    }

    item->setName(newName);

    QModelIndex itemIndex = indexFromItem(item);
    emit dataChanged(itemIndex, itemIndex, {NameRole, Qt::DisplayRole});
}

void ProjectBinModel::toggleExpanded(const QString &itemId)
{
    ProjectBinItem *item = m_rootItem->findItemById(itemId);
    if (!item || !item->isFolder()) {
        return;
    }

    bool newExpandedState = !item->isExpanded();
    item->setExpanded(newExpandedState);

    QModelIndex itemIndex = indexFromItem(item);
    emit dataChanged(itemIndex, itemIndex, {ExpandedRole});
    emit itemExpandedChanged(itemId, newExpandedState);
}

QString ProjectBinModel::toJson() const
{
    QJsonArray binArray;

    // The pseudo folders themselves are NEVER serialized. "Filesystem"'s
    // children are written as the top-level array exactly as they were
    // before the pseudo folders existed, so an existing project file
    // round-trips unchanged; "Virtual"'s generator items are appended
    // after them at the same level and are told apart on load purely by
    // their "type" (see itemFromJson / loadFromJson).
    for (int i = 0; i < m_fsRoot->childCount(); ++i) {
        binArray.append(itemToJson(m_fsRoot->child(i)));
    }
    for (int i = 0; i < m_virtualRoot->childCount(); ++i) {
        binArray.append(itemToJson(m_virtualRoot->child(i)));
    }

    QJsonDocument doc(binArray);
    return QString::fromUtf8(doc.toJson(QJsonDocument::Indented));
}

void ProjectBinModel::loadFromJson(const QString &json)
{
    // Drop anything still queued for the bin we're about to discard -
    // without this, extractions belonging to project A would keep
    // draining (throttled, but pointlessly) after switching to project B,
    // and any that complete would just be discarded by
    // updateItemMetadata()'s now-benign "item no longer exists" path.
    m_metadataExtractor->cancelAllPending();
    m_missingIds.clear();

    beginResetModel();
    buildSkeleton();

    QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8());
    if (!doc.isArray()) {
        qWarning() << "Invalid JSON format";
        endResetModel();
        return;
    }

    QJsonArray binArray = doc.array();
    for (const QJsonValue &value : binArray) {
        if (!value.isObject()) continue;
        const QJsonObject obj = value.toObject();
        // Generator entries go under "Virtual", everything else keeps
        // landing exactly where it always did - which is now spelled
        // "the Filesystem pseudo folder" instead of "the root".
        ProjectBinItem *dest = (obj["type"].toString() == QLatin1String("title"))
                             ? m_virtualRoot : m_fsRoot;
        ProjectBinItem *item = itemFromJson(obj, dest);
        if (item)
            dest->appendChild(item);
    }

    endResetModel();

    // itemFromJson() restored whatever cached fingerprint/metadata the
    // project file had (per item, possibly none for an older project).
    // revalidateTree() decides, per video item, whether that cache still
    // matches the file on disk - a cache hit needs no MetadataExtractor
    // call at all; a miss (or no cache present) enqueues one, throttled
    // and prioritized the same way as any other extraction request. This
    // replaced an earlier version that unconditionally re-ran extraction
    // (one real GStreamer pipeline per item, started all at once) for
    // EVERY restored video item on every load, regardless of whether
    // anything had actually changed.
    //
    // isCacheValid() stats every video item synchronously on the GUI
    // thread (QFileInfo::exists()/size()). For media on an unreachable
    // network mount that can block for the mount's timeout, per item,
    // with no progress indication - a full async rework of this
    // currently-synchronous load path is a larger, riskier change than
    // everything else in this pass, so it's deliberately deferred; this
    // timer at least makes the symptom immediately diagnosable from a
    // log instead of requiring a bisect ("project X takes 90s to open"
    // -> check this line -> network mount).
    QElapsedTimer loadTimer;
    loadTimer.start();
    revalidateTree(m_rootItem);
    qDebug() << "ProjectBinModel::loadFromJson: revalidateTree took" << loadTimer.elapsed() << "ms";
}

bool ProjectBinModel::isCacheValid(ProjectBinItem *item) const
{
    if (!item || !item->hasCachedMetadata()) return false;

    // Just exists() + size(), not also isReadable() - that second
    // stat-class query roughly doubles the per-item I/O cost on a slow
    // mount for comparatively little benefit: a mode-000 (unreadable)
    // file still reports its correct size via stat() as long as the
    // parent directory is traversable, so dropping isReadable() does NOT
    // make an unreadable-but-unchanged file look like a cache hit by
    // size alone - it just means that case is no longer specifically
    // distinguished from "readable and unchanged" here. Re-extraction
    // would fail for it either way, and since refreshMetadata()/a failed
    // extraction no longer destroys a valid cache (see the "don't
    // pre-invalidate" fix), that failure is harmless rather than
    // something this check needs to pre-empt.
    QFileInfo fi(toLocalPath(item->path()));
    if (!fi.exists()) {
        qDebug() << "ProjectBinModel: cache miss (file missing):" << item->path();
        return false;
    }
    if (fi.size() != item->sourceFileSize()) {
        qDebug() << "ProjectBinModel: cache miss (size changed):" << item->path()
                  << "cached:" << item->sourceFileSize() << "current:" << fi.size();
        return false;
    }
    return true;
}

void ProjectBinModel::revalidateItem(ProjectBinItem *item)
{
    if (!item) return;

    QString itemType = item->type();
    bool isProbeable = itemType == "video" || itemType == "audio" || itemType == "image";
    if (!item->isFolder() && isProbeable) {
        // registerNewFileItem() does this for files added live during
        // the session (addFile()/importDirectory()), but loadFromJson()
        // (project open, Kdenlive import) routes every restored item
        // through here instead and never registered it with
        // CacheManager - so proxy generation silently no-opped
        // ("unknown item") for every item in any reopened or imported
        // project, working only for files dropped in mid-session.
        if (m_cacheManager && (itemType == "video" || itemType == "audio")) {
            m_cacheManager->registerItem(item->id(), toLocalPath(item->path()));
        }
        // Projects saved before the bitrate fallback existed (or whose
        // files carry no bitrate tag) have a valid cache with an empty
        // bitrate: re-probe those once, in the background, so the render
        // dialog's default bitrate can be derived. Same async queue as any
        // other extraction - never blocks the UI.
        const bool bitrateMissing = itemType == "video" && item->bitrate().isEmpty();
        if (isCacheValid(item) && !bitrateMissing) {
            // Cache hit: itemFromJson() already populated every field
            // this would otherwise come from MetadataExtractor. No
            // extraction call at all. endResetModel() already told every
            // view to re-read everything, so this dataChanged is
            // belt-and-suspenders rather than load-bearing - but it costs
            // nothing and keeps the cache-hit path behaviorally identical
            // to the "extraction just completed" path, which is the
            // property that makes this safe to reason about.
            QModelIndex idx = indexFromItem(item);
            emit dataChanged(idx, idx, {
                DurationRole, ResolutionRole, FrameRateRole, AspectRatioRole,
                VideoCodecRole, AudioCodecRole, BitrateRole, EncoderRole,
                CreationTimeRole, AudioRole
            });
        } else {
            // Background, not Interactive: this is a bulk re-validation
            // sweep at project-open time, not a file the user just
            // dropped and is about to act on - it should not jump ahead
            // of extraction requests from actual user actions (e.g.
            // dragging a new file into the bin while a large project is
            // still finishing its reopen).
            m_metadataExtractor->extractMetadata(item->path(), item->id(),
                                                  MetadataExtractor::Priority::Background);
        }
    }

}

void ProjectBinModel::revalidateTree(ProjectBinItem *item)
{
    if (!item) return;
    revalidateItem(item);
    for (int i = 0; i < item->childCount(); ++i) {
        revalidateTree(item->child(i));
    }
}

void ProjectBinModel::clear()
{
    m_metadataExtractor->cancelAllPending();
    m_missingIds.clear();
    beginResetModel();
    buildSkeleton();
    endResetModel();
}

void ProjectBinModel::updateItemMetadata(const QString &itemId,
                                         const QString &duration,
                                         const QString &resolution,
                                         const QString &frameRate,
                                         const QString &aspectRatio,
                                         const QString &videoCodec,
                                         const QString &audioCodec,
                                         bool hasAudio,
                                         const QString &bitrate,
                                         const QString &encoder,
                                         const QString &creationTime)
{
    ProjectBinItem *item = m_rootItem->findItemById(itemId);
    if (!item) {
        // Expected and benign now that extraction is queued/async and can
        // complete after the item's project (or just the item) was
        // closed/removed - not a sign of a bug the way it used to be.
        qDebug() << "updateItemMetadata: item no longer exists, discarding result:" << itemId;
        return;
    }

    // Update all metadata
    item->setDuration(duration);
    item->setResolution(resolution);
    item->setFrameRate(frameRate);
    item->setAspectRatio(aspectRatio);
    item->setVideoCodec(videoCodec);
    item->setAudioCodec(audioCodec);
    item->setHasAudioStream(hasAudio);
    item->setBitrate(bitrate);
    item->setEncoder(encoder);
    item->setCreationTime(creationTime);

    // Stamp the fingerprint of the file this result actually came from,
    // so it can be persisted (itemToJson) and trusted on the next project
    // load without re-running extraction - see ProjectBinItem's
    // sourceFileSize()/hasCachedMetadata() doc comments. Gated on
    // getting SOMETHING usable back: a playbin that reached ASYNC_DONE
    // but negotiated no caps (odd container, nothing playable) would
    // otherwise cache a "valid" but all-empty/wrong result forever -
    // leaving the size at -1 means it simply re-extracts next load,
    // same as today's fallback behavior.
    if (!duration.isEmpty() || !resolution.isEmpty()) {
        QFileInfo fi(toLocalPath(item->path()));
        if (fi.exists() && fi.size() > 0) {
            item->setSourceFileSize(fi.size());
            item->setSourceFileMTime(fi.lastModified().toMSecsSinceEpoch());
        }
    }

    // Notify model that data changed
    QModelIndex itemIndex = indexFromItem(item);
    emit dataChanged(itemIndex, itemIndex, {
        DurationRole, ResolutionRole, FrameRateRole, AspectRatioRole,
        VideoCodecRole, AudioCodecRole, BitrateRole, EncoderRole, CreationTimeRole,
        AudioRole
    });
    emit itemMetadataUpdated(itemId);
}

void ProjectBinModel::onMetadataExtractionFailed(const QString &itemId, const QString &error)
{
    ProjectBinItem *item = m_rootItem->findItemById(itemId);
    if (!item) {
        // Benign - same reasoning as updateItemMetadata()'s miss case:
        // the item's project/bin was closed while this extraction was
        // still in flight.
        qDebug() << "onMetadataExtractionFailed: item no longer exists, discarding:" << itemId;
        return;
    }
    // Deliberately does NOT touch the item's cached fields - a failed
    // extraction must not destroy a cache entry that may still be valid
    // for the file on disk (see refreshMetadata()'s comment for the
    // concrete scenario this matters for).
    qWarning() << "ProjectBinModel: metadata extraction failed for" << itemId << item->path() << "-" << error;
    emit itemMetadataFailed(itemId, error);
}

QModelIndex ProjectBinModel::indexFromItemId(const QString &itemId) const
{
    ProjectBinItem *item = m_rootItem->findItemById(itemId);
    if (!item)
        return QModelIndex();

    return indexFromItem(item);
}

bool ProjectBinModel::itemHasAudio(const QString &itemId) const
{
    ProjectBinItem *item = m_rootItem->findItemById(itemId);
    if (!item) return true; // unknown item - keep the old permissive default
    if (item->type() == "audio") return true;
    if (item->type() == "video") return item->hasAudioStream();
    return false;
}

bool ProjectBinModel::itemHasVideo(const QString &itemId) const
{
    ProjectBinItem *item = m_rootItem->findItemById(itemId);
    if (!item) return true;
    // Titles and still images produce video only (no audio stream).
    return item->type() == "video" || item->type() == "title"
        || item->type() == "image";
}

QStringList ProjectBinModel::videoItemIds() const
{
    QStringList ids;
    std::function<void(ProjectBinItem*)> walk = [&](ProjectBinItem *item) {
        for (int i = 0; i < item->childCount(); ++i) {
            ProjectBinItem *child = item->child(i);
            if (!child) continue;
            if (!child->isFolder() && child->type() == "video") ids << child->id();
            if (child->isFolder() || child->childCount() > 0) walk(child);
        }
    };
    walk(m_rootItem);
    return ids;
}

QString ProjectBinModel::itemIdForPath(const QString &path) const
{
    // clipsModel rows carry itemPath but not the bin item's id (see
    // TimelinePanel's clipsModel role list) - this is the missing link,
    // used by main.qml's open-time proxy-backfill check (proxy_build_plan.md
    // Part J.2) to map a timeline clip's file path back to the Project Bin
    // item that owns it, so getProxyStatus() can be queried for it.
    // toLocalPath() so this compares correctly regardless of whether
    // either side is a percent-encoded file:// URL or a plain path -
    // mirrors videoItemIds()'s own walk.
    const QString target = toLocalPath(path);
    QString foundId;
    std::function<void(ProjectBinItem*)> walk = [&](ProjectBinItem *item) {
        if (!foundId.isEmpty()) return;
        for (int i = 0; i < item->childCount() && foundId.isEmpty(); ++i) {
            ProjectBinItem *child = item->child(i);
            if (!child) continue;
            if (!child->isFolder() && toLocalPath(child->path()) == target) {
                foundId = child->id();
                return;
            }
            if (child->isFolder() || child->childCount() > 0) walk(child);
        }
    };
    walk(m_rootItem);
    return foundId;
}

QVariantMap ProjectBinModel::getItemMetadata(const QString &itemId) const
{
    QVariantMap out;
    ProjectBinItem *item = m_rootItem->findItemById(itemId);
    if (!item) return out;
    out["resolution"] = item->resolution();
    out["frameRate"] = item->frameRate();
    out["videoCodec"] = item->videoCodec();
    out["bitrate"] = item->bitrate();
    out["path"] = item->path();
    out["duration"] = item->duration();   // "hh:mm:ss.cc" (TimelinePanel.sourceLengthOf() fallback)
    return out;
}

void ProjectBinModel::refreshMetadata(const QString &itemId)
{
    ProjectBinItem *item = m_rootItem->findItemById(itemId);
    if (!item) return;
    // Deliberately does NOT touch sourceFileSize/sourceFileMTime here.
    // MetadataExtractor consults no cache of its own - all caching logic
    // lives in this class - so simply requesting a fresh extraction is
    // both necessary and sufficient; updateItemMetadata() unconditionally
    // re-stamps the fingerprint from disk on success. Invalidating up
    // front (as an earlier version of this function did) meant a FAILED
    // refresh - e.g. the file was deleted/unmounted since it was cached -
    // permanently destroyed a cache entry that was still valid for the
    // file actually on disk, with no error ever shown anywhere (nothing
    // was connected to extractionFailed at the time). Now a failed
    // refresh just leaves the previous valid cache in place.
    m_metadataExtractor->extractMetadata(item->path(), itemId, MetadataExtractor::Priority::Interactive);
}

void ProjectBinModel::refreshAllMetadata()
{
    std::function<void(ProjectBinItem*)> walk = [this, &walk](ProjectBinItem *item) {
        if (!item) return;
        QString t = item->type();
        if (!item->isFolder() && (t == "video" || t == "audio" || t == "image")) {
            refreshMetadata(item->id());
        }
        for (int i = 0; i < item->childCount(); ++i) {
            walk(item->child(i));
        }
    };
    walk(m_rootItem);
}

ProjectBinItem *ProjectBinModel::itemFromIndex(const QModelIndex &index) const
{
    if (index.isValid()) {
        return static_cast<ProjectBinItem*>(index.internalPointer());
    }
    return m_rootItem;
}

QModelIndex ProjectBinModel::indexFromItem(ProjectBinItem *item) const
{
    if (!item || item == m_rootItem)
        return QModelIndex();

    return createIndex(item->row(), 0, item);
}

QString ProjectBinModel::generateId(bool isFolder)
{
    // Timestamp alone collides for any two items created in the same
    // millisecond (a bulk multi-file add does exactly this), silently
    // routing every later item's metadata/removal/refresh onto the
    // first one via findItemById(). The counter makes it unique; see
    // m_idCounter's doc comment for why the timestamp is still kept too.
    QString prefix = isFolder ? "folder_" : "item_";
    return prefix + QString::number(QDateTime::currentMSecsSinceEpoch())
                   + "_" + QString::number(++m_idCounter);
}

QString ProjectBinModel::extractFileName(const QString &filePath) const
{
    // toLocalPath() (not a raw mid(7) strip) so a percent-encoded name
    // from a QML fileURL (e.g. "my%20video.mp4") displays decoded
    // ("my video.mp4") instead of showing the raw escape sequence.
    return QFileInfo(toLocalPath(filePath)).fileName();
}

QString ProjectBinModel::detectFileType(const QString &fileName) const
{
    QString ext = fileName.toLower().split('.').last();
    if (videoExtensions().contains(ext))
        return "video";
    if (audioExtensions().contains(ext))
        return "audio";
    if (imageExtensions().contains(ext))
        return "image";
    return "file";
}

bool ProjectBinModel::isVideoFile(const QString &fileName) const
{
    QString ext = fileName.toLower().split('.').last();
    return videoExtensions().contains(ext);
}

QJsonObject ProjectBinModel::itemToJson(ProjectBinItem *item) const
{
    QJsonObject obj;
    obj["id"] = item->id();
    obj["type"] = item->type();
    obj["name"] = item->name();

    // Generator item: no file on disk, so none of the path/metadata/
    // cache machinery below applies - just the params blob and the
    // nominal duration.
    if (item->isGenerator()) {
        obj["titleParams"] = item->generatorParams();
        obj["duration"] = item->duration();
        return obj;
    }

    if (!item->isFolder()) {
        obj["path"] = item->path();
        obj["duration"] = item->duration();
        obj["audioChannels"] = 2;  // TODO: extract from audioCodec or add separate field

        // Cached extraction result + the fingerprint it's valid for, so a
        // reopened project can skip re-running MetadataExtractor (one real
        // GStreamer pipeline per item) when the file is unchanged. Only
        // written once a successful extraction has actually populated the
        // item - an item that's still mid-extraction (or whose extraction
        // failed) serializes without this block, so the next load
        // correctly re-extracts it instead of persisting nothing/wrong
        // data as if it were valid.
        if (item->hasCachedMetadata()) {
            QJsonObject source;
            // Stored as strings, not QJsonValue(qint64) - QJsonValue only
            // has a double number type; qint64 file sizes fit exactly
            // (53 bits of integer precision is ~9 PB), but strings avoid
            // the question entirely and avoid any QJsonDocument
            // formatting surprises.
            source["size"] = QString::number(item->sourceFileSize());
            source["mtime"] = QString::number(item->sourceFileMTime());
            obj["source"] = source;

            QJsonObject metadata;
            metadata["duration"] = item->duration();
            metadata["resolution"] = item->resolution();
            metadata["frameRate"] = item->frameRate();
            metadata["aspectRatio"] = item->aspectRatio();
            metadata["videoCodec"] = item->videoCodec();
            metadata["audioCodec"] = item->audioCodec();
            metadata["hasAudioStream"] = item->hasAudioStream();
            metadata["bitrate"] = item->bitrate();
            metadata["encoder"] = item->encoder();
            metadata["creationTime"] = item->creationTime();
            obj["metadata"] = metadata;
        }
    }

    if (item->isFolder() && item->childCount() > 0) {
        QJsonArray children;
        for (int i = 0; i < item->childCount(); ++i) {
            children.append(itemToJson(item->child(i)));
        }
        obj["children"] = children;
    } else if (item->isFolder()) {
        obj["children"] = QJsonArray();
    }

    return obj;
}

ProjectBinItem *ProjectBinModel::itemFromJson(const QJsonObject &json, ProjectBinItem *parent)
{
    QString id = json["id"].toString();
    QString name = json["name"].toString();
    QString type = json["type"].toString();
    bool isFolder = (type == "folder");
    QString path = json["path"].toString();

    ProjectBinItem *item = new ProjectBinItem(id, name, isFolder, path, parent);

    if (type == QLatin1String("title")) {
        item->setKind(type);
        item->setGeneratorParams(json["titleParams"].toString());
        const QString dur = json["duration"].toString();
        item->setDuration(dur.isEmpty() ? QStringLiteral("00:00:05.00") : dur);
        return item;
    }

    // Load metadata from JSON if available
    if (!isFolder) {
        if (json.contains("duration")) {
            QString duration = json["duration"].toString();
            if (!duration.isEmpty()) {
                item->setDuration(duration);
            }
        }
        // audioChannels is currently not stored in ProjectBinItem, but we load it for future use

        // Cached fingerprint + extraction result, if this project was
        // saved after caching was added. Absent entirely for older
        // project files - item just keeps its constructor defaults
        // (sourceFileSize -1 => hasCachedMetadata() false), which
        // revalidateTree() reads as "always re-extract", i.e. exactly
        // the old unconditional behavior for that one item.
        //
        // "source" and "metadata" are required TOGETHER, not
        // independently: itemToJson() always writes both or neither
        // (gated on hasCachedMetadata()), so finding only one means a
        // hand-edited or corrupted project file. Trusting a lone
        // "source" block would make hasCachedMetadata() true with every
        // display field still empty/default - isCacheValid() would then
        // report a genuine cache HIT (the file size really does match)
        // and the item would show blank metadata, and critically
        // hasAudioStream stuck at its permissive default, forever -
        // silently reintroducing the phantom-audio-clip bug through a
        // path the user has no reason to suspect. The content check
        // (duration/resolution non-empty) mirrors the gate
        // updateItemMetadata() uses when WRITING the cache, so what we're
        // willing to trust on read matches what we're willing to persist
        // on write.
        bool cacheOk = json.contains("source") && json["source"].isObject()
                     && json.contains("metadata") && json["metadata"].isObject();
        qint64 sourceSize = -1;
        qint64 sourceMTime = -1;
        if (cacheOk) {
            QJsonObject source = json["source"].toObject();
            bool ok = false;
            sourceSize = source["size"].toString().toLongLong(&ok);
            if (!ok || sourceSize <= 0) cacheOk = false;
            sourceMTime = source["mtime"].toString().toLongLong(&ok);
            if (!ok) sourceMTime = -1; // mtime is diagnostic-only, never gates validity
        }
        QJsonObject metadata;
        if (cacheOk) {
            metadata = json["metadata"].toObject();
            if (metadata["duration"].toString().isEmpty() && metadata["resolution"].toString().isEmpty()) {
                cacheOk = false;
            }
        }

        if (cacheOk) {
            // Overrides the legacy top-level "duration" read above with
            // the same value - harmless, keeps a single source of truth
            // once both are present.
            item->setDuration(metadata["duration"].toString());
            item->setResolution(metadata["resolution"].toString());
            item->setFrameRate(metadata["frameRate"].toString());
            item->setAspectRatio(metadata["aspectRatio"].toString());
            item->setVideoCodec(metadata["videoCodec"].toString());
            item->setAudioCodec(metadata["audioCodec"].toString());
            // Default true (permissive) if somehow absent from an
            // otherwise-valid metadata object - never false, which would
            // wrongly suppress a real audio track.
            item->setHasAudioStream(metadata["hasAudioStream"].toBool(true));
            item->setBitrate(metadata["bitrate"].toString());
            item->setEncoder(metadata["encoder"].toString());
            item->setCreationTime(metadata["creationTime"].toString());
            item->setSourceFileSize(sourceSize);
            item->setSourceFileMTime(sourceMTime);
        } else if (json.contains("source") || json.contains("metadata")) {
            // Present but rejected - distinct from "absent" (old project
            // file, expected and silent): this is a corrupt/malformed
            // project file worth a log line, even though the fallback
            // (re-extract) is the same either way.
            qWarning() << "ProjectBinModel: ignoring incomplete cache block for item" << id;
        }
    }

    if (isFolder && json.contains("children")) {
        QJsonArray children = json["children"].toArray();
        for (const QJsonValue &childValue : children) {
            if (childValue.isObject()) {
                ProjectBinItem *childItem = itemFromJson(childValue.toObject(), item);
                if (childItem)
                    item->appendChild(childItem);
            }
        }
    }

    return item;
}

void ProjectBinModel::setCacheManager(CacheManager *cacheManager)
{
    if (m_cacheManager) {
        disconnect(m_cacheManager, nullptr, this, nullptr);
    }

    m_cacheManager = cacheManager;

    if (m_cacheManager) {
        connect(m_cacheManager, &CacheManager::itemStatusChanged,
                this, &ProjectBinModel::onCacheItemStatusChanged);
    }
}

namespace {
// Every file-backed item (not folder, not generator, not pseudo group).
void collectFileItems(ProjectBinItem *parent, QList<ProjectBinItem *> &out)
{
    for (int i = 0; i < parent->childCount(); ++i) {
        ProjectBinItem *child = parent->child(i);
        if (!child) continue;
        if (child->isFolder()) {
            collectFileItems(child, out);
        } else if (!child->isGenerator() && !child->path().isEmpty()) {
            out.append(child);
        }
    }
}
} // namespace

void ProjectBinModel::setMissingItems(const QStringList &ids)
{
    const QSet<QString> next(ids.begin(), ids.end());
    if (next == m_missingIds) return;
    const QSet<QString> changed = (next - m_missingIds) + (m_missingIds - next);
    m_missingIds = next;
    for (const QString &id : changed) {
        ProjectBinItem *item = m_rootItem->findItemById(id);
        if (!item) continue;
        const QModelIndex idx = indexFromItem(item);
        emit dataChanged(idx, idx, {MissingRole});
    }
    emit missingItemsChanged();
}

QVariantList ProjectBinModel::fileItemsForCheck() const
{
    QList<ProjectBinItem *> items;
    collectFileItems(m_rootItem, items);
    QVariantList out;
    for (ProjectBinItem *item : std::as_const(items)) {
        QVariantMap m;
        m["itemId"] = item->id();
        m["path"] = toLocalPath(item->path());
        m["size"] = item->sourceFileSize();
        out << m;
    }
    return out;
}

QStringList ProjectBinModel::relinkItems(const QVariantMap &oldToNew)
{
    QHash<QString, QString> map;
    for (auto it = oldToNew.constBegin(); it != oldToNew.constEnd(); ++it)
        map.insert(toLocalPath(it.key()), it.value().toString());

    QList<ProjectBinItem *> items;
    collectFileItems(m_rootItem, items);
    QStringList changed;
    for (ProjectBinItem *item : std::as_const(items)) {
        const auto found = map.constFind(toLocalPath(item->path()));
        if (found == map.constEnd()) continue;
        const QString newPath = found.value();
        item->setPath(newPath);
        m_missingIds.remove(item->id());
        const QModelIndex idx = indexFromItem(item);
        emit dataChanged(idx, idx, {PathRole, MissingRole});
        const QString type = item->type();
        if (m_cacheManager && (type == "video" || type == "audio"))
            m_cacheManager->relinkItem(item->id(), newPath);
        revalidateItem(item);
        changed << item->id();
    }
    if (!changed.isEmpty()) emit missingItemsChanged();
    return changed;
}

void ProjectBinModel::mediaBecameAvailable(const QStringList &ids)
{
    for (const QString &id : ids) {
        ProjectBinItem *item = m_rootItem->findItemById(id);
        if (!item || item->isFolder() || item->isGenerator()) continue;
        m_missingIds.remove(id);
        const QModelIndex idx = indexFromItem(item);
        emit dataChanged(idx, idx, {MissingRole});
        const QString type = item->type();
        if (m_cacheManager && (type == "video" || type == "audio"))
            m_cacheManager->mediaBecameAvailable(id, toLocalPath(item->path()));
        revalidateItem(item);
    }
    emit missingItemsChanged();
}

void ProjectBinModel::onCacheItemStatusChanged(const QString &itemId, const QString &kind, const QString &status, int progress)
{
    Q_UNUSED(status)
    Q_UNUSED(progress)

    ProjectBinItem *item = m_rootItem->findItemById(itemId);
    if (!item) return;

    QModelIndex itemIndex = indexFromItem(item);
    if (kind == "proxy") {
        emit dataChanged(itemIndex, itemIndex, {ProxyRole, ProxyPathRole, ProxyProgressRole, ProxyResolutionsRole});
        emit proxyStatusChanged(itemId);
    } else {
        emit dataChanged(itemIndex, itemIndex, {WaveformStatusRole, WaveformPathRole, WaveformProgressRole});
        emit waveformStatusChanged(itemId);
    }
}
