#include "VideoClip.h"

VideoClip::VideoClip(const QString &filePath, QObject *parent)
    : QObject(parent)
    , m_filePath(filePath)
    , m_startTime(0)
    , m_endTime(0)
{
}
