#!/usr/bin/env python3
"""Force libwebrtc factory ADM creation onto kDummyAudio (enum value 10).

RTCPeerConnectionFactoryImpl::Initialize() calls
  CreateAudioDeviceModule(env, kPlatformDefaultAudio=0, false)
which on Linux builds Pulse/ALSA and then adm_helpers::Init Fatals when
no sound server exists. Data-only PeerJS chats must not take that path.

CreateAudioDeviceModule is 23 bytes followed by int3 padding. We overwrite
the function *and the first 5 padding bytes in place* with
    mov $0xa, %edx
so the file size and every later ELF offset stay unchanged. A previous
revision concatenated the longer body and shifted .text — that corrupted
the ELF and produced SIGSEGV on startup.

Platform capture is still gated in Dart (WebRtcAudioLifecycle) and only
attempted after an explicit call action.
"""

from __future__ import annotations

import argparse
import pathlib
import sys

# Original CreateAudioDeviceModule prologue + body (linux-x64, flutter-webrtc 1.4.0)
ORIGINAL = bytes.fromhex(
    "55"  # push %rbp
    "4889e5"  # mov %rsp, %rbp
    "53"  # push %rbx
    "50"  # push %rax
    "4889fb"  # mov %rdi, %rbx
    "488d7df0"  # lea -0x10(%rbp), %rdi
    "e8de2adfff"  # call AudioDeviceModuleImpl::Create
    "488b45f0"  # mov -0x10(%rbp), %rax
    "488903"  # mov %rax, (%rbx)
    "4889d8"  # mov %rbx, %rax
    "4883c408"  # add $0x8, %rsp
    "5b"  # pop %rbx
    "5d"  # pop %rbp
    "c3"  # ret
)

# Same function with `mov $0xa, %edx` (kDummyAudio) before the Create call.
# The relative call offset shrinks by 5 because the call sits 5 bytes later.
# Those 5 bytes occupy existing int3 padding — file length must not change.
PATCHED = bytes.fromhex(
    "55"
    "4889e5"
    "53"
    "50"
    "4889fb"
    "ba0a000000"  # mov $0xa, %edx
    "488d7df0"
    "e8d92adfff"  # call Create; rel32 adjusted by -5
    "488b45f0"
    "488903"
    "4889d8"
    "4883c408"
    "5b"
    "5d"
    "c3"
)

ELF_MAGIC = b"\x7fELF"


def _require_elf(data: bytes, path: pathlib.Path) -> None:
    if len(data) >= 4 and data[:4] == ELF_MAGIC:
        # e_phentsize at 54, e_phnum at 56 (64-bit)
        if len(data) < 64:
            raise SystemExit(f"{path} is a truncated ELF")
        phentsize = int.from_bytes(data[54:56], "little")
        phnum = int.from_bytes(data[56:58], "little")
        phoff = int.from_bytes(data[32:40], "little")
        if phentsize == 0 or phnum == 0 or phoff + phentsize * phnum > len(data):
            raise SystemExit(f"{path} ELF program headers are unreadable")


def already_patched(data: bytes) -> bool:
    return PATCHED in data and ORIGINAL not in data


def patch_so(path: pathlib.Path) -> bool:
    raw = path.read_bytes()
    size_before = len(raw)
    if already_patched(raw):
        print(f"already patched: {path}")
        _require_elf(raw, path)
        return False
    idx = raw.find(ORIGINAL)
    if idx < 0:
        raise SystemExit(f"CreateAudioDeviceModule bytes not found in {path}")
    extra = len(PATCHED) - len(ORIGINAL)
    after = raw[idx + len(ORIGINAL) : idx + len(ORIGINAL) + extra]
    if len(after) < extra or any(b not in (0xCC, 0x00) for b in after):
        raise SystemExit(
            f"no padding after CreateAudioDeviceModule at {idx:#x}: {after.hex()}"
        )
    data = bytearray(raw)
    data[idx : idx + len(PATCHED)] = PATCHED
    if len(data) != size_before:
        raise SystemExit(
            f"internal error: patch changed file size {size_before} -> {len(data)}"
        )
    if ORIGINAL in data:
        raise SystemExit(f"original CreateAudioDeviceModule still present in {path}")
    if PATCHED not in data:
        raise SystemExit(f"patched CreateAudioDeviceModule missing in {path}")
    _require_elf(bytes(data), path)
    path.write_bytes(data)
    print(
        f"patched CreateAudioDeviceModule -> kDummyAudio at {idx:#x} "
        f"(in-place, size {size_before}) in {path}"
    )
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("libwebrtc", nargs="+", type=pathlib.Path)
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="exit 0 only if every existing file is already Dummy-ADM patched",
    )
    args = parser.parse_args()
    changed = False
    seen = 0
    for so in args.libwebrtc:
        if not so.is_file():
            print(f"skip missing {so}", file=sys.stderr)
            continue
        seen += 1
        if args.verify_only:
            data = so.read_bytes()
            _require_elf(data, so)
            if not already_patched(data):
                raise SystemExit(f"not Dummy-ADM patched: {so}")
            print(f"verified Dummy-ADM: {so}")
            continue
        changed = patch_so(so) or changed
    if seen == 0:
        raise SystemExit("no libwebrtc.so files to patch")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
