#!/usr/bin/env python3
"""
Standalone diagnostic - no app, no AT-SPI, nothing but raw X11 input.
Prints every line `xinput test-xi2 --root` produces. Click and type
anywhere on your real desktop and watch what (if anything) shows up here.

Run directly (NOT through run_ui_test.sh):
    python3 tests/ui/raw_input_probe.py
Ctrl+C to stop.
"""
import os
import subprocess
import sys

display_name = os.environ.get("DISPLAY", ":0")
print(f"Running: xinput test-xi2 --root (DISPLAY={display_name})")
print("Click / type anywhere now. Ctrl+C to stop.\n")

proc = subprocess.Popen(
    ["xinput", "test-xi2", "--root"],
    env={**os.environ, "DISPLAY": display_name},
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    text=True, bufsize=1,
)
try:
    for line in proc.stdout:
        print(line, end="")
        sys.stdout.flush()
except KeyboardInterrupt:
    print("\nStopped.")
finally:
    proc.terminate()
