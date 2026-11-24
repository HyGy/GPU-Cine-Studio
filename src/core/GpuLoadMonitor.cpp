#include "GpuLoadMonitor.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QRegularExpression>
#include <QTextStream>
#include <QDebug>

GpuLoadMonitor::GpuLoadMonitor(QObject *parent)
    : QObject(parent)
    , m_decoder("nvidia")
    , m_loadText(QString())
    , m_nvidiaSmiBusy(false)
    , m_nvidiaSmiUnavailable(false)
    , m_lastIntelBusyNs(0)
    , m_lastIntelSampleTimeNs(0)
{
    m_nvidiaSmi = new QProcess(this);
    connect(m_nvidiaSmi, &QProcess::finished, this, &GpuLoadMonitor::onNvidiaSmiFinished);
    connect(m_nvidiaSmi, &QProcess::errorOccurred, this, &GpuLoadMonitor::onNvidiaSmiError);

    m_timer = new QTimer(this);
    m_timer->setInterval(1000);
    connect(m_timer, &QTimer::timeout, this, &GpuLoadMonitor::poll);
    m_timer->start();
}

void GpuLoadMonitor::setLoadText(const QString &text) {
    if (m_loadText != text) {
        m_loadText = text;
        emit loadTextChanged();
    }
}

void GpuLoadMonitor::setActiveDecoder(const QString &decoder) {
    if (m_decoder == decoder) return;
    m_decoder = decoder;
    // Discard stale sampling state from the previous decoder - an Intel
    // busy-ns reading means nothing once we've switched away from vaapi.
    m_lastIntelSampleTimeNs = 0;
    setLoadText(QString());
    poll();
}

void GpuLoadMonitor::poll() {
    if (m_decoder == "nvidia") {
        if (m_nvidiaSmiBusy || m_nvidiaSmiUnavailable) return;
        m_nvidiaSmiBusy = true;
        m_nvidiaSmi->start("nvidia-smi", {"--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"});
    } else if (m_decoder == "vaapi") {
        pollIntel();
    } else {
        // Software decode doesn't run on the GPU at all - nothing meaningful to show.
        setLoadText("CPU decode");
    }
}

void GpuLoadMonitor::onNvidiaSmiFinished(int exitCode, QProcess::ExitStatus status) {
    m_nvidiaSmiBusy = false;
    if (status != QProcess::NormalExit || exitCode != 0) {
        setLoadText("NVIDIA: n/a");
        return;
    }
    const QString output = QString::fromUtf8(m_nvidiaSmi->readAllStandardOutput()).trimmed();
    bool ok = false;
    int percent = output.toInt(&ok);
    if (ok) {
        setLoadText(QString("NVIDIA: %1%").arg(percent));
    } else {
        setLoadText("NVIDIA: n/a");
    }
}

void GpuLoadMonitor::onNvidiaSmiError(QProcess::ProcessError error) {
    Q_UNUSED(error);
    m_nvidiaSmiBusy = false;
    // nvidia-smi missing entirely (e.g. no NVIDIA driver installed) - stop
    // retrying every second, it will never succeed.
    m_nvidiaSmiUnavailable = true;
    setLoadText("NVIDIA: n/a");
}

void GpuLoadMonitor::pollIntel() {
    qint64 totalBusyNs = 0;
    bool foundAny = false;

    QDir fdDir("/proc/self/fd");
    const QStringList entries = fdDir.entryList(QDir::NoDotAndDotDot | QDir::System | QDir::Files | QDir::Dirs);
    for (const QString &entry : entries) {
        const QString linkTarget = QFile::symLinkTarget(fdDir.filePath(entry));
        if (!linkTarget.contains("/dev/dri/")) continue;

        QFile infoFile(QString("/proc/self/fdinfo/%1").arg(entry));
        if (!infoFile.open(QIODevice::ReadOnly | QIODevice::Text)) continue;

        QTextStream in(&infoFile);
        while (!in.atEnd()) {
            const QString line = in.readLine();
            // i915/Xe expose one "drm-engine-<name>: <ns> ns" line per
            // hardware engine; the video decode/encode engine is what we
            // care about here.
            if (!line.startsWith("drm-engine-video")) continue;
            const QStringList parts = line.split(QRegularExpression("[:\\s]+"), Qt::SkipEmptyParts);
            if (parts.size() >= 2) {
                bool ok = false;
                qint64 ns = parts[1].toLongLong(&ok);
                if (ok) {
                    totalBusyNs += ns;
                    foundAny = true;
                }
            }
        }
    }

    if (!foundAny) {
        setLoadText("GPU: n/a");
        m_lastIntelSampleTimeNs = 0;
        return;
    }

    const qint64 nowNs = QDateTime::currentMSecsSinceEpoch() * 1000000LL;
    if (m_lastIntelSampleTimeNs > 0) {
        const qint64 deltaBusy = totalBusyNs - m_lastIntelBusyNs;
        const qint64 deltaTime = nowNs - m_lastIntelSampleTimeNs;
        if (deltaTime > 0 && deltaBusy >= 0) {
            double pct = (double(deltaBusy) / double(deltaTime)) * 100.0;
            pct = qBound(0.0, pct, 100.0);
            setLoadText(QString("GPU: %1%").arg(qRound(pct)));
        }
    } else {
        setLoadText("GPU: …");
    }
    m_lastIntelBusyNs = totalBusyNs;
    m_lastIntelSampleTimeNs = nowNs;
}
