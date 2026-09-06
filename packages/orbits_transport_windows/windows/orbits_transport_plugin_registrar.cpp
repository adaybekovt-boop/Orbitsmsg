#include "include/orbits_transport_windows/orbits_transport_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <vector>

#include "orbits_transport_host.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

class OrbitsTransportPluginImpl : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  OrbitsTransportPluginImpl();
  virtual ~OrbitsTransportPluginImpl() = default;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result);

  OrbitsBareHost host_{};
};

const EncodableMap* AsMap(const EncodableValue* arguments) {
  if (arguments == nullptr) {
    return nullptr;
  }
  return std::get_if<EncodableMap>(arguments);
}

std::string ArgString(const EncodableMap* args, const char* key) {
  if (args == nullptr) {
    return "";
  }
  auto it = args->find(EncodableValue(key));
  if (it == args->end()) {
    return "";
  }
  if (const auto* value = std::get_if<std::string>(&it->second)) {
    return *value;
  }
  return "";
}

bool ArgBool(const EncodableMap* args, const char* key) {
  if (args == nullptr) {
    return false;
  }
  auto it = args->find(EncodableValue(key));
  if (it == args->end()) {
    return false;
  }
  if (const auto* value = std::get_if<bool>(&it->second)) {
    return *value;
  }
  return false;
}

int64_t ArgInt(const EncodableMap* args, const char* key) {
  if (args == nullptr) {
    return 0;
  }
  auto it = args->find(EncodableValue(key));
  if (it == args->end()) {
    return 0;
  }
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return *value;
  }
  return 0;
}

size_t ArgBytesLength(const EncodableMap* args, const char* key) {
  if (args == nullptr) {
    return 0;
  }
  auto it = args->find(EncodableValue(key));
  if (it == args->end()) {
    return 0;
  }
  if (const auto* value = std::get_if<std::vector<uint8_t>>(&it->second)) {
    return value->size();
  }
  return 0;
}

void ReplyHost(int code, flutter::MethodResult<EncodableValue>& result) {
  switch (code) {
    case kOrbitsHostOk:
      result.Success();
      return;
    case kOrbitsHostRemoteJs:
      result.Error("REMOTE_JS", "production Bare must not fetch remote JS");
      return;
    case kOrbitsHostNotStarted:
      result.Error("NOT_STARTED", "not started");
      return;
    case kOrbitsHostSuspended:
      result.Error("SUSPENDED", "suspended");
      return;
    case kOrbitsHostIpcFrame:
      result.Error("IPC_FRAME", "IPC frame exceeds cap");
      return;
    case kOrbitsHostPathRequired:
      result.Error("PATH_REQUIRED", "sendFile requires a path");
      return;
    case kOrbitsHostOversize:
      result.Error("OVERSIZE", "attachment exceeds path-transfer cap");
      return;
    case kOrbitsHostBundleMissing:
      result.Error("BUNDLE_MISSING", "local Bare bundle missing");
      return;
    case kOrbitsHostBundleTampered:
      result.Error("BUNDLE_TAMPERED", "local bundle hash mismatch");
      return;
    case kOrbitsHostAbiMismatch:
      result.Error("ABI_MISMATCH", "unsupported IPC version");
      return;
    case kOrbitsHostMalformed:
      result.Error("MALFORMED", "malformed request");
      return;
    case kOrbitsHostBareMissing:
      result.Error("BARE_RUNTIME_MISSING", "linked Bare runtime is not shipped");
      return;
    default:
      result.Error("HOST_ERROR", "transport host rejected the request");
  }
}

void OrbitsTransportPluginImpl::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<OrbitsTransportPluginImpl>();
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), "app.orbits/transport",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });
  registrar->AddPlugin(std::move(plugin));
}

OrbitsTransportPluginImpl::OrbitsTransportPluginImpl() = default;

void OrbitsTransportPluginImpl::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto* args = AsMap(method_call.arguments());
  const std::string& method = method_call.method_name();
  if (method == "start") {
    const std::string remote_js_url = ArgString(args, "remoteJsUrl");
    const std::string bundle_url = ArgString(args, "bundleUrl");
    const std::string script_url = ArgString(args, "scriptUrl");
    const std::string ipc_version = ArgString(args, "ipcVersion");
    const std::string expected = ArgString(args, "expectedBundleSha256");
    const std::string actual = ArgString(args, "localBundleSha256");
    ReplyHost(orbits_bare_host_start(
                  &host_, ArgBool(args, "remoteJs"), remote_js_url.c_str(),
                  bundle_url.c_str(), script_url.c_str(), ipc_version.c_str(),
                  ArgBool(args, "requireLocalBundle"),
                  ArgBool(args, "localBundlePresent"), expected.c_str(),
                  actual.c_str()),
              *result);
    return;
  }
  if (method == "stop") {
    ReplyHost(orbits_bare_host_stop(&host_), *result);
    return;
  }
  if (method == "publish") {
    const std::string device_id = ArgString(args, "deviceId");
    ReplyHost(orbits_bare_host_publish(&host_, device_id.c_str()), *result);
    return;
  }
  if (method == "unpublish") {
    ReplyHost(orbits_bare_host_unpublish(&host_), *result);
    return;
  }
  if (method == "connect") {
    ReplyHost(orbits_bare_host_connect(&host_), *result);
    return;
  }
  if (method == "disconnect") {
    ReplyHost(orbits_bare_host_disconnect(&host_), *result);
    return;
  }
  if (method == "refreshNetwork") {
    ReplyHost(orbits_bare_host_refresh_network(&host_), *result);
    return;
  }
  if (method == "send") {
    ReplyHost(orbits_bare_host_send(&host_, ArgBytesLength(args, "frame")),
              *result);
    return;
  }
  if (method == "sendFile") {
    const std::string path = ArgString(args, "path");
    ReplyHost(orbits_bare_host_send_file(&host_, path.c_str(),
                                         ArgInt(args, "sizeBytes")),
              *result);
    return;
  }
  if (method == "suspend") {
    ReplyHost(orbits_bare_host_suspend(&host_), *result);
    return;
  }
  if (method == "resume") {
    ReplyHost(orbits_bare_host_resume(&host_), *result);
    return;
  }
  result->NotImplemented();
}

}  // namespace

void OrbitsTransportPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  OrbitsTransportPluginImpl::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
