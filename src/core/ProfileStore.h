#ifndef PROFILESTORE_H
#define PROFILESTORE_H

#include <QObject>
#include <QVariantList>
#include <QVariantMap>
#include <QStringList>

// Single owner of the project-profile list (resolution + frame rate presets).
//
//  * Built-in profiles are compiled in and read-only.
//  * Custom profiles are stored GLOBALLY (not per project) as a JSON array
//    under the QSettings key "profiles/custom". Every mutation is written
//    immediately - independent of any dialog's OK/Cancel.
//  * Projects never reference a profile by name: they store the numbers
//    (project/width, project/height, project/fps), so editing or deleting a
//    profile never changes a project.
//
// Profile maps handed to QML: name, w, h, fps (string), aspect, description,
// isAuto, builtin.
class ProfileStore : public QObject
{
    Q_OBJECT
public:
    explicit ProfileStore(QObject *parent = nullptr);

    // Built-ins first (Automatic is index 0), then custom profiles.
    Q_INVOKABLE QVariantList allProfiles() const;
    Q_INVOKABLE QVariantList customProfiles() const;

    // The frame-rate strings TimelineEngine::setClips() actually understands.
    Q_INVOKABLE QStringList supportedFps() const;

    // "" when valid, otherwise a human-readable English error.
    // originalName: the profile's current name when editing (so keeping its
    // own name is allowed); empty for add/duplicate/import.
    Q_INVOKABLE QString validate(const QString &name, int w, int h,
                                 const QString &fps,
                                 const QString &originalName = QString()) const;

    // Return "" on success, otherwise the validation error.
    Q_INVOKABLE QString addCustom(const QVariantMap &profile);
    Q_INVOKABLE QString updateCustom(const QString &originalName, const QVariantMap &profile);
    Q_INVOKABLE bool removeCustom(const QString &name);

    // "<name> (copy)", "<name> (copy 2)", ... first one not taken.
    Q_INVOKABLE QString uniqueCopyName(const QString &name) const;
    // Same idea for an arbitrary base name (appends " 2", " 3" ...).
    Q_INVOKABLE QString uniqueName(const QString &base) const;

    Q_INVOKABLE QString aspectLabel(int w, int h) const;
    Q_INVOKABLE QString normalizeFps(const QString &fps) const; // "" if unsupported

    // Index into allProfiles() of the profile with exactly these values
    // (custom wins over built-in on an exact match; first otherwise), or -1.
    Q_INVOKABLE int findMatch(int w, int h, const QString &fps) const;

    // Kdenlive import: if no profile has exactly these values, add a custom
    // "Kdenlive <W>x<H> <fps> fps" one. Returns the profile name that now
    // matches ("" if nothing matched and creation failed).
    Q_INVOKABLE QString ensureImportedProfile(int w, int h, const QString &fps);

signals:
    void profilesChanged();

private:
    struct Profile { QString name; int w = 0; int h = 0; QString fps; QString description; QString aspect; bool builtin = false; bool isAuto = false; };
    static QList<Profile> builtins();
    QVariantMap toMap(const Profile &p) const;
    bool nameTaken(const QString &name, const QString &exceptName) const;
    void load();
    void save() const;

    QList<Profile> m_custom;
};

#endif
