#!/bin/bash
# Screenshot the running Neat window.
#
# XcodeBuildMCP's screenshot tool is simulator-only (it shells out to simctl),
# and the package ships no macOS window capture at any workflow setting. So we
# find the window ourselves and hand its id to screencapture.
#
# Usage: Scripts/shot.sh out.png [app-name]
set -euo pipefail

OUT="${1:-shot.png}"
APP="${2:-Neat}"

WINDOW_ID="$(
  xcrun swift - "$APP" <<'SWIFT'
import CoreGraphics
import Foundation

let app = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Neat"
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]

guard let windows = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("could not read the window list\n".utf8))
    exit(2)
}

// Largest on-screen window owned by the app: skips tooltips, menus and shadows.
let match = windows
    .filter { ($0[kCGWindowOwnerName as String] as? String) == app }
    .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
    .compactMap { w -> (Int, Double)? in
        guard let num = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let width = b["Width"] as? Double,
              let height = b["Height"] as? Double
        else { return nil }
        return (num, width * height)
    }
    .max { $0.1 < $1.1 }

guard let match else { exit(1) }
print(match.0)
SWIFT
)" || {
  echo "error: no on-screen window owned by '$APP'. Is it running?" >&2
  exit 1
}

# -o omits the window shadow, -x silences the shutter sound.
screencapture -l"$WINDOW_ID" -o -x "$OUT"

[ -s "$OUT" ] || { echo "error: screencapture produced nothing (Screen Recording permission?)" >&2; exit 1; }
echo "$OUT"
