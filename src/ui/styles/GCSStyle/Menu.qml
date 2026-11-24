// Adapted from Qt's Basic style (QtQuick/Controls/Basic/Menu.qml,
// Copyright (C) 2017 The Qt Company Ltd., SPDX-License-Identifier:
// LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only)
// with control.palette.* replaced by Theme.* - see MenuBarItem.qml's
// comment in this same directory for why. This specifically fixes a
// white border around open dropdown menus in the AppImage build: the
// original reads control.palette.dark for the border, which Qt
// auto-derives from the Button palette role when not set explicitly -
// that auto-derivation differs between packaging forms for the same
// reason MenuBarItem's text color did.

import QtQuick
import QtQuick.Controls
import QtQuick.Controls.impl
import QtQuick.Templates as T
import VideoEditor 1.0

T.Menu {
    id: control

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                            contentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset,
                             contentHeight + topPadding + bottomPadding)

    margins: 0
    padding: 1
    overlap: 2

    delegate: MenuItem { }

    contentItem: ListView {
        implicitHeight: contentHeight
        model: control.contentModel
        interactive: Window.window
                        ? contentHeight + control.topPadding + control.bottomPadding > Window.window.height
                        : false
        clip: true
        currentIndex: control.currentIndex

        ScrollIndicator.vertical: ScrollIndicator {}
    }

    background: Rectangle {
        implicitWidth: 200
        implicitHeight: 20
        color: Theme.panelBackground
        border.color: Theme.border
    }

    T.Overlay.modal: Rectangle {
        color: Color.transparent(Theme.windowBackground, 0.5)
    }

    T.Overlay.modeless: Rectangle {
        color: Color.transparent(Theme.windowBackground, 0.12)
    }
}
