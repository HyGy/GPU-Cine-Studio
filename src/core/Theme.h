#ifndef THEME_H
#define THEME_H

#include <QObject>
#include <QColor>
#include <QPalette>

// Single source of truth for every color in the app, QML and C++ alike.
//
// Background: Qt Quick Controls has no single palette-resolution path -
// different control types read from different internal QQuickTheme
// "scopes" (Button, ComboBox, Menu, MenuBar, ...), seeded independently
// from the host's QPlatformTheme. A fixed QPalette set once via
// QGuiApplication::setPalette() does not reliably reach all of them -
// confirmed live: MenuBar's "File"/"Help" labels stayed black in the
// AppImage (no bundled platform-theme plugin) even after a ToolButton
// elsewhere was fixed by the exact same palette, because the two read
// from different scopes. See the custom style files under
// src/ui/styles/ - those read Theme.* directly, bypassing the
// per-scope ambiguity entirely for whichever controls they cover.
//
// This class owns one QPalette (for the controls not yet migrated to
// the custom style) built from the SAME token table QML reads, so
// there is never a second, drifting source of truth.
class Theme : public QObject
{
    Q_OBJECT
    Q_PROPERTY(Mode mode READ mode WRITE setMode NOTIFY modeChanged)

    Q_PROPERTY(QColor windowBackground READ windowBackground NOTIFY colorsChanged)
    Q_PROPERTY(QColor panelBackground READ panelBackground NOTIFY colorsChanged)
    Q_PROPERTY(QColor listBackground READ listBackground NOTIFY colorsChanged)
    Q_PROPERTY(QColor alternateBackground READ alternateBackground NOTIFY colorsChanged)
    Q_PROPERTY(QColor border READ border NOTIFY colorsChanged)
    Q_PROPERTY(QColor textPrimary READ textPrimary NOTIFY colorsChanged)
    Q_PROPERTY(QColor textSecondary READ textSecondary NOTIFY colorsChanged)
    Q_PROPERTY(QColor textDisabled READ textDisabled NOTIFY colorsChanged)
    Q_PROPERTY(QColor accent READ accent NOTIFY colorsChanged)
    Q_PROPERTY(QColor accentText READ accentText NOTIFY colorsChanged)
    Q_PROPERTY(QColor buttonBackground READ buttonBackground NOTIFY colorsChanged)
    Q_PROPERTY(QColor warning READ warning NOTIFY colorsChanged)

public:
    // System: follow ColorSchemeWatcher's detection (wired up in a later
    // phase - see project plan). Light/Dark: explicit, user-forced via
    // the eventual Settings override. Pinned to Dark for now everywhere
    // this is constructed.
    enum class Mode { System, Light, Dark };
    Q_ENUM(Mode)

    explicit Theme(QObject *parent = nullptr);

    Mode mode() const { return m_mode; }
    void setMode(Mode mode);

    QColor windowBackground() const { return m_colors.windowBackground; }
    QColor panelBackground() const { return m_colors.panelBackground; }
    QColor listBackground() const { return m_colors.listBackground; }
    QColor alternateBackground() const { return m_colors.alternateBackground; }
    QColor border() const { return m_colors.border; }
    QColor textPrimary() const { return m_colors.textPrimary; }
    QColor textSecondary() const { return m_colors.textSecondary; }
    QColor textDisabled() const { return m_colors.textDisabled; }
    QColor accent() const { return m_colors.accent; }
    QColor accentText() const { return m_colors.accentText; }
    QColor buttonBackground() const { return m_colors.buttonBackground; }
    QColor warning() const { return m_colors.warning; }

    // QPalette built from the same table above, for any control still
    // relying on control.palette.* (i.e. not yet covered by a custom
    // style file). Role mapping mirrors the hand-written QPalette this
    // class replaced in main.cpp.
    QPalette palette() const;

signals:
    void modeChanged();
    void colorsChanged();

private:
    struct ColorSet {
        QColor windowBackground;
        QColor panelBackground;
        QColor listBackground;
        QColor alternateBackground;
        QColor border;
        QColor textPrimary;
        QColor textSecondary;
        QColor textDisabled;
        QColor accent;
        QColor accentText;
        QColor buttonBackground;
        QColor warning;
        // Shade ramp for QPalette::Light/Midlight/Mid/Dark/Shadow only -
        // consumed by Qt's own styles, never by our QML, hence no
        // Q_PROPERTY. See Theme.cpp's palette() for why these have to be
        // set rather than left to Qt's per-scope derivation.
        QColor shadeLight;
        QColor shadeMidlight;
        QColor shadeMid;
        QColor shadeDark;
        QColor shadow;
    };

    static ColorSet darkColors();

    void rebuild();

    Mode m_mode = Mode::Dark;
    ColorSet m_colors;
};

#endif // THEME_H
