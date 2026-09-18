import CallKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, CXProviderDelegate {
  private var callProvider: CXProvider?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let config = CXProviderConfiguration()
    // iOS 26 SDK: localizedName is get-only. CallKit uses the app display name.
    config.supportsVideo = true
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.generic]
    let provider = CXProvider(configuration: config)
    provider.setDelegate(self, queue: nil)
    callProvider = provider
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
    if let registrar = self.registrar(forPlugin: "OrbitsWake") {
      wakeChannel = FlutterMethodChannel(
        name: "app.orbits/wake",
        binaryMessenger: registrar.messenger()
      )
      flushPendingWake()
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    let forbidden: Set<String> = [
      "text", "body", "title", "senderName", "displayName",
      "peerId", "conversationId", "attachment", "mime", "fileName",
    ]
    let keys = Set(userInfo.keys.compactMap { $0 as? String })
    if !keys.isDisjoint(with: forbidden) {
      completionHandler(.noData)
      return
    }
    guard
      let token = userInfo["opaqueWakeToken"] as? String, !token.isEmpty,
      let collapse = userInfo["collapseId"] as? String,
      let version = userInfo["protocolVersion"] as? Int, version >= 1
    else {
      completionHandler(.noData)
      return
    }
    deliverWake([
      "opaqueWakeToken": token,
      "collapseId": collapse,
      "protocolVersion": version,
    ])
    completionHandler(.newData)
  }

  private var wakeChannel: FlutterMethodChannel?
  private var pendingWake: [String: Any]?

  private func deliverWake(_ payload: [String: Any]) {
    if let channel = wakeChannel {
      channel.invokeMethod("opaqueWake", arguments: payload)
      return
    }
    pendingWake = payload
  }

  private func flushPendingWake() {
    guard let payload = pendingWake else { return }
    pendingWake = nil
    wakeChannel?.invokeMethod("opaqueWake", arguments: payload)
  }

  func providerDidReset(_ provider: CXProvider) {}
}
