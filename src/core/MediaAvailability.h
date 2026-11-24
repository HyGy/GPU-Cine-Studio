#ifndef MEDIAAVAILABILITY_H
#define MEDIAAVAILABILITY_H

#include <QObject>
#include <QPointer>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>
#include <atomic>
#include <memory>

// Path helpers shared by the project bin, the timeline engine and the
// missing-media check.
namespace MediaPaths {
// "file://" URI -> plain local path (percent-decoded); a path that was never a
// URL comes back byte-identical.
QString toLocalPath(const QString &path);
// Mount point containing `path`, from /proc/self/mounts (longest prefix). A
// plain file read: QStorageInfo::mountedVolumes() statfs()es every mount and
// would hang on the very drive that is dead.
QString mountRootFor(const QString &path);
QStringList readMountPoints();
QString mountRootIn(const QStringList &mounts, const QString &path);
}

// Finds out which source files of the open project are not on disk, and
// searches a user-picked folder for them. Every filesystem access happens on
// detached std::threads (one per mount point, so a dead drive cannot delay the
// answer for the others); the GUI thread only collects results. No
// QtConcurrent / QThreadPool on purpose: their worker threads are joined at
// exit and would hang the app on an unresponsive drive.
class MediaAvailability : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool checking READ checking NOTIFY checkingChanged)
    Q_PROPERTY(int missingCount READ missingCount NOTIFY missingChanged)
    // [{path, folder, fileName, group, itemIds, clipCount, size, notResponding}]
    // sorted by group (responding folders first), then folder, then name.
    Q_PROPERTY(QVariantList missing READ missing NOTIFY missingChanged)
    Q_PROPERTY(bool searching READ searching NOTIFY searchingChanged)

public:
    explicit MediaAvailability(QObject *parent = nullptr);

    bool checking() const { return m_checking; }
    int missingCount() const { return m_missing.size(); }
    QVariantList missing() const { return m_missing; }
    bool searching() const { return m_searching; }

    // entries: [{path, itemIds:[...], size (-1 unknown), clipCount}]
    Q_INVOKABLE void check(const QVariantList &entries);
    // Plain local path for a plain path or a (percent-encoded) file:// URL.
    Q_INVOKABLE QString localPath(const QString &path) const { return MediaPaths::toLocalPath(path); }
    // Asks the main window to show the Missing media dialog (the Project Bin
    // chip and the File menu use this).
    Q_INVOKABLE void requestDialog() { emit dialogRequested(); }
    // Forget everything (new project / project closed).
    Q_INVOKABLE void reset();

    // Searches `folder` for the files in `missingEntries` ([{path, size}]).
    Q_INVOKABLE void searchFolder(const QString &folder, const QVariantList &missingEntries);
    Q_INVOKABLE void cancelSearch();

signals:
    void checkingChanged();
    void missingChanged();
    void searchingChanged();
    void checkFinished();
    void dialogRequested();
    void searchProgress(int scanned);
    // matches: [{oldPath, newPath, byName}], ambiguous: [{path, candidates:[...]}],
    // notFound: [path]. All paths are plain local paths.
    void searchFinished(const QVariantList &matches, const QVariantList &ambiguous,
                        const QVariantList &notFound);

private:
    struct Entry {
        QString path;
        QStringList itemIds;
        qint64 size = -1;
        int clipCount = 0;
        int state = 0;   // 0 unknown (no answer yet), 1 exists, 2 missing
    };
    void onPathsChecked(quint64 generation, const QVector<int> &indices, const QVector<int> &exists);
    void finishCheck();

    QVector<Entry> m_entries;
    quint64 m_generation = 0;
    int m_outstanding = 0;     // worker threads that have not reported yet
    bool m_checking = false;
    QVariantList m_missing;
    QTimer m_timeout;

    quint64 m_searchGeneration = 0;
    bool m_searching = false;
    std::shared_ptr<std::atomic<bool>> m_searchCancel;
};

#endif
