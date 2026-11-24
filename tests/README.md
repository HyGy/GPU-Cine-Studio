# UI tests

Automated end-to-end tests that drive the real, built app (`build/gpu-cine-studio`)
through AT-SPI (accessibility) + `xdotool`, the same way a user would click
and type. They catch things unit tests can't - freezes, wrong clicks, UI
regressions - by actually running the app and checking it stays responsive.

Two ways to get a test: **hand-write** one as a Python script, or **record**
yourself doing it once and replay it later. Both end up runnable the same way.

## One-time setup

```
sudo apt install xserver-xephyr openbox xdotool python3-pyatspi python3-xlib \
    imagemagick xsel
```

Build the app first (`build/gpu-cine-studio` must exist and be up to date).

## Running tests

Everything goes through `tests/run_tests.sh` (the whole suite) or
`tests/ui/run_ui_test.sh` (a single script). Both require picking a mode:

- `--virtual` - spins up a throwaway Xephyr + openbox display, so nothing
  touches your real desktop/mouse. Safe to run while you keep working.
- `--real` - reuses your actual, current `$DISPLAY`. The app window really
  appears and steals mouse/keyboard focus while the test drives it - needed
  for `record.py` (it has to watch you click for real), and generally more
  representative of your actual screen (DPI scaling etc.) than the virtual
  display.

```
# whole suite, virtual display
tests/run_tests.sh --virtual

# whole suite, your real desktop
tests/run_tests.sh --real

# just one test
tests/ui/run_ui_test.sh --real test_add_video_to_timeline.py
```

`run_tests.sh` with no test names discovers every `tests/ui/test_*.py` and
runs them in order, sharing one display across all of them (starting /
tearing down Xephyr+openbox once, not per test). Pass specific filenames to
run only those:

```
tests/run_tests.sh --virtual test_transition_unlink_drag.py
```

Only one `gpu-cine-studio` process may be running anywhere on the system
while a test runs (AT-SPI lookups aren't scoped to a single display, so a
second instance would make element lookups ambiguous) - close any manually
running copy first.

On failure, a screenshot is saved to `/tmp/ui_test_failure.png` and the
app's own log to `/tmp/ui_test_app.log`.

## Hand-written tests (`tests/ui/test_*.py`)

Plain Python scripts using the helpers in `tests/ui/atspi_helpers.py`
(`click`, `double_click`, `right_click`, `drag_to`, `type_text`, `find_one`,
`find_all`, `wait_until`, `assert_responsive`, `dump_tree`, ...). Elements
are found by their accessible name/role (set via `Accessible.name` /
`Accessible.role` in the QML), not pixel coordinates, so they keep working
regardless of window size, position, or display scaling.

Use `test_transition_unlink_drag.py` or `test_add_video_to_timeline.py` as
a starting template. If an element you need isn't findable, it probably
just needs `Accessible.name`/`Accessible.role` added to its QML - see the
existing ones for the pattern.

Good for: precise, deliberate checks (e.g. "assert the clip's left edge is
within 60px of the track start").

## Recorded tests (`tests/ui/recordings/*.json`)

For flows that are tedious to hand-write selectors for, record yourself
doing it once instead:

```
tests/ui/run_ui_test.sh --real record.py <recording-name>
```

This launches the app and starts watching your input. Interact with the
app normally - click, type, drag. When you're done, press **Ctrl+Alt+R**
anywhere (no need to switch windows) to stop and save to
`tests/ui/recordings/<recording-name>.json`. Switching to the terminal and
typing `done` + Enter still works as a fallback, but those keystrokes get
seen by the recorder too - it trims a trailing "done" automatically, but
Ctrl+Alt+R avoids the issue entirely.

What gets recorded, as an accessible element (name + role + position
inside it) rather than a raw screen point - so replay keeps working even
if the window moved, resized, or the display scale changed:

- **Click** - a single click on a widget.
- **Double-click** - two quick clicks (<400ms) on the same widget.
- **Drag** - press, move, release; recorded from wherever you pressed to
  wherever you released.
- **Typing** - a run of plain characters (a word, a path, ...) is recorded
  as one `type_text` action, not one `key` action per character. Replay
  sets the whole string via a single AT-SPI call (`EditableText.
  setTextContents`) on the field it was typed into, instead of N
  synthetic keystrokes - besides being faster, N keystrokes also fire N
  Qt accessibility text-change notifications, which measurably bogs down
  the app's main thread for longer text (confirmed: the delay before the
  next AT-SPI lookup scaled with how much text was typed).
- **Other key presses**, including chords (`Ctrl+A`, `Return`, arrow
  keys, ...), are recorded individually as `key` actions.
- **Paste** (`Ctrl+V`) - the clipboard's actual text content is captured
  and saved as a `paste_text` action (same one-shot AT-SPI replay as
  typing), so replay doesn't depend on the clipboard still holding the
  same thing later.
- **Alt+Tab / Alt+Shift+Tab are NOT recorded** - switching to another
  window (e.g. to copy a string before pasting it back) is fine; only the
  resulting paste is captured, not the window switch itself.

Only input that actually targets the app is recorded at all: clicks
elsewhere on your desktop/other windows are ignored outright, and key
presses are only recorded while an app window has keyboard focus.

If a click doesn't land on an actual widget (missed by a few pixels), you
get a loud warning right in the terminal - click the real target again
instead of leaving the bad one in. Replaying a click that never resolved
to a specific widget is how an earlier version of this tool ended up
clicking into an unrelated window on the real desktop; `replay.py` now
refuses those by default (see below) as a second safety net, but it's
better to just not record them in the first place.

Scrolling a long list (e.g. the Media Browser's file list) doesn't resolve
to one element the way a click does, so prefer typing/pasting a path
directly into the path field, or the arrow keys, over the mouse wheel when
navigating lists during a recording.

Replay it with:

```
tests/ui/run_ui_test.sh --real replay.py <recording-name>
```

This re-finds every recorded element fresh by name/role and replays the
clicks/keys/drags/pastes against it - same robustness to window size and
display scale as the hand-written tests.

Before trusting a replay (especially the first time for a given
recording), preview it without touching the mouse/keyboard:

```
tests/ui/run_ui_test.sh --real replay.py <recording-name> --dry-run
```

This prints exactly which element (or raw point) each action resolves to
and where, without clicking or typing anything. If the recording has any
click/drag endpoint that never resolved to a named widget, the real replay
refuses to run by default (`--dry-run` still shows it) - pass
`--allow-raw-points` once you've confirmed with `--dry-run` that those
points land where you expect, on this app's own window.

Good for: quickly capturing an end-to-end flow (e.g. "create a project,
import a file, drop it on the timeline") without writing selector code for
every step.

## Media used by tests

`tests/sourceFiles/` holds real sample video files the tests import/drag
into projects. `tests/testProjects/` is where test-created `.gpucs`
projects get saved - safe to delete its contents between runs.
