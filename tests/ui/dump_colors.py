#!/usr/bin/env python3
"""Phase 0 measurement tool for the theming rework (see project plan).

Walks the running app's QML item tree via the TestApiServer "eval"
command and dumps every item that exposes a `color` property - path,
type, resolved color, visible/enabled - as sorted, line-oriented text.
This turns "does the .deb look the same as the AppImage" from an
eyeballed screenshot comparison into a plain `diff`.

Usage:
    # Start the app with GCS_TEST_API=1 first, then:
    python3 dump_colors.py                  # print to stdout
    python3 dump_colors.py out.txt          # write to a file

Comparing two builds:
    python3 dump_colors.py deb.txt      # against the .deb-installed binary
    python3 dump_colors.py appimage.txt # against the AppImage
    diff deb.txt appimage.txt

Known limitation: only walks the visible Item tree (`children`), so
Menu/ComboBox popup content that hasn't been opened yet (not
instantiated) is invisible to this dump. Known trouble spots - the
MenuBar dropdowns, the decoder ComboBox's popup - need to be opened
first (e.g. via `exec` calling .popup()) for a complete picture; this
script covers the always-visible surface, which was enough to catch
the MenuBar bug this tool was built to prevent a repeat of.
"""
import sys

from gcs_api import GcsApi

# Returned as a JS array of {path, type, color, visible, enabled}
# objects - gcs_api's eval() already round-trips this as native Python
# data (TestApiServer's "eval" command itself JSON.stringify()s the
# result before sending it back, so no extra parsing is needed here).
_WALK_EXPR = """
(function() {
    var out = [];
    function typeName(item) {
        try { return item.toString().split("(")[0]; } catch (e) { return "?"; }
    }
    function record(item, path) {
        try {
            if (item.color !== undefined && item.color !== null) {
                out.push({
                    path: path,
                    type: typeName(item),
                    color: item.color.toString(),
                    visible: !!item.visible,
                    enabled: (item.enabled === undefined) ? null : !!item.enabled
                });
            }
        } catch (e) {}
    }
    function walk(item, path, depth) {
        if (!item || depth > 60) return;
        record(item, path);
        var kids = item.children;
        if (kids) {
            for (var i = 0; i < kids.length; i++) {
                walk(kids[i], path + "/" + i, depth + 1);
            }
        }
    }
    // root is a Window, not an Item - its own visual tree lives under
    // contentItem.children, not root.children (QObject::children() on
    // a Window returns the QObject ownership tree, which isn't the
    // same thing - this is what silently produced a 1-line dump
    // before this fix, catching nothing). menuBar is a separate
    // Window-level property, walked explicitly since it's exactly the
    // component this tool exists to watch.
    record(root, "root");
    if (root.contentItem) walk(root.contentItem, "root.contentItem", 0);
    if (root.menuBar) walk(root.menuBar, "root.menuBar", 0);
    if (root.header) walk(root.header, "root.header", 0);
    if (root.footer) walk(root.footer, "root.footer", 0);
    return out;
})()
"""


def dump_colors(api: GcsApi):
    items = api.eval(_WALK_EXPR)
    lines = []
    for it in items:
        lines.append(
            "{path}\t{type}\tcolor={color}\tvisible={visible}\tenabled={enabled}".format(
                path=it["path"],
                type=it["type"],
                color=it["color"],
                visible=it["visible"],
                enabled=it["enabled"],
            )
        )
    lines.sort()
    return lines


def main(argv):
    api = GcsApi()
    try:
        lines = dump_colors(api)
    finally:
        api.close()

    text = "\n".join(lines) + "\n"
    if len(argv) > 1:
        with open(argv[1], "w") as f:
            f.write(text)
        print(f"wrote {len(lines)} entries to {argv[1]}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
