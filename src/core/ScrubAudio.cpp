#include "ScrubAudio.h"

#include <QDebug>
#include <QMutexLocker>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <gst/app/gstappsrc.h>

namespace {
constexpr int kChunkMs = 2;          // size of the pieces the side pipeline is fed with
constexpr int kFadeMs = 3;           // grain edge fade and crossfade between grains
constexpr int kIdleShutdownMs = 2000;
constexpr int kMaxVoices = 4;
constexpr int kSinkBufferUs = 20000;
constexpr int kSinkLatencyUs = 5000;
}

int ScrubAudio::grainMsFromEnvironment()
{
    int ms = 100;
    const QByteArray v = qgetenv("GCS_SCRUB_GRAIN_MS");
    if (!v.isEmpty()) {
        bool ok = false;
        const int n = v.toInt(&ok);
        if (ok) ms = n;
    }
    return std::clamp(ms, 20, 120);
}

ScrubAudio::ScrubAudio(QObject *parent)
    : QObject(parent), m_grainMs(grainMsFromEnvironment())
{
    m_idleTimer.setSingleShot(true);
    m_idleTimer.setInterval(kIdleShutdownMs);
    connect(&m_idleTimer, &QTimer::timeout, this, [this]() { stopSidePipeline(); });
}

ScrubAudio::~ScrubAudio()
{
    detach();
    stopSidePipeline();
}

void ScrubAudio::attach(GstElement *levelElement)
{
    detach();
    if (!levelElement) return;
    GstPad *pad = gst_element_get_static_pad(levelElement, "src");   // new ref
    if (!pad) return;
    m_pad = pad;
    m_haveInfo = false;
    m_collecting = false;
    m_lastDoneSeq = 0;
    m_probeId = gst_pad_add_probe(
        m_pad, (GstPadProbeType)(GST_PAD_PROBE_TYPE_BUFFER | GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM),
        &ScrubAudio::probeCb, this, nullptr);
}

void ScrubAudio::detach()
{
    m_activeSeq.store(0);
    if (m_pad) {
        if (m_probeId) gst_pad_remove_probe(m_pad, m_probeId);
        m_probeId = 0;
        gst_object_unref(m_pad);
        m_pad = nullptr;
    }
    // Probe-thread state (m_collecting, m_acc...) is deliberately not touched
    // here: an in-flight callback may still be running. attach() resets it
    // for the next pipeline, whose threads are the only ones that can run it.
}

void ScrubAudio::arm(guint32 seqnum)
{
    if (!m_pad) return;
    ensureSidePipeline();
    if (!m_pipe) return;
    m_activeSeq.store(seqnum);
    m_idleTimer.start();
}

void ScrubAudio::disarm()
{
    m_activeSeq.store(0);
    QMutexLocker lock(&m_mutex);
    fadeOutVoicesLocked();
}

void ScrubAudio::shutdown()
{
    disarm();
    m_idleTimer.stop();
    stopSidePipeline();
}

void ScrubAudio::fadeOutVoicesLocked()
{
    const int xf = m_rate.load() * kFadeMs / 1000;
    for (Voice &v : m_voices)
        if (v.fadeLeft < 0) { v.fadeLeft = v.fadeTotal = std::max(1, xf); }
}

void ScrubAudio::ensureSidePipeline()
{
    if (m_pipe) return;
    // Same audio output as the main pipeline's playsink: it falls back to
    // autoaudiosink, which on this system resolves to pulsesink with the
    // default device. Use pulsesink directly when it exists (it takes the
    // small buffer/latency settings), else autoaudiosink.
    const char *sinkName = "autoaudiosink";
    if (GstElementFactory *f = gst_element_factory_find("pulsesink")) {
        sinkName = "pulsesink";
        gst_object_unref(f);
    }
    const int rate = m_rate.load();
    const int chunkBytes = rate * kChunkMs / 1000 * 2 * 4;
    QByteArray desc = QByteArray("appsrc name=scrubsrc is-live=true format=time do-timestamp=true block=true max-bytes=")
        + QByteArray::number(chunkBytes * 2)
        + " caps=audio/x-raw,format=F32LE,rate=" + QByteArray::number(rate)
        + ",channels=2,layout=interleaved ! audioconvert ! audioresample ! " + sinkName;
    if (!strcmp(sinkName, "pulsesink"))
        desc += " buffer-time=" + QByteArray::number(kSinkBufferUs)
              + " latency-time=" + QByteArray::number(kSinkLatencyUs);
    GError *err = nullptr;
    GstElement *pipe = gst_parse_launch(desc.constData(), &err);   // full ref (pipeline)
    if (!pipe) {
        qWarning() << "ScrubAudio: side pipeline failed:" << (err ? err->message : "?");
        if (err) g_error_free(err);
        return;
    }
    if (err) g_error_free(err);
    GstElement *src = gst_bin_get_by_name(GST_BIN(pipe), "scrubsrc");   // new ref
    if (!src) { gst_object_unref(pipe); return; }
    g_object_set(src, "emit-signals", TRUE, "min-percent", 50, nullptr);
    g_signal_connect(src, "need-data", G_CALLBACK(&ScrubAudio::needDataCb), this);
    m_pipe = pipe;
    m_src = src;
    gst_element_set_state(m_pipe, GST_STATE_PLAYING);
    qDebug() << "ScrubAudio: side pipeline started (" << sinkName << ")";
}

void ScrubAudio::stopSidePipeline()
{
    if (!m_pipe) return;
    qDebug() << "ScrubAudio: side pipeline stopped";
    // NULL joins the streaming threads, so no needDataCb runs afterwards.
    gst_element_set_state(m_pipe, GST_STATE_NULL);
    g_signal_handlers_disconnect_by_data(m_src, this);
    gst_object_unref(m_src);
    m_src = nullptr;
    gst_object_unref(m_pipe);
    m_pipe = nullptr;
    QMutexLocker lock(&m_mutex);
    m_voices.clear();
}

void ScrubAudio::needDataCb(GstElement *, guint, gpointer user)
{
    static_cast<ScrubAudio *>(user)->onNeedData();
}

void ScrubAudio::onNeedData()
{
    if (!m_src) return;
    if (m_capsDirty.exchange(false)) {
        GstCaps *c = gst_caps_new_simple("audio/x-raw",
            "format", G_TYPE_STRING, "F32LE", "rate", G_TYPE_INT, m_rate.load(),
            "channels", G_TYPE_INT, 2, "layout", G_TYPE_STRING, "interleaved", nullptr);
        gst_app_src_set_caps(GST_APP_SRC(m_src), c);
        gst_caps_unref(c);
    }
    const int frames = m_rate.load() * kChunkMs / 1000;
    GstBuffer *b = gst_buffer_new_allocate(nullptr, frames * 2 * sizeof(float), nullptr);
    GstMapInfo m;
    gst_buffer_map(b, &m, GST_MAP_WRITE);
    float *out = reinterpret_cast<float *>(m.data);
    std::memset(out, 0, m.size);
    {
        QMutexLocker lock(&m_mutex);
        for (Voice &v : m_voices) {
            const int n = int(v.d.size() / 2);
            for (int i = 0; i < frames && v.pos < n; ++i, ++v.pos) {
                float g = 1.0f;
                if (v.fadeLeft >= 0) {
                    if (v.fadeLeft == 0) { v.pos = n; break; }
                    g = float(v.fadeLeft) / float(v.fadeTotal);
                    --v.fadeLeft;
                }
                out[i * 2] += v.d[v.pos * 2] * g;
                out[i * 2 + 1] += v.d[v.pos * 2 + 1] * g;
            }
        }
        m_voices.erase(std::remove_if(m_voices.begin(), m_voices.end(),
            [](const Voice &v) { return v.pos >= int(v.d.size() / 2); }), m_voices.end());
    }
    gst_buffer_unmap(b, &m);
    // Ownership of b passes to appsrc.
    gst_app_src_push_buffer(GST_APP_SRC(m_src), b);
}

void ScrubAudio::pushGrain(std::vector<float> &&grain, guint32 seq, int rate)
{
    QMutexLocker lock(&m_mutex);
    // Disarmed (play, other seek, rebuild) while this grain was being
    // collected: drop it. disarm() takes the same mutex, so this is race-free.
    if (m_activeSeq.load() != seq) return;
    if (rate != m_rate.load()) {
        m_voices.clear();
        m_rate.store(rate);
        m_capsDirty.store(true);
    }
    fadeOutVoicesLocked();
    while (int(m_voices.size()) >= kMaxVoices) m_voices.erase(m_voices.begin());
    Voice v;
    qDebug() << "ScrubAudio: grain queued, seqnum" << seq << "frames" << int(grain.size() / 2) << "rate" << rate;
    v.d = std::move(grain);
    m_voices.push_back(std::move(v));
}

GstPadProbeReturn ScrubAudio::probeCb(GstPad *pad, GstPadProbeInfo *info, gpointer user)
{
    return static_cast<ScrubAudio *>(user)->onProbe(pad, info);
}

GstPadProbeReturn ScrubAudio::onProbe(GstPad *, GstPadProbeInfo *info)
{
    const guint32 active = m_activeSeq.load();
    if (GST_PAD_PROBE_INFO_TYPE(info) & GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM) {
        GstEvent *ev = GST_PAD_PROBE_INFO_EVENT(info);
        if (GST_EVENT_TYPE(ev) == GST_EVENT_CAPS) {
            GstCaps *caps = nullptr;
            gst_event_parse_caps(ev, &caps);
            m_haveInfo = false;
            m_inFmt = FmtNone;
            if (caps && gst_caps_get_size(caps) > 0) {
                const GstStructure *s = gst_caps_get_structure(caps, 0);
                const char *fmt = gst_structure_get_string(s, "format");
                int rate = 0, ch = 0;
                gst_structure_get_int(s, "rate", &rate);
                gst_structure_get_int(s, "channels", &ch);
                if (fmt && rate > 0 && ch > 0) {
                    if (!strcmp(fmt, "S32LE")) m_inFmt = FmtS32;
                    else if (!strcmp(fmt, "F32LE")) m_inFmt = FmtF32;
                    else if (!strcmp(fmt, "S16LE")) m_inFmt = FmtS16;
                    if (m_inFmt != FmtNone) { m_inRate = rate; m_inChannels = ch; m_haveInfo = true; }
                }
            }
        } else if (GST_EVENT_TYPE(ev) == GST_EVENT_SEGMENT) {
            const guint32 sq = gst_event_get_seqnum(ev);
            // A SEGMENT of another seek ends a half collected grain. A later
            // SEGMENT of the same seek (GES re-issues one at clip boundaries)
            // continues it.
            if (m_collecting && sq != m_curSeq) { m_collecting = false; m_acc.clear(); }
            if (!m_collecting && active != 0 && sq == active && sq != m_lastDoneSeq && m_haveInfo) {
                m_collecting = true;
                m_curSeq = sq;
                m_wantFrames = m_inRate * m_grainMs / 1000;
                m_acc.clear();
                m_acc.reserve(size_t(m_wantFrames) * 2);
            }
        }
        return GST_PAD_PROBE_OK;
    }

    if (!m_collecting) return GST_PAD_PROBE_OK;
    if (active != m_curSeq) { m_collecting = false; m_acc.clear(); return GST_PAD_PROBE_OK; }

    GstBuffer *b = GST_PAD_PROBE_INFO_BUFFER(info);
    GstMapInfo mi;
    if (!b || !gst_buffer_map(b, &mi, GST_MAP_READ)) return GST_PAD_PROBE_OK;
    const int bps = m_inFmt == FmtS16 ? 2 : 4;
    const int frames = int(mi.size / size_t(bps * m_inChannels));
    const int have = int(m_acc.size() / 2);
    const int take = std::min(frames, m_wantFrames - have);
    for (int f = 0; f < take; ++f) {
        for (int c = 0; c < 2; ++c) {
            const int cc = c < m_inChannels ? c : 0;
            const size_t idx = size_t(f) * m_inChannels + cc;
            float x = 0.f;
            switch (m_inFmt) {
            case FmtS32: x = reinterpret_cast<const gint32 *>(mi.data)[idx] / 2147483648.0f; break;
            case FmtF32: x = reinterpret_cast<const float *>(mi.data)[idx]; break;
            case FmtS16: x = reinterpret_cast<const gint16 *>(mi.data)[idx] / 32768.0f; break;
            default: break;
            }
            m_acc.push_back(x);
        }
    }
    gst_buffer_unmap(b, &mi);

    if (int(m_acc.size() / 2) >= m_wantFrames) {
        const int n = m_wantFrames;
        int fn = m_inRate * kFadeMs / 1000;
        if (fn * 2 > n) fn = n / 2;
        for (int k = 0; k < fn; ++k) {
            const float g = 0.5f - 0.5f * std::cos(float(M_PI) * k / fn);
            for (int c = 0; c < 2; ++c) {
                m_acc[size_t(k) * 2 + c] *= g;
                m_acc[size_t(n - 1 - k) * 2 + c] *= g;
            }
        }
        m_collecting = false;
        m_lastDoneSeq = m_curSeq;
        pushGrain(std::move(m_acc), m_curSeq, m_inRate);
        m_acc = std::vector<float>();
    }
    return GST_PAD_PROBE_OK;
}
