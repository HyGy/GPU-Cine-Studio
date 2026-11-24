#ifndef VIDEOOUTPUT_H
#define VIDEOOUTPUT_H

#include <QQuickItem>
#include <QRect>

class VideoSurfaceWindow;

class VideoOutput : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(WId windowId READ windowId NOTIFY windowIdChanged)

public:
    explicit VideoOutput(QQuickItem *parent = nullptr);
    ~VideoOutput();

    WId windowId() const { return m_windowId; }

signals:
    void windowIdChanged();
    void videoWindowShown();
    // Emitted right after the native surface was wiped black and
    // unmapped (e.g. the workspace page holding it was switched away
    // from). The owner of the GStreamer overlay sink should stop
    // feeding it - an overlay sink pointed at an invisible window keeps
    // decoding and blitting for nothing, and on some X/Xv drivers the
    // frames it keeps pushing are exactly what leaves a stale image
    // behind after the tab switch.
    void videoWindowHidden();
    // Emitted right after the native surface repainted itself black in
    // response to an X Expose/resize (VideoSurfaceWindow). Whoever owns
    // the GStreamer overlay sink needs to re-push its last frame
    // (gst_video_overlay_expose()) after this, or a paused/static frame
    // gets wiped by the repaint and never comes back until the next
    // buffer.
    void surfaceExposed();

protected:
    void componentComplete() override;
    void releaseResources() override;
    // QQuickItem::visibleChanged only fires for the item's OWN explicit
    // visible flag - NOT when an ancestor's visibility changes (e.g. a
    // StackLayout hiding a whole inactive workspace page). ItemVisibleHasChanged
    // reports the item's EFFECTIVE visibility (own flag AND all
    // ancestors), which is what's actually needed to hide/show the
    // native child window in step with the QML page it lives on.
    // ItemParentHasChanged/ItemSceneChange cover reparenting (e.g.
    // EditingWorkspace's editing<->effects layoutMode switch, which can
    // leave this item's own local x/y/width/height unchanged even
    // though its SCENE position changed completely) - without an
    // immediate geometry resync there, the native window stays mapped
    // at its old screen position for up to one frame.
    void itemChange(ItemChange change, const ItemChangeData &data) override;

private slots:
    void handleWindowChanged(QQuickWindow *window);
    void onVisibleChanged();

private:
    void createVideoWindow();
    // Recomputes this item's SCENE rect (mapToScene, not local x/y -
    // ancestor moves/reparents change the former without touching the
    // latter) and applies it to the native window only if it actually
    // changed, then re-evaluates show/hide. Connected to the
    // QQuickWindow's per-frame afterAnimating signal so it tracks
    // SplitView drags, StackLayout re-layout, and reparenting without
    // needing a dedicated signal for each possible cause.
    void updateGeometryNow();
    // Same geometry sync as updateGeometryNow(), but WITHOUT the
    // show/hide re-evaluation - used by updateVisibility() itself so
    // the two don't recurse into each other.
    void syncGeometry();
    void updateVisibility();

    VideoSurfaceWindow *m_videoWindow;
    WId m_windowId;
    QRect m_lastRect;
};

#endif // VIDEOOUTPUT_H
