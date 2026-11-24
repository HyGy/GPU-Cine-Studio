#ifndef GPULOADMONITOR_H
#define GPULOADMONITOR_H

#include <QObject>
#include <QString>
#include <QTimer>
#include <QProcess>

// Polls how busy the currently-selected decode path actually is, so the
// decoder combobox in main.qml can show a live "NVIDIA: 23%" /
// "GPU: 11%" readout next to it instead of leaving the user to guess from
// nvidia-smi in a separate terminal.
//
// NVIDIA: shells out to `nvidia-smi --query-gpu=utilization.gpu` - that's
// a real subprocess per sample, but it only takes tens of ms and runs
// asynchronously (QProcess, non-blocking), at most once per second.
//
// Intel/VA-API: no nvidia-smi equivalent is installed by default, and
// intel_gpu_top needs root/debugfs. Instead this reads this process's own
// per-engine busy counters from /proc/self/fdinfo/<fd> for any fd backed
// by /dev/dri/* - exposed without privilege by the i915/Xe kernel driver
// since Linux 5.19 (the same "fdinfo" mechanism modern nvtop/intel_gpu_top
// use). Two samples' delta-busy-ns / delta-wall-ns gives the %.
class GpuLoadMonitor : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString loadText READ loadText NOTIFY loadTextChanged)

public:
    explicit GpuLoadMonitor(QObject *parent = nullptr);

    QString loadText() const { return m_loadText; }

    // decoder: "nvidia" | "vaapi" | "cpu" - matches BackendManager's decoder ids.
    Q_INVOKABLE void setActiveDecoder(const QString &decoder);

signals:
    void loadTextChanged();

private slots:
    void poll();
    void onNvidiaSmiFinished(int exitCode, QProcess::ExitStatus status);
    void onNvidiaSmiError(QProcess::ProcessError error);

private:
    void pollIntel();
    void setLoadText(const QString &text);

    QString m_decoder;
    QString m_loadText;
    QTimer *m_timer;
    QProcess *m_nvidiaSmi;
    bool m_nvidiaSmiBusy;
    bool m_nvidiaSmiUnavailable;

    qint64 m_lastIntelBusyNs;
    qint64 m_lastIntelSampleTimeNs;
};

#endif // GPULOADMONITOR_H
