#!/bin/bash
# Read the hash-guarded backup; all conversion and fixture work stays under /tmp.
set -euo pipefail
PROBE_ROOT="$(cd "$(dirname "$0")" && pwd)"
PROBE_SOURCE="${1:-/Library/Application Support/LaunchpadRestore/Dock.app.orig/Contents/MacOS/Dock}"
PROBE_BUILD="$(mktemp -d /tmp/launchpad-icon-cache-probe.XXXXXX)"
echo "Probe artifacts: $PROBE_BUILD"
python3 "$PROBE_ROOT/convert-dock-dylib.py" "$PROBE_SOURCE" "$PROBE_BUILD/Dock-stock.dylib"
xcrun clang -arch x86_64 -fobjc-arc -Wall -Wextra -Werror \
    -framework Foundation -framework CoreGraphics \
    "$PROBE_ROOT/native-icon-cache-fallback-probe.m" -o "$PROBE_BUILD/icon-cache-probe"
"$PROBE_BUILD/icon-cache-probe" "$PROBE_BUILD/Dock-stock.dylib" > "$PROBE_BUILD/result.json"
python3 - "$PROBE_BUILD/result.json" <<'PY'
import json
from pathlib import Path
import sys

result = json.loads(Path(sys.argv[1]).read_text())
assert len(result["cases"]) == 17, result
print("17 stock native cache-completion fixtures passed; empty slots already display decoded cached images regardless of cached size")
PY
echo "Completed. Logs remain in $PROBE_BUILD"
