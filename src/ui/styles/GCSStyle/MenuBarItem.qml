// Adapted from Qt's Basic style (QtQuick/Controls/Basic/MenuBarItem.qml,
// Copyright (C) 2017 The Qt Company Ltd., SPDX-License-Identifier:
// LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only)
// with control.palette.* replaced by Theme.* - see src/core/Theme.h for
// why: Qt Quick Controls has no single palette-resolution path, and
// MenuBar's own internal scope specifically stayed broken in the
// AppImage build (black "File"/"Help" labels) even after every other
// control was fixed via QGuiApplication::setPalette(). This file
// bypasses that ambiguity for MenuBarItem by never touching
// control.palette at all - colors come directly from the single Theme
// singleton instead, identically regardless of packaging or host.
//
// The sizes here (padding, icon size, background implicit size) were
// re-taken from Fusion's originals rather than Basic's, in every file
// in this directory: Basic is built around a ~40px control height and
// Fusion around ~20px, and main.cpp pins Fusion as the fallback style
// for everything this directory does NOT cover. Keeping Basic's
// metrics would leave the menu bar towering over the rest of the UI.

import QtQuick
import QtQuick.Templates as T
import QtQuick.Controls.impl
import VideoEditor 1.0

T.MenuBarItem {
    id: control

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                            implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset,
                             implicitContentHeight + topPadding + bottomPadding,
                             implicitIndicatorHeight + topPadding + bottomPadding)

    spacing: 6
    padding: 6

    icon.width: 16
    icon.height: 16
    icon.color: control.enabled ? Theme.textPrimary : Theme.textDisabled

    contentItem: IconLabel {
        spacing: control.spacing
        mirrored: control.mirrored
        display: control.display
        alignment: Qt.AlignLeft

        icon: control.icon
        text: control.text
        font: control.font
        color: control.enabled ? Theme.textPrimary : Theme.textDisabled
    }

    background: Rectangle {
        implicitWidth: 20
        implicitHeight: 20
        color: control.down || control.highlighted ? Theme.accent : "transparent"
    }
}
