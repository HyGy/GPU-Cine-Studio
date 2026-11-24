"""
End-to-end smoke test, API-assisted: create a new project and add two
different source files to V1, back-to-back.

Unlike test_add_two_clips.py (pure AT-SPI), this drives the slow/fragile
non-visual setup - project creation, adding files to the project bin,
switching workspace - through the app's local test API (TestApiServer,
opt-in via GCS_TEST_API=1) instead of clicking through dialogs and
scrolling the Media Browser's virtualized file list. AT-SPI is only used
for the one thing that has to be a real UI gesture: dragging each project
bin item onto the V1 track, which is exactly what exercises
TimelineDropArea's drop-validity logic end to end.

  1. Via API: create the project (same Backend calls the New Project
     dialog's OK button makes), add both source files to the project bin,
     switch to the Editing workspace.
  2. Via AT-SPI: drag the first bin item onto the start of V1, then the
     second right after it.
  3. Via API: read back the timeline's clip list and assert there are
     exactly two clips on V1, in order, non-overlapping; save the project.

Run via tests/ui/run_ui_test.sh test_add_two_clips_api.py - do not invoke
directly without the display/accessibility environment it sets up. Also
requires GCS_TEST_API=1 to be set before launching the app (run_ui_test.sh
passes through whatever is exported in the calling shell).
"""

import json
import os
import shutil
import sys
import time

from atspi_helpers import (
    assert_responsive,
    click,
    drag_to,
    dump_tree,
    find_all,
    find_one,
    get_rect,
    wait_until,
)
from gcs_api import GcsApi, GcsApiError

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SOURCE_DIR = os.path.join(REPO_ROOT, "tests", "sourceFiles")
PROJECT_DIR = os.path.join(REPO_ROOT, "tests", "testProjects")
PROJECT_NAME = "apiTestAddTwoClips"
SOURCE_FILE_1 = "test1_full_hd_h265.mp4"
SOURCE_FILE_2 = "test1_full_hd_h264.mp4"


def step(msg):
    print(f"\n=== {msg} ===")


def run():
    step("Waiting for app to be responsive")
    assert_responsive(label="startup")

    step("Connecting to the test API")
    try:
        api = GcsApi()
    except GcsApiError as e:
        print(f"  !!! {e}")
        print("  Launch the app with GCS_TEST_API=1 exported before running this test.")
        raise
    print(f"  {api.call('ping')}")

    project_folder = os.path.join(PROJECT_DIR, PROJECT_NAME)
    if os.path.exists(project_folder):
        shutil.rmtree(project_folder)
    os.makedirs(PROJECT_DIR, exist_ok=True)
    project_file = os.path.join(project_folder, PROJECT_NAME + ".gpucs")

    step("Creating the project via API (same calls the New Project dialog's OK button makes)")
    create_src = f"""
        if (Backend.projectFolderWouldConflict({json.dumps(PROJECT_DIR)}, {json.dumps(PROJECT_NAME)})) {{
            return {{ok: false, error: "project folder conflict"}};
        }}
        var newDir = Backend.createProjectFolder({json.dumps(PROJECT_DIR)}, {json.dumps(PROJECT_NAME)});
        if (newDir === "") return {{ok: false, error: "createProjectFolder failed"}};

        Backend.setSetting("project/fileName", {json.dumps(PROJECT_NAME + ".gpucs")});
        Backend.setSetting("project/location", newDir);
        Backend.setSetting("project/name", {json.dumps(PROJECT_NAME)});
        Backend.setSetting("project/description", "");
        Backend.setSetting("project/width", "auto");
        Backend.setSetting("project/height", "auto");
        Backend.setSetting("project/fps", "auto");
        Backend.setSetting("project/decoder", "nvdec_h264");
        Backend.setSetting("project/videoTracks", 2);
        Backend.setSetting("project/audioTracks", 2);
        Backend.setSetting("project/videoThumbnails", true);
        Backend.setSetting("project/audioThumbnails", true);

        newProjectWindow.isNewProject = true;
        newProjectWindow.accepted();
        return {{ok: true, dir: newDir}};
    """
    result = api.exec(create_src)
    assert result.get("ok"), f"project creation failed: {result}"
    print(f"  project folder: {result['dir']}")

    wait_until(
        lambda: api.eval("root.isProjectOpen") is True,
        timeout=10,
        description="root.isProjectOpen to become true",
    )

    step("Adding both source files to the project bin via API")
    for source_file in (SOURCE_FILE_1, SOURCE_FILE_2):
        path = os.path.join(SOURCE_DIR, source_file)
        url = "file://" + path
        api.exec(f"Backend.projectBinModel.addFile({json.dumps(url)}); return true;")
    # Both addFile() calls kick off waveform generation, which can briefly
    # contend with the preview pipeline's own async seek right after project
    # creation - give that more room than the default 5s before treating it
    # as a real hang.
    assert_responsive(timeout=20, label="after adding both files to the project bin")

    step("Switching to the Editing workspace via API")
    api.exec('root.currentWorkspace = "Editing"; return true;')
    wait_until(
        lambda: api.eval(
            "!!(editingWorkspaceLoader && editingWorkspaceLoader.item && root.timelinePanelRef)"
        )
        is True,
        timeout=15,
        description="Editing workspace / timelinePanelRef to be ready",
    )
    assert_responsive(label="after switching to Editing")

    step("Waiting for both clips to appear in the Editing project bin (AT-SPI)")
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

    step("Verifying the first clip landed on V1 (via API)")
    # A source with both video and audio drops as a LINKED pair - one entry
    # on the video track, one on its corresponding audio track - so
    # clipsArray() has 2 entries per drop, not 1. Checks below only look at
    # the video-track (hasVideo) entries, which is what the AT-SPI "[V1]"
    # lookups and the user's "2 clips" request are actually about.
    wait_until(
        lambda: len([c for c in api.eval("root.timelinePanelRef.clipsArray()") if c["hasVideo"]]) >= 1,
        timeout=10,
        description="first video clip to appear in the timeline model",
    )
    all_clips = api.eval("root.timelinePanelRef.clipsArray()")
    video_clips = [c for c in all_clips if c["hasVideo"]]
    print(f"  {len(all_clips)} clip entries total ({len(video_clips)} video, "
          f"{len(all_clips) - len(video_clips)} audio) after first drop")
    assert len(video_clips) == 1, f"expected exactly 1 video clip after first drop, got {len(video_clips)}"
    print(f"  clip 1: {video_clips[0]['itemName']} on {video_clips[0]['trackId']}"
          f" start={video_clips[0]['startTime']:.2f}s dur={video_clips[0]['durationSeconds']:.2f}s")
    assert video_clips[0]["startTime"] < 0.5, (
        f"expected the first clip near timeline start, got startTime={video_clips[0]['startTime']}"
    )

    wait_until(
        lambda: len(find_all(role="list item", name_contains="[V1]")) >= 1,
        timeout=10,
        description="first clip to appear visually on V1",
    )

    # The first drop's commit triggers a preview-pipeline seek (see
    # onCommitCompleted in TimelineEngine) - let that settle before
    # starting the next drag, which otherwise doesn't reliably register as
    # a drag at all (no "drag entered" ever reaches TimelineDropArea).
    time.sleep(1.0)

    # The sample clips are ~56s long - at the timeline's default zoom that's
    # far wider than the test display, so the first clip's right edge (and
    # therefore the second drop's target point) would land off-screen.
    # zoomToFit() is the same function the toolbar's "zoom to fit" button
    # calls - shrink to it so both clips end up on-screen.
    api.exec("root.timelinePanelRef.zoomToFit(); return true;")
    time.sleep(0.5)

    first_clip_x, _, first_clip_w, _ = get_rect(
        find_one(role="list item", name_contains="[V1]")
    )

    step(f"Dragging '{SOURCE_FILE_2}' onto V1 right after the first clip")
    bin_item_2 = find_one(name_contains=f"Project bin item {SOURCE_FILE_2}")
    second_target_x = first_clip_x + first_clip_w + 20
    drag_to(bin_item_2, second_target_x, target_y)
    assert_responsive(label="after dragging second clip onto V1")

    step("Verifying both clips are on V1, back-to-back, non-overlapping (via API)")
    wait_until(
        lambda: len([c for c in api.eval("root.timelinePanelRef.clipsArray()") if c["hasVideo"]]) >= 2,
        timeout=10,
        description="second video clip to appear in the timeline model",
    )
    all_clips = api.eval("root.timelinePanelRef.clipsArray()")
    clips = sorted((c for c in all_clips if c["hasVideo"]), key=lambda c: c["startTime"])
    print(f"  {len(all_clips)} clip entries total ({len(clips)} video, "
          f"{len(all_clips) - len(clips)} audio) after both drops")
    assert len(clips) == 2, f"expected exactly 2 video clips on the timeline, got {len(clips)}"
    assert all(c["trackId"] == clips[0]["trackId"] for c in clips), (
        f"expected both clips on the same track, got {[c['trackId'] for c in clips]}"
    )

    c1, c2 = clips
    print(f"  clip 1: {c1['itemName']} start={c1['startTime']:.2f}s dur={c1['durationSeconds']:.2f}s")
    print(f"  clip 2: {c2['itemName']} start={c2['startTime']:.2f}s dur={c2['durationSeconds']:.2f}s")
    c1_end = c1["startTime"] + c1["durationSeconds"]
    assert c2["startTime"] >= c1_end - 0.01, (
        f"clips overlap: clip1 ends at {c1_end:.3f}s, clip2 starts at {c2['startTime']:.3f}s"
    )
    gap = c2["startTime"] - c1_end
    print(f"  gap between clips: {gap:.3f}s")
    assert gap < 1.0, f"expected the second clip right after the first (<1s gap), got {gap:.3f}s"

    step("Saving the project via API")
    api.exec("root.saveProject(); return true;")
    wait_until(
        lambda: os.path.exists(project_file),
        timeout=10,
        description=f"project file to be written to {project_file}",
    )
    assert_responsive(label="after saving project")

    api.close()
    print(f"\n  project saved at: {project_file}")
    print("\n=== ALL CHECKS PASSED ===")
    return 0


if __name__ == "__main__":
    sys.exit(run())
