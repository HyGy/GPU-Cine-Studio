#ifndef VIDEOCLIP_H
#define VIDEOCLIP_H

#include <QObject>
#include <QString>

class VideoClip : public QObject {
    Q_OBJECT
    
public:
    explicit VideoClip(const QString &filePath, QObject *parent = nullptr);
    
    QString filePath() const { return m_filePath; }
    qint64 startTime() const { return m_startTime; }
    qint64 endTime() const { return m_endTime; }
    qint64 duration() const { return m_endTime - m_startTime; }
    
    void setStartTime(qint64 time) { m_startTime = time; }
    void setEndTime(qint64 time) { m_endTime = time; }
    
private:
    QString m_filePath;
    qint64 m_startTime;
    qint64 m_endTime;
};

#endif // VIDEOCLIP_H
