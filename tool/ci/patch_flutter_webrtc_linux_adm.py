#!/usr/bin/env python3
"""Make flutter_webrtc Linux factory init lazy and Dummy-ADM-only.

See tool/ci/patch_libwebrtc_dummy_adm.py for the .so rewrite.
"""

from __future__ import annotations

import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]


def find_webrtc_base() -> pathlib.Path | None:
    candidates = []
    pub = os.environ.get("PUB_CACHE")
    if pub:
        candidates.append(pathlib.Path(pub))
    candidates.append(pathlib.Path.home() / ".pub-cache")
    flutter = os.environ.get("FLUTTER_ROOT")
    if flutter:
        candidates.append(pathlib.Path(flutter) / ".pub-cache")
    for root in candidates:
        if not root.exists():
            continue
        matches = list(root.rglob("flutter_webrtc-1.4.1/common/cpp/src/flutter_webrtc_base.cc"))
        if matches:
            return matches[0]
    return None


def patch_header(path: pathlib.Path) -> None:
    text = path.read_text()
    if "EnsureFactoryInitialized" in text:
        return
    needle = "  libwebrtc::scoped_refptr<libwebrtc::KeyProvider> GetKeyProviderForId("
    if needle not in text:
        raise SystemExit(f"header needle missing in {path}")
    text = text.replace(
        needle,
        "  void EnsureFactoryInitialized();\n"
        "  void EnsureAudioDevice();\n\n" + needle,
        1,
    )
    old = "  std::unique_ptr<EventChannelProxy> event_channel_;\n};"
    new = (
        "  std::unique_ptr<EventChannelProxy> event_channel_;\n"
        "  bool factory_initialized_ = false;\n};"
    )
    if old not in text:
        raise SystemExit(f"event_channel_ block missing in {path}")
    path.write_text(text.replace(old, new, 1))
    print("patched", path)


def _move_helpers_inside_namespace(path: pathlib.Path, text: str) -> str:
    """A previous patch appended helpers after the namespace close."""
    closer = "}  // namespace flutter_webrtc_plugin\n"
    outside = (
        "void FlutterWebRTCBase::EnsureFactoryInitialized() {\n"
        "  if (factory_initialized_ || !factory_) return;\n"
        "  if (!factory_->Initialize()) return;\n"
        "  video_device_ = factory_->GetVideoDevice();\n"
        "  desktop_device_ = factory_->GetDesktopDevice();\n"
        "  audio_processing_ = factory_->GetAudioProcessing();\n"
        "  factory_initialized_ = true;\n"
        "}\n"
        "\n"
        "void FlutterWebRTCBase::EnsureAudioDevice() {\n"
        "  EnsureFactoryInitialized();\n"
        "  if (!audio_device_ && factory_) {\n"
        "    audio_device_ = factory_->GetAudioDevice();\n"
        "  }\n"
        "}\n"
    )
    if closer in text and outside in text and text.find(outside) > text.find(closer):
        text = text.replace(outside, "")
        text = text.replace(closer, outside + "\n" + closer, 1)
        path.write_text(text)
        print("moved helpers inside namespace", path)
    return text


def patch_base_cc(path: pathlib.Path) -> None:
    text = path.read_text()
    if "EnsureFactoryInitialized" in text:
        _move_helpers_inside_namespace(path, text)
        return
    old = """  LibWebRTC::Initialize();
  factory_ = LibWebRTC::CreateRTCPeerConnectionFactory();
  factory_->Initialize();
  audio_device_ = factory_->GetAudioDevice();
  video_device_ = factory_->GetVideoDevice();
  desktop_device_ = factory_->GetDesktopDevice();
  audio_processing_ = factory_->GetAudioProcessing();
  event_channel_ = EventChannelProxy::Create(messenger_, task_runner_, kEventChannelName);
"""
    new = """  LibWebRTC::Initialize();
  factory_ = LibWebRTC::CreateRTCPeerConnectionFactory();
  // Lazy: plugin registration must not create a platform ADM.
  factory_initialized_ = false;
  event_channel_ = EventChannelProxy::Create(messenger_, task_runner_, kEventChannelName);
"""
    if old not in text:
        raise SystemExit(f"constructor block missing in {path}")
    text = text.replace(old, new, 1)
    methods = """
void FlutterWebRTCBase::EnsureFactoryInitialized() {
  if (factory_initialized_ || !factory_) return;
  if (!factory_->Initialize()) return;
  video_device_ = factory_->GetVideoDevice();
  desktop_device_ = factory_->GetDesktopDevice();
  audio_processing_ = factory_->GetAudioProcessing();
  factory_initialized_ = true;
}

void FlutterWebRTCBase::EnsureAudioDevice() {
  EnsureFactoryInitialized();
  if (!audio_device_ && factory_) {
    audio_device_ = factory_->GetAudioDevice();
  }
}

"""
    closer = "}  // namespace flutter_webrtc_plugin\n"
    if closer not in text:
        raise SystemExit(f"namespace closer missing in {path}")
    text = text.replace(closer, methods + closer, 1)
    path.write_text(text)
    print("patched", path)


def patch_webrtc_cc(path: pathlib.Path) -> None:
    text = path.read_text()
    if "EnsureFactoryInitialized();" in text:
        return
    text = text.replace(
        "    CreateRTCPeerConnection(configuration, constraints, std::move(result));",
        "    EnsureFactoryInitialized();\n"
        "    CreateRTCPeerConnection(configuration, constraints, std::move(result));",
        1,
    )
    text = text.replace(
        "    GetUserMedia(constraints, std::move(result));",
        "    EnsureAudioDevice();\n"
        "    GetUserMedia(constraints, std::move(result));",
        1,
    )
    path.write_text(text)
    print("patched", path)


def patch_third_party_cmake(base_cc: pathlib.Path) -> None:
    cmake = base_cc.parent.parent.parent / "third_party" / "CMakeLists.txt"
    if not cmake.exists():
        return
    text = cmake.read_text()
    marker = "patch_libwebrtc_dummy_adm.py"
    if marker in text:
        return
    hook = f"""
# Orbits: force Dummy ADM after libwebrtc extract (linux data-only chats).
execute_process(
  COMMAND {sys.executable} "{ROOT / "tool/ci/patch_libwebrtc_dummy_adm.py"}"
          "{cmake.parent / "libwebrtc/lib/linux-x64/libwebrtc.so"}"
          "{cmake.parent / "libwebrtc/lib/linux-arm64/libwebrtc.so"}"
  RESULT_VARIABLE _orbits_adm_patch
)
"""
    cmake.write_text(text + hook)
    print("patched", cmake)


def patch_sos(so_root: pathlib.Path) -> None:
    py = ROOT / "tool/ci/patch_libwebrtc_dummy_adm.py"
    if not so_root.exists():
        return
    for so in so_root.rglob("libwebrtc.so"):
        subprocess.run([sys.executable, str(py), str(so)], check=False)


def main() -> int:
    base = find_webrtc_base()
    if base is None:
        print("flutter_webrtc-1.4.1 not in pub-cache yet; skip source patch")
    else:
        header = base.parent.parent / "include" / "flutter_webrtc_base.h"
        webrtc_cc = base.parent / "flutter_webrtc.cc"
        patch_header(header)
        patch_base_cc(base)
        patch_webrtc_cc(webrtc_cc)
        patch_third_party_cmake(base)
        patch_sos(base.parent.parent.parent / "third_party" / "libwebrtc" / "lib")
    for extra in (
        ROOT / "build/linux/x64/debug/plugins/flutter_webrtc",
        ROOT / "build/linux/x64/release/plugins/flutter_webrtc",
    ):
        patch_sos(extra)
    print("flutter_webrtc linux ADM patch applied")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
