#!/bin/bash
# Build an isolated probe, verify Metal -> software backend selection with LLDB,
# and compare pixels while cycling 2x2, 11x11 and 128x128 IOSurface contexts.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROBE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/launchpad-surface-probe.XXXXXX")"
trap 'rm -rf "$PROBE_TMP"' EXIT
PROBE_APP="$PROBE_TMP/SurfaceBackendProbe.app"
mkdir -p "$PROBE_APP/Contents/MacOS"
cat > "$PROBE_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.launchpadrestore.surface-probe.${PROBE_TMP##*.}</string>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
PROBE_BIN="$PROBE_APP/Contents/MacOS/probe"
xcrun clang -O2 -fobjc-arc "$SCRIPT_DIR/surface-render-probe.m" \
    -framework Foundation -framework CoreGraphics -framework IOSurface -o "$PROBE_BIN"

# Resolve symbols through LLDB on each launch; no fixed ASLR addresses are used.
cat > "$PROBE_TMP/backend_watch.py" <<'PY'
import json
import lldb

breakpoints = {}

def resume(frame, location, internal_dict):
    return False

def install(debugger):
    target = debugger.GetSelectedTarget()
    breakpoints["metal"] = target.BreakpointCreateByName("CAMetalContextCreate")
    breakpoints["software"] = target.BreakpointCreateByRegex(
        r"CA::OGL::SWContext::set_destination\(")
    for breakpoint in breakpoints.values():
        breakpoint.SetScriptCallbackFunction(__name__ + ".resume")

def report(debugger):
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    if process.GetState() != lldb.eStateExited or process.GetExitStatus() != 0:
        raise RuntimeError("probe did not exit successfully")
    counts = {name: breakpoint.GetHitCount() for name, breakpoint in breakpoints.items()}
    print("BACKEND_COUNTS " + json.dumps(counts, sort_keys=True))
PY

for PROBE_MODE in metal software; do
    "$PROBE_BIN" "$PROBE_MODE" 1500 > "$PROBE_TMP/$PROBE_MODE.pixels.log" 2>&1
    xcrun lldb --batch \
        -o "command script import $PROBE_TMP/backend_watch.py" \
        -o 'script backend_watch.install(lldb.debugger)' \
        -o run \
        -o 'script backend_watch.report(lldb.debugger)' \
        -- "$PROBE_BIN" "$PROBE_MODE" 6 > "$PROBE_TMP/$PROBE_MODE.backend.log" 2>&1
 done

python3 - "$PROBE_TMP" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
def record(mode, suffix, marker):
    content = (root / f"{mode}.{suffix}.log").read_text()
    for line in content.splitlines():
        if line.startswith(marker):
            return json.loads(line[len(marker):])
    raise SystemExit(f"missing {marker.strip()} for {mode}:\n{content}")

metal = record("metal", "backend", "BACKEND_COUNTS ")
software = record("software", "backend", "BACKEND_COUNTS ")
if not (metal["metal"] > 0 and metal["software"] == 0):
    raise SystemExit(f"default probe did not select the expected Metal backend: {metal}")
if not (software["metal"] == 0 and software["software"] > 0):
    raise SystemExit(f"override did not select the expected software backend: {software}")
metal_pixels = record("metal", "pixels", "PIXEL_HASHES ")
software_pixels = record("software", "pixels", "PIXEL_HASHES ")
if metal_pixels != software_pixels:
    raise SystemExit(f"backend pixel hashes differ: {metal_pixels} vs {software_pixels}")
print("Metal backend:", metal)
print("Software backend:", software)
print("Equal pixel hashes:", metal_pixels)
print("PASS: 1500 context replacements per backend; backend switch verified with LLDB.")
print("This fixture does not switch the display mode or establish that the Dock crash is fixed.")
PY
