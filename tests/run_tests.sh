#!/bin/bash
# Entry point for the whole test suite.
#
# Each tests/ui/test_*.py is individually runnable on its own via
# tests/ui/run_ui_test.sh, but running the full suite through that script
# directly would pay the Xephyr+openbox startup/teardown cost once PER
# TEST. This script instead starts the display ONCE, shares it with every
# test it runs, and tears it down only after the whole suite is done.
#
# Usage: tests/run_tests.sh --real|--virtual [test1.py test2.py ...]
#   --virtual: one shared Xephyr + openbox display for the run.
#   --real:    reuse your existing $DISPLAY (your actual X11 session) for
#              the whole run instead.
#   The mode is REQUIRED - there is no default, since running on your real
#   display vs. a throwaway virtual one has very different side effects
#   (mouse/keyboard focus stolen, windows popping up, ...).
#   With no test names given, every tests/ui/test_*.py is discovered and
#   run, in sorted order.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="$SCRIPT_DIR/ui"

print_help() {
    cat <<'EOF'
Usage: tests/run_tests.sh --real|--virtual [test1.py test2.py ...]

Required (choose exactly one):
  --real      Run against your existing $DISPLAY (your real X11 session).
              The app window will actually appear and steal mouse/keyboard
              focus while the test drives it.
  --virtual   Run in a throwaway Xephyr + openbox display, so it doesn't
              touch your real desktop. One display is started and shared
              across all tests in this run, then torn down at the end.

Optional:
  test1.py test2.py ...   Specific test(s) to run, by filename, from
                           tests/ui/. If omitted, every tests/ui/test_*.py
                           is discovered and run, in sorted order.

Examples:
  tests/run_tests.sh --virtual
  tests/run_tests.sh --real test_transition_unlink_drag.py
EOF
}

MODE=""
TESTS=()
for arg in "$@"; do
    case "$arg" in
        --real) MODE="real" ;;
        --virtual) MODE="virtual" ;;
        -h|--help) print_help; exit 0 ;;
        *) TESTS+=("$arg") ;;
    esac
done

if [ -z "$MODE" ]; then
    print_help
    exit 1
fi

if [ ${#TESTS[@]} -eq 0 ]; then
    while IFS= read -r -d '' f; do
        TESTS+=("$(basename "$f")")
    done < <(find "$UI_DIR" -maxdepth 1 -name 'test_*.py' -print0 | sort -z)
fi

if [ ${#TESTS[@]} -eq 0 ]; then
    echo "No tests found under $UI_DIR" >&2
    exit 1
fi

DISPLAY_NUM=":97"
XEPHYR_PID=""
OPENBOX_PID=""

cleanup() {
    [ -n "$OPENBOX_PID" ] && kill "$OPENBOX_PID" 2>/dev/null
    [ -n "$XEPHYR_PID" ] && kill "$XEPHYR_PID" 2>/dev/null
}
trap cleanup EXIT

export UI_TEST_SHARED_DISPLAY=1

if [ "$MODE" = "virtual" ]; then
    echo "=== Starting shared virtual display $DISPLAY_NUM (reused for all tests) ==="
    Xephyr "$DISPLAY_NUM" -screen 1600x900 >/tmp/ui_test_xephyr.log 2>&1 &
    XEPHYR_PID=$!
    sleep 1

    DISPLAY="$DISPLAY_NUM" openbox >/tmp/ui_test_openbox.log 2>&1 &
    OPENBOX_PID=$!
    sleep 1

    export DISPLAY="$DISPLAY_NUM"
else
    : "${DISPLAY:?--real requires an existing \$DISPLAY (run this from inside your X11 session)}"
    echo "=== Using your real X11 display $DISPLAY (shared for all tests) ==="
fi

PASS=0
FAIL=0
FAILED_NAMES=()

for t in "${TESTS[@]}"; do
    echo ""
    echo "############################################"
    echo "# $t"
    echo "############################################"
    if "$UI_DIR/run_ui_test.sh" "$t"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("$t")
    fi
done

echo ""
echo "=== Summary: $PASS passed, $FAIL failed (of $((PASS + FAIL))) ==="
for n in "${FAILED_NAMES[@]}"; do
    echo "  FAIL: $n"
done

[ "$FAIL" -eq 0 ]
