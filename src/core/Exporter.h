#ifndef EXPORTER_H
#define EXPORTER_H

#include <QObject>
#include <QString>

class Exporter : public QObject {
    Q_OBJECT
    
public:
    explicit Exporter(QObject *parent = nullptr);
    
    Q_INVOKABLE void exportVideo(const QString &outputPath);
    
signals:
    void progressChanged(int percent);
    void exportFinished();
    void exportError(const QString &message);
    
private:
    // TODO: GStreamer export pipeline
};

#endif // EXPORTER_H
