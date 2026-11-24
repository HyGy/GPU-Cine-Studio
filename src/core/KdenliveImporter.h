#ifndef KDENLIVEIMPORTER_H
#define KDENLIVEIMPORTER_H

#include <QString>
#include <QVariantMap>

// One-shot, one-way translator: Kdenlive/MLT XML project -> GPU-Cine-Studio
// project JSON (the exact shapes ProjectBinModel::loadFromJson() and
// EditingWorkspace.loadProjectJSON() already consume). Deliberately NOT a
// QObject and has NO GES/GStreamer/QML dependency - plain Qt6::Core only
// (QXmlStreamReader, QJsonDocument, QDirIterator), so it can be unit-tested
// without a running app or display. BackendManager exposes thin
// Q_INVOKABLE wrappers around the three entry points below.
//
// Anything in a Kdenlive project that doesn't map onto a GPU-Cine-Studio
// feature that exists TODAY (pan/zoom, fades, color filters, chroma key,
// per-clip volume, luma-wipe transitions, keyframed params, ...) is never
// silently dropped: it is collected into an "unsupported" list carrying
// the verbatim Kdenlive XML/properties alongside the GCS clip it belongs
// to, so a LATER feature implementation can re-read the import report and
// apply itself to the already-imported (and by then possibly already
// re-edited) project, without re-importing and losing the user's work.
// See TODO.txt, "=== PLANNED: Kdenlive project import ===" for the full
// design rationale.
namespace KdenliveImporter {

// Cheap, side-effect-free read of a .kdenlive file for the import
// dialog's summary/media/unsupported-list pages. Never throws, never
// touches the filesystem beyond reading the given file and (for media
// resolution) checking candidate paths for existence. On any parse
// failure returns {"ok": false, "error": "..."}.
QVariantMap inspect(const QString &filePath, const QVariantMap &options);

// Full translation. Pure function of (file on disk, options) - does not
// create folders, does not touch QSettings, does not touch the live
// project bin/timeline. The caller (main.qml's commitKdenliveImport())
// commits the result via the EXACT SAME path a normal New Project /
// Open Project uses.
QVariantMap convert(const QString &filePath, const QVariantMap &options);

// Writes the import report sidecar (full "unsupported" list incl. raw
// Kdenlive data) to <projectDir>/.import/kdenlive-import-report.json.
// Separated from convert() so convert() stays side-effect-free.
bool writeReport(const QString &projectDir, const QVariantMap &report);

} // namespace KdenliveImporter

#endif // KDENLIVEIMPORTER_H
