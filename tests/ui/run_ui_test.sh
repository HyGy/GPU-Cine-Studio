#!/bin/bash
# Runs a single AT-SPI based UI regression test against a freshly built app.
# By default it uses an isolated virtual display (Xephyr) so it doesn't
# touch your real desktop/mouse. Prints PASS/FAIL and exits 0 on success,
# non-zero otherwise.
#
# Usage: tests/ui/run_ui_test.sh [--real|--virtual] [test_script.py [args...]]
#   --virtual (default): spin up a throwaway Xephyr + openbox display.
#   --real:              reuse your existing $DISPLAY (your actual X11
#                        session) instead of a virtual one.
#   test_script.py defaults to test_transition_unlink_drag.py. Any further
#   arguments are passed through to it as-is - e.g. for record.py/replay.py,
#   which take a recording name: run_ui_test.sh --real record.py my-flow
#
# If invoked from tests/run_tests.sh (which runs the whole suite), this
# script detects UI_TEST_SHARED_DISPLAY=1 in the environment and reuses the
# display the orchestrator already set up instead of starting/stopping its
# own Xephyr+openbox for every single test.
#
# Requires (one-time setup): xvfb-or-xserver-xephyr, openbox, xdotool,
# python3-pyatspi, imagemagick (for debug screenshots on failure).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"

MODE="virtual"
TEST_SCRIPT=""
EXTRA_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --real) MODE="real" ;;
        --virtual) MODE="virtual" ;;
        *)
            if [ -z "$TEST_SCRIPT" ]; then
                TEST_SCRIPT="$arg"
            else
                EXTRA_ARGS+=("$arg")
            fi
            ;;
    esac
done
TEST_SCRIPT="${TEST_SCRIPT:-test_transition_unlink_drag.py}"

SHARED_DISPLAY="${UI_TEST_SHARED_DISPLAY:-0}"

DISPLAY_NUM=":97"
XEPHYR_PID=""
OPENBOX_PID=""
APP_PID=""

cleanup() {
    [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null
    # Only tear down what WE started here - a shared or real display
    # belongs to the caller (tests/run_tests.sh, or you), never to us.
    [ -n "$OPENBOX_PID" ] && kill "$OPENBOX_PID" 2>/dev/null
    [ -n "$XEPHYR_PID" ] && kill "$XEPHYR_PID" 2>/dev/null
}
trap cleanup EXIT

if [ ! -x "$BUILD_DIR/gpu-cine-studio" ]; then
    echo "FAIL: $BUILD_DIR/gpu-cine-studio not found - build the project first." >&2
    exit 1
fi

# AT-SPI's desktop tree is not scoped to a single X display: if another
# gpu-cine-studio instance is already running anywhere (your own manual
# testing session, a leftover from a previous run, ...) the test could end
# up querying/clicking the WRONG instance instead of the one we just
# launched. Only one instance may run during the test.
EXISTING_PIDS=$(pgrep -f '/gpu-cine-studio$' || true)
if [ -n "$EXISTING_PIDS" ]; then
    echo "FAIL: another gpu-cine-studio instance is already running (PID(s): $EXISTING_PIDS)." >&2
    echo "      Close it first - AT-SPI lookups are not display-scoped and would be ambiguous." >&2
    exit 1
fi

if [ "$SHARED_DISPLAY" = "1" ]; then
    DISPLAY_NUM="${DISPLAY:?UI_TEST_SHARED_DISPLAY=1 but \$DISPLAY is not set}"
    echo "=== Reusing shared display $DISPLAY_NUM ==="
elif [ "$MODE" = "real" ]; then
    DISPLAY_NUM="${DISPLAY:?--real requires an existing \$DISPLAY (run this from inside your X11 session)}"
    echo "=== Using your real X11 display $DISPLAY_NUM ==="
else
    echo "=== Starting virtual display $DISPLAY_NUM ==="
    Xephyr "$DISPLAY_NUM" -screen 1600x900 >/tmp/ui_test_xephyr.log 2>&1 &
    XEPHYR_PID=$!
    sleep 1

    echo "=== Starting window manager ==="
    DISPLAY="$DISPLAY_NUM" openbox >/tmp/ui_test_openbox.log 2>&1 &
    OPENBOX_PID=$!
    sleep 1
fi

echo "=== Launching app with accessibility enabled ==="
DISPLAY="$DISPLAY_NUM" \
QT_ACCESSIBILITY=1 \
QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 \
"$BUILD_DIR/gpu-cine-studio" >/tmp/ui_test_app.log 2>&1 &
APP_PID=$!
sleep 4

if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "FAIL: app did not start - see /tmp/ui_test_app.log" >&2
    exit 1
fi

echo "=== Running $TEST_SCRIPT ${EXTRA_ARGS[*]:-} ==="
cd "$SCRIPT_DIR"
DISPLAY="$DISPLAY_NUM" python3 "$TEST_SCRIPT" "${EXTRA_ARGS[@]}"
RESULT=$?

# Give you a moment to actually look at the app before cleanup closes it -
# otherwise the window vanishes the instant the script finishes.
sleep 3

if [ $RESULT -ne 0 ]; then
    # Capture unconditionally - even if the app already quit/crashed, the
    # screen state at failure time (what WAS on top, stray dialogs, focus)
    # is exactly what's needed to diagnose why.
    echo "=== Saving failure screenshot ==="
    DISPLAY="$DISPLAY_NUM" import -window root /tmp/ui_test_failure.png 2>/dev/null
    echo "Screenshot: /tmp/ui_test_failure.png"
fi

if [ $RESULT -eq 0 ]; then
    echo ""
    echo "RESULT: PASS"
else
    echo ""
    echo "RESULT: FAIL (exit $RESULT)"
fi

exit $RESULT
