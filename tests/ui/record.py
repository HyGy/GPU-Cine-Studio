"""
Interactive action recorder.

Instead of hand-writing AT-SPI selectors for every step of a flow, run this
alongside the live app, physically click/type/drag through what you want
tested, and it records each action resolved against the app's accessible
tree (element name + role + relative position inside it) - NOT raw screen
coordinates. tests/ui/replay.py can then replay the recording later,
re-resolving each element fresh, so it stays correct across window moves,
resizes, and DPI scale changes, exactly like the hand-written tests do.

Input is captured via XInput2's "Raw" event stream (`xinput test-xi2
--root`, the same mechanism tools like xev/xnee use) - NOT by polling
button/key state, and NOT via the "cooked" ButtonPress/KeyPress events.
Two things ruled those out during development of this tool:
  - Polling has an inherent race: a real click can transition down-and-up
    between two poll samples and never get seen at all.
  - The "cooked" events follow normal X11 window event propagation: a
    click on an actual app widget is consumed by that app's own window
    and never reaches a separate client selecting on the root window, so
    it silently never shows up there either.
"Raw" events are XInput2 device-level events instead, delivered to every
listener unconditionally regardless of which window (if any) also
receives the input - reliable regardless of input device, click speed, or
what's focused. They don't carry an absolute screen position though, so
the pointer position is queried separately the moment one arrives.

Scrolling a virtualized list (e.g. the Media Browser) doesn't resolve to a
single element the way a click does, so prefer the keyboard (arrow keys,
Enter) over the mouse wheel when navigating lists during a recording -
key presses are recorded as plain key actions and replay exactly.

Usage: tests/ui/run_ui_test.sh --real record.py <recording-name>
  (reuses the same app-launch/display plumbing every other test uses -
  record.py itself just needs a live, accessible app and $DISPLAY)

Only input that actually targets the app is recorded: clicks elsewhere on
your desktop/other windows are ignored outright, and key presses are only
recorded while an app window has keyboard focus - so switching away (e.g.
to copy a string before pasting it back) never pollutes the recording.

While recording:
  - Left/right click a widget to record a click. If it didn't land on an
    actual widget (probably just missed), you'll hear a warning sound and
    see it in the terminal right away - click the real target again
    rather than leaving it in.
  - Two quick clicks on the same widget record as a double-click.
  - Press-drag-release records a drag, from wherever you pressed to
    wherever you released (by element if the release point is over one,
    otherwise as a point relative to the nearest accessible ancestor).
  - Typing a run of plain characters (a word, a path, ...) is buffered
    and recorded as ONE type_text action, not one key action per
    character - replay then sets the whole string in a single AT-SPI
    call instead of N synthetic keystrokes. Any other key (chords like
    Ctrl+A, Return, arrows, ...) ends the buffered run and is recorded
    as its own key action. Only recorded while the app has keyboard focus.
  - Alt+Tab / Alt+Shift+Tab are NOT recorded - switch windows freely
    without polluting the recording.
  - Press Ctrl+Alt+R anywhere to stop and save - no need to switch to
    the terminal (switching there and typing "done" still works as a
    fallback, but see the note on STOP_CHORD below for why it's worse).
"""

import json
import os
import re
import subprocess
import sys
import threading
import time

import pyatspi
from Xlib import XK, display

sys.path.insert(0, os.path.dirname(__file__))
from atspi_helpers import (  # noqa: E402
    APP_NAME,
    DEFAULT_DISPLAY,
    _display_scale,
    _walk,
    get_app_root,
)

RECORDINGS_DIR = os.path.join(os.path.dirname(__file__), "recordings")

# Xlib.XK.keysym_to_string() returns the character a keysym would TYPE
# (e.g. a literal "\t" for Tab, "\r" for Return) - fine for display, but
# not what xdotool's "key" action wants, which is the X11 keysym NAME
# ("Tab", "Return", "BackSpace", ...). Build that name table directly from
# the XK module's own XK_* constants instead.
_KEYSYM_NAMES = {getattr(XK, n): n[3:] for n in dir(XK) if n.startswith("XK_")}


def keysym_name(keysym):
    return _KEYSYM_NAMES.get(keysym, "")


MODIFIER_KEYSYMS = {
    "Control_L": "ctrl", "Control_R": "ctrl",
    "Shift_L": "shift", "Shift_R": "shift",
    "Alt_L": "alt", "Alt_R": "alt",
}

DRAG_THRESHOLD_PX = 15
DOUBLE_CLICK_WINDOW_S = 0.4

# Window-manager-level chords, not app input - recording these would just
# make replay try (and fail) to switch windows. Used e.g. to tab away and
# copy a string from elsewhere before pasting it back (see "ctrl+v" below).
SKIPPED_CHORDS = {"alt+Tab", "alt+shift+Tab"}

# Stops recording without needing to alt-tab to the terminal (which would
# otherwise itself need recording/filtering, same problem as "done" typed
# into the terminal getting picked up by the global key poll below).
# NOTE: must already be in the same "+".join(sorted(modifiers) + [key])
# form the chord-building code below produces (modifiers alphabetical).
STOP_CHORD = "alt+ctrl+r"

WARNING_SOUND = "/usr/share/sounds/freedesktop/stereo/dialog-warning.oga"


def beep():
    """Audible miss-warning - you're looking at the app while recording,
    not the terminal, so printed text alone is easy to miss. Fired via
    Popen (not run) so playback doesn't stall event processing."""
    try:
        subprocess.Popen(["paplay", WARNING_SOUND],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        print("\a", end="", flush=True)  # terminal bell fallback


MISS_SHOTS_DIR = os.path.join(os.path.dirname(__file__), "miss_screenshots")


def save_miss_screenshot(display_name, x, y):
    """Crops a screenshot around a missed click point and returns its path
    (or None on failure) - so what's actually there can be SEEN instead of
    guessed at from coordinates alone."""
    try:
        os.makedirs(MISS_SHOTS_DIR, exist_ok=True)
        path = os.path.join(MISS_SHOTS_DIR, f"miss_{int(time.time() * 1000)}.png")
        margin = 150
        geometry = f"{margin * 2}x{margin * 2}+{max(0, int(x - margin))}+{max(0, int(y - margin))}"
        subprocess.run(
            ["import", "-window", "root", "-crop", geometry, "+repage", path],
            env={**os.environ, "DISPLAY": display_name},
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return path
    except Exception:
        return None


NEAR_MISS_RADIUS_PX = 30


def _rect_distance(x, y, ex, ey, ew, eh):
    """Distance from point (x, y) to the nearest edge of rect (ex,ey,ew,eh)
    - 0 if the point is already inside it."""
    dx = max(ex - x, 0, x - (ex + ew))
    dy = max(ey - y, 0, y - (ey + eh))
    return (dx * dx + dy * dy) ** 0.5


def _snapshot_candidates(app, scale=1.0):
    """Walks the whole AT-SPI tree ONCE and returns every named, visible
    widget's (name, role, physical extents) - the expensive D-Bus part of
    resolving a click, separated out so it can be done in a background
    thread instead of synchronously while a click is waiting to be
    resolved (see _TreeCache below)."""
    candidates = []
    for acc, _ in _walk(app):
        try:
            ext = acc.queryComponent().getExtents(pyatspi.XY_SCREEN)
        except Exception:
            continue
        ex, ey, ew, eh = ext.x * scale, ext.y * scale, ext.width * scale, ext.height * scale
        if ew <= 0 or eh <= 0:
            continue
        try:
            name = acc.name
        except Exception:
            name = ""
        if not name:
            continue
        try:
            role = acc.getRoleName()
        except Exception:
            role = ""
        if role in ("frame", "application"):
            # Matching the whole window/app itself means no smaller,
            # actually-clickable widget was found under the cursor - as
            # good as no match (see describe_point()'s warning below).
            continue
        try:
            state = acc.getState()
            if not (state.contains(pyatspi.STATE_SHOWING) and state.contains(pyatspi.STATE_VISIBLE)):
                # A closed/hidden window (an About box, a dialog you had
                # open earlier, ...) stays in the AT-SPI tree with stale
                # leftover geometry rather than being removed. Without
                # this check its leftover rect can "steal" a click meant
                # for whatever's actually on screen right now.
                continue
        except Exception:
            pass
        candidates.append({"name": name, "role": role, "extents": (ex, ey, ew, eh)})
    return candidates


def _match_point(candidates, x, y):
    """Innermost candidate whose extents contain (x, y), or - if nothing
    contains it exactly - the closest one within NEAR_MISS_RADIUS_PX, to
    absorb small position drift (confirmed: a dialog's footer buttons can
    shift by a few dozen pixels between otherwise-identical sessions
    depending on content length affecting layout) without accepting a
    click that's actually nowhere near anything real. Pure in-memory
    lookup, no D-Bus calls - safe to use on every click without worrying
    about taking too long."""
    best = None
    best_area = None
    nearest = None
    nearest_dist = None
    for c in candidates:
        ex, ey, ew, eh = c["extents"]
        contains = ex <= x < ex + ew and ey <= y < ey + eh
        dist = 0.0 if contains else _rect_distance(x, y, ex, ey, ew, eh)
        if not contains and dist > NEAR_MISS_RADIUS_PX:
            continue
        if contains:
            area = ew * eh
            if best_area is None or area < best_area:
                best = c
                best_area = area
        elif nearest_dist is None or dist < nearest_dist:
            nearest = c
            nearest_dist = dist
    return best or nearest


def resolve_at(app, x, y, scale=1.0):
    """Live (uncached) single-shot version of TreeCache.match() - fine for
    inspect.py's continuous hover polling, where there's no click to race
    against, but NOT for click resolution (see TreeCache)."""
    return _match_point(_snapshot_candidates(app, scale), x, y)


class TreeCache:
    """Keeps a background-refreshed snapshot of the app's accessible
    tree so resolving a click is an instant in-memory lookup instead of a
    live D-Bus tree walk (50-300ms, measured) done at click time.

    That round-trip is the whole problem this exists to solve: a real,
    quick touchpad tap on a button that closes/hides itself on release
    (confirmed via screen recording of the actual behavior) can complete
    - press, release, the app reacting and closing the window - faster
    than one live AT-SPI query takes to run. No amount of querying harder
    or retrying after the fact fixes that; the button is just gone by
    the time any live query would run. Reading from a snapshot that was
    already being refreshed continuously in the background sidesteps the
    race entirely - worst case it's one refresh cycle stale (usually well
    under 300ms), but it was taken WHILE the button still existed, not
    after chasing a query that starts only once the click has already
    happened.
    """

    def __init__(self, app, scale):
        self._app = app
        self._scale = scale
        self._candidates = []
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start_and_wait_ready(self, timeout=5):
        self._thread.start()
        deadline = time.time() + timeout
        while not self._candidates and time.time() < deadline:
            time.sleep(0.02)

    def stop(self):
        self._stop.set()

    def _run(self):
        while not self._stop.is_set():
            try:
                snapshot = _snapshot_candidates(self._app, self._scale)
            except Exception:
                snapshot = None
            if snapshot is not None:
                with self._lock:
                    self._candidates = snapshot
            # No sleep: the next walk starts immediately, so the cache is
            # always as fresh as the D-Bus round-trip allows. That's the
            # whole point - there's no fixed interval to tune here.

    def match(self, x, y):
        with self._lock:
            candidates = self._candidates
        return _match_point(candidates, x, y)


def _has_app_wm_class(win):
    try:
        wm_class = win.get_wm_class()
    except Exception:
        wm_class = None
    return bool(wm_class and any(APP_NAME in part.lower() for part in wm_class))


def _window_belongs_to_app_upward(win, root):
    """Walks UP from an Xlib window to find a WM_CLASS match - for input
    focus, which normally lands on the real client window (or a sub-widget
    inside it), so the match is found by walking toward its ancestors."""
    try:
        for _ in range(15):
            if _has_app_wm_class(win):
                return True
            if win.id == root.id:
                break
            parent = win.query_tree().parent
            if parent is None or parent.id == win.id:
                break
            win = parent
    except Exception:
        pass
    return False


def _window_belongs_to_app_downward(win, max_depth=6):
    """Walks DOWN from an Xlib window to find a WM_CLASS match - for
    query_pointer().child, which is the root's immediate child at that
    point. Reparenting window managers wrap every client in their own
    frame window, so the window actually carrying WM_CLASS is a
    DESCENDANT of that, not an ancestor - the opposite direction from
    input-focus lookups."""
    if win is None or max_depth <= 0:
        return False
    if _has_app_wm_class(win):
        return True
    try:
        children = win.query_tree().children
    except Exception:
        return False
    for child in children:
        if _window_belongs_to_app_downward(child, max_depth - 1):
            return True
    return False


def point_in_app(pointer_child, root):
    """Whether the window literally under the pointer (query_pointer().
    child) is actually THIS app's - checked by WM_CLASS, not by geometric
    containment in the app's own frame bounds.

    Geometric containment alone isn't enough once the app is maximized:
    its frame then spans nearly the whole screen, so any OTHER window
    sitting on top of it at that point (e.g. switching to a text editor to
    copy a string before pasting it back) would incorrectly "contain" the
    click too, and its content would get searched for a named widget
    instead of the click being recognized as not belonging to this app at
    all - which is exactly what was happening before this check existed.
    """
    if pointer_child is None:
        return False
    return _window_belongs_to_app_downward(pointer_child)


def app_has_focus(dpy, root):
    """Whether keyboard focus is currently somewhere inside the app's
    window hierarchy."""
    try:
        win = dpy.get_input_focus().focus
    except Exception:
        return False
    return _window_belongs_to_app_upward(win, root)


def describe_point_cached(cache, x, y):
    found = cache.match(x, y)
    if found is None:
        return {"name": None, "role": None, "point": [x, y]}
    ex, ey, ew, eh = found["extents"]  # already physical pixels
    rel_x = (x - ex) / ew if ew else 0.5
    rel_y = (y - ey) / eh if eh else 0.5
    return {
        "name": found["name"],
        "role": found["role"],
        "rel_x": round(rel_x, 4),
        "rel_y": round(rel_y, 4),
    }


def describe_point(app, x, y, scale=1.0):
    found = resolve_at(app, x, y, scale)
    if found is None:
        return {"name": None, "role": None, "point": [x, y]}
    ex, ey, ew, eh = found["extents"]  # already physical pixels
    rel_x = (x - ex) / ew if ew else 0.5
    rel_y = (y - ey) / eh if eh else 0.5
    return {
        "name": found["name"],
        "role": found["role"],
        "rel_x": round(rel_x, 4),
        "rel_y": round(rel_y, 4),
    }


_EVENT_HEADER_RE = re.compile(r"EVENT type \d+ \((\w+)\)")
# The plain (non-Raw) ButtonPress/KeyPress events follow normal X11 window
# event propagation/selection rules: a click on an actual app widget is
# consumed by that app's own window and never reaches a separate listener
# selecting on the root window, so it silently never shows up - exactly
# what was happening here. The "Raw*" variants are XInput2 device-level
# events instead: delivered to every listener unconditionally, regardless
# of which window (if any) the input also gets routed to. They don't carry
# an absolute position though, so the consumer queries the pointer
# position itself right when one of these arrives.
_RELEVANT_KINDS = {"RawButtonPress", "RawButtonRelease", "RawKeyPress", "RawKeyRelease"}


def _start_xi2(display_name):
    """Starts the `xinput test-xi2 --root` subprocess. Separate from
    _xi2_events() (which just reads from it) so the caller can start it
    early and give it a moment to actually attach to the X server before
    relying on it - there's an unavoidable startup gap between Popen()
    returning and xinput actually being subscribed to events, and a click
    made in that gap (e.g. immediately after "Interact with the app now")
    would be seen by nothing at all - no match, no miss warning, nothing."""
    return subprocess.Popen(
        ["xinput", "test-xi2", "--root"],
        env={**os.environ, "DISPLAY": display_name},
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, bufsize=1,
    )


def _xi2_events(proc, stop_flag):
    """Generator yielding one dict per relevant XI2 event ({"kind",
    "detail"} - see _RELEVANT_KINDS) read from an already-started
    _start_xi2() subprocess."""
    try:
        current = None
        for line in proc.stdout:
            if stop_flag.is_set():
                break
            header = _EVENT_HEADER_RE.match(line.strip())
            if header:
                if current and current["kind"] in _RELEVANT_KINDS:
                    yield current
                current = {"kind": header.group(1)}
                continue
            if current is None:
                continue
            stripped = line.strip()
            if stripped.startswith("detail:"):
                try:
                    current["detail"] = int(stripped.split(":", 1)[1].strip())
                except ValueError:
                    pass
            elif stripped.startswith("root:"):
                try:
                    rx, ry = stripped.split(":", 1)[1].strip().split("/")
                    current["x"] = float(rx)
                    current["y"] = float(ry)
                except ValueError:
                    pass
        if current and current["kind"] in _RELEVANT_KINDS:
            yield current
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except Exception:
            proc.kill()


def record(name, display_name):
    if name.endswith(".json"):
        name = name[: -len(".json")]
    dpy = display.Display(display_name)
    root = dpy.screen().root

    print("Waiting for the app to be ready...")
    app = get_app_root(timeout=15)
    scale = _display_scale(display_name)

    cache = TreeCache(app, scale)
    cache.start_and_wait_ready()

    xi2_proc = _start_xi2(display_name)
    time.sleep(0.4)  # let xinput actually attach before input can be lost

    print(f"Recording '{name}'. Interact with the app now.")
    print("Type 'done' + Enter in THIS terminal when finished.")
    print(f"(or press {STOP_CHORD.upper()} anywhere, no need to switch to the terminal)\n")

    actions = []
    held_modifiers = set()
    press_info = {}  # button -> (x, y, time) | None (None = started outside app)
    last_click = {}
    last_named_click = None  # desc of the last click that landed on a named widget
    pending_chars = []  # buffered run of plain single-character keystrokes

    def flush_pending_text():
        """Consecutive single-character keystrokes (typing a word) are
        buffered and recorded as ONE type_text action instead of N separate
        key actions - replaying N individual key events replays N Qt
        accessibility text-change notifications too, which measurably
        bogs down the app's main thread for longer input (confirmed: delay
        before the next AT-SPI lookup scaled with the typed text's length).
        A single type_text action sets the whole string in one shot."""
        if not pending_chars:
            return
        text = "".join(pending_chars)
        pending_chars.clear()
        action = {"type": "type_text", "text": text}
        if last_named_click and last_named_click.get("name"):
            action["target_name"] = last_named_click["name"]
            action["target_role"] = last_named_click["role"]
        actions.append(action)
        print(f"  [type] {text!r}")

    stop_flag = threading.Event()

    def wait_for_stop():
        # Fallback only - typing "done" here means switching focus to the
        # terminal first, and those keystrokes get seen by the event
        # stream below same as any other key, before this thread ever
        # gets to react. Prefer the STOP_CHORD hotkey (no terminal focus
        # needed, nothing gets recorded).
        try:
            while True:
                line = input()
                if line.strip().lower() == "done":
                    break
        except EOFError:
            pass
        stop_flag.set()

    threading.Thread(target=wait_for_stop, daemon=True).start()

    for event in _xi2_events(xi2_proc, stop_flag):
        if stop_flag.is_set():
            break

        kind = event["kind"]

        if kind == "RawButtonPress":
            button = event.get("detail")
            if button not in (1, 3):
                continue
            pointer = root.query_pointer()
            x, y = pointer.root_x, pointer.root_y
            if point_in_app(pointer.child, root):
                # Resolve the widget right now, from the background cache
                # (see TreeCache) - not via a fresh live query, and not at
                # release either. A button whose own click closes/hides it
                # (e.g. a dialog's OK button) can be fully gone - press,
                # release, app reacts, window closed - faster than a
                # single live AT-SPI query takes to run (confirmed by
                # screen-recorded real touchpad taps); querying live
                # "at press" still loses that race since the query itself
                # is what's slow, no matter when it starts. The cache was
                # already being refreshed continuously before this click
                # ever happened, so reading it is instant.
                press_desc = describe_point_cached(cache, x, y)
                if not press_desc.get("name"):
                    # The cache can lag behind brand-new content the same
                    # way it used to lag behind content disappearing -
                    # e.g. right after switching to a workspace whose
                    # widgets didn't exist in the tree yet as of the
                    # cache's last background refresh (confirmed: a click
                    # that functionally worked - focused the field, text
                    # got typed into it - still came back nameless from
                    # the cache). A live, uncached query doesn't have that
                    # problem, since there's nothing here that's about to
                    # disappear - only used as a fallback so the common
                    # case stays at cache speed.
                    press_desc = describe_point(app, x, y, scale)
                press_info[button] = (x, y, time.time(), press_desc)
            else:
                press_info[button] = None

        elif kind == "RawButtonRelease":
            button = event.get("detail")
            if button not in (1, 3):
                continue
            info = press_info.pop(button, None)
            if info is None:
                continue
            pointer = root.query_pointer()
            x, y = pointer.root_x, pointer.root_y
            px, py, _pt, press_desc = info
            distance = ((x - px) ** 2 + (y - py) ** 2) ** 0.5
            flush_pending_text()
            if distance > DRAG_THRESHOLD_PX:
                start = press_desc
                end = describe_point_cached(cache, x, y)
                actions.append({"type": "drag", "from": start, "to": end})
                print(f"  [drag] {start.get('name')} -> {end.get('name') or end.get('point')}")
            else:
                desc = press_desc
                if not desc.get("name"):
                    beep()
                    shot = save_miss_screenshot(display_name, px, py)
                    print(
                        "  !!! that click didn't land on a specific widget "
                        "(probably just missed the target) - consider "
                        "clicking it again"
                        + (f"\n      screenshot: {shot}" if shot else "")
                    )
                else:
                    last_named_click = desc
                now = time.time()
                click_key = (button, desc.get("name"))
                last = last_click.get(button)
                if (
                    last
                    and desc.get("name") is not None  # never merge two raw-point misses
                    and now - last[0] < DOUBLE_CLICK_WINDOW_S
                    and last[1] == click_key[1]
                    and actions
                    and actions[-1]["type"] == "click"
                ):
                    actions[-1]["type"] = "double_click"
                    print(f"  [double-click] {desc.get('name')}")
                else:
                    actions.append({"type": "click", "button": button, **desc})
                    print(f"  [click{'' if button == 1 else '-right'}] {desc.get('name') or desc.get('point')}")
                last_click[button] = (now, click_key[1])

        elif kind == "RawKeyPress":
            keycode = event.get("detail")
            if keycode is None:
                continue
            keysym = dpy.keycode_to_keysym(keycode, 0)
            keyname = keysym_name(keysym)
            if keyname in MODIFIER_KEYSYMS:
                held_modifiers.add(MODIFIER_KEYSYMS[keyname])
                continue
            if not keyname:
                continue
            chord = "+".join(sorted(held_modifiers) + [keyname])
            if chord == STOP_CHORD:
                flush_pending_text()
                print(f"  [stop] {chord} pressed - finishing recording")
                stop_flag.set()
                break
            if chord in SKIPPED_CHORDS:
                flush_pending_text()
                print(f"  [skip] {chord} (window-manager chord, not recorded)")
                continue
            if not app_has_focus(dpy, root):
                # Typing in another window - e.g. selecting a string to
                # copy before switching back to paste it. Only the paste
                # itself (back inside the app) gets recorded.
                flush_pending_text()
                continue
            if chord == "ctrl+v":
                # The chord alone replays as a blind Ctrl+V, which only
                # reproduces the same result if the clipboard still holds
                # the same thing at replay time - not reliable. Capture
                # the actual clipboard text now instead, so replay can
                # set it directly regardless of clipboard state.
                flush_pending_text()
                try:
                    pasted = subprocess.run(
                        ["xsel", "--clipboard", "--output"],
                        env={**os.environ, "DISPLAY": display_name},
                        capture_output=True, text=True, check=True,
                    ).stdout
                except Exception as e:
                    pasted = ""
                    print(f"    !!! clipboard read failed ({e}), recording plain ctrl+v")
                if pasted:
                    action = {"type": "paste_text", "text": pasted}
                    if last_named_click and last_named_click.get("name"):
                        action["target_name"] = last_named_click["name"]
                        action["target_role"] = last_named_click["role"]
                    actions.append(action)
                    print(f"  [paste] {pasted!r}")
                    continue
            if not held_modifiers and len(keyname) == 1:
                # Plain printable character with no modifiers - buffer it
                # instead of recording a standalone key action (see
                # flush_pending_text()).
                pending_chars.append(keyname)
                continue
            flush_pending_text()
            actions.append({"type": "key", "chord": chord})
            print(f"  [key] {chord}")

        elif kind == "RawKeyRelease":
            keycode = event.get("detail")
            if keycode is None:
                continue
            keysym = dpy.keycode_to_keysym(keycode, 0)
            keyname = keysym_name(keysym)
            if keyname in MODIFIER_KEYSYMS:
                held_modifiers.discard(MODIFIER_KEYSYMS[keyname])

    flush_pending_text()
    cache.stop()

    # Safety net for the stdin "done" fallback: trim a trailing run of
    # single-character key actions that spells "done" (those keystrokes
    # happen in the terminal, after the stop chord, but the event stream
    # above sees them exactly like any other key press). In practice this
    # no longer triggers - typing in the terminal means the app doesn't
    # have focus, which is filtered out before it ever reaches here - but
    # it's a harmless extra safety net to keep.
    trailing = "".join(
        a["chord"] for a in actions[-4:] if a["type"] == "key" and len(a.get("chord", "")) == 1
    )
    if len(actions) >= 4 and trailing.lower() == "done":
        print("  (trimming trailing 'done' keystrokes typed into the terminal)")
        del actions[-4:]

    os.makedirs(RECORDINGS_DIR, exist_ok=True)
    out_path = os.path.join(RECORDINGS_DIR, f"{name}.json")
    with open(out_path, "w") as f:
        json.dump(actions, f, indent=2)
    print(f"\nSaved {len(actions)} actions to {out_path}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: record.py <recording-name>", file=sys.stderr)
        sys.exit(1)
    sys.exit(record(sys.argv[1], os.environ.get("DISPLAY", DEFAULT_DISPLAY)))
