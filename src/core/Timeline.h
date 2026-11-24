#ifndef TIMELINE_H
#define TIMELINE_H

#include <QObject>
#include <QVector>
#include "VideoClip.h"

class Timeline : public QObject {
    Q_OBJECT
    
public:
    explicit Timeline(QObject *parent = nullptr);
    
    void addClip(VideoClip *clip);
    void removeClip(int index);
    VideoClip* getClip(int index);
    int clipCount() const;
    
private:
    QVector<VideoClip*> m_clips;
};

#endif // TIMELINE_H
