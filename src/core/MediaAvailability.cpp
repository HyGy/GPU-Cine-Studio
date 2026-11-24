#include "MediaAvailability.h"

#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QMap>
#include <QUrl>
#include <QDebug>
#include <algorithm>
#include <functional>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <thread>

namespace MediaPaths {

QString toLocalPath(const QString &path)
{
    // Gated on a literal "file:" prefix (not QUrl::isLocalFile()) so a plain
    // path containing '%' or ':' is never percent-decoded / mis-parsed.
    if (path.startsWith(QLatin1String("file:"), Qt::CaseInsensitive)) {
        const QString local = QUrl(path).toLocalFile();
        if (!local.isEmpty()) return local;
    }
    return path;
}

QStringList readMountPoints()
{
    QStringList out;
    QFile f(QStringLiteral("/proc/self/mounts"));
    if (!f.open(QIODevice::ReadOnly)) return out;
    const QList<QByteArray> lines = f.readAll().split('\n');
    for (const QByteArray &line : lines) {
        const QList<QByteArray> cols = line.split(' ');
        if (cols.size() < 2) continue;
        QByteArray mp = cols[1];
        mp.replace("\\040", " ").replace("\\011", "\t").replace("\\012", "\n").replace("\\134", "\\");
        out << QString::fromUtf8(mp);
    }
    return out;
}

QString mountRootIn(const QStringList &mounts, const QString &path)
{
    QString best = QStringLiteral("/");
    for (const QString &root : mounts) {
        const bool inside = path == root || path.startsWith(root.endsWith('/') ? root : root + '/');
        if (inside && root.size() > best.size()) best = root;
    }
    return best;
}

QString mountRootFor(const QString &path)
{
    return mountRootIn(readMountPoints(), path);
}

} // namespace MediaPaths

namespace {

constexpr int kCheckTimeoutMs = 5000;
constexpr int kMaxIndexedFiles = 200000;

// Size of a regular file, -2 when it does not exist / is no regular file.
qint64 regularFileSize(const QString &path)
{
    struct stat st;
    if (::stat(path.toLocal8Bit().constData(), &st) != 0 || !S_ISREG(st.st_mode)) return -2;
    return qint64(st.st_size);
}

QString parentFolder(const QString &path)
{
    const int i = path.lastIndexOf('/');
    if (i < 0) return QString();
    return i == 0 ? QStringLiteral("/") : path.left(i);
}

QString baseName(const QString &path)
{
    return path.mid(path.lastIndexOf('/') + 1);
}

struct SearchItem {
    QString path;
    qint64 size = -1;
};

struct SearchResult {
    QVariantList matches, ambiguous, notFound;
};

SearchResult runSearch(const QString &folderIn, const QVector<SearchItem> &items,
                       const std::atomic<bool> &cancel,
                       const std::function<void(int)> &progress)
{
    SearchResult res;
    QString folder = folderIn;
    while (folder.size() > 1 && folder.endsWith('/')) folder.chop(1);

    QVector<bool> done(items.size(), false);
    QSet<QString> usedByPass1;

    // Pass 1: the missing path's own tail below the chosen folder, longest
    // tail first.
    for (int i = 0; i < items.size() && !cancel.load(); ++i) {
        const SearchItem &it = items[i];
        const QString dir = parentFolder(it.path);
        const QString file = baseName(it.path);
        const QStringList comps = dir.split('/', Qt::SkipEmptyParts);
        const int n = comps.size();
        for (int k = n; k >= 0 && !cancel.load(); --k) {
            QString cand = folder;
            if (k > 0) cand += '/' + comps.mid(n - k).join('/');
            cand += '/' + file;
            const qint64 sz = regularFileSize(cand);
            if (sz < -1) continue;
            if (it.size >= 0 && sz != it.size) continue;   // different file: try a shorter tail
            QVariantMap m;
            m["oldPath"] = it.path;
            m["newPath"] = cand;
            m["byName"] = false;
            res.matches << m;
            done[i] = true;
            usedByPass1.insert(cand);
            break;
        }
    }

    // Pass 2: basename index of the folder, only for names still wanted.
    QHash<QString, QVector<int>> wanted;   // basename -> item indices
    for (int i = 0; i < items.size(); ++i)
        if (!done[i]) wanted[baseName(items[i].path)].append(i);

    if (!wanted.isEmpty() && !cancel.load()) {
        struct Cand { QString path; qint64 size; };
        QHash<QString, QVector<Cand>> index;
        int scanned = 0;
        // No FollowSymlinks flag and NoSymLinks filter: a symlink loop cannot
        // trap the walk. Hidden files/folders are skipped (no QDir::Hidden).
        QDirIterator dit(folder, QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot | QDir::NoSymLinks,
                         QDirIterator::Subdirectories);
        while (dit.hasNext() && !cancel.load() && scanned < kMaxIndexedFiles) {
            dit.next();
            const QFileInfo fi = dit.fileInfo();
            if (++scanned % 500 == 0) progress(scanned);
            if (!fi.isFile()) continue;
            const QString name = fi.fileName();
            if (!wanted.contains(name)) continue;
            const QString p = fi.absoluteFilePath();
            if (usedByPass1.contains(p)) continue;
            index[name].append({p, fi.size()});
        }
        progress(scanned);

        // Per item: exactly one size-compatible candidate -> tentative match.
        QMap<int, QString> tentative;
        QHash<QString, int> claims;
        QMap<int, QStringList> allCands;
        for (auto w = wanted.constBegin(); w != wanted.constEnd(); ++w) {
            const QVector<Cand> cands = index.value(w.key());
            for (int i : w.value()) {
                QStringList ok;
                for (const Cand &c : cands)
                    if (items[i].size < 0 || c.size == items[i].size) ok << c.path;
                allCands[i] = ok;
                if (ok.size() == 1) {
                    tentative[i] = ok.first();
                    claims[ok.first()]++;
                }
            }
        }
        for (int i = 0; i < items.size() && !cancel.load(); ++i) {
            if (done[i]) continue;
            const QStringList ok = allCands.value(i);
            if (ok.isEmpty()) {
                res.notFound << items[i].path;
            } else if (ok.size() == 1 && claims.value(ok.first()) == 1) {
                QVariantMap m;
                m["oldPath"] = items[i].path;
                m["newPath"] = ok.first();
                m["byName"] = true;
                res.matches << m;
            } else {
                QVariantMap m;
                m["path"] = items[i].path;
                m["candidates"] = QVariant(ok);
                res.ambiguous << m;
            }
        }
    } else if (!cancel.load()) {
        for (int i = 0; i < items.size(); ++i)
            if (!done[i]) res.notFound << items[i].path;
    }
    return res;
}

} // namespace

MediaAvailability::MediaAvailability(QObject *parent)
    : QObject(parent)
{
    m_timeout.setSingleShot(true);
    m_timeout.setInterval(kCheckTimeoutMs);
    connect(&m_timeout, &QTimer::timeout, this, [this]() {
        if (m_checking) finishCheck();
    });
}

void MediaAvailability::reset()
{
    ++m_generation;
    m_timeout.stop();
    m_entries.clear();
    m_outstanding = 0;
    if (m_checking) { m_checking = false; emit checkingChanged(); }
    if (!m_missing.isEmpty()) { m_missing.clear(); emit missingChanged(); }
    cancelSearch();
}

void MediaAvailability::check(const QVariantList &entries)
{
    ++m_generation;
    m_timeout.stop();
    m_entries.clear();
    m_outstanding = 0;

    QHash<QString, int> byPath;
    for (const QVariant &v : entries) {
        const QVariantMap m = v.toMap();
        const QString path = MediaPaths::toLocalPath(m.value("path").toString());
        if (path.isEmpty()) continue;
        const auto found = byPath.constFind(path);
        if (found != byPath.constEnd()) {   // same file listed twice: merge
            Entry &e = m_entries[found.value()];
            for (const QString &id : m.value("itemIds").toStringList())
                if (!e.itemIds.contains(id)) e.itemIds << id;
            e.clipCount += m.value("clipCount").toInt();
            if (e.size < 0) e.size = m.value("size", -1).toLongLong();
            continue;
        }
        Entry e;
        e.path = path;
        e.itemIds = m.value("itemIds").toStringList();
        e.size = m.value("size", -1).toLongLong();
        e.clipCount = m.value("clipCount").toInt();
        byPath.insert(path, m_entries.size());
        m_entries.append(e);
    }

    if (m_entries.isEmpty()) {
        const bool had = !m_missing.isEmpty();
        m_missing.clear();
        if (m_checking) { m_checking = false; emit checkingChanged(); }
        if (had) emit missingChanged();
        emit checkFinished();
        return;
    }

    // Group by mount point: one detached thread per mount, so a hung drive
    // only delays its own paths.
    QMap<QString, QVector<int>> groups;
    {
        const QStringList mp = MediaPaths::readMountPoints();
        for (int i = 0; i < m_entries.size(); ++i) {
            groups[MediaPaths::mountRootIn(mp, m_entries[i].path)].append(i);
        }
    }

    if (!m_checking) { m_checking = true; emit checkingChanged(); }
    const quint64 gen = m_generation;
    QPointer<MediaAvailability> self(this);
    for (auto g = groups.constBegin(); g != groups.constEnd(); ++g) {
        QVector<int> idx = g.value();
        std::vector<std::string> paths;
        for (int i : idx) paths.push_back(m_entries[i].path.toLocal8Bit().toStdString());
        ++m_outstanding;
        std::thread([self, gen, idx, paths]() {
            QVector<int> done, exists;
            for (size_t i = 0; i < paths.size(); ++i) {
                struct stat st;
                const bool ok = ::stat(paths[i].c_str(), &st) == 0;
                done << idx[int(i)];
                exists << (ok ? 1 : 0);
            }
            if (!self) return;
            QMetaObject::invokeMethod(self.data(), [self, gen, done, exists]() {
                if (self) self->onPathsChecked(gen, done, exists);
            }, Qt::QueuedConnection);
        }).detach();
    }
    m_timeout.start();
}

void MediaAvailability::onPathsChecked(quint64 generation, const QVector<int> &indices,
                                       const QVector<int> &exists)
{
    if (generation != m_generation || !m_checking) return;
    for (int i = 0; i < indices.size(); ++i) {
        if (indices[i] < 0 || indices[i] >= m_entries.size()) continue;
        m_entries[indices[i]].state = exists[i] ? 1 : 2;
    }
    if (--m_outstanding <= 0) finishCheck();
}

void MediaAvailability::finishCheck()
{
    m_timeout.stop();
    ++m_generation;   // late reports of threads that never answered are dropped
    m_outstanding = 0;

    struct Row { QVariantMap map; QString group, folder, name; bool noResp; };
    QVector<Row> rows;
    for (const Entry &e : std::as_const(m_entries)) {
        if (e.state == 1) continue;
        Row r;
        r.noResp = (e.state == 0);
        r.folder = parentFolder(e.path);
        r.name = baseName(e.path);
        r.group = r.noResp ? QStringLiteral("Did not respond within 5 seconds") : r.folder;
        r.map["path"] = e.path;
        r.map["folder"] = r.folder;
        r.map["fileName"] = r.name;
        r.map["group"] = r.group;
        r.map["itemIds"] = QVariant(e.itemIds);
        r.map["clipCount"] = e.clipCount;
        r.map["size"] = e.size;
        r.map["notResponding"] = r.noResp;
        rows << r;
    }
    std::sort(rows.begin(), rows.end(), [](const Row &a, const Row &b) {
        if (a.noResp != b.noResp) return !a.noResp;
        if (a.folder != b.folder) return a.folder < b.folder;
        return a.name < b.name;
    });
    QVariantList list;
    for (const Row &r : std::as_const(rows)) list << r.map;

    m_missing = list;
    if (m_checking) { m_checking = false; emit checkingChanged(); }
    emit missingChanged();
    qDebug() << "MediaAvailability: check finished," << m_missing.size() << "of"
             << m_entries.size() << "path(s) missing or not responding";
    emit checkFinished();
}

void MediaAvailability::searchFolder(const QString &folder, const QVariantList &missingEntries)
{
    cancelSearch();
    QVector<SearchItem> items;
    QSet<QString> seen;
    for (const QVariant &v : missingEntries) {
        const QVariantMap m = v.toMap();
        SearchItem it;
        it.path = MediaPaths::toLocalPath(m.value("path").toString());
        it.size = m.value("size", -1).toLongLong();
        if (it.path.isEmpty() || seen.contains(it.path)) continue;
        seen.insert(it.path);
        items << it;
    }
    const QString dir = MediaPaths::toLocalPath(folder);
    const quint64 gen = ++m_searchGeneration;
    auto cancel = std::make_shared<std::atomic<bool>>(false);
    m_searchCancel = cancel;
    m_searching = true;
    emit searchingChanged();

    QPointer<MediaAvailability> self(this);
    std::thread([self, gen, cancel, dir, items]() {
        auto progress = [&](int n) {
            if (!self || cancel->load()) return;
            QMetaObject::invokeMethod(self.data(), [self, gen, n]() {
                if (self && gen == self->m_searchGeneration) emit self->searchProgress(n);
            }, Qt::QueuedConnection);
        };
        const SearchResult r = runSearch(dir, items, *cancel, progress);
        if (cancel->load() || !self) return;
        QMetaObject::invokeMethod(self.data(), [self, gen, r]() {
            if (!self || gen != self->m_searchGeneration) return;
            self->m_searching = false;
            emit self->searchingChanged();
            emit self->searchFinished(r.matches, r.ambiguous, r.notFound);
        }, Qt::QueuedConnection);
    }).detach();
}

void MediaAvailability::cancelSearch()
{
    if (m_searchCancel) m_searchCancel->store(true);
    m_searchCancel.reset();
    ++m_searchGeneration;
    if (m_searching) { m_searching = false; emit searchingChanged(); }
}
