#pragma once

#include <QObject>
#include <QTimer>
#include <QMutex>
#include <atomic>
#include <vector>
#include <gst/gst.h>

// Audio scrub for single frame steps while the timeline pipeline is PAUSED.
//
// While paused, every flushing seek makes the GES audio mixer push about one
// second of audio past the "gcsmaster" level element (the playsink audio queue
// downstream of the audio-filter is what limits it), but the sink only
// prerolls, so nothing is heard. A buffer probe on that element's src pad
// copies the first grainMs of the audio that follows ONE armed seek (matched
// by the seek event's seqnum), fades its edges and hands it to a small
// separate pipeline
//     appsrc ! audioconvert ! audioresample ! <audio sink>
// that is always PLAYING while it exists. The main pipeline's state is never
// touched.
//
// Threading: attach()/detach()/arm()/disarm()/shutdown() are called on the Qt
// main thread only. The probe runs on a GStreamer streaming thread (no Qt
// calls there); the appsrc "need-data" callback runs on the side pipeline's
// own streaming thread. Both only touch m_mutex-protected state and atomics.
class ScrubAudio : public QObject
{
    Q_OBJECT
public:
    explicit ScrubAudio(QObject *parent = nullptr);
    ~ScrubAudio() override;

    // Install the tap probe on levelElement's src pad (the element after the
    // existing GAP-clearing probe's one - call after that probe was added).
    // Holds its own refs to the pad (released in detach()). Idempotent.
    void attach(GstElement *levelElement);
    // Remove the probe and release the pad. MUST be called before the
    // pipeline that contains the element is set to NULL / destroyed.
    void detach();

    // Arm the tap for the seek event carrying this seqnum (call right before
    // sending the event). Starts the side pipeline lazily.
    void arm(guint32 seqnum);
    // Cancel: no grain will be produced for a pending or half-collected seek
    // and sounding grains are faded out within a few ms.
    void disarm();
    // disarm() + tear the side pipeline down now.
    void shutdown();

    static int grainMsFromEnvironment();

private:
    struct Voice {
        std::vector<float> d;     // interleaved stereo
        int pos = 0;
        int fadeLeft = -1;        // -1: not fading out
        int fadeTotal = 0;
    };

    static GstPadProbeReturn probeCb(GstPad *pad, GstPadProbeInfo *info, gpointer user);
    static void needDataCb(GstElement *src, guint length, gpointer user);
    GstPadProbeReturn onProbe(GstPad *pad, GstPadProbeInfo *info);
    void onNeedData();
    void pushGrain(std::vector<float> &&grain, guint32 seq, int rate);
    void ensureSidePipeline();
    void stopSidePipeline();
    void fadeOutVoicesLocked();

    // --- main thread only ---
    GstPad *m_pad = nullptr;          // own ref (gst_element_get_static_pad)
    gulong m_probeId = 0;
    GstElement *m_pipe = nullptr;     // own ref (gst_parse_launch / gst_pipeline_new result)
    GstElement *m_src = nullptr;      // own ref (gst_bin_get_by_name)
    QTimer m_idleTimer;
    int m_grainMs;

    // --- shared ---
    std::atomic<guint32> m_activeSeq{0};   // seqnum the next/current grain belongs to; 0 = off
    std::atomic<int> m_rate{48000};
    std::atomic<bool> m_capsDirty{false};
    QMutex m_mutex;                        // guards m_voices
    std::vector<Voice> m_voices;

    // --- probe thread only ---
    bool m_haveInfo = false;
    int m_inRate = 0, m_inChannels = 0;
    enum Fmt { FmtNone, FmtS16, FmtS32, FmtF32 } m_inFmt = FmtNone;
    bool m_collecting = false;
    guint32 m_curSeq = 0;
    guint32 m_lastDoneSeq = 0;
    int m_wantFrames = 0;
    std::vector<float> m_acc;              // frames collected so far (interleaved stereo)
};
