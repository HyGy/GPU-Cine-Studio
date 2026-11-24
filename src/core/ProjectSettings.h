#pragma once
#include <QString>
#include <QVariant>

// A nyitott projekt beállításai ("project/..." kulcsok). Szándékosan a folyamat
// memóriájában élnek és NEM a közös QSettings-fájlban: így két párhuzamosan
// futó app-példány nem látja és nem írja felül egymás projektjét.
namespace ProjectSettings {
    bool isProjectKey(const QString &key);                       // key.startsWith("project/")
    QVariant value(const QString &key, const QVariant &defaultValue = QVariant());
    void setValue(const QString &key, const QVariant &value);
    bool contains(const QString &key);
    void clear();
}
