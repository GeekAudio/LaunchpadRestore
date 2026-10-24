#!/usr/bin/env python3
"""Load the exact stock Dock helpers in a disposable process, without its main()."""

import argparse
import hashlib
from pathlib import Path
import struct
import subprocess
import tempfile


UNIVERSAL_SHA256 = "278ed95b86bdef7e122820a0251c5a607fec377c217fae34a651397e8082e193"
THIN_SHA256 = "507e6a925bc90e809001c53ad731ac089b341ebfdb06710ac44785119545b1b2"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="unmodified Dock 2427.6 executable")
    parser.add_argument("output", type=Path, help="new dylib path under the temporary directory")
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    output = args.output.resolve()
    temporary_roots = {Path(tempfile.gettempdir()).resolve(), Path("/tmp").resolve()}
    if not any(root in output.parents for root in temporary_roots) or output.exists():
        parser.error("output must be a new path inside the temporary directory")
    original = source.read_bytes()
    digest = hashlib.sha256(original).hexdigest()
    if digest == UNIVERSAL_SHA256:
        with tempfile.TemporaryDirectory(prefix="dock-thin-") as work:
            thin = Path(work) / "Dock.x86_64"
            subprocess.run(["lipo", "-thin", "x86_64", str(source), "-output", str(thin)], check=True)
            data = bytearray(thin.read_bytes())
    elif digest == THIN_SHA256:
        data = bytearray(original)
    else:
        parser.error(f"unsupported source SHA-256: {digest}")
    if hashlib.sha256(data).hexdigest() != THIN_SHA256:
        parser.error("unexpected x86_64 slice")
    if struct.unpack_from("<III", data) != (0xFEEDFACF, 0x01000007, 3):
        parser.error("expected the known x86_64 Mach-O header")
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    offset = 32
    commands = []
    # Preserve segment indices: chained fixup metadata uses these indices.
    for _ in range(ncmds):
        command, size = struct.unpack_from("<II", data, offset)
        item = bytearray(data[offset:offset + size])
        offset += size
        if command in (0x80000028, 0xE):  # LC_MAIN, LC_LOAD_DYLINKER
            continue
        if command == 0x19 and item[8:24].rstrip(b"\0") == b"__PAGEZERO":
            struct.pack_into("<QQ", item, 24, 0x100000000, 0)
        commands.append(item)
    name = str(output).encode() + b"\0"
    size = (24 + len(name) + 7) & ~7
    commands.append(struct.pack("<IIIIII", 0xD, size, 24, 0, 0x10000, 0x10000)
                    + name + b"\0" * (size - 24 - len(name)))
    joined = b"".join(commands)
    # __text starts at this offset in the hash-guarded input.
    if 32 + len(joined) >= 0x5FA0:
        parser.error("load commands would overlap executable code")
    struct.pack_into("<I", data, 12, 6)  # MH_DYLIB
    flags = struct.unpack_from("<I", data, 24)[0] & ~0x200000  # clear MH_PIE
    struct.pack_into("<III", data, 16, len(commands), len(joined), flags)
    length = max(sizeofcmds, len(joined))
    data[32:32 + length] = joined + b"\0" * (length - len(joined))
    output.write_bytes(data)
    subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(output)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(output)], check=True)
    print(output)


if __name__ == "__main__":
    main()
