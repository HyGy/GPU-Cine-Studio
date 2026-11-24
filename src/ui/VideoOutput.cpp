#include "VideoOutput.h"
#include <QQuickWindow>
#include <QDebug>
#include <QTimer>
#include <QBackingStore>
#include <QPainter>
#include <QExposeEvent>
#include <QResizeEvent>
#include <QScopedPointer>
#include <functional>

// A bare QWindow never receives expose-driven repaint on its own - the
// base class has no exposeEvent handling, and nothing here previously
// painted it while it was actually mapped (the old paintBlack() ran
// either right before show() or while the window was hidden by a
// workspace switch; X11 discards output written to an unmapped window,
// and Qt's xcb backend creates windows with back_pixmap=None, so the
// server never clears them either). Confirmed live: this left genuine
// leftover pixels from whatever was previously on screen in that exact
// rectangle, redrawn every single time the window got (re)mapped.
//
// This subclass paints exactly when X actually asks for it (expose)
// and when the backing store needs to match a new size (resize) - the
// only two moments a paint can't be silently discarded.
class VideoSurfaceWindow : public QWindow {
public:
    explicit VideoSurfaceWindow(QWindow *parent = nullptr)
        : QWindow(parent)
    {
        setSurfaceType(QWindow::RasterSurface);
    }

    // Plain callback instead of a Qt signal - this class is defined
    // entirely in this .cpp with no moc step, so Q_OBJECT isn't
    // available here without extra build wiring.
    std::function<void()> onExposedPainted;

    // Wipe the surface to black WHILE IT IS STILL MAPPED. Must be
    // called before hide(), never after: X discards drawing to an
    // unmapped window, so a post-hide clear is a no-op and whatever the
    // overlay sink last blitted (or keyed onto a hardware video plane)
    // stays on screen.
    void clearNow() {
        if (isExposed()) paintBlack();
    }

protected:
    void exposeEvent(QExposeEvent *event) override {
        Q_UNUSED(event)
        if (isExposed()) {
            paintBlack();
            if (onExposedPainted) onExposedPainted();
        }
    }

    void resizeEvent(QResizeEvent *event) override {
        QWindow::resizeEvent(event);
        if (isExposed()) {
            paintBlack();
            if (onExposedPainted) onExposedPainted();
        }
    }

private:
    void paintBlack() {
        if (!handle()) return;
        QSize sz = size();
        if (sz.isEmpty()) return;

        if (!m_backingStore) {
            m_backingStore.reset(new QBackingStore(this));
        }
        m_backingStore->resize(sz);
        QRect rect(QPoint(0, 0), sz);
        m_backingStore->beginPaint(rect);
        QPainter painter(m_backingStore->paintDevice());
        painter.fillRect(rect, Qt::black);
        painter.end();
        m_backingStore->endPaint();
        m_backingStore->flush(rect);
    }

    QScopedPointer<QBackingStore> m_backingStore;
};

VideoOutput::VideoOutput(QQuickItem *parent)
    : QQuickItem(parent)
    , m_videoWindow(nullptr)
    , m_windowId(0)
{
    // FONTOS: Kikapcsoljuk az ItemHasContents flaget, mert mi nem rajzolunk a
    // QML Scene Graph-ba, hanem egy natív ablakot teszünk fölé.
    setFlag(ItemHasContents, false);

    connect(this, &QQuickItem::windowChanged, this, &VideoOutput::handleWindowChanged);
    connect(this, &QQuickItem::visibleChanged, this, &VideoOutput::onVisibleChanged);
}

VideoOutput::~VideoOutput() {
    if (m_videoWindow) {
        m_videoWindow->close();
        m_videoWindow->deleteLater();
    }
}

void VideoOutput::componentComplete() {
    QQuickItem::componentComplete();
}

void VideoOutput::releaseResources() {
    if (m_videoWindow) {
        m_videoWindow->deleteLater();
        m_videoWindow = nullptr;
        m_windowId = 0;
        // Without this, QML consumers (e.g. ProjectMonitor's
        // onWindowIdChanged) never learn the native window is gone, and
        // whichever engine they last pushed this id into keeps holding a
        // handle to an already-destroyed X window.
        emit windowIdChanged();

        // releaseResources() can fire from a scene-graph invalidation
        // (window hide/minimize, context loss) without this QQuickItem
        // itself being destroyed or re-parented - in that case
        // windowChanged() never fires again, so createVideoWindow() (only
        // ever triggered from handleWindowChanged()) would otherwise
        // never run again and this VideoOutput would be permanently blind
        // for the rest of the session. Re-arm it the same way
        // handleWindowChanged() does, if the item is still attached to a
        // window at all. Safe even if `this` is destroyed before the
        // timer fires - Qt's singleShot(ms, context, slot) overload ties
        // the connection to the context object's lifetime.
        if (window()) {
            QTimer::singleShot(50, this, &VideoOutput::createVideoWindow);
        }
    }
    QQuickItem::releaseResources();
}

void VideoOutput::handleWindowChanged(QQuickWindow *window) {
    if (window && !m_videoWindow) {
        QTimer::singleShot(50, this, &VideoOutput::createVideoWindow);
    }
}

void VideoOutput::createVideoWindow() {
    if (m_videoWindow || !window()) {
        return;
    }

    if (width() <= 10 || height() <= 10) {
        // Újrapróbálkozás később
        QTimer::singleShot(100, this, &VideoOutput::createVideoWindow);
        return;
    }

    m_videoWindow = new VideoSurfaceWindow();
    m_videoWindow->setFlags(Qt::FramelessWindowHint | Qt::SubWindow);

    QQuickWindow *parentWindow = window();
    if (parentWindow) {
        m_videoWindow->setParent(parentWindow);
    }

    m_videoWindow->onExposedPainted = [this]() {
        emit surfaceExposed();
    };

    m_videoWindow->create();
    m_windowId = m_videoWindow->winId();

    qDebug() << "VideoOutput: Created Native Window ID:" << m_windowId;

    // Per-frame geometry resync - covers SplitView drags, StackLayout
    // re-layout on page activation, and reparenting (e.g.
    // EditingWorkspace's editing<->effects layoutMode switch), none of
    // which necessarily change THIS item's own local x/y/width/height
    // (mapToScene depends on every ancestor's position too). Cheap:
    // syncGeometry() early-outs when the computed rect hasn't changed.
    if (parentWindow) {
        connect(parentWindow, &QQuickWindow::afterAnimating, this, &VideoOutput::updateGeometryNow, Qt::UniqueConnection);
    }

    updateGeometryNow();

    emit windowIdChanged();
}

void VideoOutput::syncGeometry() {
    if (!m_videoWindow || !window()) return;
    if (width() <= 0 || height() <= 0) return;

    QPointF scenePos = mapToScene(QPointF(0, 0));
    QRect rect(scenePos.toPoint(), QSize(static_cast<int>(width()), static_cast<int>(height())));

    if (rect.isValid() && rect != m_lastRect) {
        m_lastRect = rect;
        m_videoWindow->setGeometry(rect);
    }
}

void VideoOutput::updateGeometryNow() {
    syncGeometry();
    updateVisibility();
}

void VideoOutput::updateVisibility() {
    if (!m_videoWindow) return;

    // Always resync geometry right before a show() decision - the
    // window must never be mapped at a stale rectangle, even for a
    // single frame.
    syncGeometry();

    bool shouldShow = isVisible() && width() > 1 && height() > 1 && opacity() > 0;

    if (shouldShow && !m_videoWindow->isVisible()) {
        m_videoWindow->show();
        // Both monitors' native windows are siblings under the same
        // top-level QWindow (Logging and Editing workspaces are both
        // kept alive by the StackLayout's Loaders) - X stacking order
        // is fixed at creation/reparent time and a plain MapWindow
        // doesn't restack, so raise() is what makes the CURRENTLY
        // visible one deterministically topmost instead of whichever
        // was created later.
        m_videoWindow->raise();
        emit videoWindowShown();
    } else if (!shouldShow && m_videoWindow->isVisible()) {
        // Order matters. Clear to black first (the window is still
        // mapped, so the clear actually reaches the server and, on
        // colour-key Xv adaptors, removes the keyed region that the
        // video plane was showing through), THEN unmap, and only then
        // tell the QML side so it can stop the pipeline from pushing
        // more frames at a surface nobody can see.
        m_videoWindow->clearNow();
        m_videoWindow->hide();
        emit videoWindowHidden();
    }
}

void VideoOutput::onVisibleChanged() {
    updateVisibility();
}

void VideoOutput::itemChange(ItemChange change, const ItemChangeData &data) {
    QQuickItem::itemChange(change, data);
    switch (change) {
    case ItemVisibleHasChanged:
        updateVisibility();
        break;
    case ItemParentHasChanged:
    case ItemSceneChange:
        updateGeometryNow();
        break;
    default:
        break;
    }
}
