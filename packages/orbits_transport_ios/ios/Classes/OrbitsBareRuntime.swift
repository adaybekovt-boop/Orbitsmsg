import Flutter
import Foundation

#if canImport(BareKit)
import BareKit
#endif

/// Official BareKit probe. Must not embed a remote URL.
/// Official bare-kit 2.4.3 host is BareWorklet +
/// BareWorkletConfiguration.defaultWorkletConfiguration.
enum OrbitsBareRuntime {
#if canImport(BareKit)
  private static var retainedWorklet: BareWorklet?
#endif

  static func tryStart(registrar: FlutterPluginRegistrar? = nil) -> Bool {
#if canImport(BareKit)
    guard let source = workletSource(registrar: registrar) else {
      return false
    }
    guard let options = BareWorkletConfiguration.defaultWorkletConfiguration() else {
      return false
    }
    guard let worklet = BareWorklet(configuration: options) else {
      return false
    }
    worklet.start("/orbits/worklet.js", source: source, arguments: [])
    retainedWorklet = worklet
    return true
#else
    _ = registrar
    return false
#endif
  }

#if canImport(BareKit)
  private static func workletSource(registrar: FlutterPluginRegistrar?) -> Data? {
    var candidates: [URL] = []
    if let registrar {
      let key = registrar.lookupKey(forAsset: "tool/connectivity_harness/src/worklet.js")
      if let path = Bundle.main.path(forResource: key, ofType: nil) {
        candidates.append(URL(fileURLWithPath: path))
      }
      if let root = Bundle.main.resourceURL {
        candidates.append(root.appendingPathComponent(key))
      }
    }
    if let bundled = Bundle.main.path(
      forResource: "worklet",
      ofType: "js",
      inDirectory: "orbits_worklet"
    ) {
      candidates.append(URL(fileURLWithPath: bundled))
    }
    if let flutter = Bundle.main.path(
      forResource: "worklet",
      ofType: "js",
      inDirectory: "flutter_assets/tool/connectivity_harness/src"
    ) {
      candidates.append(URL(fileURLWithPath: flutter))
    }
    if let app = Bundle.main.privateFrameworksURL?
      .appendingPathComponent("App.framework")
      .appendingPathComponent("flutter_assets/tool/connectivity_harness/src/worklet.js")
    {
      candidates.append(app)
    }
    if let env = ProcessInfo.processInfo.environment["ORBITS_WORKLET_JS"], !env.isEmpty {
      candidates.append(URL(fileURLWithPath: env))
    }
    for url in candidates {
      if FileManager.default.fileExists(atPath: url.path),
         let data = try? Data(contentsOf: url),
         !data.isEmpty
      {
        return data
      }
    }
    return nil
  }
#endif
}
