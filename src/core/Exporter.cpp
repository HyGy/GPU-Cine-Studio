#include "Exporter.h"
#include <QDebug>

Exporter::Exporter(QObject *parent) : QObject(parent) {
}

void Exporter::exportVideo(const QString &outputPath) {
    // TODO: Implement NVENC export
}
