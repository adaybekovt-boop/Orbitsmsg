import Foundation

#if canImport(BareKit)
import BareKit
#endif

/// Official BareKit / packaged `bare` probe. Must not embed a remote URL.
enum OrbitsBareRuntime {
  static func tryStart() -> Bool {
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
    return false
#else
    return false
#endif
  }
}
