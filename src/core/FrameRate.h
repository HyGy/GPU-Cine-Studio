#pragma once

#include <QString>
#include <QRegularExpression>
#include <cmath>
#include <numeric>

// The single place where a frame-rate STRING (project/fps setting, the render
// dialog's "23.98 fps" combo entry, ...) becomes a GStreamer fraction.
// GStreamer takes any fraction; the only limits are the callers' own tables,
// which this replaces.
namespace FrameRate {

// Accepts "23.98", "23.976", "29.97 fps", "23.98 fps (Project)", "30", "25",
// "30000/1001", "47.95", "119.88", "12.5" ... Returns false (outputs
// untouched) for anything unparsable or <= 0 (e.g. "auto", "").
// NTSC-family rates (24/30/48/60/120 * 1000/1001, however many decimals the
// string carries) map to the exact n*1000/1001 fraction; other integers to
// N/1; other decimals to a fraction rounded to 1/1000 precision (reduced).
inline bool parse(const QString &text, int &num, int &den)
{
    static const QRegularExpression fracRe(QStringLiteral("(\\d+)\\s*/\\s*(\\d+)"));
    static const QRegularExpression numRe(QStringLiteral("(\\d+(?:[.,]\\d+)?)"));

    if (text.trimmed().startsWith('-')) return false;
    const QRegularExpressionMatch fm = fracRe.match(text);
    if (fm.hasMatch()) {
        const qlonglong n = fm.captured(1).toLongLong();
        const qlonglong d = fm.captured(2).toLongLong();
        if (n <= 0 || d <= 0 || n > 1000000 || d > 1000000) return false;
        const qlonglong g = std::gcd(n, d);
        num = int(n / g); den = int(d / g);
        return true;
    }

    const QRegularExpressionMatch m = numRe.match(text);
    if (!m.hasMatch()) return false;
    QString s = m.captured(1);
    s.replace(',', '.');
    bool ok = false;
    const double v = s.toDouble(&ok);
    if (!ok || !(v > 0.0) || v > 1000.0) return false;

    static const int kNtscBases[] = {24, 30, 48, 60, 120};
    for (int b : kNtscBases) {
        if (std::fabs(v - b * 1000.0 / 1001.0) < 0.0105) { num = b * 1000; den = 1001; return true; }
    }
    const double r = std::round(v);
    if (std::fabs(v - r) < 1e-9) { num = int(r); den = 1; return true; }
    const qlonglong n = std::llround(v * 1000.0);
    if (n <= 0) return false;
    const qlonglong g = std::gcd(n, qlonglong(1000));
    num = int(n / g); den = int(1000 / g);
    return true;
}

} // namespace FrameRate
