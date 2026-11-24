"""
Regression test for the freeze bug reported 2026-10-09:

  1. Load a project with two adjacent video clips (+ linked audio).
  2. Add a transition between them via the "+" button
     (video gets a dissolve, linked audio gets a crossfade).
  3. Right-click the video clip -> "Unlink Audio/Video".
  4. Drag the (now-unlinked) transition clip around rapidly.

Previously this froze the whole app: TimelineEngine::setClips() tore down
live GES clips/pads while GStreamer streaming threads were still using them
(see TimelineEngine.cpp - the GST_STATE_READY teardown-safety fix, and the
isBusyAsync()-gated deferred setClips). This test exercises exactly that path
and fails loudly (instead of hanging the test runner) if the app locks up.

Run via tests/ui/run_ui_test.sh - do not invoke directly without the Xephyr/
openbox/accessibility environment it sets up.
"""

import sys
import time

from atspi_helpers import (
    UIHangError,
    assert_responsive,
    click,
    drag,
    find_all,
    find_one,
    right_click,
    wait_until,
)

RECENT_PROJECT_NAME = "test1"


def step(msg):
    print(f"\n=== {msg} ===")


def run():
    step("Waiting for app to be responsive")
    assert_responsive(label="startup")

    step(f"Opening recent project '{RECENT_PROJECT_NAME}'")
    wait_until(
        lambda: len(find_all(name_contains=f"Open recent project {RECENT_PROJECT_NAME}")) >= 1,
        timeout=10,
        description=f"recent project '{RECENT_PROJECT_NAME}' to appear in the list",
    )
    project_item = find_one(name_contains=f"Open recent project {RECENT_PROJECT_NAME}")
    click(project_item)

    step("Waiting for timeline clips to load")
    wait_until(
        lambda: len(find_all(role="list item", name_contains="[V1]")) >= 2,
        timeout=20,
        description="two video clips on V1",
    )
    video_clips = find_all(role="list item", name_contains="[V1]")
    assert len(video_clips) >= 2, f"expected >=2 V1 clips, got {len(video_clips)}"
    print(f"  found {len(video_clips)} clip(s) on V1")
    assert_responsive(label="after project load")

    step("Clicking the '+' Add Transition button between the two clips")
    # The timeline can still be settling clip positions right after load, so
    # the button's on-screen coordinates read a moment ago may be stale by
    # the time the synthetic click physically arrives. Re-locate and retry a
    # few times instead of assuming the first click lands.
    for attempt in range(5):
        add_buttons = find_all(name="Add Transition")
        assert add_buttons, "no 'Add Transition' button found - clips may not be adjacent"
        click(add_buttons[0])
        time.sleep(0.5)
        if find_all(name_contains="Transition: dissolve"):
            break
    else:
        raise AssertionError("clicking 'Add Transition' never produced a dissolve transition")

    wait_until(
        lambda: len(find_all(name_contains="Transition: dissolve")) >= 1,
        timeout=10,
        description="dissolve transition to appear on the video track",
    )
    wait_until(
        lambda: len(find_all(name_contains="Transition: crossfade")) >= 1,
        timeout=10,
        description="crossfade transition to appear on the linked audio track",
    )
    print("  dissolve (video) + crossfade (audio) both present - transition sync OK")
    assert_responsive(label="after adding transition")

    step("Right-clicking the first video clip and unlinking audio/video")
    video_clips = find_all(role="list item", name_contains="[V1]")
    right_click(video_clips[0])

    wait_until(
        lambda: len(find_all(name="Unlink Audio/Video")) >= 1,
        timeout=5,
        description="context menu to open",
    )
    unlink_item = find_one(name="Unlink Audio/Video")
    click(unlink_item)
    assert_responsive(label="after unlink")

    step("Rapidly dragging the (unlinked) transition clip several times")
    for i in range(4):
        video_clips = find_all(role="list item", name_contains="[V1]")
        clip = video_clips[0]
        drag(clip, dx=80 if i % 2 == 0 else -60, dy=0, steps=2, step_pause=0.05)
        # The critical check: if setClips() deadlocks tearing down GES clips,
        # this call will time out instead of the whole test hanging forever.
        assert_responsive(timeout=8, label=f"after drag #{i + 1}")

    step("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run())
    except UIHangError as e:
        print(f"\n!!! FROZEN: {e}", file=sys.stderr)
        sys.exit(2)
    except (AssertionError, TimeoutError, LookupError) as e:
        print(f"\n!!! FAILED: {e}", file=sys.stderr)
        sys.exit(1)
