#include "Theme.h"

Theme::Theme(QObject *parent)
    : QObject(parent)
{
    rebuild();
}

void Theme::setMode(Mode mode)
{
    if (m_mode == mode) return;
    m_mode = mode;
    rebuild();
    emit modeChanged();
}

void Theme::rebuild()
{
    // Light table and System (portal-driven) resolution land in a later
    // phase - see project plan. Every mode resolves to the dark table
    // for now, which keeps this a no-op refactor of the previous
    // hand-written QPalette in main.cpp.
    m_colors = darkColors();
    emit colorsChanged();
}

Theme::ColorSet Theme::darkColors()
{
    ColorSet c;
    c.windowBackground   = QColor("#202326");
    c.panelBackground    = QColor("#31363b");
    c.listBackground     = QColor("#141618");
    c.alternateBackground = QColor("#1a1d1f");
    c.border             = QColor("#5d6066");
    c.textPrimary        = QColor("#eff0f1");
    c.textSecondary      = QColor("#aaaaaa");
    c.textDisabled       = QColor("#6b6f72");
    c.accent             = QColor("#3daee9");
    c.accentText         = QColor("#eff0f1");
    c.buttonBackground   = QColor("#31363b");
    c.warning            = QColor("#e0a030");
    // Shade ramp, only ever consumed through palette() below - Qt's own
    // styles use QPalette::Light/Midlight/Mid/Dark/Shadow for frame
    // edges, scroll-bar handles, split-view handles, popup borders and
    // drop shadows. Nothing in our QML reads these, so they are not
    // exposed as Theme.* tokens; they exist so those roles are OURS
    // instead of whatever Qt derives per control scope (see palette()).
    c.shadeLight         = QColor("#4a5057");
    c.shadeMidlight      = QColor("#3c4248");
    c.shadeMid           = QColor("#5d6066");
    c.shadeDark          = QColor("#15181a");
    c.shadow             = QColor("#000000");
    return c;
}

QPalette Theme::palette() const
{
    // Every role any built-in style actually reads must be set here
    // EXPLICITLY. Rationale, the hard way: QT_QPA_PLATFORMTHEME is
    // forced empty in main.cpp, so this palette is the only input left -
    // and any role left unset does not stay "neutral", it gets resolved
    // per control scope from whatever default palette that scope was
    // seeded with. Measured live in one single app run before this was
    // fixed: palette.dark came out #212121 on the MenuBar's items but
    // #bebebe (near-white, on a dark UI) on the toolbar's buttons.
    // Unset roles are therefore not "unused" roles, they are
    // nondeterministic ones - which is why the role set below is
    // derived from the actual grep of control.palette.* uses in
    // QtQuick/Controls/{Basic,Fusion}/*.qml rather than from whatever
    // the old hand-written palette in main.cpp happened to list.
    QPalette p;
    p.setColor(QPalette::Window, m_colors.windowBackground);
    p.setColor(QPalette::WindowText, m_colors.textPrimary);
    p.setColor(QPalette::Base, m_colors.listBackground);
    p.setColor(QPalette::AlternateBase, m_colors.alternateBackground);
    p.setColor(QPalette::ToolTipBase, m_colors.panelBackground);
    p.setColor(QPalette::ToolTipText, m_colors.textPrimary);
    p.setColor(QPalette::Text, m_colors.textPrimary);
    p.setColor(QPalette::Button, m_colors.buttonBackground);
    p.setColor(QPalette::ButtonText, m_colors.textPrimary);
    // NOT Qt::red (what this role was carried forward as from the old
    // main.cpp palette). BrightText is not a "danger" color: Basic's
    // TabButton paints INACTIVE tab text with it and Basic's
    // DelayButton uses it for its progress label, so red here showed up
    // as a red "Properties" tab in the Logging workspace. Secondary
    // text is what an inactive tab label should look like.
    p.setColor(QPalette::BrightText, m_colors.textSecondary);
    p.setColor(QPalette::Link, m_colors.accent);
    p.setColor(QPalette::Highlight, m_colors.accent);
    p.setColor(QPalette::HighlightedText, m_colors.accentText);
    // Fusion's TextField/TextArea bind placeholderTextColor straight to
    // this; left unset it is derived from the DEFAULT palette's text
    // color (not from ours), i.e. it can land near-black on our dark
    // Base - the Media Browser path field is a live example.
    p.setColor(QPalette::PlaceholderText, m_colors.textDisabled);
    p.setColor(QPalette::Light, m_colors.shadeLight);
    p.setColor(QPalette::Midlight, m_colors.shadeMidlight);
    p.setColor(QPalette::Mid, m_colors.shadeMid);
    p.setColor(QPalette::Dark, m_colors.shadeDark);
    p.setColor(QPalette::Shadow, m_colors.shadow);
    p.setColor(QPalette::Disabled, QPalette::WindowText, m_colors.textDisabled);
    p.setColor(QPalette::Disabled, QPalette::Text, m_colors.textDisabled);
    p.setColor(QPalette::Disabled, QPalette::ButtonText, m_colors.textDisabled);
    p.setColor(QPalette::Disabled, QPalette::BrightText, m_colors.textDisabled);
    // A disabled-but-selected row must not keep the full accent fill -
    // it reads as "active" otherwise.
    p.setColor(QPalette::Disabled, QPalette::Highlight, m_colors.buttonBackground);
    p.setColor(QPalette::Disabled, QPalette::HighlightedText, m_colors.textDisabled);
    return p;
}
