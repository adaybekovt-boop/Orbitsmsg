import FlutterMacOS
import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(BareKit)
import BareKit
#endif

/// Official BareKit / packaged `bare` probe. Must not embed a remote URL.
enum OrbitsBareRuntime {
#if canImport(BareKit)
  private static var retainedWorklet: BareWorklet?
#endif

  static func tryStart(registrar: FlutterPluginRegistrar? = nil) -> Bool {
#if DEBUG
    let env = ProcessInfo.processInfo.environment["ORBITS_BARE_RUNTIME"]
#else
    let env: String? = nil
#endif
    if let env, !env.isEmpty, FileManager.default.isExecutableFile(atPath: env) {
      // The sidecar must carry the expected hash AND it must match the
      // actual binary bytes — existence alone proves nothing.
      let sidecar = env + ".sha256"
      guard let want = try? String(contentsOfFile: sidecar, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !want.isEmpty,
            let binary = try? Data(contentsOf: URL(fileURLWithPath: env)),
            sha256Hex(binary) == want else { return false }
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: env)
#if DEBUG
      let worklet = ProcessInfo.processInfo.environment["ORBITS_WORKLET_JS"] ??
        "tool/connectivity_harness/src/worklet.js"
#else
      let worklet = "tool/connectivity_harness/src/worklet.js"
#endif
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
#if DEBUG
    if let env = ProcessInfo.processInfo.environment["ORBITS_WORKLET_JS"], !env.isEmpty {
      candidates.append(URL(fileURLWithPath: env))
    }
#endif
    let relative = URL(fileURLWithPath: "tool/connectivity_harness/src/worklet.js")
    candidates.append(relative)
    guard let expected = manifestWorkletHash(registrar: registrar) else {
      return nil
    }
    for url in candidates {
      if FileManager.default.fileExists(atPath: url.path),
         let data = try? Data(contentsOf: url),
         !data.isEmpty,
         sha256Hex(data) == expected
      {
        return data
      }
    }
    return nil
  }

  /// Pinned worklet.js hash from the shipped BUNDLE.manifest asset.
  /// Nil (fail closed) when the manifest is missing or allows remote JS.
  private static func manifestWorkletHash(registrar: FlutterPluginRegistrar?) -> String? {
    var keys: [String] = []
    if let registrar {
      keys.append(registrar.lookupKey(forAsset: "tool/connectivity_harness/BUNDLE.manifest"))
    }
    keys.append("flutter_assets/tool/connectivity_harness/BUNDLE.manifest")
    for key in keys {
      if let path = Bundle.main.path(forResource: key, ofType: nil),
         let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
         let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         manifest["remoteJs"] as? Bool == false,
         let files = manifest["files"] as? [String: String],
         let hash = files["worklet.js"], !hash.isEmpty {
        return hash
      }
    }
    // Dev-tree fallback (repo checkout): same file the harness verifies.
    let dev = URL(fileURLWithPath: "tool/connectivity_harness/BUNDLE.manifest")
    if let data = try? Data(contentsOf: dev),
       let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       manifest["remoteJs"] as? Bool == false,
       let files = manifest["files"] as? [String: String],
       let hash = files["worklet.js"], !hash.isEmpty {
      return hash
    }
    return nil
  }
#endif

  private static func sha256Hex(_ data: Data) -> String {
#if canImport(CryptoKit)
    if #available(macOS 10.15, *) {
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
#endif
    return "unavailable-no-cryptokit"
  }
}
