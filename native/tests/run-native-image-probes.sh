#!/bin/bash
# Build and exercise stock native helpers only in disposable child processes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE="${1:-/Library/Application Support/LaunchpadRestore/Dock.app.orig/Contents/MacOS/Dock}"
BUILD="$(mktemp -d /tmp/launchpad-native-probes.XXXXXX)"
echo "Probe artifacts: $BUILD"
python3 "$ROOT/convert-dock-dylib.py" "$SOURCE" "$BUILD/Dock.dylib"
xcrun clang -arch x86_64 -fblocks -framework Foundation -framework QuartzCore \
    -framework CoreImage -framework CoreGraphics \
    "$ROOT/native-image-probe.m" -o "$BUILD/native-image-probe"
xcrun clang -arch x86_64 -fblocks -framework AppKit -framework QuartzCore \
    -framework Metal -framework CoreImage \
    "$ROOT/native-ca-render-probe.m" -o "$BUILD/native-ca-render-probe"
for source_kind in solid bitmap ci; do
    "$BUILD/native-image-probe" "$BUILD/Dock.dylib" "$source_kind" 3 \
        > "$BUILD/cpu-$source_kind.out" 2> "$BUILD/cpu-$source_kind.err"
done
for mode in default ci-draw; do
    "$BUILD/native-ca-render-probe" "$BUILD/Dock.dylib" "$mode" 120 \
        > "$BUILD/metal-$mode.out" 2> "$BUILD/metal-$mode.err"
done
CA_NO_ACCEL=1 "$BUILD/native-ca-render-probe" "$BUILD/Dock.dylib" ci-draw 120 \
    > "$BUILD/metal-ci-draw-noaccel.out" 2> "$BUILD/metal-ci-draw-noaccel.err"
python3 - "$BUILD" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
results = {}
for kind in ("solid", "bitmap", "ci"):
    lines = (root / f"cpu-{kind}.out").read_text().splitlines()
    if len(lines) != 54:
        raise SystemExit(f"{kind}: expected 54 native image cases, got {len(lines)}")
    grouped = {}
    for line in lines:
        match = re.search(r"fmt=(\d) (\d+x\d+) raw=([0-9a-f]+) layer=([0-9a-f]+)", line)
        if not match:
            raise SystemExit(f"unexpected probe output: {line}")
        grouped.setdefault(match.group(1, 2), set()).add(match.group(3, 4))
    if len(grouped) != 9 or any(len(hashes) != 1 for hashes in grouped.values()):
        raise SystemExit(f"{kind}: pixel hashes changed across size/release cycles")
    results[kind] = grouped
if results["bitmap"] != results["ci"]:
    raise SystemExit("bitmap and deferred CI image pixel hashes differ")
def final_hash(name):
    text = (root / name).read_text()
    match = re.search(r"done lastFrameHash=([0-9a-f]+)", text)
    if not match:
        raise SystemExit(f"{name}: renderer did not finish")
    return match.group(1)
final_hash("metal-default.out")
if final_hash("metal-ci-draw.out") != final_hash("metal-ci-draw-noaccel.out"):
    raise SystemExit("Metal baseline and CA_NO_ACCEL final hashes differ")
print("162 CPU image cases and 360 Metal frames passed; pixel hashes match")
PY
echo "Completed. Logs remain in $BUILD"
