#include "ProjectSettings.h"

#include <QHash>
#include <QMutex>
#include <QMutexLocker>

namespace ProjectSettings {

namespace {
QHash<QString, QVariant> g_values;
QMutex g_mutex;
}

bool isProjectKey(const QString &key)
{
    return key.startsWith(QLatin1String("project/"));
}

QVariant value(const QString &key, const QVariant &defaultValue)
{
    QMutexLocker locker(&g_mutex);
    return g_values.value(key, defaultValue);
}

void setValue(const QString &key, const QVariant &value)
{
    QMutexLocker locker(&g_mutex);
    g_values.insert(key, value);
}

bool contains(const QString &key)
{
    QMutexLocker locker(&g_mutex);
    return g_values.contains(key);
}

void clear()
{
    QMutexLocker locker(&g_mutex);
    g_values.clear();
}

} // namespace ProjectSettings
