#include "Timeline.h"

Timeline::Timeline(QObject *parent) : QObject(parent) {
}

void Timeline::addClip(VideoClip *clip) {
    m_clips.append(clip);
}

void Timeline::removeClip(int index) {
    if (index >= 0 && index < m_clips.size()) {
        m_clips.removeAt(index);
    }
}

VideoClip* Timeline::getClip(int index) {
    if (index >= 0 && index < m_clips.size()) {
        return m_clips[index];
    }
    return nullptr;
}

int Timeline::clipCount() const {
    return m_clips.size();
}
