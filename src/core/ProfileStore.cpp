#include "ProfileStore.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QDebug>
#include <QtMath>

namespace {
const char *kCustomKey = "profiles/custom";

// Exactly the strings TimelineEngine::setClips() maps to a frame rate
// (23.98/29.97/59.94 are matched first, then 24/25/50/60, and "30" is the
// fall-through default - so all eight really produce the labelled rate).
const QStringList kFps = {"23.98", "24", "25", "29.97", "30", "50", "59.94", "60"};

int gcd(int a, int b) { while (b) { int t = a % b; a = b; b = t; } return a; }
}

ProfileStore::ProfileStore(QObject *parent) : QObject(parent)
{
    load();
}

QList<ProfileStore::Profile> ProfileStore::builtins()
{
    auto mk = [](const char *n, int w, int h, const char *aspect, const char *desc) {
        Profile p; p.name = QString::fromUtf8(n); p.w = w; p.h = h; p.fps = "23.98";
        p.aspect = QString::fromUtf8(aspect); p.description = QString::fromUtf8(desc); p.builtin = true;
        return p;
    };
    QList<Profile> l;
    Profile a; a.name = "Automatic (detect from first video)"; a.fps = "auto"; a.aspect = "auto";
    a.builtin = true; a.isAuto = true;
    a.description = "Profile will be automatically determined from the first video file added to the project.";
    l << a;
    l << mk("Full HD 1080p 23.98 fps", 1920, 1080, "16:9", "Standard Full HD.");
    l << mk("4K UHD 2160p 23.98 fps", 3840, 2160, "16:9", "Standard Ultra HD.");
    l << mk("4K Scope 2.40:1 23.98 fps", 3840, 1600, "2.40:1", "The most common UHD-width widescreen size. Divisible by 16.");
    l << mk("4K Scope 2.39:1 23.98 fps", 3840, 1608, "2.39:1", "The DCI Scope aspect ratio recalculated for 3840 width.");
    l << mk("4K CinemaScope 2.35:1 23.98 fps", 3840, 1634, "2.35:1", "The classic CinemaScope aspect ratio.");
    l << mk("4K Ultrawide 21:9 23.98 fps", 3840, 1620, "64:27 (21:9)", "The real aspect ratio of '21:9' TVs and monitors (64:27, 2.37:1).");
    l << mk("DCI 4K Scope 2.39:1 23.98 fps", 4096, 1716, "2.39:1", "The cinema (DCI) standard Scope size; 4096 wide.");
    return l;
}

QString ProfileStore::normalizeFps(const QString &fps) const
{
    const QString t = fps.trimmed();
    if (kFps.contains(t)) return t;
    bool ok = false;
    const double v = t.toDouble(&ok);
    if (!ok) return QString();
    for (const QString &s : kFps)
        if (qAbs(s.toDouble() - v) < 0.01) return s;   // "24.0" -> "24"
    return QString();
}

QStringList ProfileStore::supportedFps() const { return kFps; }

QString ProfileStore::aspectLabel(int w, int h) const
{
    if (w <= 0 || h <= 0) return QString();
    const int g = gcd(w, h);
    const int rn = w / g, rd = h / g;
    static const int known[][2] = {{16, 9}, {4, 3}, {1, 1}, {3, 2}, {16, 10}, {9, 16}, {21, 9}};
    for (const auto &k : known)
        if (rn == k[0] && rd == k[1]) return QString("%1:%2").arg(rn).arg(rd);
    if (w >= h) return QString("%1:1").arg(double(w) / h, 0, 'f', 2);
    return QString("1:%1").arg(double(h) / w, 0, 'f', 2);
}

QVariantMap ProfileStore::toMap(const Profile &p) const
{
    QVariantMap m;
    m["name"] = p.name; m["w"] = p.w; m["h"] = p.h; m["fps"] = p.fps;
    m["description"] = p.description;
    m["aspect"] = p.aspect.isEmpty() ? aspectLabel(p.w, p.h) : p.aspect;
    m["isAuto"] = p.isAuto; m["builtin"] = p.builtin;
    return m;
}

QVariantList ProfileStore::allProfiles() const
{
    QVariantList l;
    for (const Profile &p : builtins()) l << toMap(p);
    for (const Profile &p : m_custom) l << toMap(p);
    return l;
}

QVariantList ProfileStore::customProfiles() const
{
    QVariantList l;
    for (const Profile &p : m_custom) l << toMap(p);
    return l;
}

bool ProfileStore::nameTaken(const QString &name, const QString &exceptName) const
{
    const QString n = name.trimmed();
    for (const Profile &p : builtins())
        if (p.name.compare(n, Qt::CaseInsensitive) == 0) return true;
    for (const Profile &p : m_custom) {
        if (!exceptName.isEmpty() && p.name.compare(exceptName, Qt::CaseInsensitive) == 0) continue;
        if (p.name.compare(n, Qt::CaseInsensitive) == 0) return true;
    }
    return false;
}

QString ProfileStore::validate(const QString &nameIn, int w, int h, const QString &fps,
                               const QString &originalName) const
{
    const QString name = nameIn.trimmed();
    if (name.isEmpty()) return "Name must not be empty.";
    if (name.size() > 80) return "Name is too long (80 characters max).";
    if (nameTaken(name, originalName)) return "A profile with this name already exists.";
    if (w < 16 || w > 8192) return "Width must be between 16 and 8192.";
    if (h < 16 || h > 8192) return "Height must be between 16 and 8192.";
    if (w % 2) return "Width must be even (4:2:0 video needs even dimensions).";
    if (h % 2) return "Height must be even (4:2:0 video needs even dimensions).";
    if (normalizeFps(fps).isEmpty()) return "Unsupported frame rate.";
    return QString();
}

QString ProfileStore::addCustom(const QVariantMap &m)
{
    const QString err = validate(m.value("name").toString(), m.value("w").toInt(),
                                 m.value("h").toInt(), m.value("fps").toString());
    if (!err.isEmpty()) return err;
    Profile p;
    p.name = m.value("name").toString().trimmed();
    p.w = m.value("w").toInt(); p.h = m.value("h").toInt();
    p.fps = normalizeFps(m.value("fps").toString());
    p.description = m.value("description").toString().trimmed();
    m_custom << p;
    save();
    emit profilesChanged();
    return QString();
}

QString ProfileStore::updateCustom(const QString &originalName, const QVariantMap &m)
{
    int idx = -1;
    for (int i = 0; i < m_custom.size(); ++i)
        if (m_custom[i].name == originalName) { idx = i; break; }
    if (idx < 0) return "Profile not found (built-in profiles cannot be edited).";
    const QString err = validate(m.value("name").toString(), m.value("w").toInt(),
                                 m.value("h").toInt(), m.value("fps").toString(), originalName);
    if (!err.isEmpty()) return err;
    Profile &p = m_custom[idx];
    p.name = m.value("name").toString().trimmed();
    p.w = m.value("w").toInt(); p.h = m.value("h").toInt();
    p.fps = normalizeFps(m.value("fps").toString());
    p.description = m.value("description").toString().trimmed();
    save();
    emit profilesChanged();
    return QString();
}

bool ProfileStore::removeCustom(const QString &name)
{
    for (int i = 0; i < m_custom.size(); ++i) {
        if (m_custom[i].name == name) {
            m_custom.removeAt(i);
            save();
            emit profilesChanged();
            return true;
        }
    }
    return false;
}

QString ProfileStore::uniqueName(const QString &base) const
{
    if (!nameTaken(base, QString())) return base;
    for (int i = 2; i < 10000; ++i) {
        const QString c = QString("%1 %2").arg(base).arg(i);
        if (!nameTaken(c, QString())) return c;
    }
    return base;
}

QString ProfileStore::uniqueCopyName(const QString &name) const
{
    QString c = name + " (copy)";
    if (!nameTaken(c, QString())) return c;
    for (int i = 2; i < 10000; ++i) {
        c = QString("%1 (copy %2)").arg(name).arg(i);
        if (!nameTaken(c, QString())) return c;
    }
    return c;
}

int ProfileStore::findMatch(int w, int h, const QString &fps) const
{
    const QString nf = normalizeFps(fps);
    if (nf.isEmpty()) return -1;
    const QList<Profile> b = builtins();
    for (int i = 0; i < m_custom.size(); ++i)
        if (m_custom[i].w == w && m_custom[i].h == h && m_custom[i].fps == nf) return b.size() + i;
    for (int i = 0; i < b.size(); ++i)
        if (!b[i].isAuto && b[i].w == w && b[i].h == h && b[i].fps == nf) return i;
    return -1;
}

QString ProfileStore::ensureImportedProfile(int w, int h, const QString &fps)
{
    const QString nf = normalizeFps(fps);
    if (nf.isEmpty()) {
        qWarning() << "ProfileStore: not creating a profile for unsupported fps" << fps;
        return QString();
    }
    const int idx = findMatch(w, h, nf);
    if (idx >= 0) return allProfiles().at(idx).toMap().value("name").toString();
    QVariantMap m;
    m["name"] = uniqueName(QString("Kdenlive %1x%2 %3 fps").arg(w).arg(h).arg(nf));
    m["w"] = w; m["h"] = h; m["fps"] = nf;
    m["description"] = "Created by Kdenlive import.";
    const QString err = addCustom(m);
    if (!err.isEmpty()) {
        qWarning() << "ProfileStore: could not create imported profile:" << err;
        return QString();
    }
    return m["name"].toString();
}

void ProfileStore::load()
{
    m_custom.clear();
    QSettings s;
    const QByteArray json = s.value(kCustomKey).toString().toUtf8();
    if (json.isEmpty()) return;
    QJsonParseError pe;
    const QJsonDocument doc = QJsonDocument::fromJson(json, &pe);
    if (pe.error != QJsonParseError::NoError || !doc.isArray()) {
        qWarning() << "ProfileStore: ignoring unreadable profiles/custom:" << pe.errorString();
        return;
    }
    for (const QJsonValue &v : doc.array()) {
        const QJsonObject o = v.toObject();
        const QString name = o.value("name").toString().trimmed();
        const int w = o.value("w").toInt(), h = o.value("h").toInt();
        const QString fps = normalizeFps(o.value("fps").toString());
        // Same validation as add (name uniqueness is checked against what is
        // loaded so far, so duplicates in a hand-edited file are dropped).
        const QString err = validate(name, w, h, fps);
        if (!err.isEmpty()) {
            qWarning() << "ProfileStore: skipping invalid stored profile" << name << ":" << err;
            continue;
        }
        Profile p; p.name = name; p.w = w; p.h = h; p.fps = fps;
        p.description = o.value("description").toString();
        m_custom << p;
    }
}

void ProfileStore::save() const
{
    QJsonArray arr;
    for (const Profile &p : m_custom) {
        QJsonObject o;
        o["name"] = p.name; o["w"] = p.w; o["h"] = p.h; o["fps"] = p.fps;
        if (!p.description.isEmpty()) o["description"] = p.description;
        arr << o;
    }
    QSettings s;
    s.setValue(kCustomKey, QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact)));
}
