"""
End-to-end smoke test: create a new project, add two different source files
to the project bin, and drag both onto V1 one after another so they sit
back-to-back without overlapping.

  1. Launch the app, click "New Project".
  2. Fill in the New Project dialog: file name + project name both set to
     "automaticTestAddTwoClips", location set to tests/testProjects.
  3. In the Media Browser, navigate to tests/sourceFiles and double-click
     two different video files to add both to the project bin.
  4. Switch to the Editing workspace.
  5. Drag the first bin item onto the start of V1 (time 0).
  6. Drag the second bin item onto V1, right after wherever the first clip
     ended, so the two sit back-to-back.
  7. Save the project (Ctrl+S) and verify both clips are on V1, in order,
     and the project file exists on disk.

Run via tests/ui/run_ui_test.sh test_add_two_clips.py - do not invoke
directly without the display/accessibility environment it sets up.
"""

import os
import subprocess
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
PROJECT_NAME = "automaticTestAddTwoClips"
# Two smallest sample files - fastest to import.
SOURCE_FILE_1 = "test1_full_hd_h265.mp4"
SOURCE_FILE_2 = "test1_full_hd_h264.mp4"


def step(msg):
    print(f"\n=== {msg} ===")


def find_in_media_browser(name, max_scrolls=150):
    """The Media Browser's file ListView is virtualized - an entry outside
    the visible viewport doesn't exist as an accessible node at all until
    scrolled into view, so this scrolls step by step and re-checks rather
    than just waiting. The home folder this test starts from can hold
    hundreds of entries, so this needs a generous scroll budget."""
    for _ in range(max_scrolls):
        matches = find_all(name=name)
        if matches:
            return matches[0]
        anchor = find_all(role="list item", name_contains="Media browser")
        if not anchor:
            break
        x, y = get_center(anchor[0])
        scroll(x, y, clicks=3)
        time.sleep(0.05)
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


def _try_set_folder_path(target_dir):
    """The "Location" field in the New Project dialog is a plain editable
    TextField (Accessible.name "Project location") - type directly into it
    instead of going through the "..." browse button's native folder
    dialog, which remembers its own last-used location across runs and so
    isn't reliably steerable by typed input alone."""
    click(find_one(name="Project location"))
    type_text(target_dir)
    time.sleep(0.3)

    loc = find_all(name="Project location")
    if not loc:
        return False
    try:
        current_text = loc[0].queryText().getText(0, -1)
    except Exception:
        current_text = ""
    return current_text == target_dir


def run():
    step("Waiting for app to be responsive")
    assert_responsive(label="startup")

    os.makedirs(PROJECT_DIR, exist_ok=True)
    # The app creates each project in its own subfolder (PROJECT_DIR/NAME/),
    # complete with a NAME.gpucs and a per-project .cache dir - and refuses
    # to confirm the New Project dialog if that subfolder already exists.
    # Remove the whole thing (not just the .gpucs) so reruns are hermetic.
    import shutil

    project_folder = os.path.join(PROJECT_DIR, PROJECT_NAME)
    if os.path.exists(project_folder):
        shutil.rmtree(project_folder)
    project_file = os.path.join(project_folder, PROJECT_NAME + ".gpucs")

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

    try:
        wait_until(
            lambda: _try_set_folder_path(PROJECT_DIR),
            timeout=5,
            description="Project location field to accept the typed path",
        )
    except Exception as e:
        print(f"  !!! setting the project location failed: {e}")
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

    for source_file in (SOURCE_FILE_1, SOURCE_FILE_2):
        step(f"Double-clicking source file '{source_file}' to add it to the project bin")
        file_item = find_in_media_browser(f"Media browser file {source_file}")
        if file_item is None:
            print("  --- full accessible tree at time of failure ---")
            dump_tree()
            raise TimeoutError(f"'{source_file}' never appeared in Media Browser")
        double_click(file_item)
        assert_responsive(label=f"after adding '{source_file}' to project bin")

    step("Switching to the Editing workspace")
    click(find_one(name="Workspace Editing"))

    step("Waiting for both clips to appear in the Editing project bin")
    for source_file in (SOURCE_FILE_1, SOURCE_FILE_2):
        wait_until(
            lambda sf=source_file: len(find_all(name_contains=f"Project bin item {sf}")) >= 1,
            timeout=10,
            description=f"'{source_file}' to appear in the Editing project bin",
        )

    step("Locating the start of the V1 track")
    wait_until(
        lambda: len(find_all(name="Track header V1")) >= 1,
        timeout=10,
        description="V1 track header",
    )
    header_x, header_y, header_w, header_h = get_rect(find_one(name="Track header V1"))
    target_x = header_x + header_w + 20
    target_y = header_y + header_h // 2

    step(f"Dragging '{SOURCE_FILE_1}' onto the start of V1")
    bin_item_1 = find_one(name_contains=f"Project bin item {SOURCE_FILE_1}")
    drag_to(bin_item_1, target_x, target_y)
    assert_responsive(label="after dragging first clip onto V1")

    step("Verifying the first clip landed on V1")
    wait_until(
        lambda: len(find_all(role="list item", name_contains="[V1]")) >= 1,
        timeout=10,
        description="first clip to appear on V1",
    )
    first_clips = find_all(role="list item", name_contains="[V1]")
    assert len(first_clips) == 1, f"expected exactly 1 clip on V1, got {len(first_clips)}"
    first_clip_x, _, first_clip_w, _ = get_rect(first_clips[0])
    distance_from_start = abs(first_clip_x - (header_x + header_w))
    print(f"  clip '{first_clips[0].name}' left edge is {distance_from_start}px from track start")
    assert distance_from_start < 60, (
        f"expected the first clip near the start of V1 (<60px), got {distance_from_start}px"
    )

    step(f"Dragging '{SOURCE_FILE_2}' onto V1 right after the first clip")
    bin_item_2 = find_one(name_contains=f"Project bin item {SOURCE_FILE_2}")
    second_target_x = first_clip_x + first_clip_w + 20
    drag_to(bin_item_2, second_target_x, target_y)
    assert_responsive(label="after dragging second clip onto V1")

    step("Verifying both clips are on V1, back-to-back, non-overlapping")
    wait_until(
        lambda: len(find_all(role="list item", name_contains="[V1]")) >= 2,
        timeout=10,
        description="second clip to appear on V1",
    )
    all_clips = sorted(
        find_all(role="list item", name_contains="[V1]"),
        key=lambda c: get_rect(c)[0],
    )
    assert len(all_clips) == 2, f"expected exactly 2 clips on V1, got {len(all_clips)}"

    (c1_x, _, c1_w, _), (c2_x, _, c2_w, _) = (get_rect(c) for c in all_clips)
    print(f"  clip 1 '{all_clips[0].name}': x={c1_x} w={c1_w}")
    print(f"  clip 2 '{all_clips[1].name}': x={c2_x} w={c2_w}")
    assert c2_x >= c1_x + c1_w - 5, (
        f"clips overlap: clip1 ends at {c1_x + c1_w}, clip2 starts at {c2_x}"
    )
    gap = c2_x - (c1_x + c1_w)
    print(f"  gap between clips: {gap}px")
    assert gap < 60, f"expected the second clip right after the first (<60px gap), got {gap}px"

    step("Saving the project (Ctrl+S)")
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


if __name__ == "__main__":
    sys.exit(run())
