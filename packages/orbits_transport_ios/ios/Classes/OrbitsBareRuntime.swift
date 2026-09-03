import Foundation

#if canImport(BareKit)
import BareKit
#endif

/// Official BareKit probe. Must not embed a remote URL.
enum OrbitsBareRuntime {
  static func tryStart() -> Bool {
#if canImport(BareKit)
    let bundled = Bundle.main.path(
      forResource: "worklet",
      ofType: "js",
      inDirectory: "orbits_worklet"
    )
    guard let bundled, FileManager.default.fileExists(atPath: bundled) else {
      return false
    }
    guard let source = try? Data(contentsOf: URL(fileURLWithPath: bundled)) else {
      return false
    }
    let worklet = BareWorklet(configuration: BareWorkletConfiguration.default())
    worklet.start("/orbits/worklet.js", source: source, arguments: [])
    return true
#else
    return false
#endif
  }
}
