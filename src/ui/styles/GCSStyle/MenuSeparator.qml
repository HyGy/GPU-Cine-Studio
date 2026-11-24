// Adapted from Qt's Basic style (QtQuick/Controls/Basic/MenuSeparator.qml,
// Copyright (C) 2017 The Qt Company Ltd., SPDX-License-Identifier:
// LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only)
// with control.palette.* replaced by Theme.* - see MenuBarItem.qml's
// comment in this same directory for why.

import QtQuick
import QtQuick.Controls.impl
import QtQuick.Templates as T
import VideoEditor 1.0

T.MenuSeparator {
    id: control

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                            implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset,
                             implicitContentHeight + topPadding + bottomPadding)

    padding: 5
    verticalPadding: 1

    contentItem: Rectangle {
        implicitWidth: 188
        implicitHeight: 1
        color: Theme.border
    }
}
