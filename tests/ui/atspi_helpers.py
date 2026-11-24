"""
Minimal AT-SPI based UI automation helpers for GPU Cine Studio.

This is the desktop-app equivalent of a web DOM-walking click bot: instead of
hardcoded pixel coordinates, elements are found by their accessible name/role
(exposed via Accessible.name / Accessible.role in QML - see TimelineClip.qml,
TimelineTransition.qml, main.qml for the properties that make this possible).

Requires: python3-pyatspi, xdotool, and the app launched with
QT_ACCESSIBILITY=1 and QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 (see run_ui_test.sh).
"""

import os
import subprocess
import threading
import time

import pyatspi

APP_NAME = "gpu-cine-studio"
DEFAULT_TIMEOUT = 10
DEFAULT_DISPLAY = os.environ.get("DISPLAY", ":99")


class UIHangError(RuntimeError):
    """Raised when the app's accessibility bridge stops responding in time.

    Since AT-SPI introspection is serviced by the app's own Qt main thread,
    a query that doesn't return within the timeout means that thread is
    blocked - i.e. the app is frozen. This is the core freeze detector.
    """


def _with_timeout(fn, timeout, *args, **kwargs):
    # A daemon thread, not ThreadPoolExecutor: if the underlying AT-SPI/dbus
    # call genuinely wedges (not just slow), ThreadPoolExecutor's __exit__
    # calls shutdown(wait=True), which blocks until that stuck worker
    # thread finishes - i.e. forever, silently defeating the timeout below.
    # A daemon thread lets join(timeout) give up on schedule and the
    # leaked, still-blocked thread can't hold up the process later.
    box = {}

    def _runner():
        try:
            box["value"] = fn(*args, **kwargs)
        except Exception as e:
            box["error"] = e

    t = threading.Thread(target=_runner, daemon=True)
    t.start()
    t.join(timeout)
    if t.is_alive():
        raise UIHangError(
            f"AT-SPI query did not respond within {timeout}s - "
            f"the app's main thread is very likely blocked/deadlocked."
        )
    if "error" in box:
        raise box["error"]
    return box.get("value")


def get_app_root(timeout=DEFAULT_TIMEOUT):
    """Returns the app's root accessible 'frame', proving the app is alive
    and its event loop is responsive. Raises UIHangError if the app's main
    thread seems blocked.

    "Not found in the desktop tree" is retried internally within the
    timeout budget - observed to be a transient blip in the AT-SPI
    registry enumeration on a real (non-virtual) desktop even while the
    app is fully alive and visible, not a sign the app quit. A real
    UIHangError (the query itself timing out, i.e. the main thread
    actually not answering) is NOT retried - it propagates immediately,
    since that's the actual freeze signal this harness exists to catch.
    """

    def _find():
        # Killed instances can leave a stale, childless entry behind in the
        # AT-SPI registry. Skip those - only a live app actually has content.
        desktop = pyatspi.Registry.getDesktop(0)
        candidate = None
        for i in range(desktop.childCount):
            app = desktop.getChildAtIndex(i)
            if app.name != APP_NAME:
                continue
            if app.childCount > 0:
                return app
            candidate = app
        if candidate is not None:
            return candidate
        raise RuntimeError(f"App '{APP_NAME}' not found in AT-SPI desktop tree")

    deadline = time.time() + timeout
    last_err = None
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            break
        try:
            return _with_timeout(_find, max(0.5, min(remaining, timeout)))
        except UIHangError:
            raise
        except RuntimeError as e:
            last_err = e
            time.sleep(0.3)
    raise last_err or RuntimeError(f"App '{APP_NAME}' not found in AT-SPI desktop tree")


def assert_responsive(timeout=5, label=""):
    """Health check: confirms the app's main thread is processing events.
    Use this after any drag/click that could trigger a freeze regression."""
    app = get_app_root(timeout)

    def _probe():
        # Walk one level - cheap, but requires the main thread to answer.
        return app.childCount

    _with_timeout(_probe, timeout)
    print(f"  [responsive] OK{(' - ' + label) if label else ''}")


def _walk(acc, depth=0, max_depth=25):
    yield acc, depth
    if depth >= max_depth:
        return
    for i in range(acc.childCount):
        try:
            child = acc.getChildAtIndex(i)
        except Exception:
            continue
        if child is None:
            continue
        yield from _walk(child, depth + 1, max_depth)


def find_all(name=None, role=None, name_contains=None, timeout=DEFAULT_TIMEOUT):
    """Finds all accessible nodes under the app matching the given criteria.

    Closed/hidden windows (a dialog you opened and closed earlier, an
    About box, ...) stay in the AT-SPI tree with stale leftover geometry
    instead of being removed - skipping anything not STATE_SHOWING/VISIBLE
    keeps a match like that from shadowing the real, currently-visible
    widget a click or lookup actually meant to find.
    """
    app = get_app_root(timeout)

    def _search():
        results = []
        for acc, _ in _walk(app):
            try:
                acc_name = acc.name
                acc_role = acc.getRoleName()
            except Exception:
                continue
            if name is not None and acc_name != name:
                continue
            if name_contains is not None and name_contains not in acc_name:
                continue
            if role is not None and acc_role != role:
                continue
            try:
                state = acc.getState()
                if not (state.contains(pyatspi.STATE_SHOWING) and state.contains(pyatspi.STATE_VISIBLE)):
                    continue
            except Exception:
                pass
            results.append(acc)
        return results

    return _with_timeout(_search, timeout)


def find_one(name=None, role=None, name_contains=None, timeout=DEFAULT_TIMEOUT):
    results = find_all(name=name, role=role, name_contains=name_contains, timeout=timeout)
    if not results:
        raise LookupError(
            f"No accessible element found (name={name!r}, role={role!r}, "
            f"name_contains={name_contains!r})"
        )
    return results[0]


def _xdotool_env(display):
    env = dict(os.environ)
    env["DISPLAY"] = display
    return env


def _top_frame(acc):
    """AT-SPI's top-level 'application' node has no geometry of its own -
    descend to its first 'frame' child, which does."""
    if acc.getRoleName() == "frame":
        return acc
    for i in range(acc.childCount):
        child = acc.getChildAtIndex(i)
        try:
            if child.getRoleName() == "frame":
                return child
        except Exception:
            continue
    return acc


_display_scale_cache = {}


def _display_scale(display):
    """Ratio of physical X11 pixels (what xdotool moves/clicks in) to the
    logical pixels AT-SPI reports extents in. On an unscaled display this is
    1.0 and everything lines up; on a HiDPI display with fractional/integer
    scaling active (GNOME/Wayland, QT_SCALE_FACTOR, ...) AT-SPI keeps
    reporting logical coordinates while xdotool only understands physical
    ones, so clicks silently land off-target unless corrected.

    Measured empirically - the app's own top-level frame's AT-SPI (logical)
    size vs. its actual (physical) X11 window size - rather than reading any
    specific desktop-environment scaling setting, so it keeps working
    whatever the scaling mechanism turns out to be.
    """
    if display in _display_scale_cache:
        return _display_scale_cache[display]

    scale = 1.0
    try:
        frame = _top_frame(get_app_root())
        extents = frame.queryComponent().getExtents(pyatspi.XY_SCREEN)
        logical_w = extents.width

        env = _xdotool_env(display)
        # --class also matches the app's tiny internal/helper windows (seen:
        # a 1x1 Qt selection-owner window and a 20x20 helper, alongside the
        # real ~3840px main window) - search by the frame's own AT-SPI name
        # (the actual window title) instead, which is unique to the real
        # window, and additionally pick the largest match by area as a
        # safety net against any other same-named decoys.
        win_ids = subprocess.run(
            ["xdotool", "search", "--name", frame.name],
            env=env, capture_output=True, text=True, check=True,
        ).stdout.split()

        best_area = 0
        physical_w = 0
        for win_id in win_ids:
            geo = subprocess.run(
                ["xdotool", "getwindowgeometry", "--shell", win_id],
                env=env, capture_output=True, text=True, check=True,
            ).stdout
            physical = dict(
                line.split("=", 1) for line in geo.splitlines() if "=" in line
            )
            w, h = int(physical.get("WIDTH", 0)), int(physical.get("HEIGHT", 0))
            if w * h > best_area:
                best_area = w * h
                physical_w = w

        if physical_w > 0 and logical_w > 0:
            scale = physical_w / logical_w
    except Exception as e:
        print(f"  [display] scale detection failed, assuming 1.0: {e}")
        scale = 1.0

    print(f"  [display] logical->physical scale factor: {scale:.3f}")
    _display_scale_cache[display] = scale
    return scale


def get_center(acc, display=DEFAULT_DISPLAY):
    component = acc.queryComponent()
    extents = component.getExtents(pyatspi.XY_SCREEN)
    scale = _display_scale(display)
    cx = extents.x + extents.width // 2
    cy = extents.y + extents.height // 2
    return int(round(cx * scale)), int(round(cy * scale))


def click(acc, display=DEFAULT_DISPLAY, button=1):
    x, y = get_center(acc, display=display)
    print(f"  [click] '{acc.name}' at physical screen ({x}, {y}) button={button}")
    subprocess.run(
        ["xdotool", "mousemove", str(x), str(y), "click", str(button)],
        env=_xdotool_env(display),
        check=True,
    )


def right_click(acc, display=DEFAULT_DISPLAY):
    click(acc, display=display, button=3)


def scroll(x, y, display=DEFAULT_DISPLAY, clicks=2, down=True):
    """Mouse-wheel scroll at a physical-pixel point - ListViews here are
    virtualized, so an off-screen entry doesn't exist as an accessible
    node at all until scrolled into view; waiting alone won't produce it."""
    env = _xdotool_env(display)
    button = "5" if down else "4"
    subprocess.run(["xdotool", "mousemove", str(x), str(y)], env=env, check=True)
    for _ in range(clicks):
        subprocess.run(["xdotool", "click", button], env=env, check=True)


def drag(acc, dx, dy, display=DEFAULT_DISPLAY, steps=3, step_pause=0.1):
    """Drags an element by (dx, dy) pixels via real mouse-down/move/up events,
    the same way a user would - needed since AT-SPI alone can't simulate drags.
    dx/dy are in logical pixels (the same unit AT-SPI reports element sizes
    in) and get converted to physical pixels internally, same as get_center()."""
    env = _xdotool_env(display)
    x, y = get_center(acc, display=display)
    scale = _display_scale(display)
    dx, dy = int(round(dx * scale)), int(round(dy * scale))
    subprocess.run(["xdotool", "mousemove", str(x), str(y)], env=env, check=True)
    subprocess.run(["xdotool", "mousedown", "1"], env=env, check=True)
    for i in range(1, steps + 1):
        subprocess.run(
            ["xdotool", "mousemove_relative", "--", str(dx // steps), str(dy // steps)],
            env=env,
            check=True,
        )
        time.sleep(step_pause)
    subprocess.run(["xdotool", "mouseup", "1"], env=env, check=True)


def double_click(acc, display=DEFAULT_DISPLAY):
    """QML code in this app wires file/folder opening to onDoubleClicked, not
    onClicked - two quick clicks via xdotool's own click action land well
    within Qt's double-click interval."""
    x, y = get_center(acc, display=display)
    print(f"  [double-click] '{acc.name}' at physical screen ({x}, {y})")
    env = _xdotool_env(display)
    subprocess.run(["xdotool", "mousemove", str(x), str(y), "click", "1"], env=env, check=True)
    time.sleep(0.08)
    subprocess.run(["xdotool", "mousemove", str(x), str(y), "click", "1"], env=env, check=True)


def get_rect(acc, display=DEFAULT_DISPLAY):
    """Physical-pixel (x, y, width, height) of an accessible's on-screen
    extents, scaled the same way get_center() is."""
    component = acc.queryComponent()
    extents = component.getExtents(pyatspi.XY_SCREEN)
    scale = _display_scale(display)
    return (
        int(round(extents.x * scale)),
        int(round(extents.y * scale)),
        int(round(extents.width * scale)),
        int(round(extents.height * scale)),
    )


def drag_to(acc, target_x, target_y, display=DEFAULT_DISPLAY, steps=10, step_pause=0.08, hold=0.4):
    """Drags an element to an absolute physical-pixel destination (as
    opposed to drag()'s relative offset) - for drops onto a specific spot
    in a different panel, like a project bin item onto a timeline track.

    This app's cross-panel drag (project bin -> timeline) is a real QML
    Drag/DropArea, not a plain MouseArea drag - it needs actual
    onPositionChanged events to fire (to trigger Drag.start(), then to
    update the DropArea's entered/previewIsValid state) before onDropped
    will accept anything. A couple of big single jumps isn't necessarily
    enough of that, and releasing immediately on arrival can race the
    DropArea's own validity bookkeeping - so this uses more, smaller
    steps, and holds still (with one more position nudge) at the
    destination briefly before releasing, giving the drop target time to
    actually register as a valid drop zone first."""
    env = _xdotool_env(display)
    x, y = get_center(acc, display=display)
    print(f"  [drag] '{acc.name}' from ({x}, {y}) to ({target_x}, {target_y})")
    subprocess.run(["xdotool", "mousemove", str(x), str(y)], env=env, check=True)
    subprocess.run(["xdotool", "mousedown", "1"], env=env, check=True)
    for i in range(1, steps + 1):
        ix = int(round(x + (target_x - x) * i / steps))
        iy = int(round(y + (target_y - y) * i / steps))
        subprocess.run(["xdotool", "mousemove", str(ix), str(iy)], env=env, check=True)
        time.sleep(step_pause)
    time.sleep(hold)
    subprocess.run(["xdotool", "mousemove", str(target_x), str(target_y)], env=env, check=True)
    time.sleep(hold)
    subprocess.run(["xdotool", "mouseup", "1"], env=env, check=True)


def type_text(text, display=DEFAULT_DISPLAY, select_all_first=True):
    """Types into whatever currently has keyboard focus - call click() on
    the target field first."""
    env = _xdotool_env(display)
    if select_all_first:
        subprocess.run(["xdotool", "key", "ctrl+a"], env=env, check=True)
    subprocess.run(["xdotool", "type", "--delay", "15", text], env=env, check=True)


def dump_tree(timeout=DEFAULT_TIMEOUT):
    """Debug helper: prints role + name of every accessible node under the
    app. Use when a step can't find what it expects, to see what's actually
    there instead of guessing blind."""
    app = get_app_root(timeout)

    def _dump():
        lines = []
        for acc, depth in _walk(app):
            try:
                lines.append(f"{'  ' * depth}[{acc.getRoleName()}] {acc.name!r}")
            except Exception as e:
                lines.append(f"{'  ' * depth}<error: {e}>")
        return lines

    for line in _with_timeout(_dump, timeout):
        print(line)


def wait_until(predicate, timeout=DEFAULT_TIMEOUT, interval=0.3, description="condition"):
    deadline = time.time() + timeout
    last_error = None
    while time.time() < deadline:
        try:
            if predicate():
                return
        except Exception as e:
            last_error = e
        time.sleep(interval)
    extra = f" (last error: {last_error})" if last_error else ""
    raise TimeoutError(f"Timed out waiting for: {description}{extra}")
