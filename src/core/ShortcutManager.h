#ifndef SHORTCUTMANAGER_H
#define SHORTCUTMANAGER_H

#include <QObject>
#include <QHash>
#include <QPointer>
#include <QSet>
#include <QStringList>
#include <QVariantList>
#include <QVector>

#include <QQuickItem>
#include <QQuickWindow>

// The ONE registry of the application's keyboard shortcuts (plan_shortcuts.md).
//
// - Static action table (id, title, category, scope, autoRepeat, defaults).
// - User bindings live in the app-wide QSettings under "shortcuts/<id>" as a
//   PortableText string list (key absent = defaults, empty list = unbound).
//   Never per project: "shortcuts/" is not a ProjectSettings key.
// - Dispatch: an event filter on the main QQuickWindow. A key press that
//   matches a binding is consumed BEFORE it reaches the focused item - so
//   which panel has keyboard focus does not matter - but only while the
//   registry is "armed": no text field is being edited, no popup / menu /
//   ComboBox list / in-window dialog is open. Key presses in other windows
//   (Settings, Save As, ...) never reach the main window's filter at all.
//   A match emits activated(id); main.qml's runAction(id) does the work.
// - Focus hygiene: a mouse press in the main window outside the text field
//   that is being edited ends the editing (focus moves to focusRoot, which
//   commits the field like any focus-out); the press is delivered normally.
class ShortcutManager : public QObject
{
    Q_OBJECT
    // Set from main.qml: true while the Editing or Effects layout is shown
    // with an open project. "editing"-scope actions only fire while true.
    Q_PROPERTY(bool editingScopeActive READ editingScopeActive WRITE setEditingScopeActive NOTIFY editingScopeActiveChanged)
    // Item that receives keyboard focus when text editing ends (the visible
    // workspace). Set from main.qml.
    Q_PROPERTY(QQuickItem* focusRoot READ focusRoot WRITE setFocusRoot NOTIFY focusRootChanged)
    // Bumped on every bindingsChanged(): read it in a QML binding that calls
    // displayText() so the binding re-evaluates when the bindings change.
    Q_PROPERTY(int revision READ revision NOTIFY bindingsChanged)

public:
    explicit ShortcutManager(QObject *parent = nullptr);

    struct Action {
        QString id;
        QString title;
        QString category;
        QString scope;        // "app" or "editing"
        bool autoRepeat;
        QStringList defaults; // PortableText, normalized
    };

    bool editingScopeActive() const { return m_editingScopeActive; }
    void setEditingScopeActive(bool on);
    QQuickItem *focusRoot() const;
    void setFocusRoot(QQuickItem *item);
    int revision() const { return m_revision; }

    Q_INVOKABLE QVariantList actions() const;
    Q_INVOKABLE QStringList sequences(const QString &id) const;
    // Replaces the bindings of one action (0-2 sequences). Returns false (and
    // changes nothing) for an unknown id, a rejected key, more than two
    // sequences, or a sequence that another action in an overlapping scope
    // already uses (remove it there first - see conflict()).
    Q_INVOKABLE bool setSequences(const QString &id, const QStringList &list);
    // Back to the defaults. A default sequence another action has taken in
    // the meantime is removed from that other action (the reset wins).
    Q_INVOKABLE void resetAction(const QString &id);
    Q_INVOKABLE void resetAll();
    Q_INVOKABLE QString conflict(const QString &sequence, const QString &exceptId) const;
    // Key + modifiers of a key event -> normalized PortableText ("" for a bare
    // modifier key). KeypadModifier is stripped; Shift is stripped for a
    // printable non-letter character (the character already says it: "+" is
    // Shift+3 on a Hungarian layout, Shift+= on a US one).
    Q_INVOKABLE QString sequenceFromKey(int key, int modifiers) const;
    // True for sequences that may never be bound (Escape, Return/Enter,
    // Tab/Backtab, bare modifiers, empty/unparsable).
    Q_INVOKABLE bool isRejected(const QString &sequence) const;
    // Display text of the first binding. Always English key names
    // ("Ctrl+Left", "PgUp", "Del"), independent of the system locale.
    Q_INVOKABLE QString displayText(const QString &id) const;
    Q_INVOKABLE QString nativeText(const QString &sequence) const;
    Q_INVOKABLE QString title(const QString &id) const;
    Q_INVOKABLE bool isDefault(const QString &id) const;

    // Is this item (or its ancestors up to 2 levels, or its contentItem) an
    // editable text control: TextField/TextInput/TextArea/TextEdit, editable
    // SpinBox / ComboBox. Read-only text does not count.
    Q_INVOKABLE bool isTextEditing(QQuickItem *item) const;

    Q_INVOKABLE void attachWindow(QObject *window);
    // Ends text editing: focus moves to focusRoot (commits the field).
    Q_INVOKABLE void releaseTextFocus();
    // Diagnostics / tests: "" when armed, otherwise why not.
    Q_INVOKABLE QString disarmReason() const;

signals:
    void bindingsChanged();
    void activated(const QString &id);
    void editingScopeActiveChanged();
    void focusRootChanged();

protected:
    bool eventFilter(QObject *obj, QEvent *event) override;

private:
    const Action *find(const QString &id) const;
    QString normalize(const QString &sequence) const;
    QStringList effective(const QString &id) const;
    void store(const QString &id, const QStringList &list);
    void rebuildIndex();
    static bool scopesOverlap(const QString &a, const QString &b);
    QQuickItem *textEditingControl(QQuickItem *item) const;
    QString openPopup() const;
    bool handleKeyPress(class QKeyEvent *ke);
    void handleMousePress(class QMouseEvent *me);

    QVector<Action> m_actions;
    QHash<QString, QStringList> m_bindings;     // id -> current sequences
    QHash<QString, QStringList> m_bySequence;   // sequence -> ids
    QPointer<QQuickWindow> m_window;
    QPointer<QQuickItem> m_focusRoot;
    QSet<int> m_eatenKeys;   // keys whose press was consumed: eat the release too
    bool m_editingScopeActive = false;
    int m_revision = 0;
};

#endif // SHORTCUTMANAGER_H
