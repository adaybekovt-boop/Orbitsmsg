import Flutter
import UIKit

/// iOS Bare host. The worklet bundle is embedded at build time.
/// Production must not fetch remote JS.
public class OrbitsTransportPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "app.orbits/transport",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(OrbitsTransportPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "start" {
      let args = call.arguments as? [String: Any]
      let remoteJs = args?["remoteJs"] as? Bool ?? false
      let remoteJsUrl = args?["remoteJsUrl"] as? String ?? ""
      if remoteJs || !remoteJsUrl.isEmpty {
        result(
          FlutterError(
            code: "REMOTE_JS",
            message: "production Bare must not fetch remote JS",
            details: nil
          )
        )
        return
      }
      result(nil)
      return
    }
    result(FlutterMethodNotImplemented)
  }
}
