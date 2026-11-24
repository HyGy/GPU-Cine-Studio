#pragma once

// UI-thread hang watchdog (Linux only, no-op elsewhere; no GStreamer
// dependency).
//
// A QTimer on the main thread refreshes a monotonic heartbeat every
// 250 ms; a plain std::thread checks it once a second. When the heartbeat
// is older than the threshold (default 8 s, env GCS_HANG_THRESHOLD_MS,
// minimum 1000) it handles the stall ONCE (re-armed only after the
// heartbeat moves again), at most 5 dumps per run:
//   - prints "HANG: UI thread not responding for N s, writing backtrace
//     to <path>" to stderr,
//   - writes hang-YYYYMMDD-HHMMSS.txt into the app config directory (the
//     same AppConfigLocation as crash.log / operation_log.txt, so
//     isolated-XDG instances write into their own dir), containing a
//     header (heartbeat age, app version, pid) and `thread apply all bt`
//     of this very process produced by a gdb child. If gdb is not in PATH
//     the file says so and lists the threads from /proc/self/task.
//   - when the heartbeat moves again it logs "UI thread recovered after
//     N s", so a long legitimate blocking operation can be told apart
//     from a deadlock.
//
// ptrace without sudo: with kernel.yama.ptrace_scope=1 only ancestors
// may attach, so the process names the gdb child it just forked as its
// tracer with prctl(PR_SET_PTRACER, <gdb pid>) (never PR_SET_PTRACER_ANY)
// and only then lets the child exec gdb through a pipe.
//
// Environment:
//   GCS_HANG_WATCHDOG=0        disable (default: on)
//   GCS_HANG_THRESHOLD_MS=<n>  stall threshold in ms
//   GCS_HANG_REPORT_INACTIVE=1 also report while the app is inactive / the
//                              window not exposed (default: such a stall only
//                              logs one info line; the driver blocks the swap
//                              of hidden windows, which is not a real hang).
//                              The activity state sampled at the last
//                              heartbeat is in the report header.
//   GCS_TEST_STALL_MS=<n>      TEST ONLY: the main thread sleeps n ms once,
//                              ~3 s after start(), to provoke a hang.
//                              Never set by the app itself.
namespace HangWatchdog {

// Call on the main thread right before QCoreApplication::exec() (start-up
// work before the event loop would otherwise count as a stall).
void start();

// Idempotent; joins the watchdog thread promptly (never waits a full
// poll interval). Safe to call from aboutToQuit and again after exec().
void stop();

} // namespace HangWatchdog
