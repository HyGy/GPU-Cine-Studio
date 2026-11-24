#include "core/X11ThreadInit.h"
#include "core/AppPaths.h"
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QTimer>
#include <QSettings>
#include <QIcon>
#include <QPalette>
#include <QColor>
#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QScopedPointer>
#include <gst/gst.h>
#include <glib.h>
#include "core/VideoEngine.h"
#include "core/Qml6GLSink.h"
#include "core/TimelineEngine.h"
#include "core/ProjectBinModel.h"
#include "core/BackendManager.h"
#include "core/GpuLoadMonitor.h"
#include "core/Theme.h"
#include "core/ColorSchemeWatcher.h"
#include "core/CodecCheck.h"
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include "core/TestApiServer.h"
#include "core/HangWatchdog.h"
#include "core/gl/gstgllut3d.h"
#include "core/gl/gstglcurves.h"
#include "core/gl/gstglbrightcontrast.h"
#include "ui/VideoOutput.h"

#include <QSocketNotifier>

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>
#include <fcntl.h>
#include <execinfo.h>
#include <sys/socket.h>

namespace {

// Written once at startup so the signal handler never has to allocate.
char g_crashLogPath[1024] = {0};
char g_programPath[1024] = {0};

void crashSignalHandler(int sig) {
    const char *name = "UNKNOWN";
    switch (sig) {
        case SIGSEGV: name = "SIGSEGV (segmentation fault)"; break;
        case SIGABRT: name = "SIGABRT (abort)"; break;
        case SIGFPE:  name = "SIGFPE (floating point exception)"; break;
        case SIGILL:  name = "SIGILL (illegal instruction)"; break;
        case SIGBUS:  name = "SIGBUS (bus error)"; break;
    }

    void *frames[64];
    int frameCount = backtrace(frames, 64);

    // backtrace_symbols_fd is async-signal-safe enough for our purposes
    // (no malloc on our part); write to stderr and, if available, to a log file.
    dprintf(STDERR_FILENO, "\n=== GPU Cine Studio crashed: %s ===\n", name);
    backtrace_symbols_fd(frames, frameCount, STDERR_FILENO);
    dprintf(STDERR_FILENO, "=== end of backtrace (%d frames) ===\n", frameCount);
    dprintf(STDERR_FILENO, "Tip: run under gdb for a symbolized backtrace:\n"
                           "  gdb -batch -ex run -ex bt --args %s\n", g_programPath);

    if (g_crashLogPath[0] != '\0') {
        int fd = open(g_crashLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            dprintf(fd, "\n=== GPU Cine Studio crashed: %s ===\n", name);
            backtrace_symbols_fd(frames, frameCount, fd);
            dprintf(fd, "=== end of backtrace (%d frames) ===\n", frameCount);
            close(fd);
        }
    }

    // Re-raise with default disposition so the OS still produces a core dump / correct exit code.
    signal(sig, SIG_DFL);
    raise(sig);
}

void installCrashHandler(const char *programPath) {
    const QString logDir = AppPaths::configDir();
    QDir().mkpath(logDir);
    const QByteArray path = (logDir + "/crash.log").toLocal8Bit();
    snprintf(g_crashLogPath, sizeof(g_crashLogPath), "%s", path.constData());
    snprintf(g_programPath, sizeof(g_programPath), "%s", programPath);

    signal(SIGSEGV, crashSignalHandler);
    signal(SIGABRT, crashSignalHandler);
    signal(SIGFPE, crashSignalHandler);
    signal(SIGILL, crashSignalHandler);
    signal(SIGBUS, crashSignalHandler);
}

// Ctrl+C in the launching terminal (SIGINT) previously fell through to
// the OS default disposition - an immediate, unclean process kill that
// never ran the app's own safe-shutdown sequence (main.qml's
// onClosing/checkCleanupAndQuit, which waits for the GES/GStreamer
// engines to tear down before actually exiting). A signal handler
// can't safely call into Qt/GLib itself (not async-signal-safe), so
// this uses the standard self-pipe trick: the handler only writes one
// byte to a socketpair, and a QSocketNotifier on the Qt event loop
// (set up in main(), after QGuiApplication exists) does the actual
// QCoreApplication::quit() call once that byte arrives. SIGTERM (a
// plain `kill`, no -9) gets the same treatment for consistency.
int g_sigintFd[2] = {-1, -1};

void sigintHandler(int) {
    char marker = 1;
    ssize_t written = ::write(g_sigintFd[1], &marker, sizeof(marker));
    (void)written; // nothing useful to do with a failed write here
}

void installSigintHandler() {
    if (::socketpair(AF_UNIX, SOCK_STREAM, 0, g_sigintFd) != 0) {
        return; // best-effort - Ctrl+C just falls back to the OS default
    }
    signal(SIGINT, sigintHandler);
    signal(SIGTERM, sigintHandler);
}

// Validates (and, if needed, rewrites) the fontconfig cache before Qt touches
// any fonts. A stale/corrupt cache entry crashes deep inside Qt's font
// shaping code (FcCharSetHasChar) with no useful diagnostics, so we run
// fontconfig's own up-to-date check up front instead of waiting to hit it.
// Unforced fc-cache only re-validates what looks out-of-date, so on a
// healthy cache this costs a few milliseconds - cheap enough to always run.
void validateFontCache() {
    int rc = std::system("fc-cache");
    if (rc != 0)
        fprintf(stderr, "fc-cache validation failed (exit %d); continuing anyway.\n", rc);
}

} // namespace

// QSettings identity: <XDG_CONFIG_HOME>/gpu-cine-studio/gpu-cine-studio.conf
// (same folder as config.json, hang reports, operation_log.txt). Before
// this was set, QSettings wrote to "Unknown Organization/gpu-cine-studio.conf"
// - a folder other apps (e.g. DaVinci Resolve) share. One-time migration:
// copy the old file over if the new one does not exist yet. The old file
// is never moved or deleted.
void setupSettingsIdentityAndMigrate() {
    QCoreApplication::setOrganizationName(QStringLiteral("gpu-cine-studio"));
    QCoreApplication::setApplicationName(QStringLiteral("gpu-cine-studio"));

    const QString base = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
    const QString newPath = base + QStringLiteral("/gpu-cine-studio/gpu-cine-studio.conf");
    const QString oldPath = base + QStringLiteral("/Unknown Organization/gpu-cine-studio.conf");
    if (!QFileInfo::exists(newPath) && QFileInfo::exists(oldPath)) {
        QDir().mkpath(QFileInfo(newPath).absolutePath());
        if (QFile::copy(oldPath, newPath))
            qInfo().noquote() << "Settings migrated (copied):" << oldPath << "->" << newPath;
        else
            qWarning().noquote() << "Settings migration failed:" << oldPath << "->" << newPath;
    }
}

int main(int argc, char *argv[]) {
    // Must run before any QSettings is constructed anywhere.
    setupSettingsIdentityAndMigrate();

    // Xlib docs require this be the very first Xlib-touching call in
    // the process if more than one thread will ever touch an X11
    // Display - true here regardless of video sink path: GStreamer
    // streaming threads hand off buffers while the Qt/main thread
    // renders, and some decode/sink elements (VA-API, the native-
    // window fallback path) talk to X11 directly. Cheap, one-time,
    // defensive - NOT a fix for any specific bug (an earlier version
    // of this comment blamed it for the installGLSink/autovideosink
    // fallback issue; that turned out to be an unrelated GES state-
    // check bug in TimelineEngine.cpp's installGLSink(), fixed there -
    // disabling it did not actually fix that issue when tested live).
    gcsInitXThreads();

    installCrashHandler(argv[0]);
    installSigintHandler();
    validateFontCache();

    // Initialize GStreamer
    gst_init(&argc, &argv);

    // Register our own "gcclut3d" 3D LUT GL filter (ClipEffects.cpp's
    // "lut3d" registry entry) into the default registry - this app is
    // self-contained and should not depend on third-party GStreamer
    // plugin discovery/GST_PLUGIN_PATH for an element it ships itself.
    if (!gst_gl_lut3d_register()) {
        fprintf(stderr, "warning: could not register gcclut3d; 3D LUT effect unavailable\n");
    }
    // "gcccurves" tonal-curves GL filter (ClipEffects.cpp's "curves"
    // registry entry) - same self-contained-registration rationale as
    // gcclut3d above.
    if (!gst_gl_curves_register()) {
        fprintf(stderr, "warning: could not register gcccurves; Curves effect unavailable\n");
    }
    // "gccbc" GPU brightness/contrast (frei0r-compatible) - used by the
    // "brightness"/"contrast" registry entries in GL timeline mode.
    if (!gst_gl_bright_contrast_register()) {
        fprintf(stderr, "warning: could not register gccbc; GPU brightness/contrast unavailable\n");
    }

    // Spike: force-load the "qml6" GStreamer plugin NOW, before the QML
    // engine parses anything. qml6glsink's QML type (GstGLQt6VideoItem,
    // import org.freedesktop.gstreamer.Qt6GLVideoItem) is NOT registered
    // via a qmldir/qmltypes file - this build's ext/qt6/meson.build never
    // runs qmltyperegistrar, so QML_ELEMENT on Qt6GLVideoItem is inert.
    // The actual registration is imperative, in the qml6 plugin's
    // plugin_init (gstqt6element.cc's qt6_element_init(), wired via
    // GST_ELEMENT_REGISTER_DEFINE_WITH_CODE on the qml6glsink factory) -
    // it only runs once that plugin is loaded, and it must run before
    // QQmlApplicationEngine::load() or the import fails with "module not
    // installed". A throwaway factory probe is enough to trigger plugin
    // load; it's immediately discarded.
    if (GstElement *probe = gst_element_factory_make("qml6glsink", nullptr)) {
        gst_object_unref(probe);
    } else {
        fprintf(stderr, "warning: qml6glsink not available - qml6-gl-video-sink spike inactive\n");
    }

    // Never let a host platform-theme plugin (GTK3/KDE bridge) inject
    // its own palette on top of ours. On this dev machine (Cinnamon/
    // GTK desktop) the .deb install picks up libqgtk3.so automatically
    // via apt dependencies and happens to apply a dark palette that
    // looked consistent with ours - but the AppImage never bundles
    // that plugin (it's loaded dynamically at runtime, invisible to
    // linuxdeploy's static dependency walk), so it fell back to Qt's
    // own neutral/light default for any control reading
    // control.palette.* without an explicit color override (confirmed
    // via QtQuick.Controls.Basic's ToolButton.qml/MenuBarItem.qml
    // source - they correctly read control.palette.buttonText /
    // .windowText, so the component logic was never the bug). Forcing
    // this empty makes BOTH packaging forms resolve colors purely from
    // our own QPalette below, deterministically, regardless of the
    // host desktop's theme.
    qputenv("QT_QPA_PLATFORMTHEME", QByteArray());

    // Partial custom Qt Quick Controls style (src/ui/styles/GCSStyle/):
    // only the control types that have a .qml file there (the MenuBar /
    // Menu family - the components that stayed broken even after the
    // platform-theme fix above) are overridden; everything else comes
    // from the fallback style set just below. This is NOT
    // the same thing as a blanket QQuickStyle::setStyle("Basic")/
    // ("Fusion") call - that was tried earlier this session and broke
    // the .deb build too, because it switches every control's styling
    // wholesale instead of leaving unlisted ones on the fallback path.
    // QQuickStyle::addStylePath() is a newer-Qt-only convenience (not
    // present in Qt 6.4.2's QQuickStyle, confirmed against this build's
    // headers). setStyle() itself rejects a path outright ("Style names
    // must not contain paths" - confirmed live), and
    // QT_QUICK_CONTROLS_STYLE_PATH did not make the qrc-embedded style
    // resolve either (also confirmed live: "module GCSStyle is not
    // installed" - that env var appears to search real filesystem
    // directories, not qrc paths). So: a bare style NAME here, with the
    // qrc path registered as a normal QML import path on the engine
    // instead (see engine.addImportPath() below) - that mechanism is
    // documented to support qrc paths.
    //
    // The fallback is NOT optional and NOT cosmetic. A custom style only
    // provides the control types it has files for; every other control
    // comes from the fallback style, which defaults to "Basic" - but the
    // style this machine resolved by itself before GCSStyle existed was
    // Fusion (measured: a bare Button is 24px tall under the default
    // resolution and under an explicit QT_QUICK_CONTROLS_STYLE=Fusion,
    // 40px under =Basic). So merely naming a custom style silently
    // re-styled the whole app Basic and changed every uncovered
    // control's metrics AND which palette roles it reads - that is the
    // single cause of all three regressions reported after a932715:
    //   - Basic/TabButton.qml paints inactive tab text with
    //     palette.brightText (Fusion uses buttonText for both states),
    //     which our palette had set to Qt::red -> red "Properties" tab,
    //   - Basic's Button background is implicitly 100x40 vs Fusion's
    //     80x24, so the Media Browser path bar's 30px-tall row (20px
    //     after margins) could no longer fit its buttons,
    //   - Basic's CheckBox indicator is 28x28 vs Fusion's 14x14 (40px
    //     vs 27px implicit control height), which is the "giant Show
    //     Subtitles checkbox" pushing the Clip Monitor transport row.
    // Pinning the fallback explicitly also removes the last piece of
    // host dependence: style resolution is now stated in code instead of
    // inferred from the environment, same as the palette above.
    QQuickStyle::setFallbackStyle(QStringLiteral("Fusion"));
    QQuickStyle::setStyle(QStringLiteral("GCSStyle"));

    // Qt platform selection. On a Wayland session the app runs NATIVE Wayland
    // by default. X11 (XWayland, xcb) is used instead when
    //   - QT_QPA_PLATFORM is set explicitly (always wins; "xcb" forces X11),
    //   - GCS_FORCE_X11=1, or Settings > Playback > "Force X11" is ticked
    //     (QSettings key display/forceX11; read here, before QGuiApplication -
    //     the organisation/application name are already set by
    //     setupSettingsIdentityAndMigrate() above, which QSettings needs), or
    //   - safety fallback: the GStreamer qml6 plugin lacks Wayland support
    //     (Qml6GLSink::pluginSupportsWayland(); gst_init() above already made the
    //     plugin registry available), because the video preview would stay
    //     black. GCS_NATIVE_WAYLAND=1 is kept as a developer override that
    //     skips this check and stays native.
    {
        const QByteArray qpa = qgetenv("QT_QPA_PLATFORM");
        const bool haveX = !qEnvironmentVariableIsEmpty("DISPLAY");
        const bool nativeForced = qgetenv("GCS_NATIVE_WAYLAND") == "1";
        const bool pluginOk = nativeForced || Qml6GLSink::pluginSupportsWayland();
        const char *noPluginMsg =
            "WARNING: native Wayland would be used, but the GStreamer qml6 plugin was built "
            "without Wayland support (libQt6WaylandClient is not linked)";
        const char *rebuildMsg =
            "Rebuild GStreamer with scripts/build-gstreamer.sh (needs qt6-wayland-dev) for native Wayland.";

        if (!qpa.isEmpty()) {
            if (qpa.startsWith("wayland") && !pluginOk) {
                if (haveX) {
                    qputenv("QT_QPA_PLATFORM", "xcb");
                    fprintf(stderr, "%s - falling back to xcb (XWayland). %s\n", noPluginMsg, rebuildMsg);
                } else {
                    fprintf(stderr, "%s and there is no DISPLAY to fall back to: the video preview will not work.\n", noPluginMsg);
                }
            }
        } else if (!qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY")
                   || qgetenv("XDG_SESSION_TYPE") == "wayland") {
            const bool forceX11 = qgetenv("GCS_FORCE_X11") == "1"
                || QSettings().value(QStringLiteral("display/forceX11"), false).toBool();
            if (forceX11 && haveX) {
                qputenv("QT_QPA_PLATFORM", "xcb");
                fprintf(stderr, "Wayland session: X11 (XWayland, xcb) forced by GCS_FORCE_X11 / Settings.\n");
            } else if (!pluginOk && haveX) {
                qputenv("QT_QPA_PLATFORM", "xcb");
                fprintf(stderr, "%s - falling back to xcb (XWayland). %s\n", noPluginMsg, rebuildMsg);
            } else {
                if (forceX11)
                    fprintf(stderr, "Warning: X11 forced but there is no DISPLAY (no XWayland) - using native Wayland.\n");
                else if (!pluginOk)
                    fprintf(stderr, "%s and there is no DISPLAY to fall back to: the video preview will not work.\n", noPluginMsg);
                else
                    fprintf(stderr, "Wayland session detected: using native Wayland "
                                    "(GCS_FORCE_X11=1 or Settings > Playback forces X11).\n");
            }
        }
    }

    QGuiApplication app(argc, argv);

    // Wayland compositors match the window to its launcher/icon through the
    // app id, which Qt derives from the desktop file name (must equal
    // packaging/gpu-cine-studio.desktop minus ".desktop").
    QGuiApplication::setDesktopFileName(QStringLiteral("gpu-cine-studio"));
    // qml6glsink renders through OpenGL textures: pin Qt Quick's scene graph to
    // OpenGL (before any window exists) so a different default RHI backend
    // cannot be picked on some platform.
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);

    // Wires the SIGINT/SIGTERM self-pipe (installSigintHandler(), called
    // above before Qt existed) into the Qt event loop: once the signal
    // handler writes its marker byte, this notifier fires and runs the
    // app's normal clean-shutdown path instead of the OS just killing
    // the process - a plain OS-default SIGINT never gave the GES/
    // GStreamer engines a chance to tear down (main.qml's
    // onClosing/checkCleanupAndQuit).
    if (g_sigintFd[0] >= 0) {
        QSocketNotifier *sigintNotifier = new QSocketNotifier(g_sigintFd[0], QSocketNotifier::Read, &app);
        QObject::connect(sigintNotifier, &QSocketNotifier::activated, &app, [sigintNotifier]() {
            char marker;
            ssize_t bytesRead = ::read(sigintNotifier->socket(), &marker, sizeof(marker));
            (void)bytesRead;
            qInfo() << "Received interrupt - starting clean shutdown...";
            BackendManager::markSignalQuit();
            QCoreApplication::quit();
        });
    }

    // Single source of truth for every color in the app - see Theme.h.
    // Declared here (not inside a narrower scope) so it outlives
    // QQmlApplicationEngine below; qmlRegisterSingletonInstance() shares
    // this exact instance with QML further down.
    Theme theme;
    app.setPalette(theme.palette());

    // Portal-based system light/dark detection (see ColorSchemeWatcher.h).
    // Not wired to Theme's mode yet - this phase only proves the
    // detection itself works, logged via qInfo(); nothing visually
    // changes until a later phase consumes detectedMode().
    ColorSchemeWatcher colorSchemeWatcher;

    // Set application icon
    app.setWindowIcon(QIcon(":/icons/app_icon.svg"));

    // Integrate GLib main context with Qt event loop
    // This is essential for GES and other async GStreamer operations
    QTimer glibTimer;
    QObject::connect(&glibTimer, &QTimer::timeout, []() {
        g_main_context_iteration(g_main_context_default(), FALSE);
    });
    glibTimer.start(10); // Iterate GLib context every 10ms

    // Register C++ types for QML
    qmlRegisterType<VideoEngine>("VideoEditor", 1, 0, "VideoEngine");
    qmlRegisterType<TimelineEngine>("VideoEditor", 1, 0, "TimelineEngine");
    qmlRegisterType<VideoOutput>("VideoEditor", 1, 0, "VideoOutput");
    // Uncreatable: QML only ever reaches this through Backend.projectBinModel
    // (a live C++-owned instance), never instantiates its own. Registering
    // it at all is what's needed for its Roles enum (DurationRole,
    // ResolutionRole, ...) to resolve from QML - without a QML type
    // registration, "Backend.projectBinModel.DurationRole" is silently
    // undefined even with Q_ENUM(Roles) in the C++ class (confirmed live:
    // every SourceMonitor.qml metadata field was reading back role 0 /
    // Qt::DisplayRole instead, i.e. showing the filename for every field).
    qmlRegisterUncreatableType<ProjectBinModel>("VideoEditor", 1, 0, "ProjectBinModel",
        "ProjectBinModel is only accessible via Backend.projectBinModel");

    // Register BackendManager as QML singleton
    qmlRegisterSingletonType<BackendManager>("VideoEditor", 1, 0, "Backend",
        [](QQmlEngine *engine, QJSEngine *scriptEngine) -> QObject * {
            Q_UNUSED(engine)
            Q_UNUSED(scriptEngine)
            return new BackendManager();
        }
    );

    // Register GpuLoadMonitor as QML singleton
    qmlRegisterSingletonType<GpuLoadMonitor>("VideoEditor", 1, 0, "GpuMonitor",
        [](QQmlEngine *engine, QJSEngine *scriptEngine) -> QObject * {
            Q_UNUSED(engine)
            Q_UNUSED(scriptEngine)
            return new GpuLoadMonitor();
        }
    );

    // Shares the single Theme/ColorSchemeWatcher instances constructed
    // above with QML, rather than letting qmlRegisterSingletonType's
    // factory lambda create its own separate instance (that would be a
    // second, out-of-sync copy of the SAME theme - the opposite of the
    // "one source of truth" this class exists for).
    qmlRegisterSingletonInstance<Theme>("VideoEditor", 1, 0, "Theme", &theme);
    qmlRegisterSingletonInstance<ColorSchemeWatcher>("VideoEditor", 1, 0, "ColorSchemeWatcher",
                                                      &colorSchemeWatcher);

    // Which codec features work with the registered GStreamer plugins (the
    // AppImage takes H.264/H.265/AAC from the host distribution) - drives
    // the "missing codecs" dialog and Settings > Codecs.
    CodecCheck codecCheck;
    qmlRegisterSingletonInstance<CodecCheck>("VideoEditor", 1, 0, "Codecs", &codecCheck);

    QQmlApplicationEngine engine;
    // Makes the qrc-embedded GCSStyle module (src/ui/styles/GCSStyle/)
    // resolvable by name via QQuickStyle::setStyle() above - the
    // engine's own import-path mechanism supports qrc paths directly,
    // unlike QT_QUICK_CONTROLS_STYLE_PATH (see the comment above).
    engine.addImportPath(QStringLiteral(":/ui/styles"));
    const QUrl url(QStringLiteral("qrc:/ui/main.qml"));

    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated,
                     &app, [url](QObject *obj, const QUrl &objUrl) {
        if (!obj && url == objUrl)
            QCoreApplication::exit(-1);
    }, Qt::QueuedConnection);

    engine.load(url);

    // Opt-in local automation API, used to drive the app from an external
    // test script (see src/core/TestApiServer.h) instead of simulated
    // mouse/keyboard input. OFF unless explicitly requested - a creative
    // app must never open a listener of any kind by default.
    QString testApiPath;
    bool testApiRequested = qEnvironmentVariableIsSet("GCS_TEST_API");
    for (int i = 1; i < argc; ++i) {
        const QString a = QString::fromLocal8Bit(argv[i]);
        if (a == QLatin1String("--test-api")) testApiRequested = true;
        else if (a.startsWith(QLatin1String("--test-api="))) {
            testApiRequested = true;
            testApiPath = a.mid(11);
        }
    }
    if (testApiPath.isEmpty()) testApiPath = qEnvironmentVariable("GCS_TEST_API_SOCKET");

    QScopedPointer<TestApiServer> testApi;
    if (testApiRequested && !engine.rootObjects().isEmpty()) {
        testApi.reset(new TestApiServer(&engine, engine.rootObjects().first(), testApiPath));
        testApi->listen();
    }

    // Started only now, right before the event loop: the startup work
    // above (QML singleton creation incl. BackendManager's CUDA/GPU probe,
    // measured at ~2.5 s here) runs before any event loop and would
    // otherwise count as a stall. Writes hang-*.txt with a gdb backtrace
    // if the UI thread stalls later (see core/HangWatchdog.h;
    // GCS_HANG_WATCHDOG=0 disables it).
    HangWatchdog::start();

    int result = app.exec();
    HangWatchdog::stop();
    testApi.reset();

    // Cleanup GStreamer
    gst_deinit();

    return result;
}
