import FlutterMacOS
import Foundation

#if canImport(BareKit)
import BareKit
#endif

/// Official BareKit / packaged `bare` probe. Must not embed a remote URL.
enum OrbitsBareRuntime {
#if canImport(BareKit)
  private static var retainedWorklet: BareWorklet?
#endif

  static func tryStart(registrar: FlutterPluginRegistrar? = nil) -> Bool {
    let env = ProcessInfo.processInfo.environment["ORBITS_BARE_RUNTIME"]
    if let env, !env.isEmpty, FileManager.default.isExecutableFile(atPath: env) {
      let sidecar = env + ".sha256"
      guard FileManager.default.fileExists(atPath: sidecar) else { return false }
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: env)
      let worklet = ProcessInfo.processInfo.environment["ORBITS_WORKLET_JS"] ??
        "tool/connectivity_harness/src/worklet.js"
      proc.arguments = [worklet]
      do {
        try proc.run()
        return true
      } catch {
        return false
      }
    }
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
    if let env = ProcessInfo.processInfo.environment["ORBITS_WORKLET_JS"], !env.isEmpty {
      candidates.append(URL(fileURLWithPath: env))
    }
    let relative = URL(fileURLWithPath: "tool/connectivity_harness/src/worklet.js")
    candidates.append(relative)
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
