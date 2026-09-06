import Flutter
import Foundation

#if canImport(BareKit)
import BareKit
#endif

/// Official BareKit host. Must not embed a remote URL.
/// Official bare-kit 2.4.3 host is BareWorklet +
/// BareWorkletConfiguration.defaultWorkletConfiguration.
/// After start() returns, attach BareIPC and speak OTP1.
enum OrbitsBareRuntime {
#if canImport(BareKit)
  private static var worklet: BareWorklet?
  private static var ipc: BareIPC?
  private static var writeQueue: [Data] = []
  private static var totalQueuedBytes = 0
  private static var isPumpingWrites = false
#endif
  private static var decoder = Otp1Decoder()
  private static var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
  private static var earlyEvents: [[String: Any]] = []
  private static var nextId = 1
  private static let lock = NSLock()
  static var eventSink: (([String: Any]) -> Void)?

  static var isLive: Bool {
#if canImport(BareKit)
    return worklet != nil && ipc != nil
#else
    return false
#endif
  }

  static func setEventSink(_ sink: (([String: Any]) -> Void)?) {
    lock.lock()
    eventSink = sink
    let buffered = earlyEvents
    earlyEvents.removeAll()
    lock.unlock()
    if let s = sink {
      for ev in buffered {
        s(ev)
      }
    }
  }

  static func tryStart(registrar: FlutterPluginRegistrar? = nil) -> Bool {
    do {
      _ = try startSession(args: [:], registrar: registrar)
      return true
    } catch {
      return false
    }
  }

  static func startSession(
    args: [String: Any],
    registrar: FlutterPluginRegistrar?
  ) throws -> [String: Any] {
#if canImport(BareKit)
    stopSession()
    guard let script = extractWorkletTree(registrar: registrar) else {
      throw HostError.workletFailed
    }
    let source = try Data(contentsOf: script)
    guard !source.isEmpty else { throw HostError.workletFailed }
    guard let options = BareWorkletConfiguration.defaultWorkletConfiguration() else {
      throw HostError.runtimeMissing
    }
    options.memoryLimit = 96 * 1024 * 1024
    options.assets = script.deletingLastPathComponent().path
    guard let created = BareWorklet(configuration: options) else {
      throw HostError.runtimeMissing
    }
    let storage = applicationSupport().appendingPathComponent("orbits-corestore", isDirectory: true)
    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    let backend = (args["backend"] as? String)?.isEmpty == false
      ? (args["backend"] as? String)!
      : "hyperswarm"
    let argv = [
      "--backend=\(backend)",
      "--storage=\(storage.path)",
    ]
    created.start(script.path, source: source, arguments: argv)
    guard let pipe = BareIPC(worklet: created) else {
      created.terminate()
      throw HostError.runtimeMissing
    }
    worklet = created
    ipc = pipe
    pipe.readable = { incoming in
      while let chunk = incoming.read(), !chunk.isEmpty {
        ingest(chunk)
      }
    }
    var params: [String: Any] = [
      "peerId": args["peerId"] as Any,
      "discoverySecret": args["discoverySecret"] as Any,
      "relayForced": args["relayForced"] as? Bool ?? false,
      "backend": backend,
      "requireRealCorestore": true,
      "firewalled": false,
      "storageDir": storage.path,
      "writerDeviceId": args["deviceId"] ?? args["peerId"] as Any,
      "noiseSeed": args["noiseSeed"] as Any,
    ]
    let started = try request("start", params: params, timeoutMs: 45_000)
    let info = try request("runtime.info", params: [:], timeoutMs: 8_000)
    var combined = started
    for (key, value) in info {
      combined[key] = value
    }
    return combined
#else
    _ = registrar
    _ = args
    throw HostError.runtimeMissing
#endif
  }

  static func request(
    _ method: String,
    params: [String: Any] = [:],
    timeoutMs: Int
  ) throws -> [String: Any] {
#if canImport(BareKit)
    guard let pipe = ipc else { throw HostError.notStarted }
    lock.lock()
    if pending.count >= 64 {
      lock.unlock()
      throw HostError.backpressure
    }
    let id = nextId
    nextId += 1
    lock.unlock()
    let frame = try Otp1.encode(
      type: Otp1.request,
      body: [
        "id": id,
        "method": method,
        "params": params,
      ]
    )
    let box = RequestBox()
    lock.lock()
    pending[id] = { result in box.finish(result) }
    lock.unlock()

    try writeFrame(frame, pipe: pipe)

    let result = box.wait(timeoutMs: timeoutMs)
    lock.lock()
    pending.removeValue(forKey: id)
    lock.unlock()
    switch result {
    case .success(let value):
      return value
    case .failure(let error):
      throw error
    case .none:
      throw HostError.timeout
    }
#else
    throw HostError.runtimeMissing
#endif
  }

#if canImport(BareKit)
  private static func writeFrame(_ frame: Data, pipe: BareIPC) throws {
    lock.lock()
    if writeQueue.count >= 64 || totalQueuedBytes + frame.count > 2 * 1024 * 1024 {
      lock.unlock()
      throw HostError.backpressure
    }
    writeQueue.append(frame)
    totalQueuedBytes += frame.count
    lock.unlock()
    pumpWrites(pipe)
  }

  private static func pumpWrites(_ pipe: BareIPC) {
    lock.lock()
    if isPumpingWrites || writeQueue.isEmpty {
      lock.unlock()
      return
    }
    isPumpingWrites = true
    let frame = writeQueue.removeFirst()
    totalQueuedBytes -= frame.count
    lock.unlock()

    pipe.write(frame) { error in
      if let error = error {
        lock.lock()
        for (_, waiter) in pending {
          waiter(.failure(error))
        }
        pending.removeAll()
        writeQueue.removeAll()
        totalQueuedBytes = 0
        isPumpingWrites = false
        lock.unlock()
        return
      }
      lock.lock()
      isPumpingWrites = false
      let hasMore = !writeQueue.isEmpty
      lock.unlock()
      if hasMore {
        pumpWrites(pipe)
      }
    }
  }
#endif

  static func runtimeInfo() throws -> [String: Any] {
    return try request("runtime.info", timeoutMs: 8_000)
  }

  static func suspendRuntime() {
#if canImport(BareKit)
    _ = try? request("suspend", timeoutMs: 8_000)
    worklet?.suspend()
#endif
  }

  static func resumeRuntime() {
#if canImport(BareKit)
    worklet?.resume()
    _ = try? request("resume", timeoutMs: 8_000)
#endif
  }

  static func stopSession() {
#if canImport(BareKit)
    _ = try? request("stop", timeoutMs: 2_000)
    ipc?.close()
    worklet?.terminate()
    ipc = nil
    worklet = nil
    lock.lock()
    for (_, waiter) in pending {
      waiter(.failure(HostError.closed))
    }
    pending.removeAll()
    writeQueue.removeAll()
    totalQueuedBytes = 0
    isPumpingWrites = false
    decoder.reset()
    lock.unlock()
#endif
  }

#if canImport(BareKit)
  private static func ingest(_ data: Data) {
    do {
      for msg in try decoder.add(data) {
        if msg.type == Otp1.response {
          let id = msg.body["id"] as? Int ?? (msg.body["id"] as? NSNumber)?.intValue
          lock.lock()
          let waiter = id.flatMap { pending.removeValue(forKey: $0) }
          lock.unlock()
          if msg.body["ok"] as? Bool == false {
            waiter?(.failure(HostError.worklet(msg.body["error"] as? String ?? "ipc error")))
          } else {
            waiter?(.success(msg.body["result"] as? [String: Any] ?? [:]))
          }
        } else if msg.type == Otp1.event {
          let flat = flattenEvent(msg.body)
          lock.lock()
          let sink = eventSink
          if sink == nil && earlyEvents.count < 64 {
            earlyEvents.append(flat)
          }
          lock.unlock()
          sink?(flat)
        }
      }
    } catch {
      decoder.reset()
      let errEvent: [String: Any] = [
        "name": "error",
        "code": "DECODE_ERROR",
        "message": error.localizedDescription,
      ]
      lock.lock()
      let sink = eventSink
      lock.unlock()
      sink?(errEvent)
    }
  }
#endif

  private static func flattenEvent(_ body: [String: Any]) -> [String: Any] {
    let payload = body["payload"] as? [String: Any] ?? [:]
    var out: [String: Any] = [
      "name": body["name"] as Any,
      "peerId": payload["peerId"] ?? body["peerId"] as Any,
      "channel": payload["channel"] ?? body["channel"] as Any,
      "path": payload["path"] ?? body["path"] as Any,
      "frameB64": payload["frameB64"] ?? body["frameB64"] as Any,
      "code": payload["code"] ?? body["code"] as Any,
      "message": payload["message"] ?? body["message"] as Any,
      "detail": payload["detail"] ?? body["detail"] as Any,
      "state": payload["state"] ?? body["state"] as Any,
      "requestId": payload["requestId"] ?? body["requestId"] as Any,
      "binding": payload["binding"] ?? body["binding"] as Any,
      "connectionNoisePublicKey": payload["connectionNoisePublicKey"] ?? body["connectionNoisePublicKey"] as Any,
      "ownerPeerId": payload["ownerPeerId"] ?? body["ownerPeerId"] as Any,
    ]
    if let b64 = (payload["frameB64"] ?? body["frameB64"]) as? String, !b64.isEmpty,
       let bytes = Data(base64Encoded: b64) {
      out["bytes"] = FlutterStandardTypedData(bytes: bytes)
    }
    return out
  }

  private static func extractWorkletTree(registrar: FlutterPluginRegistrar?) -> URL? {
    let dest = applicationSupport().appendingPathComponent("orbits-worklet", isDirectory: true)
    try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let names = [
      "worklet.js", "mux.js", "discovery.js", "loopback.js", "ipc.js",
      "swarm.js", "stand.js", "corestore_journal.js", "bare_compat.js",
    ]
    for name in names {
      if let data = workletSourceData(registrar: registrar, file: name) {
        try? data.write(to: dest.appendingPathComponent(name), options: .atomic)
      }
    }
    extractModuleZip(into: dest, registrar: registrar)
    let script = dest.appendingPathComponent("worklet.js")
    let hyperswarm = dest.appendingPathComponent("node_modules/hyperswarm/package.json")
    guard FileManager.default.fileExists(atPath: script.path),
          FileManager.default.fileExists(atPath: hyperswarm.path)
    else { return nil }
    return script
  }

  private static func workletSourceData(registrar: FlutterPluginRegistrar?, file: String) -> Data? {
    var candidates: [URL] = []
    if let registrar {
      let key = registrar.lookupKey(forAsset: "tool/connectivity_harness/src/\(file)")
      if let path = Bundle.main.path(forResource: key, ofType: nil) {
        candidates.append(URL(fileURLWithPath: path))
      }
      if let root = Bundle.main.resourceURL {
        candidates.append(root.appendingPathComponent(key))
      }
    }
    if let flutter = Bundle.main.path(
      forResource: file.replacingOccurrences(of: ".js", with: ""),
      ofType: "js",
      inDirectory: "flutter_assets/tool/connectivity_harness/src"
    ) {
      candidates.append(URL(fileURLWithPath: flutter))
    }
    if let app = Bundle.main.privateFrameworksURL?
      .appendingPathComponent("App.framework")
      .appendingPathComponent("flutter_assets/tool/connectivity_harness/src/\(file)")
    {
      candidates.append(app)
    }
    if file == "worklet.js",
       let env = ProcessInfo.processInfo.environment["ORBITS_WORKLET_JS"], !env.isEmpty {
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

  private static func extractModuleZip(into dest: URL, registrar: FlutterPluginRegistrar?) {
    let fm = FileManager.default
    var zips: [URL] = []
    for bundle in Bundle.allBundles {
      if let url = bundle.url(forResource: "orbits-worklet-modules", withExtension: "zip") {
        zips.append(url)
      }
      if let root = bundle.resourceURL {
        zips.append(root.appendingPathComponent("orbits-worklet-modules.zip"))
      }
    }
    if let registrar {
      let key = registrar.lookupKey(forAsset: "orbits-worklet-modules.zip")
      if let path = Bundle.main.path(forResource: key, ofType: nil) {
        zips.append(URL(fileURLWithPath: path))
      }
    }
    if let flutter = Bundle.main.resourceURL?
      .appendingPathComponent("flutter_assets/orbits-worklet-modules.zip")
    {
      zips.append(flutter)
    }
    if let app = Bundle.main.privateFrameworksURL?
      .appendingPathComponent("App.framework")
      .appendingPathComponent("flutter_assets/orbits-worklet-modules.zip")
    {
      zips.append(app)
    }
    for zipURL in zips where fm.fileExists(atPath: zipURL.path) {
      if let data = try? Data(contentsOf: zipURL), !data.isEmpty {
        try? ZipExtract.unzip(data: data, into: dest)
        return
      }
    }
    let dirs = [
      Bundle.main.resourceURL?.appendingPathComponent("orbits-worklet-modules"),
      Bundle.main.resourceURL?.appendingPathComponent("orbits_worklet_modules"),
    ].compactMap { $0 }
    for dir in dirs where fm.fileExists(atPath: dir.path) {
      if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
        for item in items {
          let ext = item.pathExtension.lowercased()
          if ext == "bare" || ext == "dylib" || ext == "so" || ext == "node" {
            continue
          }
          let target = dest.appendingPathComponent(item.lastPathComponent)
          try? fm.removeItem(at: target)
          try? fm.copyItem(at: item, to: target)
        }
        return
      }
    }
  }

  private static func applicationSupport() -> URL {
    let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    let root = urls.first ?? FileManager.default.temporaryDirectory
    let dir = root.appendingPathComponent("orbits", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}

enum HostError: Error, LocalizedError {
  case runtimeMissing
  case workletFailed
  case notStarted
  case timeout
  case backpressure
  case closed
  case worklet(String)

  var errorDescription: String? {
    switch self {
    case .runtimeMissing: return "BARE_RUNTIME_MISSING"
    case .workletFailed: return "BARE_WORKLET_FAILED"
    case .notStarted: return "NOT_STARTED"
    case .timeout: return "IPC_TIMEOUT"
    case .backpressure: return "IPC_BACKPRESSURE"
    case .closed: return "ipc closed"
    case .worklet(let message): return message
    }
  }
}

private final class RequestBox {
  private let lock = NSCondition()
  private var result: Result<[String: Any], Error>?

  func finish(_ value: Result<[String: Any], Error>) {
    lock.lock()
    result = value
    lock.broadcast()
    lock.unlock()
  }

  func wait(timeoutMs: Int) -> Result<[String: Any], Error>? {
    lock.lock()
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    while result == nil {
      if !lock.wait(until: deadline) { break }
    }
    let out = result
    lock.unlock()
    return out
  }
}
