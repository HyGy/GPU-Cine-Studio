#include "TitleClips.h"
#include "ClipEffects.h"

#include <QDebug>
#include <QJsonDocument>
#include <QJsonObject>

namespace TitleClips {

namespace {

// Every key we are willing to forward to GES, in a deterministic order.
// halignment/valignment go FIRST: xpos/ypos are only honoured once the
// alignment enum is in "position" mode, and writing them in the other
// order relies on textoverlay re-reading the position on the next frame
// (it does, but there is no reason to depend on it).
const char *const kOrderedKeys[] = {
    "halignment", "valignment",
    "xpos", "ypos", "x-absolute", "y-absolute",
    "text", "font-desc",
    "color", "outline-color", "foreground-color",
    "draw-shadow", "shaded-background",
    nullptr
};

bool isKnownKey(const QString &k)
{
    for (int i = 0; kOrderedKeys[i]; i++) {
        if (k == QLatin1String(kOrderedKeys[i])) return true;
    }
    return false;
}

} // namespace

QString defaultParamsJson(const QString &text)
{
    QJsonObject o;
    o["text"] = text;
    // ~12% of frame height at any project resolution - see the font-size
    // note in TitleClips.h. "Sans Bold 72" measured ~25%, far too big.
    o["font-desc"] = QStringLiteral("Sans Bold 36");
    o["color"] = double(0xFFFFFFFFu);          // opaque white text
    o["outline-color"] = double(0xFF000000u);  // opaque black outline
    // Alpha 0 => the title's own background is invisible and the video
    // on the layer below shows through. THIS is what makes a title an
    // overlay rather than an opaque card; see TitleClips.h.
    o["foreground-color"] = 0.0;
    o["draw-shadow"] = true;
    o["shaded-background"] = false;
    // Written as enum NICKS, not integers, on purpose: the two enums do
    // NOT share numbering - "position" is 4 for halignment but 3 for
    // valignment (4 there is "center", which silently ignores ypos).
    // That exact off-by-one shipped here as a hardcoded 4/4 pair and was
    // caught live (ypos 0.0 and ypos 1.0 rendered identically). Nicks
    // are resolved by ClipEffects::setChildProperty()'s G_TYPE_ENUM case
    // against the property's own GEnumClass, so they can't drift again.
    o["halignment"] = QStringLiteral("position");
    o["valignment"] = QStringLiteral("position");
    o["xpos"] = 0.5;
    o["ypos"] = 0.5;
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

void applyToClip(GESClip *clip, const QString &titleParamsJson)
{
    if (!clip || titleParamsJson.trimmed().isEmpty()) return;

    QJsonParseError perr{};
    const QJsonDocument doc = QJsonDocument::fromJson(titleParamsJson.toUtf8(), &perr);
    if (perr.error != QJsonParseError::NoError || !doc.isObject()) {
        qWarning() << "TitleClips: corrupt titleParams JSON:" << perr.errorString();
        return;
    }
    const QJsonObject obj = doc.object();
    GESTimelineElement *el = GES_TIMELINE_ELEMENT(clip);

    // Ordered pass first, then anything else the caller supplied (so a
    // future key needs no change here, it just loses the ordering
    // guarantee).
    for (int i = 0; kOrderedKeys[i]; i++) {
        const QString key = QString::fromLatin1(kOrderedKeys[i]);
        if (!obj.contains(key)) continue;
        ClipEffects::setChildProperty(el, key, obj.value(key).toVariant());
    }
    for (auto it = obj.constBegin(); it != obj.constEnd(); ++it) {
        if (isKnownKey(it.key())) continue;
        ClipEffects::setChildProperty(el, it.key(), it.value().toVariant());
    }
}

bool setParam(GESClip *clip, const QString &param, const QVariant &value)
{
    if (!clip || param.isEmpty()) return false;
    return ClipEffects::setChildProperty(GES_TIMELINE_ELEMENT(clip), param, value);
}

} // namespace TitleClips
