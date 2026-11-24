#include "KdenliveImporter.h"

#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QDirIterator>
#include <QXmlStreamReader>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QJsonValue>
#include <QDateTime>
#include <QDebug>
#include <QVector>
#include <QHash>
#include <QSet>
#include <algorithm>
#include <cmath>
#include <functional>

namespace KdenliveImporter {
namespace {

// ===================== XML tree (pass 1) =====================

// <property name="X">text</property> children are flattened into `props`
// (they're the overwhelming majority of Kdenlive's actual data); every
// other child element is kept structurally in `children`. Pointers taken
// into this tree after parsing are stable for the tree's lifetime - it is
// never copied or resized after readNode() returns.
struct KdlNode {
    QString tag;
    QMap<QString, QString> attrs;
    QMap<QString, QString> props;
    QVector<KdlNode> children;
};

KdlNode readNode(QXmlStreamReader &xml, int depth)
{
    KdlNode node;
    node.tag = xml.name().toString();
    const auto attrs = xml.attributes();
    for (const auto &a : attrs) node.attrs.insert(a.name().toString(), a.value().toString());

    if (depth > 64) { xml.raiseError("document too deeply nested"); return node; }

    while (!xml.atEnd() && !xml.hasError()) {
        QXmlStreamReader::TokenType tok = xml.readNext();
        if (tok == QXmlStreamReader::EndElement) break;
        if (tok == QXmlStreamReader::StartElement) {
            QString childTag = xml.name().toString();
            if (childTag == QLatin1String("property")) {
                QString pname = xml.attributes().value("name").toString();
                QString ptext = xml.readElementText(QXmlStreamReader::SkipChildElements);
                node.props.insert(pname, ptext);
            } else {
                node.children.append(readNode(xml, depth + 1));
            }
        }
    }
    return node;
}

// Re-serializes a parsed node back to XML text, for the "raw.xml" field
// attached to unsupported-feature entries - computed on demand from the
// already-parsed KdlNode rather than captured during streaming, which
// keeps the parser itself simple and this independently correct.
QString serializeNode(const KdlNode &node)
{
    QString out = "<" + node.tag;
    for (auto it = node.attrs.constBegin(); it != node.attrs.constEnd(); ++it)
        out += " " + it.key() + "=\"" + it.value().toHtmlEscaped() + "\"";
    if (node.props.isEmpty() && node.children.isEmpty()) return out + "/>";
    out += ">";
    for (auto it = node.props.constBegin(); it != node.props.constEnd(); ++it)
        out += "<property name=\"" + it.key().toHtmlEscaped() + "\">" + it.value().toHtmlEscaped() + "</property>";
    for (const KdlNode &c : node.children) out += serializeNode(c);
    out += "</" + node.tag + ">";
    return out;
}

struct KdlDoc {
    KdlNode root; // <mlt>
    QString mltRoot;
    int fpsNum = 0, fpsDen = 1;
    int width = 0, height = 0;
    QHash<QString, const KdlNode *> byId;
    QHash<QString, QVector<const KdlNode *>> producersByKdenliveId;
    const KdlNode *mainBin = nullptr;
    QVector<const KdlNode *> sequenceTractors;
    QString activeSequenceUuid;
};

void indexNode(const KdlNode &node, KdlDoc &doc)
{
    QString id = node.attrs.value("id");
    if (!id.isEmpty()) doc.byId.insert(id, &node);
    if (node.tag == QLatin1String("chain") || node.tag == QLatin1String("producer")) {
        QString kid = node.props.value("kdenlive:id");
        if (!kid.isEmpty()) doc.producersByKdenliveId[kid].append(&node);
    }
    if (node.tag == QLatin1String("playlist") && id == QLatin1String("main_bin")) doc.mainBin = &node;
    if (node.tag == QLatin1String("tractor") && !node.props.value("kdenlive:uuid").isEmpty())
        doc.sequenceTractors.append(&node);
    for (const KdlNode &c : node.children) indexNode(c, doc);
}

bool parseXml(const QString &filePath, KdlDoc &doc, QString &error)
{
    QFile f(filePath);
    if (!f.open(QIODevice::ReadOnly)) {
        error = "Cannot open file: " + f.errorString();
        return false;
    }
    QXmlStreamReader xml(&f);
    bool found = false;
    while (!xml.atEnd() && !xml.hasError()) {
        xml.readNext();
        if (xml.isStartElement() && xml.name() == QLatin1String("mlt")) {
            doc.root = readNode(xml, 0);
            found = true;
            break;
        }
    }
    if (xml.hasError()) { error = "XML parse error: " + xml.errorString(); return false; }
    if (!found || doc.root.tag != QLatin1String("mlt")) {
        error = "Not a valid MLT/Kdenlive file (no <mlt> root element found)";
        return false;
    }
    doc.mltRoot = doc.root.attrs.value("root");
    indexNode(doc.root, doc);
    for (const KdlNode &c : doc.root.children) {
        if (c.tag == QLatin1String("profile")) {
            doc.width = c.attrs.value("width").toInt();
            doc.height = c.attrs.value("height").toInt();
            doc.fpsNum = c.attrs.value("frame_rate_num").toInt();
            doc.fpsDen = c.attrs.value("frame_rate_den").toInt();
            if (doc.fpsDen <= 0) doc.fpsDen = 1;
            break;
        }
    }
    if (doc.mainBin)
        doc.activeSequenceUuid = doc.mainBin->props.value("kdenlive:docproperties.activetimeline");
    if (doc.fpsNum <= 0) { error = "Could not read project frame rate from <profile>"; return false; }
    return true;
}

// ===================== frame/time arithmetic =====================

// Accepts both MLT encodings seen in real files: "hh:mm:ss.mmm" clock
// strings (used for <entry in/out>, <blank length>, <transition in/out>
// in the real test file) and bare frame-count integers. llround(), not
// truncation: the clock strings are millisecond-truncated, so at
// 24000/1001 (~41.7ms/frame) naive truncation would accumulate a full
// frame of drift roughly every 24 clips.
qint64 framesFromClockOrFrames(const QString &s, int fpsNum, int fpsDen)
{
    if (s.isEmpty()) return 0;
    if (s.contains(QLatin1Char(':'))) {
        QStringList parts = s.split(QLatin1Char(':'));
        if (parts.size() != 3) return 0;
        double totalSec = parts[0].toDouble() * 3600.0 + parts[1].toDouble() * 60.0 + parts[2].toDouble();
        return qint64(llround(totalSec * fpsNum / double(fpsDen)));
    }
    bool ok = false;
    qint64 v = s.toLongLong(&ok);
    return ok ? v : 0;
}

// MLT's `out` is INCLUSIVE - off-by-one here accumulates visible drift
// across dozens of clips. `<blank length>` is a plain count and does NOT
// get this +1 (handled by the caller using framesFromClockOrFrames()
// directly for blanks, never this function).
qint64 clipDurationFrames(qint64 inFrame, qint64 outFrame) { return outFrame - inFrame + 1; }

struct FpsMapping { QString label; bool mapped; };

// TimelineEngine::createPipeline() (src/core/TimelineEngine.cpp:971-979)
// matches project/fps by SUBSTRING, not by parsing - it is checked in
// this exact order with no "30" branch (bare "30" is the unconditional
// fallback), so the label returned here must be one of exactly these
// seven strings (or "30", used when nothing matches) for the project to
// actually play back at the right rate.
FpsMapping mapFpsToProjectSetting(int num, int den)
{
    struct Entry { int n, d; const char *label; };
    static const Entry table[] = {
        {24000, 1001, "23.98"}, {30000, 1001, "29.97"}, {60000, 1001, "59.94"},
        {24, 1, "24"}, {25, 1, "25"}, {50, 1, "50"}, {60, 1, "60"},
    };
    for (const auto &e : table)
        if (e.n == num && e.d == den) return { QString::fromLatin1(e.label), true };

    // Not an exact rational match - fall back to the nearest table entry
    // by real-valued fps, but flag it: TimelineEngine's substring match
    // means anything not EXACTLY one of these seven labels (e.g. a
    // literal "23.976") silently plays back at 30fps, which is worse
    // than an honest "we picked the nearest preset" report entry.
    double target = double(num) / double(den ? den : 1);
    const Entry *best = &table[0];
    double bestDelta = 1e9;
    for (const auto &e : table) {
        double d = std::abs(double(e.n) / e.d - target);
        if (d < bestDelta) { bestDelta = d; best = &e; }
    }
    return { QString::fromLatin1(best->label), false };
}

// ===================== resolved model =====================

struct UnsupportedEntry {
    QString code, category, severity, title, detail;
    QString trackId, clipId, binItemId;
    double timelineStart = 0, durationSeconds = 0;
    QVariantMap rawProperties;
    QString rawXml, rawTag;
};

struct KdlBinItem {
    QString kdenliveId, gcsItemId, name, folderId;
    QString originalUrl, proxyUrl, resourceRaw, mltService;
    QString resolvedPath, resolution; // original|rescued|missing (Kdenlive proxies are never used - see resolveMediaPaths())
    bool hasVideoStream = false, hasAudioStream = false;
    bool isGenerator = false, isSequence = false, usedOnTimeline = false;
    // Source pixel dimensions (meta.media.width/height) - needed to
    // aspect-correct a pan_zoom/affine rect: MLT preserves the source's
    // own aspect ratio inside the rect (fill=1,distort=0), GES's frame
    // positioner always stretches to fill it exactly, so a rect whose
    // aspect differs from the source needs the importer to pre-shrink it
    // to the aspect-correct inner rect before handing it to "transform".
    int srcWidth = 0, srcHeight = 0;
};

struct KdlFolder { QString id, name, parentId; };

struct KdlPlacement {
    qint64 startFrame = 0, inFrame = 0, outFrame = 0, durFrame = 0;
    QString kdenliveId;
    const KdlNode *entry = nullptr;
    QString gcsClipId;
    int trackListIndex = -1; // index into the filtered track list (for AVSplit lookup)
};

struct KdlTrack {
    QString tractorId, name, gcsTrackId;
    bool isAudio = false, active = true;
    QVector<QString> playlistIds;
    QVector<KdlPlacement> clips;
    const KdlNode *tractorNode = nullptr;
};

struct KdlTransitionAnno {
    int trackIdx = 0, aIdx = 0, bIdx = 0;
    qint64 overlapFrames = 0;
    // A GES transition-type NICK (e.g. "crossfade", "clock-cw12") - NOT a
    // generic "dissolve" label - set by gesWipeNickForLumaResource() in
    // detectAndAnnotateTransitions() below. Defaults to "crossfade" (GES's
    // own default/the audio-side value) rather than "dissolve": GES has no
    // "dissolve" transition type, crossfade IS what a dissolve actually is.
    QString gcsType = "crossfade";
    bool wipe = false, asymmetric = false;
    QString wipeResource;
    // kdenlive:mixcut is measured BACKWARDS from the END of the overlap
    // (verified against Kdenlive's own trackmodel.cpp/clipmodel.cpp - see
    // detectAndAnnotateTransitions()) - cutOffsetFrames is that same value
    // re-expressed as a FORWARD offset from the overlap's start, which is
    // what every consumer in this codebase actually wants.
    qint64 mixcutFrames = -1;    // raw kdenlive:mixcut, -1 = property absent
    qint64 mixDurFrames = -1;    // the <transition> element's own out-in
    qint64 cutOffsetFrames = -1; // overlap - clamp(mixcut, 0, overlap); -1 = unknown
    bool lumaUnmapped = false;   // resource present but not in the luma table
};

struct KdlLinkPair { QString videoClipId, audioClipId, linkGroupId; };

struct KdlModel {
    bool ok = false;
    QString error;
    QString kdenliveVersion, mltRoot;
    // clipId -> array of applied ClipEffects JSON objects (id/type/enabled/
    // params), for the small subset of Kdenlive filters we can actually
    // translate (currently: frei0r.select0r -> our "colorkey" effect).
    // Everything else stays report-only in `unsupported`.
    QHash<QString, QJsonArray> appliedEffectsByClip;
    int appliedEffectCounter = 0;
    int width = 0, height = 0, fpsNum = 0, fpsDen = 1;
    QString fpsLabel; bool fpsMapped = true;
    QVector<KdlFolder> folders;
    QVector<KdlBinItem> binItems; // keyed by kdenliveId, dedup'd
    QHash<QString, int> binItemIndexByKdenliveId;
    // Kdenlive ids that resolved to a bin item we intentionally never
    // create (currently: color-generator clips, see buildBinItems()) -
    // distinct from "missing media", which DOES get a binItems entry
    // (just an unresolved path). Used by emitEditingJson() to catch any
    // timeline placement referencing one of these BEFORE it becomes a
    // pathless ghost clip.
    QSet<QString> generatorKdenliveIds;
    QVector<KdlTrack> tracks; // in emission order (Vn..V1, A1..Am)
    QVector<KdlTransitionAnno> transitions;
    QVector<KdlLinkPair> links;
    QVector<UnsupportedEntry> unsupported;
    QString activeSequenceId, activeSequenceName;
    int sequenceCount = 0, sequencesSkipped = 0, gapsConsumed = 0;
};

// ===================== pass 2: resolve =====================

bool isPlumbingFilter(const KdlNode &f, const QString &parentTag)
{
    if (!f.props.value("internal_added").isEmpty()) return true;
    if (parentTag == QLatin1String("tractor")) return true;
    QString svc = f.props.value("mlt_service");
    if ((svc == QLatin1String("volume") || svc == QLatin1String("panner") || svc == QLatin1String("audiolevel"))
        && parentTag != QLatin1String("entry")) return true;
    return false;
}

bool isPlumbingTransition(const KdlNode &t)
{
    if (!t.props.value("internal_added").isEmpty()) return true;
    QString svc = t.props.value("mlt_service");
    return svc == QLatin1String("mix") || svc == QLatin1String("qtblend") || svc == QLatin1String("frei0r.cairoblend");
}

QString absolutizePath(const QString &p, const QString &mltRoot)
{
    if (p.isEmpty()) return p;
    QFileInfo fi(p);
    if (fi.isAbsolute()) return p;
    return QDir(mltRoot).filePath(p);
}

QString applyRelinkMap(const QString &path, const QVariantMap &relinkMap)
{
    if (relinkMap.isEmpty()) return path;
    QStringList keys = relinkMap.keys();
    std::sort(keys.begin(), keys.end(), [](const QString &a, const QString &b) { return a.size() > b.size(); });
    for (const QString &k : keys)
        if (path.startsWith(k)) return relinkMap.value(k).toString() + path.mid(k.size());
    return path;
}

void buildBinFolders(const KdlDoc &doc, KdlModel &model)
{
    if (!doc.mainBin) return;
    for (auto it = doc.mainBin->props.constBegin(); it != doc.mainBin->props.constEnd(); ++it) {
        if (!it.key().startsWith(QLatin1String("kdenlive:folder."))) continue;
        QStringList parts = it.key().split(QLatin1Char('.'));
        if (parts.size() != 3) continue;
        KdlFolder folder;
        folder.parentId = parts[1];
        folder.id = parts[2];
        folder.name = it.value();
        model.folders.append(folder);
    }
}

void buildBinItems(const KdlDoc &doc, KdlModel &model)
{
    if (!doc.mainBin) return;
    for (const KdlNode &entry : doc.mainBin->children) {
        if (entry.tag != QLatin1String("entry")) continue;
        QString producerId = entry.attrs.value("producer");
        const KdlNode *prod = doc.byId.value(producerId, nullptr);
        if (!prod) continue;
        if (prod->tag == QLatin1String("tractor")) {
            // Every sequence (every tractor with a kdenlive:uuid, incl.
            // the one we're ACTIVELY importing) also lists itself as a
            // plain bin entry - this is just that listing, not a
            // separate "found an extra sequence" signal, so it must NOT
            // touch model.sequencesSkipped: that count is already fully
            // derived once, from doc.sequenceTractors.size()-1 (see
            // runConversion(), set before buildBinItems() runs this
            // loop). Incrementing it again here used to DOUBLE-count
            // every real extra sequence (it has both a sequenceTractors
            // entry AND a main_bin entry) - and, in the common case of
            // exactly ONE sequence in the project, falsely counted that
            // single sequence's own bin-listing entry as if it were a
            // second, unimported sequence (reporting "1 other
            // sequence(s)" when there were none). Just skip adding a
            // normal binItem for it - nothing else to do here.
            continue;
        }
        QString kid = prod->props.value("kdenlive:id");
        if (kid.isEmpty()) continue;
        if (model.binItemIndexByKdenliveId.contains(kid)) continue; // dedupe

        QString mltService = prod->props.value("mlt_service");
        KdlBinItem item;
        item.kdenliveId = kid;
        item.gcsItemId = "item_kdl_" + kid;
        item.name = prod->props.value("kdenlive:clipname");
        if (item.name.isEmpty()) {
            // `resource` on a Kdenlive-proxied clip's bin producer is the
            // PROXY file (one of Kdenlive's own hash-named cache files
            // under kdenlive/proxy/, e.g. "8b131bf...mpg" - not anything
            // a user would recognize), while kdenlive:originalurl always
            // holds the real source path regardless of whether a Kdenlive
            // proxy is active. Prefer that for the fallback name; only
            // fall back to resource's basename when originalurl is also
            // empty (a genuinely non-proxied clip, where resource IS the
            // real media - see resolveMediaPaths() below for the same
            // distinction applied to path resolution).
            QString originalUrl = prod->props.value("kdenlive:originalurl");
            item.name = QFileInfo(!originalUrl.isEmpty() ? originalUrl
                                                            : prod->props.value("resource")).fileName();
        }
        item.folderId = prod->props.value("kdenlive:folderid");
        item.originalUrl = prod->props.value("kdenlive:originalurl");
        item.proxyUrl = prod->props.value("kdenlive:proxy");
        item.resourceRaw = prod->props.value("resource");
        item.mltService = mltService;
        item.srcWidth = prod->props.value("meta.media.width").toInt();
        item.srcHeight = prod->props.value("meta.media.height").toInt();
        item.hasVideoStream = prod->props.value("video_index", "0") != QLatin1String("-1");
        item.hasAudioStream = prod->props.value("audio_index", "0") != QLatin1String("-1");
        item.isGenerator = (mltService == QLatin1String("color"));
        if (item.isGenerator) {
            // No binItems entry is created for this kid (the `continue`
            // below) - record it here so emitEditingJson() can recognize
            // ANY timeline placement referencing it and skip that
            // placement cleanly, instead of it falling through to
            // binItemIndexByKdenliveId.value(..., -1) and getting placed
            // as a pathless ghost clip with no media behind it at all.
            model.generatorKdenliveIds.insert(kid);
            UnsupportedEntry u;
            u.code = "bin.generator_skipped"; u.category = "media"; u.severity = "info";
            u.title = "Color generator clip skipped";
            u.detail = item.name.isEmpty() ? QStringLiteral("generator clip") : item.name;
            u.binItemId = ""; u.rawTag = prod->tag; u.rawXml = serializeNode(*prod);
            model.unsupported.append(u);
            continue;
        }
        if (item.proxyUrl.isEmpty() && !item.originalUrl.isEmpty() && item.originalUrl != item.resourceRaw) {
            // Non-proxied clip whose resource already differs from
            // originalurl for other reasons - treat resource as the
            // thing to resolve normally; originalUrl stays as a hint.
        }
        model.binItemIndexByKdenliveId.insert(kid, model.binItems.size());
        model.binItems.append(item);
    }
}

void resolveMediaPaths(const QString &mltRoot, const QVariantMap &options, KdlModel &model)
{
    QVariantMap relinkMap = options.value("relinkMap").toMap();
    QStringList searchRoots;
    for (const QVariant &v : options.value("searchRoots").toList()) searchRoots << v.toString();
    if (searchRoots.isEmpty() && !mltRoot.isEmpty()) searchRoots << mltRoot;

    // Lazily-built basename -> candidate absolute paths index, shared
    // across all bin items that need rescue.
    QHash<QString, QStringList> basenameIndex;
    bool basenameIndexBuilt = false;
    auto buildBasenameIndex = [&]() {
        if (basenameIndexBuilt) return;
        basenameIndexBuilt = true;
        int cap = 200000;
        for (const QString &root : searchRoots) {
            QDirIterator it(root, QDir::Files, QDirIterator::Subdirectories);
            while (it.hasNext() && cap-- > 0) {
                QString p = it.next();
                basenameIndex[QFileInfo(p).fileName()].append(p);
            }
        }
    };

    for (KdlBinItem &item : model.binItems) {
        QString original = applyRelinkMap(absolutizePath(item.originalUrl, mltRoot), relinkMap);
        bool hasProxy = !item.proxyUrl.isEmpty();

        // Kdenlive's own proxies are NEVER used as playable media, even
        // if they're the only thing that currently exists on disk -
        // they're a lower-resolution stand-in Kdenlive generated for
        // ITS OWN editing performance, in a format/profile this app
        // doesn't control. Using one transparently would mean the
        // imported project silently plays a degraded substitute with
        // no indication, and (per a real, measured problem with one
        // such proxy format - see TODO.txt's mpegpsdemux dead-zone
        // notes) can carry format-specific seeking issues that have
        // nothing to do with the actual source footage. If/when this
        // app generates its OWN proxies, that's a deliberate, visible,
        // user-controlled feature - not an implicit fallback here. An
        // item whose original media isn't available is treated as
        // "missing" even if its Kdenlive proxy is sitting right there.
        bool resolved = false;
        if (!original.isEmpty() && QFileInfo::exists(original)) {
            item.resolvedPath = original; item.resolution = "original"; resolved = true;
        }
        if (!resolved && !hasProxy) {
            // Plain (non-proxied) clip: `resource` IS the real media.
            QString res = applyRelinkMap(absolutizePath(item.resourceRaw, mltRoot), relinkMap);
            if (!res.isEmpty() && QFileInfo::exists(res)) {
                item.resolvedPath = res; item.resolution = "original"; resolved = true;
            }
        }
        if (!resolved) {
            buildBasenameIndex();
            QString base = QFileInfo(!item.originalUrl.isEmpty() ? item.originalUrl : item.resourceRaw).fileName();
            QStringList candidates = basenameIndex.value(base);
            if (candidates.size() == 1) {
                item.resolvedPath = candidates.first(); item.resolution = "rescued"; resolved = true;
            }
        }
        if (!resolved) {
            // Deliberately never falls back to the proxy path here -
            // see the comment above. resolvedPath stays the real
            // original path (even though it doesn't currently exist)
            // so a later-reappearing original file resolves
            // automatically, same as any other missing item.
            item.resolvedPath = original;
            item.resolution = "missing";
        }
    }
}

const KdlNode *findTractorTrackContainer(const KdlDoc &doc, const QString &uuid)
{
    for (const KdlNode *t : doc.sequenceTractors)
        if (t->props.value("kdenlive:uuid") == uuid) return t;
    return nullptr;
}

void buildTracks(const KdlDoc &doc, const KdlNode &seqTractor, KdlModel &model)
{
    QVector<const KdlNode *> videoTractors, audioTractors;
    for (const KdlNode &trackRef : seqTractor.children) {
        if (trackRef.tag != QLatin1String("track")) continue;
        const KdlNode *producer = doc.byId.value(trackRef.attrs.value("producer"), nullptr);
        if (!producer || producer->tag != QLatin1String("tractor")) continue; // drops bg/preview tracks
        bool isAudio = producer->props.value("kdenlive:audio_track") == QLatin1String("1");
        (isAudio ? audioTractors : videoTractors).append(producer);
    }
    std::reverse(audioTractors.begin(), audioTractors.end());

    QVector<const KdlNode *> ordered;
    QVector<QString> ids;
    for (int i = 0; i < videoTractors.size(); ++i) { ordered << videoTractors[i]; ids << QString("V%1").arg(i + 1); }
    for (int i = 0; i < audioTractors.size(); ++i) { ordered << audioTractors[i]; ids << QString("A%1").arg(i + 1); }

    for (int i = 0; i < ordered.size(); ++i) {
        const KdlNode *tr = ordered[i];
        KdlTrack track;
        track.tractorId = tr->attrs.value("id");
        track.gcsTrackId = ids[i];
        track.isAudio = tr->props.value("kdenlive:audio_track") == QLatin1String("1");
        track.name = tr->props.value("kdenlive:track_name");
        track.active = tr->props.value("kdenlive:timeline_active", "1") != QLatin1String("0");
        track.tractorNode = tr;
        for (const KdlNode &c : tr->children)
            if (c.tag == QLatin1String("track")) track.playlistIds.append(c.attrs.value("producer"));
        model.tracks.append(track);
    }
}

void flattenPlaylists(const KdlDoc &doc, KdlModel &model, int fpsNum, int fpsDen)
{
    for (int ti = 0; ti < model.tracks.size(); ++ti) {
        KdlTrack &track = model.tracks[ti];
        QVector<KdlPlacement> combined;
        for (const QString &plId : track.playlistIds) {
            const KdlNode *pl = doc.byId.value(plId, nullptr);
            if (!pl) continue;
            qint64 cursor = 0;
            for (const KdlNode &child : pl->children) {
                if (child.tag == QLatin1String("blank")) {
                    cursor += framesFromClockOrFrames(child.attrs.value("length"), fpsNum, fpsDen);
                    model.gapsConsumed++;
                } else if (child.tag == QLatin1String("entry")) {
                    KdlPlacement p;
                    p.inFrame = framesFromClockOrFrames(child.attrs.value("in"), fpsNum, fpsDen);
                    p.outFrame = framesFromClockOrFrames(child.attrs.value("out"), fpsNum, fpsDen);
                    p.durFrame = clipDurationFrames(p.inFrame, p.outFrame);
                    p.startFrame = cursor;
                    p.entry = &child;
                    p.trackListIndex = ti;
                    QString kid = child.props.value("kdenlive:id");
                    if (kid.isEmpty()) {
                        const KdlNode *prod = doc.byId.value(child.attrs.value("producer"), nullptr);
                        if (prod) kid = prod->props.value("kdenlive:id");
                    }
                    p.kdenliveId = kid;
                    combined.append(p);
                    cursor += p.durFrame;
                }
            }
        }
        std::stable_sort(combined.begin(), combined.end(), [](const KdlPlacement &a, const KdlPlacement &b) {
            return a.startFrame < b.startFrame;
        });
        track.clips = combined;
    }
}

// MLT generates its 22 built-in wipe lumas ("luma01.pgm".."luma22.pgm")
// algorithmically (mlt_luma_map_new()) rather than shipping real image
// files - Kdenlive's <transition resource="..."> just names one of them.
// This table maps each to the closest real GES
// GESVideoStandardTransitionType nick, cross-verified from TWO
// independent sources: MLT's own mlt_luma_map.c (the {type,bands,
// mirror,...} generator params) and Shotcut's lumamixtransition.cpp
// (which has human-readable labels for the same 22 files, in the same
// order) - see TODO.txt or the import-fidelity session notes for the
// full derivation. `approximate=true` means no GES nick captures the
// same wipe SHAPE (only orientation/rough family) - still a real wipe,
// just not visually identical to Kdenlive's.
//
// Naming gotcha (deliberately NOT "corrected" below): Shotcut names barn
// doors by the axis of MOTION, GES by the axis of the SPLITTING LINE -
// GES's "barndoor-v" (a vertical center line, opening left/right) is
// Shotcut's horizontally-opening "Barn Door Horizontal". Verified via
// ges-enums.h's own doc comment on BARNDOOR_V.
struct LumaMapping { const char *luma; const char *nick; bool approximate; };
const LumaMapping kLumaMappings[] = {
    { "luma01", "bar-wipe-lr",       false },
    { "luma02", "bar-wipe-tb",       false },
    { "luma03", "barndoor-v",        false },
    { "luma04", "barndoor-h",        false },
    { "luma05", "barndoor-dbl",      false },
    { "luma06", "barndoor-dtl",      false },
    { "luma07", "diagonal-tl",       false },
    { "luma08", "diagonal-tr",       false },
    { "luma09", "bar-wipe-lr",       true  }, // Matrix Waterfall H - no GES analogue
    { "luma10", "bar-wipe-tb",       true  }, // Matrix Waterfall V - no GES analogue
    { "luma11", "bar-wipe-lr",       true  }, // Matrix Snake H - no GES analogue
    { "luma12", "bar-wipe-lr",       true  }, // Matrix Snake Parallel H - no GES analogue
    { "luma13", "bar-wipe-tb",       true  }, // Matrix Snake V - no GES analogue
    { "luma14", "bar-wipe-tb",       true  }, // Matrix Snake Parallel V - no GES analogue
    { "luma15", "barnvee-u",         false },
    { "luma16", "iris-rect",         true  }, // Iris Circle - GES has no round iris
    { "luma17", "four-box-wipe-ci",  true  }, // Double Iris - approximate
    { "luma18", "iris-rect",         false },
    { "luma19", "box-wipe-br",       false },
    { "luma20", "box-wipe-bl",       false },
    { "luma21", "box-wipe-rc",       false },
    { "luma22", "clock-cw12",        false },
};

// Normalizes a Kdenlive luma `resource` (bare name, "%"-prefixed
// MLT-relative name, or absolute path - all seen in the wild) and looks
// it up in kLumaMappings. Returns an empty nick (with `approximate` left
// untouched) when the resource isn't one of MLT's 22 built-ins - e.g. a
// user-supplied custom luma image - so the caller can fall back to a
// plain crossfade rather than guessing a wipe shape for an unknown
// pattern (a wrong wipe shape is a more confusing wrong answer than a
// dissolve).
QString gesWipeNickForLumaResource(const QString &resource, bool &approximate)
{
    approximate = false;
    QString base = QFileInfo(resource).fileName();
    if (base.startsWith('%')) base = base.mid(1);
    base = base.toLower();
    int dot = base.lastIndexOf('.');
    QString stem = dot > 0 ? base.left(dot) : base;
    for (const LumaMapping &m : kLumaMappings) {
        if (stem == QLatin1String(m.luma)) {
            approximate = m.approximate;
            return QString::fromLatin1(m.nick);
        }
    }
    return QString();
}

void detectAndAnnotateTransitions(const KdlDoc &doc, KdlModel &model, int fpsNum, int fpsDen)
{
    Q_UNUSED(doc)
    for (int ti = 0; ti < model.tracks.size(); ++ti) {
        KdlTrack &track = model.tracks[ti];
        // Gather this track's non-plumbing <transition> elements, sorted
        // by their own `in` frame, for positional pairing against the
        // geometric overlaps detected below (counts match in practice:
        // one <transition> per same-track mix).
        QVector<const KdlNode *> transitionNodes;
        for (const KdlNode &c : track.tractorNode->children) {
            if (c.tag == QLatin1String("transition") && !isPlumbingTransition(c))
                transitionNodes.append(&c);
        }
        std::sort(transitionNodes.begin(), transitionNodes.end(), [&](const KdlNode *a, const KdlNode *b) {
            return framesFromClockOrFrames(a->attrs.value("in"), fpsNum, fpsDen)
                 < framesFromClockOrFrames(b->attrs.value("in"), fpsNum, fpsDen);
        });

        int tIdx = 0;
        for (int i = 0; i + 1 < track.clips.size(); ++i) {
            const KdlPlacement &a = track.clips[i];
            const KdlPlacement &b = track.clips[i + 1];
            qint64 aEnd = a.startFrame + a.durFrame;
            qint64 overlap = aEnd - b.startFrame;
            if (overlap <= 0) continue;

            KdlTransitionAnno anno;
            anno.trackIdx = ti; anno.aIdx = i; anno.bIdx = i + 1;
            anno.overlapFrames = overlap;

            if (tIdx < transitionNodes.size()) {
                const KdlNode *tn = transitionNodes[tIdx++];
                QString svc = tn->props.value("mlt_service");
                QString resource = tn->props.value("resource");

                // The <transition> element's OWN in/out is the authority
                // for its duration (matches Kdenlive's own
                // get_length() - 1); the geometric overlap is derived
                // independently from clip placements and should agree -
                // when it doesn't, the positional pairing between
                // transitionNodes and track.clips has drifted (e.g. a
                // plumbing transition wasn't filtered), so drop the
                // wipe/mixcut annotation rather than mis-apply it to the
                // wrong clip pair.
                qint64 tIn = framesFromClockOrFrames(tn->attrs.value("in"), fpsNum, fpsDen);
                qint64 tOut = framesFromClockOrFrames(tn->attrs.value("out"), fpsNum, fpsDen);
                anno.mixDurFrames = tOut - tIn;
                bool durationsAgree = std::abs(anno.mixDurFrames - overlap) <= 1;

                if (durationsAgree) {
                    if (svc == QLatin1String("luma") && !resource.isEmpty()) {
                        anno.wipe = true; anno.wipeResource = resource;
                        bool approximate = false;
                        QString nick = gesWipeNickForLumaResource(resource, approximate);
                        if (!nick.isEmpty()) {
                            anno.gcsType = nick;
                        } else {
                            anno.lumaUnmapped = true; // stays "crossfade" (O2: safe fallback)
                        }
                    }
                    QString mixcutStr = tn->props.value("kdenlive:mixcut");
                    if (!mixcutStr.isEmpty()) {
                        // kdenlive:mixcut is measured BACKWARDS from the
                        // END of the overlap (verified against Kdenlive's
                        // trackmodel.cpp: mixCutPos = min(mixcut,
                        // mixDuration); clipmodel.cpp: m_mixCutPos =
                        // cutOffset) - re-express as a FORWARD offset from
                        // the overlap's start, clamped the same way
                        // Kdenlive clamps it.
                        qint64 mixcut = qBound<qint64>(0, mixcutStr.toLongLong(), overlap);
                        anno.mixcutFrames = mixcut;
                        anno.cutOffsetFrames = overlap - mixcut;
                        if (std::abs(double(anno.cutOffsetFrames) - overlap / 2.0) > 1.0) anno.asymmetric = true;
                    }
                } else {
                    qWarning() << "KdenliveImporter: transition duration mismatch (element:"
                               << anno.mixDurFrames << "vs geometric overlap:" << overlap
                               << ") - dropping wipe/mixcut annotation for this pair";
                }
            }
            model.transitions.append(anno);
        }
    }
}

void buildLinkGroups(const KdlDoc &doc, const KdlNode &seqTractor, KdlModel &model,
                      QHash<QString, QString> &clipIdByTrackIdxAndFrame)
{
    QString groupsJson = seqTractor.props.value("kdenlive:sequenceproperties.groups");
    QSet<QString> linkedClipIds;
    int linkCounter = 0;

    if (!groupsJson.isEmpty()) {
        QJsonParseError perr;
        QJsonDocument gdoc = QJsonDocument::fromJson(groupsJson.toUtf8(), &perr);
        if (perr.error == QJsonParseError::NoError && gdoc.isArray()) {
            for (const QJsonValue &gv : gdoc.array()) {
                QJsonObject g = gv.toObject();
                if (g.value("type").toString() != QLatin1String("AVSplit")) continue;
                QJsonArray leaves = g.value("children").toArray();
                if (leaves.size() != 2) continue;
                QStringList clipIds;
                for (const QJsonValue &lv : leaves) {
                    QString data = lv.toObject().value("data").toString();
                    QStringList parts = data.split(':');
                    if (parts.size() < 2) continue;
                    QString key = parts[0] + ":" + parts[1];
                    QString cid = clipIdByTrackIdxAndFrame.value(key);
                    if (!cid.isEmpty()) clipIds << cid;
                }
                if (clipIds.size() != 2) continue;
                KdlLinkPair pair;
                pair.videoClipId = clipIds[0];
                pair.audioClipId = clipIds[1];
                pair.linkGroupId = QString("link_kdl_%1").arg(linkCounter++);
                model.links.append(pair);
                linkedClipIds << clipIds[0] << clipIds[1];
            }
        }
    }

    // Heuristic fallback for anything the groups blob didn't cover:
    // same kdenlive:id + same startFrame + same inFrame across a video
    // and an audio track.
    struct Key { QString kid; qint64 start, in; };
    QVector<QPair<Key, QString>> videoCandidates, audioCandidates;
    for (const KdlTrack &track : model.tracks) {
        for (const KdlPlacement &p : track.clips) {
            if (linkedClipIds.contains(p.gcsClipId) || p.kdenliveId.isEmpty()) continue;
            Key k { p.kdenliveId, p.startFrame, p.inFrame };
            (track.isAudio ? audioCandidates : videoCandidates).append({ k, p.gcsClipId });
        }
    }
    for (const auto &vc : videoCandidates) {
        for (const auto &ac : audioCandidates) {
            if (vc.first.kid == ac.first.kid && vc.first.start == ac.first.start && vc.first.in == ac.first.in) {
                if (linkedClipIds.contains(vc.second) || linkedClipIds.contains(ac.second)) continue;
                KdlLinkPair pair;
                pair.videoClipId = vc.second; pair.audioClipId = ac.second;
                pair.linkGroupId = QString("link_kdl_%1").arg(linkCounter++);
                model.links.append(pair);
                linkedClipIds << vc.second << ac.second;
            }
        }
    }
    Q_UNUSED(doc)
}

bool isKeyframedValue(const QString &v) { return v.contains(';') && v.contains('='); }

// MLT animated-property values are written as "<time>=<value>" even for a
// single, non-animated point (e.g. "00:00:00.000=0x000000ff") - strip
// that prefix when present so callers that only care about a static
// value don't have to special-case it.
QString stripLeadingKeyframeTime(const QString &v)
{
    int eq = v.indexOf('=');
    if (eq > 0 && v.left(eq).contains(':')) return v.mid(eq + 1);
    return v;
}

// "0x000000ff" (frei0r's RRGGBBAA hex, as written by Kdenlive's select0r
// "Color to select" property) -> {r,g,b} 0-255. Returns false (leaving
// out unset) if the string doesn't parse as an 8-hex-digit color.
bool parseHexRgba(const QString &raw, int &r, int &g, int &b)
{
    QString s = stripLeadingKeyframeTime(raw).trimmed();
    if (s.startsWith("0x", Qt::CaseInsensitive)) s = s.mid(2);
    if (s.size() < 6) return false;
    bool ok1 = false, ok2 = false, ok3 = false;
    r = s.mid(0, 2).toInt(&ok1, 16);
    g = s.mid(2, 2).toInt(&ok2, 16);
    b = s.mid(4, 2).toInt(&ok3, 16);
    return ok1 && ok2 && ok3;
}

// First segment of a possibly-keyframed MLT animated value, with its
// leading "<time>=" stripped - i.e. "the value at its first keyframe"
// for both animated ("t0=v0;t1=v1") and plain static ("t0=v0") forms.
QString firstKeyframeSegment(const QString &raw)
{
    return stripLeadingKeyframeTime(raw.split(';').first());
}

double parseAnimatedDouble(const QString &raw, double defaultValue = 0.0)
{
    bool ok = false;
    double v = firstKeyframeSegment(raw).toDouble(&ok);
    return ok ? v : defaultValue;
}

// Full keyframe list from an MLT animated value ("t0=v0;t1=v1;...") -
// the ClipEffects.cpp counterpart to this importer's existing "first
// keyframe only" helpers above, used where an effect's full animation
// should actually be imported rather than collapsed to one value.
// Each raw segment value is converted via `conv` (the SAME conversion
// each filter already applies to its single first-keyframe value, e.g.
// volume's dB->linear) - returns a {"kf":[{"t":secs,"v":val},...]}
// JSON object (ClipEffects.cpp's "animated param" shape), `t` in
// SECONDS of the clip's own media/source time (frame-number times
// converted via the project's fps; clock-format times already are
// absolute - framesFromClockOrFrames() already handles both forms).
// A leading non-digit marker character (Kdenlive's smooth/discrete
// segment-type prefix, e.g. "~"/"|") is stripped from the time part -
// not yet distinguished, every segment is treated as linear (see
// TODO.txt's keyframe-system entry for why that's an acceptable v1 cut).
QJsonObject parseKeyframeListParam(const QString &raw, int fpsNum, int fpsDen,
                                    const std::function<double(const QString&)> &conv,
                                    double filterInSec = 0.0)
{
    QJsonArray kfArr;
    const QStringList segments = raw.split(';', Qt::SkipEmptyParts);
    for (const QString &seg : segments) {
        int eq = seg.indexOf('=');
        if (eq <= 0) continue;
        QString timePart = seg.left(eq);
        while (!timePart.isEmpty() && !timePart.at(0).isDigit()) timePart = timePart.mid(1);
        QString valuePart = seg.mid(eq + 1);
        qint64 frames = framesFromClockOrFrames(timePart, fpsNum, fpsDen);
        double tSec = (fpsNum > 0) ? double(frames) * fpsDen / fpsNum : 0.0;
        QJsonObject kf;
        kf["t"] = tSec + filterInSec;
        kf["v"] = conv(valuePart);
        kfArr.append(kf);
    }
    QJsonObject param;
    param["kf"] = kfArr;
    return param;
}

// A single-value-OR-animated MLT property, read as a plain double param
// when static and as a {"kf":[...]} animated param (ClipEffects.cpp's
// generic mechanism) when it's one of MLT's "<time>=<value>;..." animated
// strings. Used for select0r's continuous sliders (deltas/slope/subspace)
// - its enum-valued properties (shape/edge-mode/operation) deliberately
// keep using parseAnimatedDouble() (first-value-only) instead, since
// animating a discrete mode would just be visually incoherent.
QJsonValue animatableDoubleParam(const QString &raw, int fpsNum, int fpsDen, double defaultValue = 0.0)
{
    if (isKeyframedValue(raw)) {
        auto identity = [](const QString &v) {
            bool ok = false;
            double d = v.toDouble(&ok);
            return ok ? d : 0.0;
        };
        return parseKeyframeListParam(raw, fpsNum, fpsDen, identity);
    }
    bool ok = false;
    double d = firstKeyframeSegment(raw).toDouble(&ok);
    return ok ? d : defaultValue;
}

void collectUnsupportedForEntry(const KdlNode &entry, const QString &trackId, const QString &clipId,
                                 double timelineStart, double durationSeconds, const QString &clipName,
                                 int srcWidth, int srcHeight, int projectWidth, int projectHeight,
                                 KdlModel &model)
{
    for (const KdlNode &f : entry.children) {
        if (f.tag != QLatin1String("filter")) continue;
        if (isPlumbingFilter(f, QLatin1String("entry"))) continue;

        QString kid = f.props.value("kdenlive_id");
        QString svc = f.props.value("mlt_service");
        QString key = !kid.isEmpty() ? kid : svc;

        UnsupportedEntry u;
        u.category = "effect"; u.severity = "changes-output";
        u.trackId = trackId; u.clipId = clipId;
        u.timelineStart = timelineStart; u.durationSeconds = durationSeconds;
        u.rawTag = "filter"; u.rawXml = serializeNode(f);
        for (auto it = f.props.constBegin(); it != f.props.constEnd(); ++it) u.rawProperties.insert(it.key(), it.value());
        u.detail = clipName;

        if (key == QLatin1String("pan_zoom")) {
            // Applied via a "transform" effect (GstFramePositioner
            // fposx/fposy/fwidth/fheight set directly on the clip, see
            // ClipEffects.cpp's isTransformParam()) rather than approximated
            // and reported-only - the frame positioner is the ONE mechanism
            // that can express "render the source larger/offset than the
            // project frame and let the compositor crop it", which is
            // exactly what Kdenlive's pan_zoom/affine does.
            QString rectRaw = f.props.value("transition.rect");
            bool kf = isKeyframedValue(rectRaw);

            if (kf) {
                // Full per-keyframe import (not just the first point): each
                // "x y w h" segment gets the SAME aspect-fit treatment the
                // static branch below applies once, then becomes four
                // parallel {"kf":[...]} animated params (fposx/fposy/
                // fwidth/fheight) - ClipEffects.cpp's generic animation
                // mechanism (applyAnimation(), see its comment) already
                // handles "transform" params written this way with no
                // further changes needed on that side.
                QJsonArray xArr, yArr, wArr, hArr;
                bool anyAspectFitted = false;
                const QStringList segments = rectRaw.split(';', Qt::SkipEmptyParts);
                for (const QString &seg : segments) {
                    int eq = seg.indexOf('=');
                    if (eq <= 0) continue;
                    QString timePart = seg.left(eq);
                    while (!timePart.isEmpty() && !timePart.at(0).isDigit()) timePart = timePart.mid(1);
                    QString valuePart = seg.mid(eq + 1);
                    qint64 frames = framesFromClockOrFrames(timePart, model.fpsNum, model.fpsDen);
                    double tSec = (model.fpsNum > 0) ? double(frames) * model.fpsDen / model.fpsNum : 0.0;

                    QStringList vparts = valuePart.split(' ', Qt::SkipEmptyParts);
                    if (vparts.size() < 4) continue;
                    double rx = vparts[0].toDouble(), ry = vparts[1].toDouble();
                    double rw = vparts[2].toDouble(), rh = vparts[3].toDouble();

                    if (srcWidth > 0 && srcHeight > 0 && rh > 0) {
                        double srcAspect = double(srcWidth) / srcHeight;
                        double newW = rh * srcAspect;
                        double newX = rx + (rw - newW) / 2.0;
                        if (std::abs(newW - rw) > 0.01 * rw || std::abs(newX - rx) > 0.5) anyAspectFitted = true;
                        rw = newW; rx = newX;
                    }

                    QJsonObject kx, ky, kw, kh;
                    kx["t"] = tSec; kx["v"] = rx; xArr.append(kx);
                    ky["t"] = tSec; ky["v"] = ry; yArr.append(ky);
                    kw["t"] = tSec; kw["v"] = rw; wArr.append(kw);
                    kh["t"] = tSec; kh["v"] = rh; hArr.append(kh);
                }

                if (!xArr.isEmpty()) {
                    QJsonObject params;
                    QJsonObject ox; ox["kf"] = xArr; params["fposx"] = ox;
                    QJsonObject oy; oy["kf"] = yArr; params["fposy"] = oy;
                    QJsonObject ow; ow["kf"] = wArr; params["fwidth"] = ow;
                    QJsonObject oh; oh["kf"] = hArr; params["fheight"] = oh;
                    QJsonObject fx;
                    fx["id"] = QString("fx_kdl_%1").arg(++model.appliedEffectCounter);
                    fx["type"] = "transform"; fx["enabled"] = true; fx["params"] = params;
                    QJsonArray arr = model.appliedEffectsByClip.value(clipId);
                    arr.append(fx);
                    model.appliedEffectsByClip.insert(clipId, arr);

                    u.code = "filter.pan_zoom.keyframed_animated";
                    u.severity = "info";
                    u.title = QString("Pan/zoom automation imported (%1 keyframes%2)")
                                  .arg(xArr.size())
                                  .arg(anyAspectFitted ? ", source-aspect-fit applied" : "");
                } else {
                    u.code = "filter.pan_zoom.unparseable"; u.severity = "changes-output";
                    u.title = "Pan/zoom not applied (could not read its rect)";
                }
                model.unsupported.append(u);
                continue;
            }

            QStringList parts = firstKeyframeSegment(rectRaw).split(' ', Qt::SkipEmptyParts);
            if (parts.size() >= 4) {
                double rx = parts[0].toDouble(), ry = parts[1].toDouble();
                double rw = parts[2].toDouble(), rh = parts[3].toDouble();

                // Identity iff it's literally the whole project frame at
                // the origin - NOT "x==0 && y==0" alone, which earlier
                // mis-classified a full-width TOP CROP (e.g. a 16:9
                // source's "0 0 3840 2160" rect inside a 3840x1640
                // project) as a no-op. It isn't: GES's own no-positioner
                // default is a pillarboxed CENTER fit, not a top crop, so
                // every one of those rects genuinely changes framing.
                bool identity = (rx == 0.0 && ry == 0.0
                                  && qFuzzyCompare(rw, double(projectWidth)) && qFuzzyCompare(rh, double(projectHeight)));

                if (!identity) {
                    // distort=0 in every Kdenlive pan_zoom instance seen -
                    // MLT's affine does NOT contain-fit or cover-fit the
                    // source inside the rect - empirically measured (melt
                    // 7.42, 9 rect configurations, ground truth matched
                    // to +-1px by this exact formula): the rect's HEIGHT
                    // is always authoritative and untouched, the width is
                    // ALWAYS recomputed from the source's own aspect
                    // ratio, and the result is horizontally CENTERED
                    // within the original rect - even when that makes
                    // the content wider than the rect (verified with a
                    // rect narrower than the fitted content: the content
                    // overhangs symmetrically, confirming this is "fit
                    // height + center", not a contain/cover/clip mode).
                    // GES's frame positioner's fposx/fposy are the
                    // rendered content's own top-left corner (separately
                    // confirmed empirically), so centering must be baked
                    // into fposx here - unconditional, not just when the
                    // aspect visibly differs, so this is also a no-op
                    // (newW==rw, newX==rx) when the rect already matches
                    // the source aspect.
                    bool aspectFitted = false;
                    if (srcWidth > 0 && srcHeight > 0 && rh > 0) {
                        double srcAspect = double(srcWidth) / srcHeight;
                        double newW = rh * srcAspect;
                        double newX = rx + (rw - newW) / 2.0;
                        if (std::abs(newW - rw) > 0.01 * rw || std::abs(newX - rx) > 0.5) aspectFitted = true;
                        rw = newW; rx = newX;
                    }

                    QJsonObject params;
                    params["fposx"] = rx; params["fposy"] = ry;
                    params["fwidth"] = rw; params["fheight"] = rh;
                    QJsonObject fx;
                    fx["id"] = QString("fx_kdl_%1").arg(++model.appliedEffectCounter);
                    fx["type"] = "transform"; fx["enabled"] = true; fx["params"] = params;
                    QJsonArray arr = model.appliedEffectsByClip.value(clipId);
                    arr.append(fx);
                    model.appliedEffectsByClip.insert(clipId, arr);

                    if (aspectFitted) {
                        u.code = "filter.pan_zoom.aspect_fit"; u.severity = "cosmetic";
                        u.title = "Pan/zoom applied with a source-aspect-fit width (height kept, horizontally centered - matches Kdenlive's affine, verified against melt)";
                    } else {
                        u.code = "filter.pan_zoom.applied"; u.severity = "info";
                        u.title = "Pan/zoom applied (position/size changed)";
                    }
                } else {
                    u.code = "filter.pan_zoom.static.identity"; u.severity = "info";
                    u.title = "Pan/zoom present but identity (no visual change)";
                }
            } else {
                u.code = "filter.pan_zoom.unparseable"; u.severity = "changes-output";
                u.title = "Pan/zoom not applied (could not read its rect)";
            }
        } else if (key == QLatin1String("fade_from_black") || key == QLatin1String("fade_to_black")) {
            // Applied via a "fade" effect (a 2-keyframe linear alpha ramp
            // on GstFramePositioner's "alpha" child property, see
            // ClipEffects.cpp's applyFade()) rather than left unapplied.
            // Kdenlive always anchors fade_from_black to the clip's own
            // start and fade_to_black to its own end, so only the
            // filter's own duration (its in/out attrs, same frame-number
            // space as an <entry>'s in/out - NOT clip-timeline-position-
            // relative) matters; applyFade() re-derives the actual
            // keyframe placement from the clip's current inpoint/
            // duration at apply time, so this works regardless of
            // trimming elsewhere in the clip.
            bool isFadeIn = (key == QLatin1String("fade_from_black"));
            qint64 fIn = framesFromClockOrFrames(f.attrs.value("in"), model.fpsNum, model.fpsDen);
            qint64 fOut = framesFromClockOrFrames(f.attrs.value("out"), model.fpsNum, model.fpsDen);
            double fadeDurSec = fOut >= fIn && model.fpsNum > 0
                ? double(clipDurationFrames(fIn, fOut)) * model.fpsDen / model.fpsNum : 0.0;

            u.code = isFadeIn ? "filter.fade_from_black" : "filter.fade_to_black";
            if (fadeDurSec <= 0.0) {
                u.title = isFadeIn ? "Fade from black not applied (could not read its duration)"
                                    : "Fade to black not applied (could not read its duration)";
            } else {
                QJsonObject params;
                params[isFadeIn ? "in" : "out"] = fadeDurSec;
                QJsonArray arr = model.appliedEffectsByClip.value(clipId);
                // Fade-in and fade-out on the same clip are two separate
                // <filter> entries in the source XML - merge them into
                // ONE "fade" effect object (applyFade() reads both "in"
                // and "out" together) instead of two competing ones that
                // would each install their own control source and fight
                // over "alpha".
                int existingIdx = -1;
                for (int i = 0; i < arr.size(); ++i) {
                    if (arr[i].toObject().value("type").toString() == QLatin1String("fade")) { existingIdx = i; break; }
                }
                if (existingIdx >= 0) {
                    QJsonObject fx = arr[existingIdx].toObject();
                    QJsonObject existingParams = fx.value("params").toObject();
                    existingParams[isFadeIn ? "in" : "out"] = fadeDurSec;
                    fx["params"] = existingParams;
                    arr[existingIdx] = fx;
                } else {
                    QJsonObject fx;
                    fx["id"] = QString("fx_kdl_%1").arg(++model.appliedEffectCounter);
                    fx["type"] = "fade"; fx["enabled"] = true; fx["params"] = params;
                    arr.append(fx);
                }
                model.appliedEffectsByClip.insert(clipId, arr);

                u.severity = "info";
                u.title = isFadeIn ? QString("Fade from black applied (%1s)").arg(fadeDurSec, 0, 'f', 2)
                                    : QString("Fade to black applied (%1s)").arg(fadeDurSec, 0, 'f', 2);
            }
        } else if (svc == QLatin1String("frei0r.brightness") || svc == QLatin1String("frei0r.contrast0r")) {
            // 1:1 passthrough for both: the raw stored value is copied
            // straight to the gst frei0r property (gstfrei0r.c passes it
            // through unrescaled), clamped to the declared [0,1] range -
            // NOT clamping would make GStreamer silently reject the
            // property and the effect would vanish. Kdenlive only
            // DISPLAYS the values scaled (factor 1000 brightness, 500
            // contrast: raw 1.06 shows as "530"); the stored raw value
            // is what the plugin gets. Do not halve/rescale contrast -
            // that was tried and flattened the image. The remaining
            // Kdenlive mismatch was effect ORDER (see ClipEffects.cpp).
            bool isBrightness = (svc == QLatin1String("frei0r.brightness"));
            QString propKey = isBrightness ? QStringLiteral("Brightness") : QStringLiteral("Contrast");
            QString raw = f.props.value(propKey);
            bool kf = isKeyframedValue(raw);
            auto clamp01 = [](const QString &v) {
                bool ok = false;
                double d = v.toDouble(&ok);
                return qBound(0.0, ok ? d : 0.5, 1.0);
            };

            u.code = isBrightness ? "filter.frei0r.brightness" : "filter.frei0r.contrast0r";

            QJsonObject params;
            QString paramKey = isBrightness ? "brightness" : "contrast";
            if (kf) {
                params[paramKey] = parseKeyframeListParam(raw, model.fpsNum, model.fpsDen, clamp01);
            } else {
                params[paramKey] = clamp01(firstKeyframeSegment(raw));
            }
            QJsonObject fx;
            fx["id"] = QString("fx_kdl_%1").arg(++model.appliedEffectCounter);
            fx["type"] = isBrightness ? "brightness" : "contrast"; fx["enabled"] = true; fx["params"] = params;
            QJsonArray arr = model.appliedEffectsByClip.value(clipId);
            arr.append(fx);
            model.appliedEffectsByClip.insert(clipId, arr);

            u.severity = "info";
            QString label = isBrightness ? QStringLiteral("Brightness") : QStringLiteral("Contrast");
            u.title = kf
                ? QString("%1 automation imported (%2 keyframes)").arg(label).arg(raw.count(';') + 1)
                : QString("%1 applied (frei0r %2, same as Kdenlive)").arg(label, isBrightness ? "brightness" : "contrast0r");
        } else if (svc == QLatin1String("frei0r.select0r")) {
            // 1:1 passthrough, not an approximation: ClipEffects.cpp's
            // "colorkey" registry entry is now the REAL frei0r select0r
            // filter (via gst-plugins-bad's frei0r wrapper + the
            // frei0r-plugins system package), with property names and
            // semantics identical to what Kdenlive's own UI exposes - so
            // every select0r property just needs its value copied over
            // (hex color -> 0-1 floats, 0-1 doubles verbatim), no
            // translation/approximation logic at all. "Color to select"
            // is the only one needing real parsing (hex RRGGBBAA) - and,
            // when keyframed, the only one needing a per-point SPLIT
            // (ClipEffects.cpp's animation mechanism animates one scalar
            // property at a time, so one {"kf":[hex...]} color curve
            // becomes three parallel r/g/b curves). The continuous
            // sliders (deltas/slope/subspace) reuse animatableDoubleParam()
            // to import their own animation the same way, generalizing
            // the volume/brightness/contrast keyframe import already done
            // this project; the enum-valued properties (shape/edge-mode/
            // operation/invert) are deliberately left first-value-only -
            // animating a discrete mode has no coherent visual meaning.
            QString colorRaw = f.props.value("Color to select");
            bool colorKf = isKeyframedValue(colorRaw);
            u.code = "filter.frei0r.select0r";

            QJsonObject params;
            bool haveColor = true;
            if (colorKf) {
                QJsonArray rArr, gArr, bArr;
                const QStringList segments = colorRaw.split(';', Qt::SkipEmptyParts);
                for (const QString &seg : segments) {
                    int eq = seg.indexOf('=');
                    if (eq <= 0) continue;
                    QString timePart = seg.left(eq);
                    while (!timePart.isEmpty() && !timePart.at(0).isDigit()) timePart = timePart.mid(1);
                    QString valuePart = seg.mid(eq + 1);
                    qint64 frames = framesFromClockOrFrames(timePart, model.fpsNum, model.fpsDen);
                    double tSec = (model.fpsNum > 0) ? double(frames) * model.fpsDen / model.fpsNum : 0.0;
                    int r = 0, g = 0, b = 0;
                    if (!parseHexRgba(valuePart, r, g, b)) continue;
                    QJsonObject kr, kg, kb;
                    kr["t"] = tSec; kr["v"] = r / 255.0; rArr.append(kr);
                    kg["t"] = tSec; kg["v"] = g / 255.0; gArr.append(kg);
                    kb["t"] = tSec; kb["v"] = b / 255.0; bArr.append(kb);
                }
                haveColor = !rArr.isEmpty();
                if (haveColor) {
                    QJsonObject orr; orr["kf"] = rArr; params["color-to-select-r"] = orr;
                    QJsonObject ogg; ogg["kf"] = gArr; params["color-to-select-g"] = ogg;
                    QJsonObject obb; obb["kf"] = bArr; params["color-to-select-b"] = obb;
                }
            } else {
                int r = 0, g = 0, b = 0;
                haveColor = parseHexRgba(colorRaw, r, g, b);
                if (haveColor) {
                    params["color-to-select-r"] = r / 255.0;
                    params["color-to-select-g"] = g / 255.0;
                    params["color-to-select-b"] = b / 255.0;
                }
            }

            if (!haveColor) {
                u.severity = "changes-output";
                u.title = "Colour keyer not applied (could not read its target colour)";
            } else {
                bool invert = f.props.value("Invert selection").trimmed() == QLatin1String("1");
                params["invert-selection"] = invert;
                params["selection-subspace"] = animatableDoubleParam(f.props.value("Selection subspace"), model.fpsNum, model.fpsDen, 0.0);
                params["subspace-shape"] = parseAnimatedDouble(f.props.value("Subspace shape"), 0.0);
                params["edge-mode"] = parseAnimatedDouble(f.props.value("Edge mode"), 0.0);
                params["operation"] = parseAnimatedDouble(f.props.value("Operation"), 0.0);
                params["delta-r---a---hue"] = animatableDoubleParam(f.props.value("Delta R / A / Hue"), model.fpsNum, model.fpsDen, 0.2);
                params["delta-g---b---chroma"] = animatableDoubleParam(f.props.value("Delta G / B / Chroma"), model.fpsNum, model.fpsDen, 0.2);
                params["delta-b---i---i"] = animatableDoubleParam(f.props.value("Delta B / I / I"), model.fpsNum, model.fpsDen, 0.2);
                params["slope"] = animatableDoubleParam(f.props.value("Slope"), model.fpsNum, model.fpsDen, 0.0);

                QJsonObject fx;
                fx["id"] = QString("fx_kdl_%1").arg(++model.appliedEffectCounter);
                fx["type"] = "colorkey"; fx["enabled"] = true; fx["params"] = params;
                QJsonArray arr = model.appliedEffectsByClip.value(clipId);
                arr.append(fx);
                model.appliedEffectsByClip.insert(clipId, arr);

                bool anyKf = colorKf
                    || isKeyframedValue(f.props.value("Selection subspace"))
                    || isKeyframedValue(f.props.value("Delta R / A / Hue"))
                    || isKeyframedValue(f.props.value("Delta G / B / Chroma"))
                    || isKeyframedValue(f.props.value("Delta B / I / I"))
                    || isKeyframedValue(f.props.value("Slope"));

                u.severity = "info";
                u.title = anyKf
                    ? "Colour keyer automation imported (frei0r select0r)"
                    : "Colour keyer applied (frei0r select0r, same as Kdenlive)";
            }
        } else if (key == QLatin1String("volume")) {
            // GStreamer's "volume" element takes a LINEAR amplitude
            // multiplier (1.0=unity); Kdenlive/MLT's "level" is in dB -
            // verified live (direct PCM sample peak/RMS comparison, not
            // just documentation) that 10^(dB/20) is the exact, correct
            // conversion in both directions. A keyframed level (this
            // filter is frequently used for audio ducking automation -
            // seen in the real test project as a 10-keyframe narration-
            // ducking curve) is imported as a full animated "volume"
            // param via ClipEffects.cpp's general keyframe mechanism,
            // not just its first value - collapsing a ducking curve to
            // one constant level would be one of the most audible
            // possible losses of any filter this importer handles.
            QString levelRaw = f.props.value("level");
            bool kf = isKeyframedValue(levelRaw);
            auto dbToLinear = [](const QString &raw) {
                bool ok = false;
                double dB = raw.toDouble(&ok);
                return qBound(0.0, std::pow(10.0, (ok ? dB : 0.0) / 20.0), 10.0);
            };

            u.code = kf ? "filter.volume.keyframed" : "filter.volume";

            QJsonObject params;
            if (kf) {
                double filterInSec = model.fpsNum > 0
                    ? double(framesFromClockOrFrames(f.attrs.value("in"), model.fpsNum, model.fpsDen)) * model.fpsDen / model.fpsNum
                    : 0.0;
                params["volume"] = parseKeyframeListParam(levelRaw, model.fpsNum, model.fpsDen, dbToLinear, filterInSec);
            } else {
                params["volume"] = dbToLinear(firstKeyframeSegment(levelRaw));
            }
            QJsonObject fx;
            fx["id"] = QString("fx_kdl_%1").arg(++model.appliedEffectCounter);
            fx["type"] = "volume"; fx["enabled"] = true; fx["params"] = params;
            QJsonArray arr = model.appliedEffectsByClip.value(clipId);
            arr.append(fx);
            model.appliedEffectsByClip.insert(clipId, arr);

            double dB0 = parseAnimatedDouble(levelRaw, 0.0);
            u.severity = "info";
            u.title = kf
                ? QString("Clip volume automation imported (%1 keyframes)").arg(levelRaw.count(';') + 1)
                : QString("Clip volume applied (%1dB)").arg(dB0, 0, 'f', 1);
        } else {
            u.code = "filter.unknown"; u.title = QString("Unsupported effect (%1) not applied").arg(!key.isEmpty() ? key : "?");
        }
        model.unsupported.append(u);
    }
}

} // namespace

// ===================== public entry points =====================

namespace {

// gcsClipIds of every placement whose Kdenlive producer never resolved to
// a usable binItems entry at all (currently: color-generator clips - see
// buildBinItems()'s model.generatorKdenliveIds.insert() - but written
// generically so any future "intentionally never added to binItems"
// producer kind is covered too). Deliberately NOT the same as "missing
// media": a missing-media item DOES have a binItems entry (just an
// unresolved path) and is handled separately by the
// missingMediaPlaceholder option. Pure function of `model` so it can be
// called identically from runConversion() (to report) and
// emitEditingJson() (to actually skip the placement) without either one
// needing to mutate data the other owns.
QSet<QString> unresolvedProducerClipIds(const KdlModel &model)
{
    QSet<QString> ids;
    for (const KdlTrack &t : model.tracks)
        for (const KdlPlacement &p : t.clips)
            if (model.binItemIndexByKdenliveId.value(p.kdenliveId, -1) < 0) ids.insert(p.gcsClipId);
    return ids;
}

KdlModel runConversion(const QString &filePath, const QVariantMap &options)
{
    KdlModel model;
    KdlDoc doc;
    QString err;
    if (!parseXml(filePath, doc, err)) { model.ok = false; model.error = err; return model; }

    model.mltRoot = doc.mltRoot;
    model.width = doc.width; model.height = doc.height;
    model.fpsNum = doc.fpsNum; model.fpsDen = doc.fpsDen;
    auto fm = mapFpsToProjectSetting(doc.fpsNum, doc.fpsDen);
    model.fpsLabel = fm.label; model.fpsMapped = fm.mapped;
    if (!model.fpsMapped) {
        UnsupportedEntry u;
        u.code = "project.fps.unmapped"; u.category = "project"; u.severity = "changes-output";
        u.title = "Project frame rate could not be matched exactly";
        u.detail = QString("Source: %1/%2 (%3 fps) - nearest supported: %4 fps")
                       .arg(doc.fpsNum).arg(doc.fpsDen).arg(double(doc.fpsNum) / doc.fpsDen).arg(model.fpsLabel);
        model.unsupported.append(u);
    }

    model.kdenliveVersion = doc.root.attrs.value("version");
    model.sequenceCount = doc.sequenceTractors.size();

    const KdlNode *seqTractor = nullptr;
    QString requestedSeq = options.value("sequenceId").toString();
    if (!requestedSeq.isEmpty()) seqTractor = doc.byId.value(requestedSeq, nullptr);
    if (!seqTractor && !doc.activeSequenceUuid.isEmpty())
        seqTractor = findTractorTrackContainer(doc, doc.activeSequenceUuid);
    if (!seqTractor && !doc.sequenceTractors.isEmpty()) seqTractor = doc.sequenceTractors.first();
    if (!seqTractor) { model.ok = false; model.error = "No timeline sequence found in this project"; return model; }

    model.activeSequenceId = seqTractor->attrs.value("id");
    model.activeSequenceName = seqTractor->props.value("kdenlive:clipname");
    model.sequencesSkipped = qMax(0, doc.sequenceTractors.size() - 1);

    buildBinFolders(doc, model);
    buildBinItems(doc, model);
    resolveMediaPaths(doc.mltRoot, options, model);
    buildTracks(doc, *seqTractor, model);
    flattenPlaylists(doc, model, doc.fpsNum, doc.fpsDen);

    // Assign GCS clip ids + build the (trackListIndex:startFrame) lookup
    // AVSplit groups reference, then filter/unsupported-collect per clip.
    QHash<QString, QString> clipIdByTrackIdxAndFrame;
    int videoCounter = 0, audioCounter = 0;
    for (int ti = 0; ti < model.tracks.size(); ++ti) {
        KdlTrack &track = model.tracks[ti];
        for (KdlPlacement &p : track.clips) {
            p.gcsClipId = track.isAudio ? QString("clip_a_%1").arg(++audioCounter)
                                         : QString("clip_v_%1").arg(++videoCounter);
            clipIdByTrackIdxAndFrame.insert(QString("%1:%2").arg(ti).arg(p.startFrame), p.gcsClipId);
            int binIdx = model.binItemIndexByKdenliveId.value(p.kdenliveId, -1);
            QString clipName = binIdx >= 0 ? model.binItems[binIdx].name : p.kdenliveId;
            if (binIdx >= 0) model.binItems[binIdx].usedOnTimeline = true;
            double startSec = double(p.startFrame) * doc.fpsDen / doc.fpsNum;
            double durSec = double(p.durFrame) * doc.fpsDen / doc.fpsNum;
            int srcW = binIdx >= 0 ? model.binItems[binIdx].srcWidth : 0;
            int srcH = binIdx >= 0 ? model.binItems[binIdx].srcHeight : 0;
            if (p.entry) collectUnsupportedForEntry(*p.entry, track.gcsTrackId, p.gcsClipId, startSec, durSec, clipName,
                                                     srcW, srcH, model.width, model.height, model);
        }
    }

    detectAndAnnotateTransitions(doc, model, doc.fpsNum, doc.fpsDen);
    buildLinkGroups(doc, *seqTractor, model, clipIdByTrackIdxAndFrame);

    // Track-level plumbing filters (e.g. audiolevel on the track tractor
    // itself, which lacks internal_added) - counted as one aggregate
    // info row per track rather than per-filter noise.
    int plumbingCount = 0;
    for (const KdlTrack &track : model.tracks)
        for (const KdlNode &f : track.tractorNode->children)
            if (f.tag == QLatin1String("filter") && isPlumbingFilter(f, QLatin1String("tractor"))) plumbingCount++;
    if (plumbingCount > 0) {
        UnsupportedEntry u;
        u.code = "track.plumbing_filter"; u.category = "track"; u.severity = "info";
        u.title = "Track-level mix/level filters skipped (Kdenlive internal plumbing)";
        u.detail = QString("%1 filter(s)").arg(plumbingCount);
        model.unsupported.append(u);
    }

    if (model.sequencesSkipped > 0) {
        UnsupportedEntry u;
        u.code = "sequence.multiple"; u.category = "sequence"; u.severity = "info";
        u.title = "Additional sequence(s) in this project were not imported";
        u.detail = QString("%1 other sequence(s); only \"%2\" was imported")
                       .arg(model.sequencesSkipped).arg(model.activeSequenceName.isEmpty() ? model.activeSequenceId : model.activeSequenceName);
        model.unsupported.append(u);
    }

    // See unresolvedProducerClipIds()'s comment - this reports what
    // emitEditingJson() will separately (and identically) compute to
    // actually skip the placement, since that function can't mutate
    // model.unsupported itself.
    {
        const QSet<QString> unresolvedIds = unresolvedProducerClipIds(model);
        if (!unresolvedIds.isEmpty()) {
            for (const KdlTrack &t : model.tracks) {
                for (const KdlPlacement &p : t.clips) {
                    if (!unresolvedIds.contains(p.gcsClipId)) continue;

                    double startSec = model.fpsNum > 0 ? double(p.startFrame) * model.fpsDen / model.fpsNum : 0.0;
                    double durSec = model.fpsNum > 0 ? double(p.durFrame) * model.fpsDen / model.fpsNum : 0.0;

                    UnsupportedEntry u;
                    u.category = "media"; u.clipId = p.gcsClipId; u.trackId = t.gcsTrackId;
                    u.timelineStart = startSec; u.durationSeconds = durSec;
                    if (model.generatorKdenliveIds.contains(p.kdenliveId)) {
                        u.code = "timeline.generator_clip_skipped"; u.severity = "changes-output";
                        u.title = "Colour generator clip skipped on the timeline (no real media behind it)";
                    } else {
                        u.code = "timeline.unresolved_producer"; u.severity = "changes-output";
                        u.title = "Clip skipped (its Kdenlive producer could not be resolved to any bin item)";
                    }
                    u.detail = p.kdenliveId;
                    model.unsupported.append(u);
                }
            }
        }
    }

    for (const KdlTransitionAnno &t : model.transitions) {
        if (t.wipe) {
            UnsupportedEntry u;
            u.category = "transition"; u.trackId = model.tracks[t.trackIdx].gcsTrackId;
            u.detail = t.wipeResource;
            if (t.lumaUnmapped) {
                u.code = "transition.luma_wipe.unmapped"; u.severity = "changes-output";
                u.title = QString("Custom luma wipe not supported - using a plain crossfade (%1)").arg(t.wipeResource);
            } else {
                bool approximate = false;
                gesWipeNickForLumaResource(t.wipeResource, approximate);
                if (approximate) {
                    u.code = "transition.luma_wipe.approximate"; u.severity = "changes-output";
                    u.title = QString("Luma wipe approximated (%1 -> GES \"%2\", not an exact shape match)").arg(t.wipeResource, t.gcsType);
                } else {
                    u.code = "transition.luma_wipe.mapped"; u.severity = "info";
                    u.title = QString("Luma wipe mapped to GES \"%1\" (%2)").arg(t.gcsType, t.wipeResource);
                }
            }
            model.unsupported.append(u);
        }
        if (t.asymmetric) {
            UnsupportedEntry u;
            // Verified against Kdenlive's own trackmodel.cpp/clipmodel.cpp:
            // kdenlive:mixcut only drives KDENLIVE's own UI (cut-marker
            // drawing/snapping) - the MLT luma transition itself ignores
            // it and ramps across the whole overlap exactly like GES's
            // auto-transition does, so the RENDERED output already
            // matches Kdenlive here. What previously differed is this
            // app's OWN timeline drawing, which hardcoded the overlap
            // midpoint - see transitionCutOffset (emitEditingJson()) and
            // its UI consumers for the actual fix.
            u.code = "transition.asymmetric_mixcut"; u.category = "transition"; u.severity = "cosmetic";
            u.title = "Asymmetric transition cut point (rendered output already matches Kdenlive; only the timeline's own cut-point drawing needed correcting)";
            u.detail = QString("overlap %1f, cut at +%2f from overlap start").arg(t.overlapFrames).arg(t.cutOffsetFrames);
            u.trackId = model.tracks[t.trackIdx].gcsTrackId;
            model.unsupported.append(u);
        }
    }

    for (const KdlBinItem &item : model.binItems) {
        if (item.resolution == QLatin1String("missing")) {
            UnsupportedEntry u;
            u.code = "media.missing"; u.category = "media"; u.severity = "changes-output";
            // Kdenlive proxies are never used as a substitute (see
            // resolveMediaPaths()'s comment) - an item is "missing"
            // even when its Kdenlive proxy exists on disk, so say so
            // explicitly rather than leaving the user wondering why a
            // file that's clearly present wasn't picked up.
            u.title = !item.proxyUrl.isEmpty()
                ? "Media file not found (a Kdenlive proxy exists but is not used - see TODO)"
                : "Media file not found";
            u.detail = item.name; u.binItemId = item.gcsItemId;
            model.unsupported.append(u);
        } else if (item.resolution == QLatin1String("rescued")) {
            UnsupportedEntry u;
            u.code = "media.rescued"; u.category = "media"; u.severity = "info";
            u.title = "Original media found by filename search (path had moved)";
            u.detail = item.name; u.binItemId = item.gcsItemId;
            model.unsupported.append(u);
        }
    }

    model.ok = true;
    return model;
}

QVariantMap unsupportedEntryToMap(const UnsupportedEntry &u)
{
    QVariantMap m;
    m["code"] = u.code; m["category"] = u.category; m["severity"] = u.severity;
    m["title"] = u.title; m["detail"] = u.detail;
    m["trackId"] = u.trackId; m["clipId"] = u.clipId; m["binItemId"] = u.binItemId;
    m["timelineStart"] = u.timelineStart; m["durationSeconds"] = u.durationSeconds;
    QVariantMap raw;
    raw["tag"] = u.rawTag; raw["properties"] = u.rawProperties; raw["xml"] = u.rawXml;
    m["raw"] = raw;
    return m;
}

QVariantList unsupportedSummary(const QVector<UnsupportedEntry> &list)
{
    QHash<QString, QVariantMap> byCode;
    QStringList order;
    for (const UnsupportedEntry &u : list) {
        if (!byCode.contains(u.code)) {
            QVariantMap m; m["code"] = u.code; m["title"] = u.title; m["severity"] = u.severity;
            m["category"] = u.category; m["count"] = 0;
            byCode.insert(u.code, m);
            order << u.code;
        }
        QVariantMap m = byCode[u.code];
        m["count"] = m["count"].toInt() + 1;
        byCode[u.code] = m;
    }
    QVariantList out;
    for (const QString &c : order) out << byCode[c];
    return out;
}

QVariantMap buildSummary(const KdlModel &model)
{
    QVariantMap out;
    out["ok"] = model.ok;
    out["error"] = model.error;
    if (!model.ok) return out;

    out["kdenliveVersion"] = model.kdenliveVersion;
    out["mltRoot"] = model.mltRoot;

    QVariantMap profile;
    profile["width"] = model.width; profile["height"] = model.height;
    profile["fpsNum"] = model.fpsNum; profile["fpsDen"] = model.fpsDen;
    profile["fpsLabel"] = model.fpsLabel; profile["fpsMapped"] = model.fpsMapped;
    profile["fpsExact"] = double(model.fpsNum) / model.fpsDen;
    out["profile"] = profile;

    QVariantList tracks;
    int videoTracks = 0, audioTracks = 0;
    for (const KdlTrack &t : model.tracks) {
        QVariantMap tm;
        tm["gcsTrackId"] = t.gcsTrackId; tm["name"] = t.name;
        tm["type"] = t.isAudio ? "audio" : "video"; tm["clips"] = t.clips.size();
        tracks << tm;
        if (t.isAudio) audioTracks++; else videoTracks++;
    }
    out["tracks"] = tracks;

    QVariantList media;
    int cOriginal = 0, cProxy = 0, cRescued = 0, cMissing = 0;
    for (const KdlBinItem &item : model.binItems) {
        QVariantMap m;
        m["kdenliveId"] = item.kdenliveId; m["name"] = item.name;
        m["originalPath"] = item.originalUrl; m["proxyPath"] = item.proxyUrl;
        m["resolution"] = item.resolution; m["resolvedPath"] = item.resolvedPath;
        m["usedOnTimeline"] = item.usedOnTimeline; m["folderId"] = item.folderId;
        m["hasVideo"] = item.hasVideoStream; m["hasAudio"] = item.hasAudioStream;
        media << m;
        if (item.resolution == "original") cOriginal++;
        else if (item.resolution == "proxy") cProxy++;
        else if (item.resolution == "rescued") cRescued++;
        else if (item.resolution == "missing") cMissing++;
    }
    out["media"] = media;
    QVariantMap mediaSummary;
    mediaSummary["original"] = cOriginal; mediaSummary["proxy"] = cProxy;
    mediaSummary["rescued"] = cRescued; mediaSummary["missing"] = cMissing;
    out["mediaSummary"] = mediaSummary;

    int gaps = model.gapsConsumed;
    QVariantMap counts;
    int totalClips = 0; for (const KdlTrack &t : model.tracks) totalClips += t.clips.size();
    counts["binItems"] = model.binItems.size();
    counts["binFolders"] = model.folders.size();
    counts["clips"] = totalClips;
    counts["gaps"] = gaps;
    counts["transitions"] = model.transitions.size();
    counts["linkPairs"] = model.links.size();
    counts["videoTracks"] = videoTracks;
    counts["audioTracks"] = audioTracks;
    counts["sequencesSkipped"] = model.sequencesSkipped;
    out["counts"] = counts;

    QVariantList unsupported, unsupSummary;
    for (const UnsupportedEntry &u : model.unsupported) unsupported << unsupportedEntryToMap(u);
    out["unsupported"] = unsupported;
    out["unsupportedSummary"] = unsupportedSummary(model.unsupported);

    QVariantList sequences;
    QVariantMap seq; seq["id"] = model.activeSequenceId; seq["name"] = model.activeSequenceName; seq["active"] = true;
    sequences << seq;
    out["sequences"] = sequences;
    out["activeSequenceId"] = model.activeSequenceId;

    return out;
}

QString emitProjectBinJson(const KdlModel &model)
{
    // Folder tree keyed by folder id, root = "-1".
    QHash<QString, QJsonArray> childrenByParent;
    QHash<QString, QJsonObject> folderObjBygId;
    for (const KdlFolder &f : model.folders) {
        QJsonObject fo;
        fo["id"] = "folder_kdl_" + f.id;
        fo["type"] = "folder";
        fo["name"] = f.name;
        fo["children"] = QJsonArray();
        folderObjBygId.insert(f.id, fo);
    }
    for (int i = 0; i < model.binItems.size(); ++i) {
        const KdlBinItem &item = model.binItems[i];
        QString itemType = item.hasVideoStream ? "video" : (item.hasAudioStream ? "audio" : "file");
        QJsonObject fo;
        fo["id"] = "item_kdl_" + item.kdenliveId;
        fo["type"] = itemType;
        fo["name"] = item.name;
        fo["path"] = item.resolvedPath;
        fo["duration"] = "";
        childrenByParent[item.folderId.isEmpty() ? "-1" : item.folderId].append(fo);
    }
    // nest folders into each other
    for (const KdlFolder &f : model.folders) {
        QJsonObject fo = folderObjBygId.value(f.id);
        QJsonArray kids = childrenByParent.value(f.id);
        fo["children"] = kids;
        folderObjBygId[f.id] = fo;
    }
    // attach folders to their parents' children arrays (two-pass: ensure
    // children already nested above before pushing folder object upward)
    QJsonArray rootArray = childrenByParent.value("-1");
    QSet<QString> placedAsChild;
    for (const KdlFolder &f : model.folders) {
        if (f.parentId == "-1") { rootArray.append(folderObjBygId.value(f.id)); placedAsChild.insert(f.id); }
    }
    for (const KdlFolder &f : model.folders) {
        if (f.parentId != "-1" && folderObjBygId.contains(f.parentId)) {
            QJsonObject parentObj = folderObjBygId.value(f.parentId);
            QJsonArray kids = parentObj["children"].toArray();
            kids.append(folderObjBygId.value(f.id));
            parentObj["children"] = kids;
            folderObjBygId[f.parentId] = parentObj;
        }
    }
    // rebuild rootArray from the now-updated folderObjBygId for root-level folders
    rootArray = childrenByParent.value("-1");
    for (const KdlFolder &f : model.folders)
        if (f.parentId == "-1") rootArray.append(folderObjBygId.value(f.id));

    return QString::fromUtf8(QJsonDocument(rootArray).toJson(QJsonDocument::Compact));
}

// audioSide always stays a plain crossfade (GES video transition types
// don't apply to audio-only transitions - see TimelineEngine's
// applyTransitionTypes(), which guards on GES_TRACK_TYPE_VIDEO); the
// video side now carries the REAL GES nick the importer resolved
// (gesWipeNickForLumaResource(), or "crossfade" for a plain dissolve) -
// not a generic "dissolve" placeholder like before.
QString transitionTypeFor(bool audioSide, const QString &gesNick)
{
    return audioSide ? QStringLiteral("crossfade") : gesNick;
}

QString emitEditingJson(const KdlModel &model, const QVariantMap &options)
{
    double pixelsPerSecond = options.value("pixelsPerSecond", 50).toDouble();

    // "Use placeholder" (default on, matches Kdenlive's own default
    // behaviour for missing media): a clip whose bin item couldn't be
    // resolved to a real file on disk still gets its full timeline
    // entry - position, duration, name, linked-clip pairing, applied
    // effects - built from the ORIGINAL (unmodified) Kdenlive data,
    // exactly as if the file were present. Nothing about it is
    // invented or rewritten; it just can't play right now. Because the
    // path recorded is the real original path (see resolveBinMedia(),
    // "missing" branch), putting the real file back there later makes
    // it play with no further action - the project file never needed
    // to change. Unchecking this option instead skips the clip (and
    // any transition/link referencing it) entirely, leaving a true gap
    // rather than a reserved placeholder.
    bool keepPlaceholders = options.value("missingMediaPlaceholder", true).toBool();
    QSet<QString> skippedClipIds;
    if (!keepPlaceholders) {
        for (const KdlTrack &t : model.tracks) {
            for (const KdlPlacement &p : t.clips) {
                int binIdx = model.binItemIndexByKdenliveId.value(p.kdenliveId, -1);
                if (binIdx >= 0 && model.binItems[binIdx].resolution == QLatin1String("missing")) {
                    skippedClipIds.insert(p.gcsClipId);
                }
            }
        }
    }

    // Unconditional (NOT gated by keepPlaceholders, unlike the "missing
    // media" case above): a placement whose Kdenlive producer is a
    // color-generator, or that otherwise never got a binItems entry at
    // all, has NO file-backed media behind it - there is no "put the
    // original back later" story for it the way there is for missing
    // media, so there's no placeholder worth keeping. Before this
    // existed such a placement fell through with binIdx==-1 and still
    // got placed with an empty itemPath, which TimelineEngine::
    // addClipToGES() then rejected as "Missing file" - a confusing,
    // silent-until-playback failure instead of a clear, up-front import
    // report entry (added to model.unsupported in runConversion(), via
    // this same unresolvedProducerClipIds() helper - this function only
    // receives `model` by const ref and can't append to it itself).
    skippedClipIds.unite(unresolvedProducerClipIds(model));

    QJsonArray tracksArr;
    for (const KdlTrack &t : model.tracks) {
        QJsonObject to;
        to["trackId"] = t.gcsTrackId; to["type"] = t.isAudio ? "audio" : "video";
        to["name"] = t.name; to["disabled"] = !t.active; to["hidden"] = false; to["locked"] = false;
        tracksArr.append(to);
    }

    // clipId -> linked info
    QHash<QString, QString> linkGroupByClip, linkedPartnerByClip;
    for (const KdlLinkPair &lp : model.links) {
        linkGroupByClip[lp.videoClipId] = lp.linkGroupId;
        linkGroupByClip[lp.audioClipId] = lp.linkGroupId;
        linkedPartnerByClip[lp.videoClipId] = lp.audioClipId;
        linkedPartnerByClip[lp.audioClipId] = lp.videoClipId;
    }

    // (trackIdx,clipIdx) -> transition annotation, both as "A" (has
    // transition into the next clip) - applied per the exact invariants
    // applyTransition() expects (TimelinePanel.qml).
    struct TransAnno { QString bClipId; double duration; QString gesNick; double cutOffsetSec; };
    QHash<QString, TransAnno> transByAClip;
    for (const KdlTransitionAnno &t : model.transitions) {
        const KdlTrack &track = model.tracks[t.trackIdx];
        const KdlPlacement &a = track.clips[t.aIdx];
        const KdlPlacement &b = track.clips[t.bIdx];
        if (skippedClipIds.contains(a.gcsClipId) || skippedClipIds.contains(b.gcsClipId)) continue;
        double durSec = double(t.overlapFrames) * model.fpsDen / model.fpsNum;
        // cutOffsetFrames is -1 when kdenlive:mixcut was absent (a
        // natively-symmetric Kdenlive transition) - the overlap midpoint
        // is the correct default for that case, same as a
        // freshly-applied GCS transition (TimelinePanel.qml's
        // applyTransition()).
        double cutOffsetSec = t.cutOffsetFrames >= 0
            ? double(t.cutOffsetFrames) * model.fpsDen / model.fpsNum
            : durSec / 2.0;
        transByAClip[a.gcsClipId] = { b.gcsClipId, durSec, t.gcsType, cutOffsetSec };
    }

    double totalSeconds = 0;
    QJsonArray clipsArr;
    for (int ti = 0; ti < model.tracks.size(); ++ti) {
        const KdlTrack &track = model.tracks[ti];
        for (const KdlPlacement &p : track.clips) {
            if (skippedClipIds.contains(p.gcsClipId)) continue;
            int binIdx = model.binItemIndexByKdenliveId.value(p.kdenliveId, -1);
            QString path = binIdx >= 0 ? model.binItems[binIdx].resolvedPath : "";
            QString baseName = binIdx >= 0 ? model.binItems[binIdx].name : p.kdenliveId;

            double startSec = double(p.startFrame) * model.fpsDen / model.fpsNum;
            double durSec = double(p.durFrame) * model.fpsDen / model.fpsNum;
            double srcOffSec = double(p.inFrame) * model.fpsDen / model.fpsNum;
            totalSeconds = qMax(totalSeconds, startSec + durSec);

            QJsonObject co;
            co["clipId"] = p.gcsClipId; co["trackId"] = track.gcsTrackId;
            co["itemName"] = track.isAudio ? (baseName + " (Audio)") : baseName;
            co["itemPath"] = path;
            co["startTime"] = startSec; co["durationSeconds"] = durSec;
            co["xPos"] = startSec * pixelsPerSecond;
            co["sourceOffset"] = srcOffSec;
            co["hasVideo"] = !track.isAudio; co["hasAudio"] = track.isAudio;

            bool hasT = transByAClip.contains(p.gcsClipId);
            co["hasTransition"] = hasT;
            if (hasT) {
                const TransAnno &ta = transByAClip[p.gcsClipId];
                co["transitionDuration"] = ta.duration;
                co["transitionType"] = transitionTypeFor(track.isAudio, ta.gesNick);
                co["transitionOriginalBId"] = ta.bClipId;
                co["transitionOriginalStartB"] = startSec + durSec;
                co["transitionCutOffset"] = ta.cutOffsetSec;
            } else {
                co["transitionDuration"] = 0; co["transitionType"] = "";
                co["transitionOriginalBId"] = ""; co["transitionOriginalStartB"] = 0;
                co["transitionCutOffset"] = 0;
            }
            co["transitionAudioTrimA"] = 0;

            QString partnerId = linkedPartnerByClip.value(p.gcsClipId);
            bool partnerSkipped = !partnerId.isEmpty() && skippedClipIds.contains(partnerId);
            QString lg = partnerSkipped ? QString() : linkGroupByClip.value(p.gcsClipId);
            co["linkGroupId"] = lg;
            co["linkedClipId"] = partnerSkipped ? QString() : partnerId;
            co["isLinked"] = !lg.isEmpty();

            co["sourceItemId"] = binIdx >= 0 ? QString("item_kdl_%1").arg(model.binItems[binIdx].kdenliveId) : "";
            co["waveformPath"] = "";
            QJsonArray appliedFx = model.appliedEffectsByClip.value(p.gcsClipId);
            co["effects"] = appliedFx.isEmpty() ? "" : QString::fromUtf8(QJsonDocument(appliedFx).toJson(QJsonDocument::Compact));
            clipsArr.append(co);
        }
    }

    QJsonObject root;
    root["tracks"] = tracksArr; root["clips"] = clipsArr;
    root["pixelsPerSecond"] = pixelsPerSecond; root["totalSeconds"] = totalSeconds;
    return QString::fromUtf8(QJsonDocument(root).toJson(QJsonDocument::Compact));
}

} // namespace

QVariantMap inspect(const QString &filePath, const QVariantMap &options)
{
    KdlModel model = runConversion(filePath, options);
    return buildSummary(model);
}

QVariantMap convert(const QString &filePath, const QVariantMap &options)
{
    KdlModel model = runConversion(filePath, options);
    QVariantMap out = buildSummary(model);
    if (!model.ok) return out;

    out["projectBinJson"] = emitProjectBinJson(model);
    out["editingJson"] = emitEditingJson(model, options);

    QVariantMap settings;
    settings["name"] = QFileInfo(filePath).completeBaseName();
    settings["description"] = QString("Imported from Kdenlive %1").arg(model.kdenliveVersion);
    settings["width"] = model.width; settings["height"] = model.height; settings["fps"] = model.fpsLabel;
    int videoTracks = 0, audioTracks = 0;
    for (const KdlTrack &t : model.tracks) (t.isAudio ? audioTracks : videoTracks)++;
    settings["videoTracks"] = videoTracks; settings["audioTracks"] = audioTracks;
    out["projectSettings"] = settings;

    QVariantMap report;
    QVariantMap source;
    source["path"] = filePath;
    source["kdenliveVersion"] = model.kdenliveVersion;
    source["mltRoot"] = model.mltRoot;
    source["sequenceId"] = model.activeSequenceId;
    report["source"] = source;
    report["importedAt"] = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
    report["options"] = options;
    report["counts"] = out["counts"];
    report["media"] = out["media"];
    report["unsupported"] = out["unsupported"];
    out["report"] = report;

    return out;
}

bool writeReport(const QString &projectDir, const QVariantMap &report)
{
    QDir dir(projectDir);
    if (!dir.exists(".import")) dir.mkpath(".import");
    QFile f(dir.filePath(".import/kdenlive-import-report.json"));
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
    QJsonDocument doc = QJsonDocument::fromVariant(report);
    f.write(doc.toJson(QJsonDocument::Indented));
    f.close();
    return true;
}

} // namespace KdenliveImporter
