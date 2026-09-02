import CallKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, CXProviderDelegate {
  private var callProvider: CXProvider?
  private var pushChannel: FlutterMethodChannel?
  private var lifecycleChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    // Provider UI name is the bundle product name. `localizedName` is
    // get-only on the iOS 26 SDK.
    let config = CXProviderConfiguration()
    config.supportsVideo = true
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.generic]
    let provider = CXProvider(configuration: config)
    provider.setDelegate(self, queue: nil)
    callProvider = provider
    if let pushRegistrar = self.registrar(forPlugin: "OrbitsPush") {
      let channel = FlutterMethodChannel(
        name: "app.orbits/push",
        binaryMessenger: pushRegistrar.messenger()
      )
      channel.setMethodCallHandler { call, result in
        if call.method == "register" {
          UIApplication.shared.registerForRemoteNotifications()
          result(nil)
          return
        }
        result(FlutterMethodNotImplemented)
      }
      pushChannel = channel
    }
    if let lifeRegistrar = self.registrar(forPlugin: "OrbitsLifecycle") {
      let channel = FlutterMethodChannel(
        name: "app.orbits/lifecycle",
        binaryMessenger: lifeRegistrar.messenger()
      )
      lifecycleChannel = channel
    }
    UIDevice.current.isBatteryMonitoringEnabled = true
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(batteryDidChange),
      name: UIDevice.batteryStateDidChangeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(batteryDidChange),
      name: UIDevice.batteryLevelDidChangeNotification,
      object: nil
    )
    if let registrar = self.registrar(forPlugin: "OrbitsCallKit") {
      let channel = FlutterMethodChannel(
        name: "app.orbits/calling",
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { [weak self] call, result in
        let args = call.arguments as? [String: Any] ?? [:]
        if let peer = args["peerId"] as? String, !peer.isEmpty {
          result(FlutterError(code: "PEER_ID", message: "system calling must not receive a peer id", details: nil))
          return
        }
        switch call.method {
        case "reportIncoming":
          let handle = args["opaqueCallId"] as? String ?? ""
          let video = args["video"] as? Bool ?? false
          let update = CXCallUpdate()
          update.remoteHandle = CXHandle(type: .generic, value: handle)
          update.localizedCallerName = "Orbits"
          update.hasVideo = video
          self?.callProvider?.reportNewIncomingCall(with: UUID(), update: update) { _ in }
          result(nil)
        case "endCall":
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    pushChannel?.invokeMethod("token", arguments: ["apns": hex])
  }

  /// Aligned with OpaqueWake.forbiddenKeys / kForbiddenReplicationFields plus UX keys.
  private static let forbiddenKeys: Set<String> = [
    "plaintext", "password", "kek", "vaultKek", "rootKey", "sendCk", "recvCk",
    "dhPriv", "skipped", "discoverySecret", "sharedDiscoverySecret",
    "attachmentBytes", "fileKey", "fileKeyB64", "privBytes",
    "text", "body", "title", "senderName", "displayName", "peerId",
    "conversationId", "attachment", "mime", "fileName",
  ]

  /// nested walk of NSDictionary / NSArray (and [AnyHashable: Any] / arrays).
  /// Cycle-safe via ObjectIdentifier on NSDictionary/NSArray class objects;
  /// already-seen values are safe (not forbidden).
  private static func hasForbiddenKey(
    _ value: Any?,
    seen: inout Set<ObjectIdentifier>
  ) -> Bool {
    guard let value = value else { return false }
    if let dict = value as? NSDictionary {
      let id = ObjectIdentifier(dict)
      if seen.contains(id) { return false }
      seen.insert(id)
      for (key, child) in dict {
        if let name = key as? String, forbiddenKeys.contains(name) {
          return true
        }
        if hasForbiddenKey(child, seen: &seen) { return true }
      }
      return false
    }
    if let array = value as? NSArray {
      let id = ObjectIdentifier(array)
      if seen.contains(id) { return false }
      seen.insert(id)
      for item in array {
        if hasForbiddenKey(item, seen: &seen) { return true }
      }
      return false
    }
    if let dict = value as? [AnyHashable: Any] {
      for (key, child) in dict {
        if let name = key as? String, forbiddenKeys.contains(name) {
          return true
        }
        if hasForbiddenKey(child, seen: &seen) { return true }
      }
      return false
    }
    if let array = value as? [Any] {
      for item in array {
        if hasForbiddenKey(item, seen: &seen) { return true }
      }
      return false
    }
    return false
  }

  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    var seen = Set<ObjectIdentifier>()
    if Self.hasForbiddenKey(userInfo, seen: &seen) {
      completionHandler(.noData)
      return
    }
    guard userInfo["opaqueWakeToken"] != nil else {
      completionHandler(.noData)
      return
    }
    pushChannel?.invokeMethod("wake", arguments: userInfo)
    completionHandler(.newData)
  }

  @objc private func batteryDidChange(_ notification: Notification) {
    let device = UIDevice.current
    let level = device.batteryLevel
    let low: Bool
    if level < 0 {
      low = false
    } else {
      low = level <= 0.20 && device.batteryState == .unplugged
    }
    lifecycleChannel?.invokeMethod("battery", arguments: ["low": low])
  }

  func providerDidReset(_ provider: CXProvider) {}
}
