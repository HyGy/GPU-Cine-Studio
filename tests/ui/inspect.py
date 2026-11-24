"""
Live accessibility inspector - no clicking, no recording. Move the mouse
around the app and this prints, continuously, which accessible element (if
any) is under the cursor. Use it to find out BEFORE recording a flow
whether the widget you want to interact with has an Accessible.name set in
the QML at all - if it prints "(no named widget here)", that's why
record.py can't resolve a click there, and the QML needs
Accessible.role/Accessible.name added to that item (see TimelineClip.qml
or ProjectSettingsDialog.qml for the pattern).

Usage: tests/ui/run_ui_test.sh --real inspect.py
Ctrl+C in the terminal to stop.
"""

import os
import sys
import time

from Xlib import display

sys.path.insert(0, os.path.dirname(__file__))
from atspi_helpers import DEFAULT_DISPLAY, _display_scale, get_app_root  # noqa: E402
from record import resolve_at  # noqa: E402

POLL_INTERVAL_S = 0.1


def inspect(display_name):
    dpy = display.Display(display_name)
    root = dpy.screen().root

    print("Waiting for the app to be ready...")
    app = get_app_root(timeout=15)
    scale = _display_scale(display_name)
    print("Move the mouse over the app. Ctrl+C here to stop.\n")

    last_printed = None
    try:
        while True:
            pointer = root.query_pointer()
            x, y = pointer.root_x, pointer.root_y
            found = resolve_at(app, x, y, scale)
            if found is None:
                label = f"({x}, {y})  (no named widget here)"
            else:
                label = f"({x}, {y})  [{found['role']}] {found['name']!r}"
            if label != last_printed:
                print(f"  {label}")
                last_printed = label
            time.sleep(POLL_INTERVAL_S)
    except KeyboardInterrupt:
        print("\nStopped.")
    return 0


if __name__ == "__main__":
    sys.exit(inspect(os.environ.get("DISPLAY", DEFAULT_DISPLAY)))
