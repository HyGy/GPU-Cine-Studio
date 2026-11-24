// Adapted from Qt's Basic style (QtQuick/Controls/Basic/MenuBar.qml,
// Copyright (C) 2017 The Qt Company Ltd., SPDX-License-Identifier:
// LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only).
//
// Why this file has to exist even though GCSStyle/MenuBarItem.qml
// already exists: Basic's own MenuBar.qml (the one GCSStyle fell back
// to, since GCSStyle didn't provide a MenuBar.qml of its own) declares
// `delegate: MenuBarItem {}` - and because that reference lives INSIDE
// the Basic module's own qmldir scope, it resolves to Basic's OWN
// MenuBarItem.qml directly, not through the active-style selection
// mechanism. Confirmed live: GCSStyle/MenuBarItem.qml's background was
// given an unmistakable diagnostic magenta color and it never
// appeared - the rendered color stayed Qt's auto-derived
// control.palette.mid (~#b8b8b8), which is exactly Basic's own
// MenuBarItem.qml's hover/down background. Providing our own
// MenuBar.qml here means ITS `delegate: MenuBarItem {}` resolves
// within OUR module's scope instead, finally reaching our file.

import QtQuick
import QtQuick.Templates as T
import VideoEditor 1.0

T.MenuBar {
    id: control

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                            contentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset,
                             contentHeight + topPadding + bottomPadding)

    delegate: MenuBarItem { }

    contentItem: Row {
        spacing: control.spacing
        Repeater {
            model: control.contentModel
        }
    }

    background: Rectangle {
        implicitHeight: 20
        color: Theme.windowBackground
    }
}
