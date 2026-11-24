#include "HangWatchdog.h"
#include "AppPaths.h"

#ifdef __linux__

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QGuiApplication>
#include <QWindow>
#include <QFile>
#include <QStandardPaths>
#include <QThread>
#include <QTimer>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <thread>

#include <fcntl.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef PR_SET_PTRACER
#define PR_SET_PTRACER 0x59616d61
#endif

namespace {

using Clock = std::chrono::steady_clock;

std::atomic<qint64> g_heartbeatNs{0};
std::atomic<bool> g_started{false};
// Written on the GUI thread only (heartbeat + applicationStateChanged), read
// by the watchdog thread: the values as of the last heartbeat.
std::atomic<bool> g_appActive{true};
std::atomic<bool> g_windowExposed{true};
bool g_reportInactive = false;
std::thread g_thread;
std::mutex g_mutex;
std::condition_variable g_cv;
bool g_stop = false;

qint64 nowNs()
{
    return std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now().time_since_epoch()).count();
}

void writeAll(int fd, const QByteArray &data)
{
    const char *p = data.constData();
    qsizetype left = data.size();
    while (left > 0) {
        ssize_t n = ::write(fd, p, size_t(left));
        if (n <= 0) return;
        p += n;
        left -= n;
    }
}

QByteArray procFile(const QString &path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return QByteArray();
    return f.readAll().trimmed();
}

// GUI thread only.
void sampleWindowState()
{
    bool exposed = false;
    const auto wins = QGuiApplication::topLevelWindows();
    for (QWindow *w : wins) {
        if (w->isExposed() && w->visibility() != QWindow::Minimized) { exposed = true; break; }
    }
    g_windowExposed.store(exposed);
    g_appActive.store(QGuiApplication::applicationState() == Qt::ApplicationActive);
}

QByteArray header(double stalledSec, const QString &path)
{
    QByteArray h;
    h += "GPU Cine Studio hang report\n";
    h += "time: " + QDateTime::currentDateTime().toString(Qt::ISODate).toUtf8() + "\n";
#ifdef APP_VERSION
    h += "version: " APP_VERSION "\n";
#endif
    h += QByteArray("app active at last heartbeat: ") + (g_appActive.load() ? "yes" : "no") + "\n";
    h += QByteArray("window exposed at last heartbeat: ") + (g_windowExposed.load() ? "yes" : "no") + "\n";
    h += "pid: " + QByteArray::number(qint64(getpid())) + "\n";
    h += "last heartbeat age: " + QByteArray::number(stalledSec, 'f', 2) + " s\n";
    h += "ptrace_scope: " + procFile(QStringLiteral("/proc/sys/kernel/yama/ptrace_scope")) + "\n";
    h += "report: " + path.toUtf8() + "\n\n";
    return h;
}

// Fallback without gdb: thread ids, names and kernel wait channels.
QByteArray threadList()
{
    QByteArray out = "gdb not found in PATH - no stack traces. Threads of this process:\n";
    const QStringList tids = QDir(QStringLiteral("/proc/self/task")).entryList(QDir::Dirs | QDir::NoDotAndDotDot);
    for (const QString &tid : tids) {
        const QString base = QStringLiteral("/proc/self/task/") + tid;
        out += "  tid " + tid.toUtf8() + "  " + procFile(base + QStringLiteral("/comm"))
             + "  wchan=" + procFile(base + QStringLiteral("/wchan")) + "\n";
    }
    out += "(main thread tid == pid " + QByteArray::number(qint64(getpid())) + ")\n";
    return out;
}

void runGdb(const QString &gdbPath, const QString &outPath, double stalledSec)
{
    // Everything the child needs is prepared BEFORE fork(): the process is
    // multi-threaded, so between fork and exec only async-signal-safe calls
    // (read, dup2, close, execv, _exit) may run.
    int outFd = ::open(outPath.toLocal8Bit().constData(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (outFd < 0) return;
    writeAll(outFd, header(stalledSec, outPath));

    const QByteArray gdbBytes = gdbPath.toLocal8Bit();
    const QByteArray pidStr = QByteArray::number(qint64(getpid()));
    char *argv[] = {
        const_cast<char *>(gdbBytes.constData()),
        const_cast<char *>("-p"), const_cast<char *>(pidStr.constData()),
        const_cast<char *>("-batch"),
        const_cast<char *>("-ex"), const_cast<char *>("set pagination off"),
        const_cast<char *>("-ex"), const_cast<char *>("thread apply all bt"),
        nullptr
    };

    int gate[2];
    if (::pipe(gate) != 0) { ::close(outFd); return; }

    pid_t child = ::fork();
    if (child < 0) { ::close(gate[0]); ::close(gate[1]); ::close(outFd); return; }
    if (child == 0) {
        ::close(gate[1]);
        char c;
        if (::read(gate[0], &c, 1) != 1) _exit(127);   // parent gave up
        ::close(gate[0]);
        ::dup2(outFd, STDOUT_FILENO);
        ::dup2(outFd, STDERR_FILENO);
        ::execv(argv[0], argv);
        _exit(127);
    }

    ::close(gate[0]);
    // Name the child as the one process allowed to ptrace us (Yama scope 1),
    // then release it.
    ::prctl(PR_SET_PTRACER, (unsigned long)child, 0, 0, 0);
    const char go = 1;
    ssize_t w = ::write(gate[1], &go, 1);
    (void)w;
    ::close(gate[1]);

    int status = 0;
    bool done = false;
    for (int i = 0; i < 1200 && !done; ++i) {   // up to 120 s
        pid_t r = ::waitpid(child, &status, WNOHANG);
        if (r == child) done = true;
        else if (r < 0) { done = true; status = -1; }
        else std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    if (!done) {
        ::kill(child, SIGKILL);
        ::waitpid(child, &status, 0);
        writeAll(outFd, "\n[watchdog] gdb did not finish within 120 s, killed\n");
    }
    ::prctl(PR_SET_PTRACER, 0UL, 0, 0, 0);

    QByteArray footer = "\n[watchdog] gdb ";
    if (WIFEXITED(status)) footer += "exit status " + QByteArray::number(WEXITSTATUS(status));
    else footer += "terminated abnormally";
    footer += "\n";
    writeAll(outFd, footer);
    ::close(outFd);
}

void dump(double stalledSec)
{
    QString dir = AppPaths::configDir();
    QDir().mkpath(dir);
    const QString path = dir + QStringLiteral("/hang-")
        + QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd-HHmmss")) + QStringLiteral(".txt");

    fprintf(stderr, "HANG: UI thread not responding for %.0f s, writing backtrace to %s\n",
            stalledSec, path.toLocal8Bit().constData());
    fflush(stderr);

    const QString gdb = QStandardPaths::findExecutable(QStringLiteral("gdb"));
    if (gdb.isEmpty()) {
        QFile f(path);
        if (f.open(QIODevice::WriteOnly | QIODevice::Append)) {
            f.write(header(stalledSec, path));
            f.write(threadList());
        }
        return;
    }
    runGdb(gdb, path, stalledSec);
}

void watchdogLoop(qint64 thresholdNs)
{
    int dumps = 0;
    bool handled = false;
    qint64 handledHb = 0;

    std::unique_lock<std::mutex> lock(g_mutex);
    while (!g_stop) {
        g_cv.wait_for(lock, std::chrono::seconds(1), [] { return g_stop; });
        if (g_stop) break;

        const qint64 hb = g_heartbeatNs.load();
        const qint64 age = nowNs() - hb;

        if (handled) {
            if (hb != handledHb) {
                fprintf(stderr, "UI thread recovered after %.1f s\n", double(hb - handledHb) / 1e9);
                fflush(stderr);
                handled = false;
            }
            continue;
        }
        if (age > thresholdNs && dumps < 5) {
            handled = true;
            handledHb = hb;
            if (!g_reportInactive && (!g_appActive.load() || !g_windowExposed.load())) {
                // Hidden/inactive windows get their swap blocked by the driver;
                // that is not a hang the user can see.
                qInfo("UI stalled %.0f s while the window was inactive - not reported",
                      double(age) / 1e9);
                continue;
            }
            ++dumps;
            lock.unlock();      // never hold the lock while gdb runs (stop() must not wait)
            dump(double(age) / 1e9);
            lock.lock();
        }
    }
}

} // namespace

namespace HangWatchdog {

void start()
{
    // Test hook (documented in the header): provoke one stall.
    bool stallOk = false;
    const qint64 stallMs = qEnvironmentVariable("GCS_TEST_STALL_MS").toLongLong(&stallOk);
    if (stallOk && stallMs > 0) {
        QTimer::singleShot(3000, qApp, [stallMs] {
            fprintf(stderr, "GCS_TEST_STALL_MS: blocking the UI thread for %lld ms\n", stallMs);
            fflush(stderr);
            QThread::msleep(ulong(stallMs));
        });
    }

    if (qgetenv("GCS_HANG_WATCHDOG") == "0") return;
    if (g_started.exchange(true)) return;

    qint64 thresholdMs = 8000;
    bool ok = false;
    const qint64 envMs = qEnvironmentVariable("GCS_HANG_THRESHOLD_MS").toLongLong(&ok);
    if (ok && envMs >= 1000) thresholdMs = envMs;

    g_reportInactive = qEnvironmentVariable("GCS_HANG_REPORT_INACTIVE") == QLatin1String("1");
    sampleWindowState();
    g_heartbeatNs = nowNs();
    QObject::connect(qGuiApp, &QGuiApplication::applicationStateChanged, qApp,
                     [](Qt::ApplicationState st) { g_appActive.store(st == Qt::ApplicationActive); });
    QTimer *beat = new QTimer(qApp);
    beat->setInterval(250);
    QObject::connect(beat, &QTimer::timeout, qApp, [] { sampleWindowState(); g_heartbeatNs.store(nowNs()); });
    beat->start();

    {
        std::lock_guard<std::mutex> g(g_mutex);
        g_stop = false;
    }
    g_thread = std::thread(watchdogLoop, thresholdMs * 1000000LL);

    QObject::connect(qApp, &QCoreApplication::aboutToQuit, qApp, [] { stop(); });
}

void stop()
{
    {
        std::lock_guard<std::mutex> g(g_mutex);
        g_stop = true;
    }
    g_cv.notify_all();
    if (g_thread.joinable()) {
        // If a dump is mid-flight the join waits for gdb (bounded, 120 s max);
        // the normal case returns immediately.
        g_thread.join();
    }
}

} // namespace HangWatchdog

#else

namespace HangWatchdog {
void start() {}
void stop() {}
}

#endif
