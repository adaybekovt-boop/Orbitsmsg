#!/usr/bin/env python3
"""Force libwebrtc factory ADM creation onto kDummyAudio (enum value 10).

RTCPeerConnectionFactoryImpl::Initialize() calls
  CreateAudioDeviceModule(env, kPlatformDefaultAudio=0, false)
which on Linux builds Pulse/ALSA and then adm_helpers::Init Fatals when
no sound server exists. Data-only PeerJS chats must not take that path.

CreateAudioDeviceModule is 23 bytes plus int3 padding. We insert
  mov $0xa, %edx
so every ADM created through this wrapper is Dummy. Platform capture is
still gated in Dart (WebRtcAudioLifecycle) and only attempted after an
explicit call action.
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


def patch_so(path: pathlib.Path) -> bool:
    data = path.read_bytes()
    if PATCHED in data:
        print(f"already patched: {path}")
        return False
    idx = data.find(ORIGINAL)
    if idx < 0:
        # Allow the shorter unique prefix (prologue through original call)
        prefix = ORIGINAL[:16]
        idx = data.find(prefix)
        if idx < 0:
            raise SystemExit(f"CreateAudioDeviceModule bytes not found in {path}")
        if data[idx : idx + len(ORIGINAL)] != ORIGINAL:
            raise SystemExit(
                f"CreateAudioDeviceModule at {idx:#x} does not match expected body"
            )
    extra = len(PATCHED) - len(ORIGINAL)
    after = data[idx + len(ORIGINAL) : idx + len(ORIGINAL) + extra]
    if any(b not in (0xCC, 0x00) for b in after):
        raise SystemExit(
            f"no padding after CreateAudioDeviceModule at {idx:#x}: {after.hex()}"
        )
    patched = data[:idx] + PATCHED + data[idx + len(ORIGINAL) :]
    path.write_bytes(patched)
    print(f"patched CreateAudioDeviceModule -> kDummyAudio at {idx:#x} in {path}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("libwebrtc", nargs="+", type=pathlib.Path)
    args = parser.parse_args()
    changed = False
    for so in args.libwebrtc:
        if not so.is_file():
            print(f"skip missing {so}", file=sys.stderr)
            continue
        changed = patch_so(so) or changed
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
