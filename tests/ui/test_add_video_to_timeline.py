"""
End-to-end smoke test: create a new project, add one source file to the
project bin in the Logging workspace, switch to Editing, and drag that
clip onto the start of the V1 track.

  1. Launch the app, click "New Project".
  2. Fill in the New Project dialog: file name + project name both set to
     "automaticTestAddVideoToTimeline", location set to tests/testProjects
     (created if missing).
  3. Confirm - the app auto-switches to the Logging workspace with an
     empty project bin.
  4. In the Media Browser, navigate from the home folder down to
     tests/sourceFiles and double-click a video file to add it to the
     project bin.
  5. Switch to the Editing workspace.
  6. Drag the project bin item onto the V1 track, as close to its start
     (time 0) as the drop logic allows.
  7. Save the project (Ctrl+S) so the .gpucs file actually lands in
     tests/testProjects, and verify both the clip is on V1 and the
     project file exists on disk.

Run via tests/ui/run_ui_test.sh test_add_video_to_timeline.py - do not
invoke directly without the display/accessibility environment it sets up.
"""

import os
import sys
import time

from atspi_helpers import (
    assert_responsive,
    click,
    double_click,
    drag_to,
    dump_tree,
    find_all,
    find_one,
    get_center,
    get_rect,
    scroll,
    type_text,
    wait_until,
)

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SOURCE_DIR = os.path.join(REPO_ROOT, "tests", "sourceFiles")
PROJECT_DIR = os.path.join(REPO_ROOT, "tests", "testProjects")
PROJECT_NAME = "automaticTestAddVideoToTimeline"
SOURCE_FILE = "test1_full_hd_h265.mp4"  # smallest sample file - fastest to import


def step(msg):
    print(f"\n=== {msg} ===")


def find_in_media_browser(name, max_scrolls=40):
    """The Media Browser's file ListView is virtualized - an entry outside
    the visible viewport doesn't exist as an accessible node at all until
    scrolled into view, so this scrolls step by step and re-checks rather
    than just waiting."""
    for _ in range(max_scrolls):
        matches = find_all(name=name)
        if matches:
            return matches[0]
        anchor = find_all(role="list item", name_contains="Media browser")
        if not anchor:
            break
        x, y = get_center(anchor[0])
        scroll(x, y, clicks=2)
        time.sleep(0.1)
    return None


def navigate_media_browser_to(path_segments):
    """Double-clicks through the Media Browser folder tree, one path
    segment at a time, starting from whatever folder it's currently
    showing (the user's home folder on a fresh app start)."""
    for segment in path_segments:
        step(f"Media Browser: entering '{segment}'")
        folder_item = find_in_media_browser(f"Media browser folder {segment}")
        if folder_item is None:
            print("  --- full accessible tree at time of failure ---")
            dump_tree()
            raise TimeoutError(f"folder '{segment}' never appeared in Media Browser")
        double_click(folder_item)
        time.sleep(0.4)  # let the folder listing reload before the next lookup


def run():
    step("Waiting for app to be responsive")
    assert_responsive(label="startup")

    os.makedirs(PROJECT_DIR, exist_ok=True)
    project_file = os.path.join(PROJECT_DIR, PROJECT_NAME + ".gpucs")
    if os.path.exists(project_file):
        os.remove(project_file)

    step("Clicking 'New Project'")
    click(find_one(name="New Project"))

    step("Filling in the New Project dialog")
    wait_until(
        lambda: len(find_all(name="File name")) >= 1,
        timeout=10,
        description="New Project dialog to appear",
    )
    click(find_one(name="File name"))
    type_text(PROJECT_NAME + ".gpucs")

    click(find_one(name="Project name"))
    type_text(PROJECT_NAME)

    click(find_one(name="Choose project location"))
    time.sleep(1)
    # The folder picker's exact shape depends on the Qt Quick Dialogs
    # backend in use - dump what's actually there so a first-run failure
    # is diagnosable instead of a blind guess.
    try:
        wait_until(
            lambda: _try_set_folder_path(PROJECT_DIR),
            timeout=5,
            description="folder dialog to accept a typed path",
        )
    except Exception as e:
        print(f"  !!! folder picker automation failed: {e}")
        print("  --- full accessible tree at time of failure ---")
        dump_tree()
        raise

    step("Confirming project settings")
    click(find_one(name="Confirm project settings"))

    step("Waiting for Logging workspace / empty project bin")
    wait_until(
        lambda: len(find_all(name_contains="Media browser")) >= 1,
        timeout=15,
        description="Logging workspace Media Browser to appear",
    )
    assert_responsive(label="after creating project")

    home_to_source = os.path.relpath(SOURCE_DIR, os.path.expanduser("~"))
    segments = [s for s in home_to_source.split(os.sep) if s not in ("", ".")]
    navigate_media_browser_to(segments)

    step(f"Double-clicking source file '{SOURCE_FILE}' to add it to the project bin")
    file_item = find_in_media_browser(f"Media browser file {SOURCE_FILE}")
    if file_item is None:
        print("  --- full accessible tree at time of failure ---")
        dump_tree()
        raise TimeoutError(f"'{SOURCE_FILE}' never appeared in Media Browser")
    double_click(file_item)
    assert_responsive(label="after adding file to project bin")

    step("Switching to the Editing workspace")
    click(find_one(name="Workspace Editing"))

    step("Waiting for the clip to appear in the Editing project bin")
    wait_until(
        lambda: len(find_all(name_contains=f"Project bin item {SOURCE_FILE}")) >= 1,
        timeout=10,
        description=f"'{SOURCE_FILE}' to appear in the Editing project bin",
    )
    bin_item = find_one(name_contains=f"Project bin item {SOURCE_FILE}")

    step("Locating the start of the V1 track")
    wait_until(
        lambda: len(find_all(name="Track header V1")) >= 1,
        timeout=10,
        description="V1 track header",
    )
    header_x, header_y, header_w, header_h = get_rect(find_one(name="Track header V1"))
    target_x = header_x + header_w + 20
    target_y = header_y + header_h // 2

    step("Dragging the clip onto the start of V1")
    drag_to(bin_item, target_x, target_y)
    assert_responsive(label="after dragging clip onto V1")

    step("Verifying the clip landed on V1")
    wait_until(
        lambda: len(find_all(role="list item", name_contains=f"[V1]")) >= 1,
        timeout=10,
        description="clip to appear on V1",
    )
    clip = find_one(role="list item", name_contains="[V1]")
    clip_x, _, _, _ = get_rect(clip)
    distance_from_start = abs(clip_x - (header_x + header_w))
    print(f"  clip '{clip.name}' left edge is {distance_from_start}px from track start")
    assert distance_from_start < 60, (
        f"expected the clip near the start of V1 (<60px), got {distance_from_start}px"
    )

    step("Saving the project (Ctrl+S)")
    import subprocess

    subprocess.run(
        ["xdotool", "key", "ctrl+s"],
        env={**os.environ, "DISPLAY": os.environ.get("DISPLAY", ":99")},
        check=True,
    )
    wait_until(
        lambda: os.path.exists(project_file),
        timeout=10,
        description=f"project file to be written to {project_file}",
    )
    assert_responsive(label="after saving project")

    print(f"\n  project saved at: {project_file}")
    print("\n=== ALL CHECKS PASSED ===")
    return 0


def _try_set_folder_path(target_dir):
    """Best-effort: types the target path into whatever the folder dialog
    exposes. Returns True once the project location field reflects it."""
    import subprocess

    env = {**os.environ, "DISPLAY": os.environ.get("DISPLAY", ":99")}

    text_fields = find_all(role="text")
    path_field = None
    for f in text_fields:
        try:
            if "path" in (f.name or "").lower() or "location" in (f.name or "").lower():
                path_field = f
                break
        except Exception:
            continue

    if path_field is not None:
        click(path_field)
        type_text(target_dir)
        subprocess.run(["xdotool", "key", "Return"], env=env, check=True)
    else:
        # GTK/KDE-style folder choosers open with a path bar you can
        # replace via Ctrl+L, type the path, Enter.
        subprocess.run(["xdotool", "key", "ctrl+l"], env=env, check=True)
        time.sleep(0.2)
        type_text(target_dir, select_all_first=True)
        time.sleep(0.1)
        subprocess.run(["xdotool", "key", "Return"], env=env, check=True)

    time.sleep(0.5)
    loc = find_all(name="Project location")
    if not loc:
        return False
    try:
        current_text = loc[0].queryText().getText(0, -1)
    except Exception:
        current_text = ""
    return target_dir in current_text


if __name__ == "__main__":
    sys.exit(run())
