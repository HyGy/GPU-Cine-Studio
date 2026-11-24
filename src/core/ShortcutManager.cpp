#include "ShortcutManager.h"
#include "ProjectSettings.h"

#include <QDebug>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QKeySequence>
#include <QMouseEvent>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSet>
#include <QSettings>

namespace {
const char *kSettingsPrefix = "shortcuts/";

bool isModifierKey(int key)
{
    switch (key) {
    case Qt::Key_Shift: case Qt::Key_Control: case Qt::Key_Alt: case Qt::Key_Meta:
    case Qt::Key_AltGr: case Qt::Key_CapsLock: case Qt::Key_NumLock: case Qt::Key_ScrollLock:
    case Qt::Key_Super_L: case Qt::Key_Super_R: case Qt::Key_Hyper_L: case Qt::Key_Hyper_R:
    case Qt::Key_Mode_switch: case Qt::Key_unknown: case 0:
        return true;
    default:
        return false;
    }
}

bool isReservedKey(int key)
{
    return key == Qt::Key_Escape || key == Qt::Key_Return || key == Qt::Key_Enter
        || key == Qt::Key_Tab || key == Qt::Key_Backtab;
}

bool isEditableText(const QObject *o)
{
    if (!o) return false;
    if (o->inherits("QQuickTextInput") || o->inherits("QQuickTextEdit"))
        return !o->property("readOnly").toBool() && o->property("enabled").toBool()
            && o->property("visible").toBool();
    return false;
}

bool isEditableCompound(const QObject *o)
{
    return o && (o->inherits("QQuickSpinBox") || o->inherits("QQuickComboBox"))
        && o->property("editable").toBool();
}
} // namespace

ShortcutManager::ShortcutManager(QObject *parent)
    : QObject(parent)
{
    auto add = [this](const char *id, const char *title, const char *category,
                      const char *scope, bool repeat, QStringList defs) {
        Action a{QString::fromLatin1(id), QString::fromUtf8(title), QString::fromLatin1(category),
                 QString::fromLatin1(scope), repeat, {}};
        for (const QString &d : defs) {
            const QString n = normalize(d);
            if (n.isEmpty()) qWarning() << "ShortcutManager: bad default" << d << "for" << id;
            else a.defaults << n;
        }
        m_actions.push_back(a);
    };
    // Defaults = the keys bound before the registry existed (see the
    // inventory in plan_shortcuts.md).
    add("play_pause",  "Play / Pause",                    "Playback",   "editing", false, {"Space"});
    add("frame_back",  "Step one frame back",             "Navigation", "editing", true,  {"Left"});
    add("frame_fwd",   "Step one frame forward",          "Navigation", "editing", true,  {"Right"});
    add("second_back", "Step one second back",            "Navigation", "editing", true,  {"Shift+Left"});
    add("second_fwd",  "Step one second forward",         "Navigation", "editing", true,  {"Shift+Right"});
    add("go_start",    "Go to start",                     "Navigation", "editing", false, {"Home"});
    add("go_end",      "Go to end",                       "Navigation", "editing", false, {"End"});
    add("prev_cut",    "Previous cut point",              "Navigation", "editing", true,  {"Ctrl+Left", "PgUp"});
    add("next_cut",    "Next cut point",                  "Navigation", "editing", true,  {"Ctrl+Right", "PgDown"});
    add("track_up",    "Active track up",                 "Tracks",     "editing", true,  {"Shift+Up"});
    add("track_down",  "Active track down",               "Tracks",     "editing", true,  {"Shift+Down"});
    add("select_at_playhead", "Select clip under playhead", "Editing",  "editing", false, {"D"});
    add("split",       "Split at playhead",               "Editing",    "editing", false, {"S"});
    add("trim_start",  "Trim clip start to playhead",     "Editing",    "editing", false, {"Q"});
    add("trim_end",    "Trim clip end to playhead",       "Editing",    "editing", false, {"W"});
    add("delete_clip", "Delete selected clip",            "Editing",    "editing", false, {"Del"});
    add("toggle_ripple", "Ripple edit on/off",            "Editing",    "editing", false, {"R"});
    add("toggle_ripple_all_tracks", "Ripple all tracks on/off", "Editing", "editing", false, {"Shift+R"});
    add("toggle_split_mode", "Split one / Split all tracks", "Editing",  "editing", false, {"Shift+S"});
    add("undo",        "Undo",                            "Editing",    "app",     true,  {"Ctrl+Z"});
    add("redo",        "Redo",                            "Editing",    "app",     true,  {"Ctrl+Shift+Z", "Ctrl+Y"});
    add("zoom_in",     "Zoom timeline in",                "View",       "editing", true,  {"+", "="});
    add("zoom_out",    "Zoom timeline out",               "View",       "editing", true,  {"-"});
    add("zoom_fit",    "Zoom to fit",                     "View",       "editing", false, {"Shift+Z"});
    add("new_project", "New project",                     "File",       "app",     false, {"Ctrl+N"});
    add("save",        "Save project",                    "File",       "app",     false, {"Ctrl+S"});
    add("save_as",     "Save project as",                 "File",       "app",     false, {"Ctrl+Shift+S"});
    add("quit",        "Quit",                            "File",       "app",     false, {"Ctrl+Q"});

    Q_ASSERT(!ProjectSettings::isProjectKey(QString::fromLatin1(kSettingsPrefix) + "x"));

    // Load user bindings (app-wide QSettings). Invalid stored sequences are
    // dropped; a stored conflict (hand-edited file) keeps the first owner.
    QSettings settings;
    QSet<QString> taken;
    for (const Action &a : std::as_const(m_actions)) {
        const QString key = QString::fromLatin1(kSettingsPrefix) + a.id;
        if (!settings.contains(key)) continue;
        QStringList list;
        const QVariant v = settings.value(key);
        for (const QString &s : v.toStringList()) {
            const QString n = normalize(s);
            if (!n.isEmpty() && !isRejected(n) && !list.contains(n) && list.size() < 2) list << n;
        }
        m_bindings.insert(a.id, list);
    }
    // Resolve conflicts deterministically: user bindings first, then defaults.
    QHash<QString, QStringList> resolved;
    for (const Action &a : std::as_const(m_actions)) {
        if (!m_bindings.contains(a.id)) continue;
        QStringList keep;
        for (const QString &s : m_bindings.value(a.id)) {
            if (taken.contains(s)) { qWarning() << "ShortcutManager: stored" << s << "for" << a.id << "already used - dropped"; continue; }
            taken.insert(s); keep << s;
        }
        resolved.insert(a.id, keep);
    }
    for (const Action &a : std::as_const(m_actions)) {
        if (resolved.contains(a.id)) continue;
        QStringList keep;
        for (const QString &s : a.defaults) {
            if (taken.contains(s)) { qWarning() << "ShortcutManager: default" << s << "for" << a.id << "is used by a user binding - not active"; continue; }
            taken.insert(s); keep << s;
        }
        // Not stored: the action still follows its defaults (minus the taken one).
        resolved.insert(a.id, keep);
    }
    m_bindings = resolved;
    rebuildIndex();
}

const ShortcutManager::Action *ShortcutManager::find(const QString &id) const
{
    for (const Action &a : m_actions)
        if (a.id == id) return &a;
    return nullptr;
}

QString ShortcutManager::sequenceFromKey(int key, int modifiers) const
{
    if (isModifierKey(key)) return QString();
    Qt::KeyboardModifiers mods = Qt::KeyboardModifiers(modifiers)
        & (Qt::ShiftModifier | Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier);
    // A printable non-letter character already encodes Shift ("+", "!", ...).
    if ((mods & Qt::ShiftModifier) && key > 0x20 && key < 0x10000) {
        const QChar c(key);
        if (c.isPrint() && !c.isLetter() && !c.isSpace()) mods &= ~Qt::ShiftModifier;
    }
    return QKeySequence(QKeyCombination(mods, Qt::Key(key))).toString(QKeySequence::PortableText);
}

QString ShortcutManager::normalize(const QString &sequence) const
{
    const QKeySequence ks = QKeySequence::fromString(sequence.trimmed(), QKeySequence::PortableText);
    if (ks.count() != 1) return QString();
    const QKeyCombination kc = ks[0];
    if (kc.key() == Qt::Key_unknown) return QString();
    return sequenceFromKey(int(kc.key()), int(kc.keyboardModifiers()));
}

bool ShortcutManager::isRejected(const QString &sequence) const
{
    const QString n = normalize(sequence);
    if (n.isEmpty()) return true;
    const QKeySequence ks = QKeySequence::fromString(n, QKeySequence::PortableText);
    return isReservedKey(int(ks[0].key()));
}

QStringList ShortcutManager::effective(const QString &id) const
{
    return m_bindings.value(id);
}

QStringList ShortcutManager::sequences(const QString &id) const
{
    return effective(id);
}

bool ShortcutManager::isDefault(const QString &id) const
{
    const Action *a = find(id);
    return a && effective(id) == a->defaults;
}

QVariantList ShortcutManager::actions() const
{
    QVariantList out;
    for (const Action &a : m_actions) {
        QVariantMap m;
        m["id"] = a.id;
        m["title"] = a.title;
        m["category"] = a.category;
        m["scope"] = a.scope;
        m["autoRepeat"] = a.autoRepeat;
        m["sequences"] = effective(a.id);
        m["defaults"] = a.defaults;
        m["isDefault"] = isDefault(a.id);
        out << m;
    }
    return out;
}

bool ShortcutManager::scopesOverlap(const QString &a, const QString &b)
{
    if (a == QLatin1String("app") || b == QLatin1String("app")) return true;
    return a == b;
}

QString ShortcutManager::conflict(const QString &sequence, const QString &exceptId) const
{
    const QString n = normalize(sequence);
    if (n.isEmpty()) return QString();
    const Action *self = find(exceptId);
    for (const QString &id : m_bySequence.value(n)) {
        if (id == exceptId) continue;
        const Action *other = find(id);
        if (!other) continue;
        if (!self || scopesOverlap(self->scope, other->scope)) return id;
    }
    return QString();
}

void ShortcutManager::store(const QString &id, const QStringList &list)
{
    const Action *a = find(id);
    if (!a) return;
    QSettings settings;
    const QString key = QString::fromLatin1(kSettingsPrefix) + id;
    if (list == a->defaults) settings.remove(key);
    else settings.setValue(key, list);
    m_bindings.insert(id, list);
}

void ShortcutManager::rebuildIndex()
{
    m_bySequence.clear();
    for (const Action &a : std::as_const(m_actions))
        for (const QString &s : m_bindings.value(a.id))
            m_bySequence[s] << a.id;
}

bool ShortcutManager::setSequences(const QString &id, const QStringList &list)
{
    if (!find(id)) return false;
    QStringList clean;
    for (const QString &s : list) {
        if (s.trimmed().isEmpty()) continue;
        if (isRejected(s)) return false;
        const QString n = normalize(s);
        if (clean.contains(n)) continue;
        if (!conflict(n, id).isEmpty()) return false;
        clean << n;
    }
    if (clean.size() > 2) return false;
    if (clean == effective(id)) return true;
    store(id, clean);
    rebuildIndex();
    ++m_revision;
    emit bindingsChanged();
    return true;
}

void ShortcutManager::resetAction(const QString &id)
{
    const Action *a = find(id);
    if (!a) return;
    for (const QString &s : a->defaults) {
        const QString other = conflict(s, id);
        if (other.isEmpty()) continue;
        QStringList rest = effective(other);
        rest.removeAll(s);
        qInfo() << "ShortcutManager: reset of" << id << "takes" << s << "back from" << other;
        store(other, rest);
    }
    QSettings().remove(QString::fromLatin1(kSettingsPrefix) + id);
    m_bindings.insert(id, a->defaults);
    rebuildIndex();
    ++m_revision;
    emit bindingsChanged();
}

void ShortcutManager::resetAll()
{
    QSettings settings;
    for (const Action &a : std::as_const(m_actions)) {
        settings.remove(QString::fromLatin1(kSettingsPrefix) + a.id);
        m_bindings.insert(a.id, a.defaults);
    }
    rebuildIndex();
    ++m_revision;
    emit bindingsChanged();
}

QString ShortcutManager::nativeText(const QString &sequence) const
{
    const QString n = normalize(sequence);
    if (n.isEmpty()) return QString();
    // Always the English (portable) names - NativeText is translated by the
    // system locale ("Ctrl+Bal", "Fel" under Hungarian), which the user does
    // not want. On X11 the two forms are otherwise identical.
    return n;
}

QString ShortcutManager::displayText(const QString &id) const
{
    const QStringList l = effective(id);
    return l.isEmpty() ? QString() : nativeText(l.first());
}

QString ShortcutManager::title(const QString &id) const
{
    const Action *a = find(id);
    return a ? a->title : QString();
}

void ShortcutManager::setEditingScopeActive(bool on)
{
    if (m_editingScopeActive == on) return;
    m_editingScopeActive = on;
    emit editingScopeActiveChanged();
}

QQuickItem *ShortcutManager::focusRoot() const
{
    return m_focusRoot.data();
}

void ShortcutManager::setFocusRoot(QQuickItem *item)
{
    if (m_focusRoot.data() == item) return;
    m_focusRoot = item;
    emit focusRootChanged();
}

QQuickItem *ShortcutManager::textEditingControl(QQuickItem *item) const
{
    if (!item) return nullptr;
    // The item itself or an ancestor up to 2 levels up.
    QQuickItem *it = item;
    for (int depth = 0; it && depth <= 2; ++depth, it = it->parentItem()) {
        if (isEditableCompound(it)) return it;
        if (isEditableText(it)) {
            // Prefer the surrounding SpinBox/ComboBox as "the control"
            // (its rectangle is what a click-outside is measured against).
            QQuickItem *p = it->parentItem();
            for (int up = 0; p && up < 2; ++up, p = p->parentItem())
                if (isEditableCompound(p)) return p;
            return it;
        }
    }
    // A control whose contentItem is the editable text. Not for a
    // SpinBox/ComboBox: their contentItem is a text field even when they are
    // not editable - the "editable" check above decides for them.
    if (item->inherits("QQuickSpinBox") || item->inherits("QQuickComboBox")) return nullptr;
    const QVariant ci = item->property("contentItem");
    if (ci.isValid()) {
        QObject *o = ci.value<QObject *>();
        if (isEditableText(o)) return item;
    }
    return nullptr;
}

bool ShortcutManager::isTextEditing(QQuickItem *item) const
{
    return textEditingControl(item) != nullptr;
}

QString ShortcutManager::openPopup() const
{
    if (!m_window) return QString();
    // Focus inside a popup (Menu, focused Dialog), or on a ComboBox whose list is open.
    for (QQuickItem *it = m_window->activeFocusItem(); it; it = it->parentItem()) {
        if (it->inherits("QQuickPopupItem") && it->isVisible()) return QStringLiteral("focus in popup");
        if (it->inherits("QQuickComboBox")) {
            QObject *p = it->property("popup").value<QObject *>();
            if (p && p->property("visible").toBool()) return QStringLiteral("ComboBox list open");
        }
    }
    // Any other visible popup in the window (modal dialogs that do not take
    // focus, context menus, ...). Tool tips do not count.
    QSet<QObject *> seen;
    QList<QObject *> all = m_window->findChildren<QObject *>();
    if (m_window->contentItem()) all += m_window->contentItem()->findChildren<QObject *>();
    for (QObject *o : std::as_const(all)) {
        if (seen.contains(o)) continue;
        seen.insert(o);
        if (!o->inherits("QQuickPopup") || o->inherits("QQuickToolTip")) continue;
        if (o->property("visible").toBool())
            return QStringLiteral("open popup %1 %2").arg(QString::fromLatin1(o->metaObject()->className()), o->objectName());
    }
    return QString();
}

QString ShortcutManager::disarmReason() const
{
    if (!m_window) return QStringLiteral("no window");
    if (QGuiApplication::focusWindow() != m_window) return QStringLiteral("main window not active");
    if (isTextEditing(m_window->activeFocusItem())) return QStringLiteral("text editing");
    return openPopup();
}

void ShortcutManager::attachWindow(QObject *window)
{
    QQuickWindow *w = qobject_cast<QQuickWindow *>(window);
    if (!w) { qWarning() << "ShortcutManager::attachWindow: not a QQuickWindow" << window; return; }
    if (m_window) m_window->removeEventFilter(this);
    m_window = w;
    w->installEventFilter(this);
}

void ShortcutManager::releaseTextFocus()
{
    if (m_focusRoot) { m_focusRoot->forceActiveFocus(Qt::OtherFocusReason); return; }
    if (m_window && m_window->contentItem()) m_window->contentItem()->forceActiveFocus(Qt::OtherFocusReason);
}

bool ShortcutManager::handleKeyPress(QKeyEvent *ke)
{
    // Typing safety: a single-line text field does not use Up/Down/PgUp/PgDn,
    // and an unused key normally propagates to the field's ancestors - a
    // ListView there moves its current item and takes keyboard focus out of
    // the field. Deliver these keys to the field only (an editable SpinBox /
    // ComboBox is left alone: it steps its value with them).
    if (m_window) {
        const int k = ke->key();
        if (k == Qt::Key_Up || k == Qt::Key_Down || k == Qt::Key_PageUp || k == Qt::Key_PageDown) {
            QQuickItem *fi = m_window->activeFocusItem();
            QQuickItem *control = textEditingControl(fi);
            if (control && control == fi && fi->inherits("QQuickTextInput")) {
                QCoreApplication::sendEvent(fi, ke);
                return true;
            }
        }
    }

    // A fresh press decides anew whether its release is eaten.
    if (!ke->isAutoRepeat()) m_eatenKeys.remove(ke->key());
    const QString seq = sequenceFromKey(ke->key(), int(ke->modifiers()));
    if (seq.isEmpty()) return false;
    QStringList ids;
    for (const QString &id : m_bySequence.value(seq)) {
        const Action *a = find(id);
        if (!a) continue;
        if (a->scope == QLatin1String("app") || m_editingScopeActive) ids << id;
    }
    if (ids.isEmpty()) return false;
    if (!disarmReason().isEmpty()) return false;   // the key goes to the focused item / popup
    if (ids.size() > 1) {
        qWarning() << "ShortcutManager: ambiguous key" << seq << "bound to" << ids << "- nothing done";
        return true;
    }
    const Action *a = find(ids.first());
    // The matching release is eaten too: a focused control may act on the
    // release alone (a closed ComboBox opens its list on a Space release).
    m_eatenKeys.insert(ke->key());
    if (ke->isAutoRepeat() && !a->autoRepeat) return true;   // held key: once only
    emit activated(a->id);
    return true;
}

void ShortcutManager::handleMousePress(QMouseEvent *me)
{
    if (!m_window) return;
    QQuickItem *control = textEditingControl(m_window->activeFocusItem());
    if (!control) return;
    // While a popup is open it manages its own focus / closing.
    if (!openPopup().isEmpty()) return;
    const QRectF r = control->mapRectToScene(QRectF(0, 0, control->width(), control->height()));
    if (r.contains(me->scenePosition())) return;
    releaseTextFocus();   // focus-out commits the field; the press is delivered normally
}

bool ShortcutManager::eventFilter(QObject *obj, QEvent *event)
{
    if (obj == m_window) {
        if (event->type() == QEvent::KeyPress)
            return handleKeyPress(static_cast<QKeyEvent *>(event));
        if (event->type() == QEvent::KeyRelease) {
            auto *ke = static_cast<QKeyEvent *>(event);
            if (m_eatenKeys.contains(ke->key())) {
                if (!ke->isAutoRepeat()) m_eatenKeys.remove(ke->key());
                return true;
            }
        }
        if (event->type() == QEvent::MouseButtonPress)
            handleMousePress(static_cast<QMouseEvent *>(event));
    }
    return QObject::eventFilter(obj, event);
}
