#pragma once
// Timeline seconds (double, as stored in the QML model / project file) ->
// GstClockTime nanoseconds, used by every place that hands clip timing to
// GES (preview TimelineEngine and RenderEngine alike).
//
// Rounded, not truncated: a plain (GstClockTime)(sec * GST_SECOND) cast
// truncates, and start/duration were truncated independently - so for two
// clips that butt in the model (A.start + A.dur == B.start up to a few
// ulps, e.g. after a ripple shift computed as B.start - gap) A's GES end
// could land 1 ns past B's GES start. GES's auto-transition turns ANY
// overlap into a transition, so that produced invisible 1 ns "phantom"
// transition clips. span() derives the duration from a rounded END, so
// butted model clips always butt exactly in nanoseconds too.
#include <gst/gst.h>
#include <cmath>

namespace TimeConv {

inline GstClockTime secToNs(double sec)
{
    if (!(sec > 0.0)) return 0;
    return (GstClockTime)std::llround(sec * (double)GST_SECOND);
}

struct Span { GstClockTime start; GstClockTime duration; };

// start = round(start), end = round(start + duration), duration = end - start.
inline Span span(double startSec, double durationSec)
{
    const GstClockTime s = secToNs(startSec);
    const GstClockTime e = secToNs(startSec + durationSec);
    return { s, e > s ? e - s : 0 };
}

} // namespace TimeConv
