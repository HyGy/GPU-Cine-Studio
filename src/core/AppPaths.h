#pragma once
#include <QDir>
#include <QStandardPaths>
#include <QString>

// The app's per-user config directory: <XDG_CONFIG_HOME>/gpu-cine-studio.
// Spelled out explicitly because QStandardPaths::AppConfigLocation would
// become <config>/<organization>/<app> (gpu-cine-studio/gpu-cine-studio)
// once QCoreApplication::setOrganizationName() is set, and it is also
// empty-appName before the QGuiApplication exists. QSettings (org + app
// name "gpu-cine-studio") lands in the same folder.
namespace AppPaths {
inline QString configDir()
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation)
           + QStringLiteral("/gpu-cine-studio");
}
}
