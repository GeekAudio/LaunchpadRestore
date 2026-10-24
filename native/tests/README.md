# Isolated native image probes

These probes load the actual Dock 2427.6 x86_64 image helpers in a child process.
They do not launch Dock's entry point, instantiate its environment, change preferences,
create visible windows, switch display modes, or install files.

Run `bash native/tests/run-native-image-probes.sh [original-Dock-executable]` from the
repository. Build products and logs remain in a newly created `/tmp` directory.
The conversion tool accepts only the known original executable hashes; its output
must be a new file inside the temporary directory.

The conversion retains segment indices and function offsets for chained fixups,
changes `MH_EXECUTE` to `MH_DYLIB`, clears `MH_PIE`, removes `LC_MAIN` and
`LC_LOAD_DYLINKER`, changes the empty `__PAGEZERO` segment to zero size, adds an
`LC_ID_DYLIB`, and signs the temporary library. The two original constructor offsets
(`0xcf11f`, `0xd9ee4`) initialize local state. There are no nonlazy Objective-C classes.

Native offsets are deliberately specific to this hash-guarded build:

| Offset | Signature and ownership |
| --- | --- |
| `0x1099f` | `id(bool floatP3, size_t w, size_t h, int vmTag, void (^)(CGContextRef))`; autoreleased CGImage, retained by probe |
| `0x19204` | `void *(size_t w, size_t h, int vmTag, void (^)(CGContextRef))`; owned CARender object, released with `CARenderRelease` |

The CPU probe cycles 2×2, 11×11 and 128×128 inputs through both CGImage formats
and the CARenderImage helper, then consumes them with `CALayer.renderInContext:`.
It reports original provider bytes, rendered pixel hashes, and final mapping protection.
It covers solid drawing, source bitmap images, and deferred Core Image images.

The Metal probe uses the same actual helpers as sources for an offscreen `CARenderer`
with shadows and rasterization, cycles source sizes and replaces the destination
texture while releasing previous images. A supplied Metal command queue permits
explicit completion waits every 16 frames; the probe releases its preceding source
image after each new frame, so source release also happens with GPU work in flight.
Its `ci-draw` mode draws deferred Core Image sources into
the actual native helper and then uses a custom layer drawing callback.

Observed on this machine: the CPU cases pass with repeatable hashes and readonly
backing pages. The Metal cases also pass; `CA_NO_ACCEL=1` produced the same final
hash as its baseline. These probes have not reproduced the real Dock crash and do
not prove that either backend preference repairs it. Offscreen `CARenderer` does
not establish that the desktop's QuartzCore Whippet path was exercised.

## Client CGContext backend selection

Run `bash native/tests/verify-surface-backend.sh` to exercise an actual IOSurface
CGContext queue instead of offscreen CARenderer. The probe has a fresh bundle ID
and sets `CAEnableMetalWhippet` only in its own process preference cache.
LLDB dynamically observes `CAMetalContextCreate` and `CA::OGL::SWContext::set_destination`;
the override must remove Metal creation hits and produce software destination hits.
Both backends run 1,500 context creation/draw/release cycles and compare pixel hashes
for 2×2, 11×11 and 128×128 surfaces. Temporary files are removed after the run.

This validates the chosen backend and rendered pixels. It does not switch the
desktop resolution and has not reproduced the original Dock crash.
