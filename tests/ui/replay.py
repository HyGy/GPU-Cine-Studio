"""
Replays a recording made with record.py.

Each action is re-resolved against the live accessible tree by name/role
(not the raw coordinates it was recorded at), the same way the
hand-written tests do - so it keeps working if the window has moved,
resized, or the display scale is different from when it was recorded.

Usage: tests/ui/run_ui_test.sh --real replay.py <recording-name> [options]
  --dry-run           Print what would happen, resolve every element, but
                       never move the mouse or send a key. Use this first
                       on any recording you haven't replayed before.
  --allow-raw-points   A click/drag that didn't land on any named element
                       at record time was saved as a bare screen point
                       instead - replaying that blind is how a recording
                       can end up clicking into a DIFFERENT window of
                       yours (anything on screen at that pixel, not
                       necessarily this app). Refused by default; pass
                       this to allow it anyway once you've checked with
                       --dry-run that the points look sane.
"""

import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from atspi_helpers import (  # noqa: E402
    DEFAULT_DISPLAY,
    _xdotool_env,
    assert_responsive,
    drag_to,
    find_all,
    find_one,
    get_rect,
    wait_until,
)

RECORDINGS_DIR = os.path.join(os.path.dirname(__file__), "recordings")
ELEMENT_WAIT_TIMEOUT = 15


def _find_recorded(desc, timeout=ELEMENT_WAIT_TIMEOUT):
    """Walking the whole AT-SPI tree is the expensive part here, not any
    deliberate delay - so unlike a plain wait_until(find_all(...)) +
    find_one(...), which would walk it twice (once to check, once more to
    actually fetch the match), this reuses the single walk that already
    found it."""
    name, role = desc.get("name"), desc.get("role")
    if not name:
        return None
    found = []

    def check():
        found[:] = find_all(name=name, role=role)
        return len(found) >= 1

    wait_until(check, timeout=timeout, description=f"recorded element {role!r} {name!r} to reappear")
    return found[0]


def _set_text(action, display):
    """Sets a type_text/paste_text action's text via the clipboard + one
    Ctrl+V, instead of synthesizing one key event per character.

    AT-SPI's EditableText.setTextContents() would be the cleanest one-shot
    way to do this, but this app's QML TextField only implements the
    (read-only) Text interface over AT-SPI, not EditableText - confirmed
    by hand, queryEditableText() raises NotImplementedError. Clipboard
    paste is the next best thing: it's still a SINGLE synthetic key event
    (Ctrl+V) feeding the whole string to the field in one go, rather than
    xdotool typing it character by character. That distinction matters -
    sending N synthetic keystrokes fires N Qt accessibility text-change
    notifications, which measurably backs up the app's main thread
    (confirmed: the delay before the NEXT AT-SPI lookup scaled with the
    typed text's length, not with anything else). A single paste should
    produce (at most) one such notification instead of N.

    Falls back to xdotool typing character-by-character if setting the
    clipboard or sending the paste fails for some reason.
    """
    env = _xdotool_env(display)
    try:
        subprocess.run(
            ["xsel", "--clipboard", "--input"],
            input=action["text"], env=env, text=True, check=True,
        )
        subprocess.run(["xdotool", "key", "ctrl+v"], env=env, check=True)
        return
    except Exception as e:
        print(f"    (clipboard paste failed ({type(e).__name__}: {e!r}), falling back to typing)")
    subprocess.run(
        ["xdotool", "type", "--delay", "2", action["text"]],
        env=env, check=True,
    )


def _point_for(desc, display):
    """Absolute physical-pixel point for a recorded click/drag endpoint -
    the matched element's rect plus the originally recorded relative
    offset inside it, or the bare point it was recorded at if nothing
    resolved at record time.

    Points recorded without an element came straight from Xlib's
    query_pointer(), which - like xdotool - already works in physical
    pixels, same as get_rect()'s output: neither needs any display-scale
    conversion applied again here.
    """
    if desc.get("name"):
        acc = _find_recorded(desc)
        x, y, w, h = get_rect(acc, display=display)
        return (
            int(round(x + desc.get("rel_x", 0.5) * w)),
            int(round(y + desc.get("rel_y", 0.5) * h)),
        ), acc
    px, py = desc["point"]
    return (int(px), int(py)), None


def _raw_point_actions(actions):
    """Click/drag endpoints with no element name - recorded as a bare
    screen point because nothing accessible was found under the cursor at
    record time. Replaying these blind can hit whatever happens to be at
    that pixel on a DIFFERENT run - another one of your windows, not
    necessarily this app - which is exactly what went wrong the first
    time this was replayed."""
    bad = []
    for i, a in enumerate(actions):
        if a["type"] in ("click", "double_click") and not a.get("name"):
            bad.append((i, "point", a["point"]))
        elif a["type"] == "drag":
            if not a["from"].get("name"):
                bad.append((i, "drag-from", a["from"]["point"]))
            if not a["to"].get("name"):
                bad.append((i, "drag-to", a["to"]["point"]))
    return bad


def replay(name, display, dry_run=False, allow_raw_points=False):
    if name.endswith(".json"):
        name = name[: -len(".json")]
    path = os.path.join(RECORDINGS_DIR, f"{name}.json")
    with open(path) as f:
        actions = json.load(f)

    print(f"Replaying '{name}' ({len(actions)} actions){' [DRY RUN]' if dry_run else ''}")

    raw = _raw_point_actions(actions)
    if raw and not allow_raw_points and not dry_run:
        print(
            "\nFAIL: this recording has actions with no matching accessible "
            "element - they were saved as a bare screen point instead, "
            "which can end up clicking a DIFFERENT window of yours on replay:"
        )
        for i, kind, point in raw:
            print(f"    action {i + 1}: {kind} at {point}")
        print(
            "\nRun with --dry-run first to see exactly where every action "
            "resolves to, and --allow-raw-points once you've checked the "
            "points above look right."
        )
        return 1

    if not dry_run:
        # No countdown: by the time this prints, the app (launched by
        # run_ui_test.sh beforehand) already has focus and is covering the
        # terminal, so a multi-second wait here just delayed things without
        # ever actually being visible.
        print(
            "This takes over your real mouse and keyboard for the duration "
            "of the replay - hands off until it says REPLAY COMPLETE."
        )

    env = _xdotool_env(display)

    for i, action in enumerate(actions):
        kind = action["type"]
        t0 = time.time()
        ts = time.strftime("%H:%M:%S", time.localtime(t0))

        if kind in ("click", "double_click"):
            (x, y), acc = _point_for(action, display)
            button = str(action.get("button", 1))
            print(f"  [{ts}] [{i + 1}/{len(actions)}] {kind} '{action.get('name')}' at ({x}, {y}) (lookup took {time.time() - t0:.2f}s)")
            if dry_run:
                continue
            clicks = 2 if kind == "double_click" else 1
            for n in range(clicks):
                subprocess.run(
                    ["xdotool", "mousemove", str(x), str(y), "click", button],
                    env=env, check=True,
                )
                if n == 0 and clicks == 2:
                    time.sleep(0.08)

        elif kind == "drag":
            (sx, sy), start_acc = _point_for(action["from"], display)
            (tx, ty), _ = _point_for(action["to"], display)
            print(
                f"  [{ts}] [{i + 1}/{len(actions)}] drag '{action['from'].get('name')}' "
                f"({sx}, {sy}) -> '{action['to'].get('name')}' ({tx}, {ty}) "
                f"(lookup took {time.time() - t0:.2f}s)"
            )
            if dry_run:
                continue
            if start_acc is not None:
                drag_to(start_acc, tx, ty, display=display)
            else:
                subprocess.run(["xdotool", "mousemove", str(sx), str(sy)], env=env, check=True)
                subprocess.run(["xdotool", "mousedown", "1"], env=env, check=True)
                for step in range(1, 6):
                    ix = int(round(sx + (tx - sx) * step / 5))
                    iy = int(round(sy + (ty - sy) * step / 5))
                    subprocess.run(["xdotool", "mousemove", str(ix), str(iy)], env=env, check=True)
                    time.sleep(0.08)
                subprocess.run(["xdotool", "mouseup", "1"], env=env, check=True)
            # Give the app a moment to actually process the drop (create
            # the clip, settle the timeline) before the next action - the
            # drop itself completing (mouseup returning) doesn't mean the
            # app has finished reacting to it yet.
            time.sleep(0.6)

        elif kind == "key":
            print(f"  [{ts}] [{i + 1}/{len(actions)}] key {action['chord']}")
            if dry_run:
                continue
            subprocess.run(["xdotool", "key", action["chord"]], env=env, check=True)

        elif kind in ("paste_text", "type_text"):
            print(f"  [{ts}] [{i + 1}/{len(actions)}] {kind} {action['text']!r}")
            if dry_run:
                continue
            _set_text(action, display)

        else:
            print(f"  [{i + 1}/{len(actions)}] !!! unknown action type {kind!r}, skipping")
            continue

        if not dry_run:
            print(f"    (step total: {time.time() - t0:.2f}s)")

    if dry_run:
        print("\n=== DRY RUN COMPLETE (nothing was clicked/typed) ===")
        return 0

    assert_responsive(label="after replay")
    print("\n=== REPLAY COMPLETE ===")
    return 0


if __name__ == "__main__":
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    positional = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not positional:
        print("Usage: replay.py <recording-name> [--dry-run] [--allow-raw-points]", file=sys.stderr)
        sys.exit(1)
    sys.exit(replay(
        positional[0],
        os.environ.get("DISPLAY", DEFAULT_DISPLAY),
        dry_run="--dry-run" in flags,
        allow_raw_points="--allow-raw-points" in flags,
    ))
