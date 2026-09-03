import FlutterMacOS

/// macOS Bare host. The worklet bundle is embedded at build time.
/// Production must not fetch remote JS.
public class OrbitsTransportPlugin: NSObject, FlutterPlugin {
  private var started = false
  private var suspended = false
  private var published = false
  private var registrar: FlutterPluginRegistrar?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "app.orbits/transport",
      binaryMessenger: registrar.messenger
    )
    let instance = OrbitsTransportPlugin()
    instance.registrar = registrar
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start":
      start(args: args, result: result)
    case "stop":
      started = false
      suspended = false
      published = false
      result(nil)
    case "publish":
      guard requireStarted(result) else { return }
      guard let deviceId = args["deviceId"] as? String, !deviceId.isEmpty else {
        result(FlutterError(code: "MALFORMED", message: "publish needs deviceId", details: nil))
        return
      }
      published = true
      result(nil)
    case "unpublish":
      published = false
      result(nil)
    case "connect", "disconnect", "refreshNetwork":
      guard requireLive(result) else { return }
      result(nil)
    case "send":
      guard requireLive(result) else { return }
      let frame = args["frame"] as? FlutterStandardTypedData
      if let frame, frame.data.count > 256 * 1024 {
        result(FlutterError(code: "IPC_FRAME", message: "IPC frame exceeds cap", details: nil))
        return
      }
      result(nil)
    case "sendFile":
      guard requireLive(result) else { return }
      let path = args["path"] as? String ?? ""
      let size = args["sizeBytes"] as? Int ?? 0
      if path.isEmpty {
        result(FlutterError(code: "PATH_REQUIRED", message: "sendFile requires a path", details: nil))
        return
      }
      if size > 50 * 1024 * 1024 {
        result(FlutterError(code: "OVERSIZE", message: "attachment exceeds path-transfer cap", details: nil))
        return
      }
      result(nil)
    case "suspend":
      suspended = true
      result(nil)
    case "resume":
      suspended = false
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start(args: [String: Any], result: FlutterResult) {
    let remoteJs = args["remoteJs"] as? Bool ?? false
    let remoteJsUrl = args["remoteJsUrl"] as? String ?? ""
    let bundleUrl = args["bundleUrl"] as? String ?? ""
    let scriptUrl = args["scriptUrl"] as? String ?? ""
    if remoteJs || looksRemote(remoteJsUrl) || looksRemote(bundleUrl) || looksRemote(scriptUrl) {
      result(
        FlutterError(
          code: "REMOTE_JS",
          message: "production Bare must not fetch remote JS",
          details: nil
        )
      )
      return
    }
    if let ipc = args["ipcVersion"] as? String, !ipc.isEmpty, ipc != "orbits-bare-ipc-v1" {
      result(FlutterError(code: "ABI_MISMATCH", message: "unsupported IPC version", details: nil))
      return
    }
    if (args["requireLocalBundle"] as? Bool ?? false) &&
      (args["localBundlePresent"] as? Bool ?? false) == false {
      result(FlutterError(code: "BUNDLE_MISSING", message: "local Bare bundle missing", details: nil))
      return
    }
    if let expected = args["expectedBundleSha256"] as? String,
       let actual = args["localBundleSha256"] as? String,
       !expected.isEmpty, !actual.isEmpty, expected != actual {
      result(FlutterError(code: "BUNDLE_TAMPERED", message: "local bundle hash mismatch", details: nil))
      return
    }
    if OrbitsBareRuntime.tryStart(registrar: registrar) {
      started = true
      result(nil)
      return
    }
    result(
      FlutterError(
        code: "BARE_RUNTIME_MISSING",
        message: "linked Bare runtime is not shipped",
        details: nil
      )
    )
  }

  private func looksRemote(_ url: String) -> Bool {
    url.hasPrefix("http://") || url.hasPrefix("https://")
  }

  private func requireStarted(_ result: FlutterResult) -> Bool {
    if !started {
      result(FlutterError(code: "NOT_STARTED", message: "not started", details: nil))
      return false
    }
    return true
  }

  private func requireLive(_ result: FlutterResult) -> Bool {
    guard requireStarted(result) else { return false }
    if suspended {
      result(FlutterError(code: "SUSPENDED", message: "suspended", details: nil))
      return false
    }
    return true
  }
}
