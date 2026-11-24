#ifndef COLORSCHEMEWATCHER_H
#define COLORSCHEMEWATCHER_H

#include <QObject>
#include <QDBusVariant>
#include "Theme.h"

class QDBusPendingCallWatcher;

// Queries the freedesktop.org XDG Desktop Portal (org.freedesktop.portal.
// Settings, namespace org.freedesktop.appearance, key color-scheme) for
// the user's configured light/dark preference, over the session D-Bus.
//
// Why this instead of Qt's own platform-theme detection: Qt 6.4.2 (what
// this project builds against) has no QStyleHints::colorScheme() - that
// landed in Qt 6.5. Even on a newer Qt, relying on it would reintroduce
// the exact .deb-vs-AppImage divergence this class exists to avoid: the
// .deb runs against whatever Qt the host ships, the AppImage bundles a
// fixed version - two different detection mechanisms, two chances to
// disagree. Querying the portal directly, with our own code, behaves
// identically regardless of packaging or installed Qt version.
//
// Verified live against this dev machine's Cinnamon/Mint session
// (xdg-desktop-portal + xdg-desktop-portal-xapp): the portal answers
// "prefer-dark" correctly. NOT verified: that every tester's desktop
// has a working portal backend for this namespace - a bare WM, a KDE
// install without xdg-desktop-portal-kde, or a container may have none
// at all, or answer with "no preference". Both cases, and any D-Bus
// error, fall back to Dark (the app's existing default) rather than
// leaving the UI in an undetermined state. A manual override in
// Settings (later phase) always wins over this regardless.
//
// All calls are asynchronous - a cold D-Bus activation of
// xdg-desktop-portal can take real time, and this must never block
// app startup or hang on a broken/absent portal.
class ColorSchemeWatcher : public QObject
{
    Q_OBJECT
    Q_PROPERTY(Theme::Mode detectedMode READ detectedMode NOTIFY detectedModeChanged)

public:
    explicit ColorSchemeWatcher(QObject *parent = nullptr);

    Theme::Mode detectedMode() const { return m_detectedMode; }

signals:
    void detectedModeChanged();

private slots:
    void onReadOneFinished(QDBusPendingCallWatcher *watcher);
    void onReadFallbackFinished(QDBusPendingCallWatcher *watcher);
    void onSettingChanged(const QString &ns, const QString &key, const QDBusVariant &value);

private:
    void queryInitial();
    void applyColorSchemeValue(const QVariant &value, const char *source);

    Theme::Mode m_detectedMode = Theme::Mode::Dark;
};

#endif // COLORSCHEMEWATCHER_H
