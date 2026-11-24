#include "ColorSchemeWatcher.h"

#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusPendingCall>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusArgument>
#include <QDebug>

namespace {
constexpr const char *kPortalService = "org.freedesktop.portal.Desktop";
constexpr const char *kPortalPath = "/org/freedesktop/portal/desktop";
constexpr const char *kSettingsInterface = "org.freedesktop.portal.Settings";
constexpr const char *kAppearanceNamespace = "org.freedesktop.appearance";
constexpr const char *kColorSchemeKey = "color-scheme";

// The portal's value arrives single- or double-variant-wrapped
// depending on which method answered (ReadOne vs the deprecated Read)
// and which backend implements it - observed both shapes live via
// gdbus against xdg-desktop-portal-xapp on the dev machine. Unwrap
// defensively until a plain value falls out, rather than assuming one
// shape.
QVariant unwrapVariant(QVariant v)
{
    for (int guard = 0; guard < 4; ++guard) {
        if (v.canConvert<QDBusVariant>()) {
            v = v.value<QDBusVariant>().variant();
            continue;
        }
        if (v.userType() == qMetaTypeId<QDBusArgument>()) {
            QDBusArgument arg = v.value<QDBusArgument>();
            QVariant inner;
            arg >> inner;
            v = inner;
            continue;
        }
        break;
    }
    return v;
}
}

ColorSchemeWatcher::ColorSchemeWatcher(QObject *parent)
    : QObject(parent)
{
    QDBusConnection::sessionBus().connect(
        kPortalService, kPortalPath, kSettingsInterface, "SettingChanged",
        this, SLOT(onSettingChanged(QString,QString,QDBusVariant)));

    queryInitial();
}

void ColorSchemeWatcher::queryInitial()
{
    auto *iface = new QDBusInterface(kPortalService, kPortalPath, kSettingsInterface,
                                      QDBusConnection::sessionBus(), this);
    if (!iface->isValid()) {
        qInfo() << "ColorSchemeWatcher: portal not reachable on session bus"
                << "- staying on fallback mode (Dark)";
        iface->deleteLater();
        return;
    }

    QDBusPendingCall call = iface->asyncCall("ReadOne", kAppearanceNamespace, kColorSchemeKey);
    auto *watcher = new QDBusPendingCallWatcher(call, this);
    connect(watcher, &QDBusPendingCallWatcher::finished,
            this, &ColorSchemeWatcher::onReadOneFinished);
    iface->deleteLater();
}

void ColorSchemeWatcher::onReadOneFinished(QDBusPendingCallWatcher *watcher)
{
    watcher->deleteLater();
    QDBusPendingReply<QDBusVariant> reply = *watcher;

    if (reply.isError()) {
        if (reply.error().name() == QLatin1String("org.freedesktop.DBus.Error.UnknownMethod")) {
            // Older portal (< 1.17): ReadOne doesn't exist, retry with
            // the deprecated-but-universally-supported Read.
            auto *iface = new QDBusInterface(kPortalService, kPortalPath, kSettingsInterface,
                                              QDBusConnection::sessionBus(), this);
            QDBusPendingCall call = iface->asyncCall("Read", kAppearanceNamespace, kColorSchemeKey);
            auto *fallbackWatcher = new QDBusPendingCallWatcher(call, this);
            connect(fallbackWatcher, &QDBusPendingCallWatcher::finished,
                    this, &ColorSchemeWatcher::onReadFallbackFinished);
            iface->deleteLater();
        } else {
            qInfo() << "ColorSchemeWatcher: ReadOne failed:" << reply.error().message()
                    << "- staying on fallback mode (Dark)";
        }
        return;
    }

    applyColorSchemeValue(unwrapVariant(reply.value().variant()), "ReadOne");
}

void ColorSchemeWatcher::onReadFallbackFinished(QDBusPendingCallWatcher *watcher)
{
    watcher->deleteLater();
    QDBusPendingReply<QDBusVariant> reply = *watcher;

    if (reply.isError()) {
        qInfo() << "ColorSchemeWatcher: Read (fallback) failed too:" << reply.error().message()
                << "- staying on fallback mode (Dark)";
        return;
    }

    applyColorSchemeValue(unwrapVariant(reply.value().variant()), "Read");
}

void ColorSchemeWatcher::onSettingChanged(const QString &ns, const QString &key,
                                           const QDBusVariant &value)
{
    if (ns != QLatin1String(kAppearanceNamespace) || key != QLatin1String(kColorSchemeKey))
        return;
    applyColorSchemeValue(unwrapVariant(value.variant()), "SettingChanged signal");
}

void ColorSchemeWatcher::applyColorSchemeValue(const QVariant &value, const char *source)
{
    // 0 = no preference, 1 = prefer dark, 2 = prefer light (portal spec).
    // "no preference" maps to our own default (Dark), not to light.
    bool ok = false;
    const uint scheme = value.toUInt(&ok);
    const Theme::Mode newMode = (ok && scheme == 2) ? Theme::Mode::Light : Theme::Mode::Dark;

    qInfo() << "ColorSchemeWatcher: portal color-scheme via" << source << "=" << value
            << "-> detected mode" << (newMode == Theme::Mode::Light ? "Light" : "Dark");

    if (newMode != m_detectedMode) {
        m_detectedMode = newMode;
        emit detectedModeChanged();
    }
}
