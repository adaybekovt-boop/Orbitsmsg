import CallKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, CXProviderDelegate {
  private var callProvider: CXProvider?
  private var pushChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let config = CXProviderConfiguration()
    config.localizedName = "Orbits"
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

  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    let forbidden = [
      "text", "body", "title", "senderName", "displayName",
      "peerId", "conversationId", "attachment", "mime", "fileName",
    ]
    for key in forbidden {
      if userInfo[key] != nil {
        completionHandler(.noData)
        return
      }
    }
    guard userInfo["opaqueWakeToken"] != nil else {
      completionHandler(.noData)
      return
    }
    pushChannel?.invokeMethod("wake", arguments: userInfo)
    completionHandler(.newData)
  }

  func providerDidReset(_ provider: CXProvider) {}
}
