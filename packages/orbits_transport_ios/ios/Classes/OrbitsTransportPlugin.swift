import Flutter
import UIKit

/// iOS Bare host. The worklet bundle is embedded at build time.
/// Production must not fetch remote JS. Every method writes OTP1 or fails.
public class OrbitsTransportPlugin: NSObject, FlutterPlugin {
  private var started = false
  private var suspended = false
  private var registrar: FlutterPluginRegistrar?
  private var channel: FlutterMethodChannel?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "app.orbits/transport",
      binaryMessenger: registrar.messenger()
    )
    let instance = OrbitsTransportPlugin()
    instance.registrar = registrar
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start":
      DispatchQueue.global(qos: .userInitiated).async {
        self.reply(result) { try self.start(args: args) }
      }
    case "stop":
      DispatchQueue.global(qos: .userInitiated).async {
        self.reply(result) { self.stop() }
      }
    case "publish":
      DispatchQueue.global(qos: .userInitiated).async {
        self.reply(result) { try self.publish(args: args) }
      }
    case "unpublish":
      DispatchQueue.global(qos: .userInitiated).async {
        self.reply(result) { try self.ipc("unpublish") }
      }
    case "connect":
      DispatchQueue.global(qos: .userInitiated).async {
        self.reply(result) { try self.connect(args: args) }
      }
    case "disconnect":
      DispatchQueue.global(qos: .userInitiated).async {
        self.reply(result) { try self.disconnect(args: args, raw: call.arguments) }
      }
    case "send":
      DispatchQueue.global(qos: .userInitiated).async {
        self.reply(result) { try self.send(args: args) }
      }
    case "sendFile":
      DispatchQueue.global(qos: .userInitiated).async {
        self.reply(result) { try self.sendFile(args: args) }
      }
    case "suspend":
      DispatchQueue.global(qos: .userInitiated).async {
        self.reply(result) { try self.suspendCall() }
      }
    case "resume":
      DispatchQueue.global(qos: .userInitiated).async {
        self.reply(result) { try self.resumeCall() }
      }
    case "refreshNetwork":
      DispatchQueue.global(qos: .userInitiated).async {
        self.reply(result) { try self.ipc("refreshNetwork") }
      }
    case "runtimeInfo":
      DispatchQueue.global(qos: .userInitiated).async {
        self.reply(result) { try self.runtimeInfo() }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func applicationWillResignActive(_ application: UIApplication) {
    guard started, !suspended else { return }
    DispatchQueue.global(qos: .userInitiated).async {
      OrbitsBareRuntime.suspendRuntime()
      self.suspended = true
    }
  }

  public func applicationDidBecomeActive(_ application: UIApplication) {
    guard started, suspended else { return }
    DispatchQueue.global(qos: .userInitiated).async {
      OrbitsBareRuntime.resumeRuntime()
      self.suspended = false
    }
  }

  private func start(args: [String: Any]) throws -> Any? {
    let remoteJs = args["remoteJs"] as? Bool ?? false
    let remoteJsUrl = args["remoteJsUrl"] as? String ?? ""
    let bundleUrl = args["bundleUrl"] as? String ?? ""
    let scriptUrl = args["scriptUrl"] as? String ?? ""
    if remoteJs || looksRemote(remoteJsUrl) || looksRemote(bundleUrl) || looksRemote(scriptUrl) {
      throw FlutterError(code: "REMOTE_JS", message: "production Bare must not fetch remote JS", details: nil)
    }
    if let ipc = args["ipcVersion"] as? String, !ipc.isEmpty, ipc != "orbits-bare-ipc-v1" {
      throw FlutterError(code: "ABI_MISMATCH", message: "unsupported IPC version", details: nil)
    }
    if (args["requireLocalBundle"] as? Bool ?? false) &&
      (args["localBundlePresent"] as? Bool ?? false) == false {
      throw FlutterError(code: "BUNDLE_MISSING", message: "local Bare bundle missing", details: nil)
    }
    if let expected = args["expectedBundleSha256"] as? String,
       let actual = args["localBundleSha256"] as? String,
       !expected.isEmpty, !actual.isEmpty, expected != actual {
      throw FlutterError(code: "BUNDLE_TAMPERED", message: "local bundle hash mismatch", details: nil)
    }
    do {
      let info = try OrbitsBareRuntime.startSession(args: args, registrar: registrar)
      OrbitsBareRuntime.eventSink = { [weak self] event in
        DispatchQueue.main.async {
          self?.channel?.invokeMethod("event", arguments: event)
        }
      }
      started = true
      suspended = false
      return info
    } catch {
      let message = error.localizedDescription
      let code = message.contains("BARE_WORKLET_FAILED") ? "BARE_WORKLET_FAILED" : "BARE_RUNTIME_MISSING"
      throw FlutterError(code: code, message: message, details: nil)
    }
  }

  private func stop() -> Any? {
    OrbitsBareRuntime.stopSession()
    started = false
    suspended = false
    return nil
  }

  private func publish(args: [String: Any]) throws -> Any? {
    try requireStarted()
    guard let deviceId = args["deviceId"] as? String, !deviceId.isEmpty else {
      throw FlutterError(code: "MALFORMED", message: "publish needs deviceId", details: nil)
    }
    return try OrbitsBareRuntime.request("publish", params: ["binding": args], timeoutMs: 30_000)
  }

  private func connect(args: [String: Any]) throws -> Any? {
    try requireLive()
    let peerId = args["peerId"] as? String ?? ""
    let noise = args["noisePublicKey"] as? String ?? ""
    if peerId.isEmpty && noise.isEmpty {
      throw FlutterError(code: "MALFORMED", message: "connect needs peerId or noisePublicKey", details: nil)
    }
    return try OrbitsBareRuntime.request("connect", params: args, timeoutMs: 45_000)
  }

  private func disconnect(args: [String: Any], raw: Any?) throws -> Any? {
    try requireStarted()
    let peerId: String
    if let value = raw as? String {
      peerId = value
    } else {
      peerId = args["peerId"] as? String ?? ""
    }
    return try OrbitsBareRuntime.request("disconnect", params: ["peerId": peerId], timeoutMs: 10_000)
  }

  private func send(args: [String: Any]) throws -> Any? {
    try requireLive()
    let frame = args["frame"] as? FlutterStandardTypedData
    if let frame, frame.data.count > 256 * 1024 {
      throw FlutterError(code: "IPC_FRAME", message: "IPC frame exceeds cap", details: nil)
    }
    let bytes = frame?.data ?? Data()
    return try OrbitsBareRuntime.request(
      "send",
      params: [
        "peerId": args["peerId"] as? String ?? "",
        "channel": args["channel"] as? String ?? "message",
        "frameB64": bytes.base64EncodedString(),
      ],
      timeoutMs: 15_000
    )
  }

  private func sendFile(args: [String: Any]) throws -> Any? {
    try requireLive()
    let path = args["path"] as? String ?? ""
    let size = args["sizeBytes"] as? Int ?? 0
    if path.isEmpty {
      throw FlutterError(code: "PATH_REQUIRED", message: "sendFile requires a path", details: nil)
    }
    if size > 50 * 1024 * 1024 {
      throw FlutterError(code: "OVERSIZE", message: "attachment exceeds path-transfer cap", details: nil)
    }
    return try OrbitsBareRuntime.request(
      "sendFile",
      params: [
        "peerId": args["peerId"] as? String ?? "",
        "file": [
          "path": path,
          "sizeBytes": size,
          "fileName": (path as NSString).lastPathComponent,
        ],
      ],
      timeoutMs: 10 * 60_000
    )
  }

  private func suspendCall() throws -> Any? {
    try requireStarted()
    OrbitsBareRuntime.suspendRuntime()
    suspended = true
    return nil
  }

  private func resumeCall() throws -> Any? {
    try requireStarted()
    OrbitsBareRuntime.resumeRuntime()
    suspended = false
    return nil
  }

  private func runtimeInfo() throws -> Any? {
    try requireStarted()
    return try OrbitsBareRuntime.runtimeInfo()
  }

  private func ipc(_ method: String) throws -> Any? {
    try requireLive()
    return try OrbitsBareRuntime.request(method, timeoutMs: 15_000)
  }

  private func requireStarted() throws {
    if !started || !OrbitsBareRuntime.isLive {
      throw FlutterError(code: "NOT_STARTED", message: "not started", details: nil)
    }
  }

  private func requireLive() throws {
    try requireStarted()
    if suspended {
      throw FlutterError(code: "SUSPENDED", message: "suspended", details: nil)
    }
  }

  private func looksRemote(_ url: String) -> Bool {
    url.hasPrefix("http://") || url.hasPrefix("https://")
  }

  private func reply(_ result: @escaping FlutterResult, _ block: () throws -> Any?) {
    do {
      let value = try block()
      DispatchQueue.main.async { result(value) }
    } catch let error as FlutterError {
      DispatchQueue.main.async { result(error) }
    } catch {
      let message = error.localizedDescription
      let code: String
      if message.contains("NOT_STARTED") {
        code = "NOT_STARTED"
      } else if message.contains("timeout") || message.contains("IPC_TIMEOUT") {
        code = "IPC_TIMEOUT"
      } else if message.contains("BARE_RUNTIME_MISSING") {
        code = "BARE_RUNTIME_MISSING"
      } else {
        code = "BARE_WORKLET_FAILED"
      }
      DispatchQueue.main.async {
        result(FlutterError(code: code, message: message, details: nil))
      }
    }
  }
}

extension FlutterError: Error {}
