package app.orbits.transport

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Android Bare host. The worklet bundle is embedded at build time.
/// Production must not fetch remote JS. The Bare binary is not linked
/// in this tree yet — start succeeds only for a local bundle.
class OrbitsTransportPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var channel: MethodChannel
  private var started = false
  private var suspended = false
  private var published = false

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "app.orbits/transport")
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    started = false
    suspended = false
    published = false
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "start" -> start(call, result)
      "stop" -> {
        started = false
        suspended = false
        published = false
        result.success(null)
      }
      "publish" -> {
        if (!requireStarted(result)) return
        val deviceId = call.argument<String>("deviceId")
        if (deviceId.isNullOrEmpty()) {
          result.error("MALFORMED", "publish needs deviceId", null)
          return
        }
        published = true
        result.success(null)
      }
      "unpublish" -> {
        published = false
        result.success(null)
      }
      "connect", "disconnect", "refreshNetwork" -> {
        if (!requireLive(result)) return
        result.success(null)
      }
      "send" -> {
        if (!requireLive(result)) return
        val frame = call.argument<ByteArray>("frame") ?: ByteArray(0)
        if (frame.size > 256 * 1024) {
          result.error("IPC_FRAME", "IPC frame exceeds cap", null)
          return
        }
        result.success(null)
      }
      "sendFile" -> {
        if (!requireLive(result)) return
        val path = call.argument<String>("path") ?: ""
        val size = call.argument<Int>("sizeBytes") ?: 0
        if (path.isEmpty()) {
          result.error("PATH_REQUIRED", "sendFile requires a path", null)
          return
        }
        if (size > 50 * 1024 * 1024) {
          result.error("OVERSIZE", "attachment exceeds path-transfer cap", null)
          return
        }
        result.success(null)
      }
      "suspend" -> {
        suspended = true
        result.success(null)
      }
      "resume" -> {
        suspended = false
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  private fun start(call: MethodCall, result: MethodChannel.Result) {
    val remoteJs = call.argument<Boolean>("remoteJs")
    val remoteJsUrl = call.argument<String>("remoteJsUrl")
    val bundleUrl = call.argument<String>("bundleUrl")
    val scriptUrl = call.argument<String>("scriptUrl")
    if (remoteJs == true ||
      !remoteJsUrl.isNullOrEmpty() ||
      looksRemote(bundleUrl) ||
      looksRemote(scriptUrl)
    ) {
      result.error("REMOTE_JS", "production Bare must not fetch remote JS", null)
      return
    }
    val ipcVersion = call.argument<String>("ipcVersion")
    if (!ipcVersion.isNullOrEmpty() && ipcVersion != "orbits-bare-ipc-v1") {
      result.error("ABI_MISMATCH", "unsupported IPC version", null)
      return
    }
    if (call.argument<Boolean>("requireLocalBundle") == true &&
      call.argument<Boolean>("localBundlePresent") != true
    ) {
      result.error("BUNDLE_MISSING", "local Bare bundle missing", null)
      return
    }
    val expected = call.argument<String>("expectedBundleSha256")
    val actual = call.argument<String>("localBundleSha256")
    if (!expected.isNullOrEmpty() && !actual.isNullOrEmpty() && expected != actual) {
      result.error("BUNDLE_TAMPERED", "local bundle hash mismatch", null)
      return
    }
    // A linked Bare binary is not shipped in this tree. Success would
    // be a false send path. Fail closed until the artifact exists.
    result.error(
      "BARE_RUNTIME_MISSING",
      "linked Bare runtime is not shipped",
      null,
    )
  }

  private fun looksRemote(url: String?): Boolean {
    if (url.isNullOrEmpty()) return false
    return url.startsWith("http://") || url.startsWith("https://")
  }

  private fun requireStarted(result: MethodChannel.Result): Boolean {
    if (!started) {
      result.error("NOT_STARTED", "not started", null)
      return false
    }
    return true
  }

  private fun requireLive(result: MethodChannel.Result): Boolean {
    if (!requireStarted(result)) return false
    if (suspended) {
      result.error("SUSPENDED", "suspended", null)
      return false
    }
    return true
  }
}
