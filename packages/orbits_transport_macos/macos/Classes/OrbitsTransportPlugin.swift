import FlutterMacOS

/// macOS Bare host. The worklet bundle is embedded at build time.
/// Production must not fetch remote JS.
public class OrbitsTransportPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "app.orbits/transport",
      binaryMessenger: registrar.messenger
    )
    registrar.addMethodCallDelegate(OrbitsTransportPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "start" {
      let args = call.arguments as? [String: Any]
      let remoteJs = args?["remoteJs"] as? Bool ?? false
      func nonempty(_ key: String) -> Bool {
        let s = args?[key] as? String ?? ""
        return !s.isEmpty
      }
      func hasScheme(_ key: String) -> Bool {
        let s = args?[key] as? String ?? ""
        return s.contains("://")
      }
      if remoteJs || nonempty("remoteJsUrl") || nonempty("bundleUrl") ||
          nonempty("scriptUrl") || hasScheme("worklet") || hasScheme("workletPath") {
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
    if call.method == "stop" {
      result(nil)
      return
    }
    if call.method == "barePath" {
      result(Self.bundledBarePath())
      return
    }
    result(FlutterMethodNotImplemented)
  }

  static func bundledBarePath() -> String? {
    let fm = FileManager.default
    var dirs: [String] = []
    let plugin = Bundle(for: OrbitsTransportPlugin.self)
    if let path = plugin.resourcePath { dirs.append(path) }
    dirs.append(plugin.bundlePath)
    if let nested = plugin.url(forResource: "OrbitsTransportBare", withExtension: "bundle"),
       let rb = Bundle(url: nested), let path = rb.resourcePath {
      dirs.append(path)
    }
    if let path = Bundle.main.resourcePath { dirs.append(path) }
    dirs.append(Bundle.main.bundlePath)
    for dir in dirs {
      let candidate = (dir as NSString).appendingPathComponent("bare")
      if fm.fileExists(atPath: candidate) {
        return candidate
      }
    }
    let named = [
      plugin.path(forResource: "bare", ofType: nil),
      Bundle.main.path(forResource: "bare", ofType: nil),
    ]
    for path in named {
      if let path, fm.fileExists(atPath: path) {
        return path
      }
    }
    return nil
  }
}
