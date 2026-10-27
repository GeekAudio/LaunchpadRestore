#!/usr/bin/env python3
"""Apply the verified x86_64 Dock 2427.6 Launchpad v9 patch."""

from pathlib import Path
import hashlib
import sys


IMAGE_BASE = 0x100000000
ALLOWED_INPUT_SHA256 = {
    # x86_64 thin slices of Apple's Dock 2427.6 for the two supported builds.
    "507e6a925bc90e809001c53ad731ac089b341ebfdb06710ac44785119545b1b2",
    "d38193aa3fb074f5b0ea636b639f76ee6bc4dc970c37f6600f69fdff0d58cc31",
}


def patch(input_path: Path, output_path: Path) -> None:
    if input_path.is_symlink() or not input_path.is_file():
        raise SystemExit("input must be a regular, non-symlink file")
    if output_path.exists() or output_path.is_symlink():
        raise SystemExit("output must not already exist or be a symlink")
    if input_path.resolve() == output_path.resolve():
        raise SystemExit("input and output must be different files")

    data = bytearray(input_path.read_bytes())
    source_hash = hashlib.sha256(data).hexdigest()
    if source_hash not in ALLOWED_INPUT_SHA256:
        raise SystemExit("input SHA-256 is not a supported stock Dock 2427.6 slice")

    # Keep the native Springboard route instead of routing through the
    # substituted implementation.
    feature_offset = 0x2D7B00
    feature_expected = bytes.fromhex("554889e5b0015dc3")
    if data[feature_offset : feature_offset + len(feature_expected)] != feature_expected:
        raise SystemExit("Unexpected Springboard route bytes")
    data[feature_offset + 5] = 0

    # Dock 2427.6 retains the old LPSpringboard class and display callbacks,
    # but no longer constructs its global instance at startup. Recreate it
    # after Spotlight initialization and use the Dock environment in rbx.
    hook = 0x100058885
    resume = 0x10005888C
    cave = 0x1003F9300
    lpspringboard_class = 0x1004760E0
    init_with_environment_selref = 0x10046A720
    springboard_global = 0x1004972E8
    objc_alloc_with_zone = 0x10035FD0A
    objc_msg_send = 0x10035FD76
    original = bytes.fromhex("498b45004885c0")  # mov rax,[r13]; test rax,rax
    hook_offset = hook - IMAGE_BASE
    resume_offset = resume - IMAGE_BASE
    cave_offset = cave - IMAGE_BASE

    if data[hook_offset:resume_offset] != original:
        raise SystemExit("Unexpected Dock startup bytes")
    if any(data[cave_offset : cave_offset + 96]):
        raise SystemExit("Dock executable padding is not empty")

    code = bytearray()

    def rel32(target: int, instruction_size: int) -> bytes:
        next_pc = cave + len(code) + instruction_size
        displacement = target - next_pc
        try:
            return displacement.to_bytes(4, "little", signed=True)
        except OverflowError as exc:
            raise SystemExit("Dock trampoline target is out of range") from exc

    def lea_rdi(target: int) -> None:
        code.extend(b"\x48\x8d\x3d" + rel32(target, 7))

    def mov_rsi_ref(target: int) -> None:
        code.extend(b"\x48\x8b\x35" + rel32(target, 7))

    def lea_rcx(target: int) -> None:
        code.extend(b"\x48\x8d\x0d" + rel32(target, 7))

    def call(target: int) -> None:
        code.extend(b"\xe8" + rel32(target, 5))

    lea_rdi(lpspringboard_class)
    call(objc_alloc_with_zone)
    mov_rsi_ref(init_with_environment_selref)
    code.extend(bytes.fromhex("4889c74889da"))  # rdi = object; rdx = environment
    call(objc_msg_send)
    lea_rcx(springboard_global)
    code.extend(bytes.fromhex("488b3948890141ffd6"))  # replace global; release old value
    code.extend(original)
    code.extend(b"\xe9" + rel32(resume, 5))
    if len(code) > 96:
        raise SystemExit("Startup trampoline exceeds reserved padding")

    data[cave_offset : cave_offset + len(code)] = code
    hook_displacement = cave - (hook + 5)
    try:
        jump = b"\xe9" + hook_displacement.to_bytes(4, "little", signed=True)
    except OverflowError as exc:
        raise SystemExit("Dock hook target is out of range") from exc
    data[hook_offset:resume_offset] = jump + b"\x90\x90"
    try:
        with output_path.open("xb") as output:
            output.write(data)
    except FileExistsError as exc:
        raise SystemExit("output must not already exist or be a symlink") from exc


if len(sys.argv) != 3:
    raise SystemExit("usage: patch-native-dock.py INPUT_X86_64 OUTPUT_X86_64")

patch(Path(sys.argv[1]), Path(sys.argv[2]))
