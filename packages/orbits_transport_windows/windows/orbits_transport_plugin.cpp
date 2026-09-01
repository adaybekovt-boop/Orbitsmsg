// Windows Bare host. Registers a Flutter plugin, refuses remote JS, and
// reports a local bundled Bare path when present. Never downloads.

#include "include/orbits_transport_windows/orbits_transport_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/encodable_value.h>
#include <windows.h>

#include <fstream>
#include <memory>
#include <optional>
#include <string>

namespace {

bool file_exists(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  return in.good();
}

std::string dirname_of(const std::string& path) {
  const auto pos = path.find_last_of("\\/");
  if (pos == std::string::npos) return ".";
  if (pos == 0) return path;
  return path.substr(0, pos);
}

std::optional<std::string> bundled_bare_path() {
  HMODULE module = nullptr;
  if (!::GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            reinterpret_cast<LPCSTR>(
                                &OrbitsTransportPluginRegisterWithRegistrar),
                            &module) ||
      module == nullptr) {
    return std::nullopt;
  }
  char buf[MAX_PATH] = {};
  const DWORD n = ::GetModuleFileNameA(module, buf, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return std::nullopt;
  const std::string dir = dirname_of(std::string(buf, n));
  const std::string next_to_plugin = dir + "\\bare.exe";
  if (file_exists(next_to_plugin)) return next_to_plugin;
  char exe[MAX_PATH] = {};
  const DWORD e = ::GetModuleFileNameA(nullptr, exe, MAX_PATH);
  if (e == 0 || e >= MAX_PATH) return std::nullopt;
  const std::string exe_dir = dirname_of(std::string(exe, e));
  const std::string next_to_exe = exe_dir + "\\bare.exe";
  if (file_exists(next_to_exe)) return next_to_exe;
  return std::nullopt;
}

class OrbitsTransportPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
    auto channel =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), "app.orbits/transport",
            &flutter::StandardMethodCodec::GetInstance());
    auto plugin = std::make_unique<OrbitsTransportPlugin>();
    channel->SetMethodCallHandler(
        [plugin_pointer = plugin.get()](const auto& call, auto result) {
          plugin_pointer->HandleMethodCall(call, std::move(result));
        });
    registrar->AddPlugin(std::move(plugin));
  }

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() == "start") {
      bool remote_js = false;
      std::string remote_js_url;
      if (const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments())) {
        const auto flag = args->find(flutter::EncodableValue("remoteJs"));
        if (flag != args->end()) {
          if (const auto* b = std::get_if<bool>(&flag->second)) {
            remote_js = *b;
          }
        }
        const auto url = args->find(flutter::EncodableValue("remoteJsUrl"));
        if (url != args->end()) {
          if (const auto* s = std::get_if<std::string>(&url->second)) {
            remote_js_url = *s;
          }
        }
      }
      if (remote_js || !remote_js_url.empty()) {
        result->Error("REMOTE_JS", "production Bare must not fetch remote JS");
        return;
      }
      result->Success();
      return;
    }
    if (call.method_name() == "stop") {
      result->Success();
      return;
    }
    if (call.method_name() == "barePath") {
      const auto path = bundled_bare_path();
      if (!path.has_value()) {
        result->Success();
        return;
      }
      result->Success(flutter::EncodableValue(*path));
      return;
    }
    result->NotImplemented();
  }
};

}  // namespace

void OrbitsTransportPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  OrbitsTransportPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
