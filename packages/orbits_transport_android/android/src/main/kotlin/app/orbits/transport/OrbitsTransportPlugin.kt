package app.orbits.transport

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/// Android Bare host. The worklet bundle is embedded at build time.
/// Production must not fetch remote JS. Official BareKit is linked
/// only when a verified local classes.jar is present; otherwise start
/// stays fail-closed. Every method writes OTP1 or fails with a code.
class OrbitsTransportPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
  private lateinit var channel: MethodChannel
  private var engineBinding: FlutterPlugin.FlutterPluginBinding? = null
  private val main = Handler(Looper.getMainLooper())
  private var started = false
  private var suspended = false
  private var hostActivity: Activity? = null

  private val activityCallbacks = object : Application.ActivityLifecycleCallbacks {
    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
    override fun onActivityStarted(activity: Activity) {}
    override fun onActivityStopped(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
    override fun onActivityDestroyed(activity: Activity) {}

    override fun onActivityPaused(activity: Activity) {
      if (activity !== hostActivity || !started || suspended) return
      OrbitsBareRuntime.suspendRuntime {
        suspended = true
      }
    }

    override fun onActivityResumed(activity: Activity) {
      if (activity !== hostActivity || !started || !suspended) return
      OrbitsBareRuntime.resumeRuntime {
        suspended = false
      }
    }
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    engineBinding = binding
    channel = MethodChannel(binding.binaryMessenger, "app.orbits/transport")
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    engineBinding = null
    OrbitsBareRuntime.stopSession()
    started = false
    suspended = false
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    attachLifecycle(binding.activity)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    detachLifecycle()
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    attachLifecycle(binding.activity)
  }

  override fun onDetachedFromActivity() {
    detachLifecycle()
  }

  private fun attachLifecycle(activity: Activity) {
    detachLifecycle()
    hostActivity = activity
    activity.application.registerActivityLifecycleCallbacks(activityCallbacks)
  }

  private fun detachLifecycle() {
    hostActivity?.application?.unregisterActivityLifecycleCallbacks(activityCallbacks)
    hostActivity = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "start" -> startAsync(call, result)
      "stop" -> stopAsync(result)
      "publish" -> publishAsync(call, result)
      "unpublish" -> ipcAsync("unpublish", emptyMap(), 15_000, result)
      "connect" -> connectAsync(call, result)
      "disconnect" -> disconnectAsync(call, result)
      "send" -> sendAsync(call, result)
      "sendFile" -> sendFileAsync(call, result)
      "suspend" -> suspendAsync(result)
      "resume" -> resumeAsync(result)
      "refreshNetwork" -> ipcAsync("refreshNetwork", emptyMap(), 15_000, result)
      "runtimeInfo" -> runtimeInfoAsync(result)
      else -> result.notImplemented()
    }
  }

  private fun startAsync(call: MethodCall, result: MethodChannel.Result) {
    val remoteJs = call.argument<Boolean>("remoteJs")
    val remoteJsUrl = call.argument<String>("remoteJsUrl")
    val bundleUrl = call.argument<String>("bundleUrl")
    val scriptUrl = call.argument<String>("scriptUrl")
    if (remoteJs == true ||
      !remoteJsUrl.isNullOrEmpty() ||
      looksRemote(bundleUrl) ||
      looksRemote(scriptUrl)
    ) {
      replyError(result, HostError("REMOTE_JS", "production Bare must not fetch remote JS"))
      return
    }
    val ipcVersion = call.argument<String>("ipcVersion")
    if (!ipcVersion.isNullOrEmpty() && ipcVersion != "orbits-bare-ipc-v1") {
      replyError(result, HostError("ABI_MISMATCH", "unsupported IPC version"))
      return
    }
    if (call.argument<Boolean>("requireLocalBundle") == true &&
      call.argument<Boolean>("localBundlePresent") != true
    ) {
      replyError(result, HostError("BUNDLE_MISSING", "local Bare bundle missing"))
      return
    }
    val expected = call.argument<String>("expectedBundleSha256")
    val actual = call.argument<String>("localBundleSha256")
    if (!expected.isNullOrEmpty() && !actual.isNullOrEmpty() && expected != actual) {
      replyError(result, HostError("BUNDLE_TAMPERED", "local bundle hash mismatch"))
      return
    }

    // Register event sink before completion so initial events are not missed
    OrbitsBareRuntime.setEventSink { event ->
      if (::channel.isInitialized) {
        channel.invokeMethod("event", event)
      }
    }

    val args = call.arguments as? Map<*, *>
    OrbitsBareRuntime.startSessionAsync(args, engineBinding) { startRes ->
      startRes.fold(
        onSuccess = { info ->
          started = true
          suspended = false
          replySuccess(result, info)
        },
        onFailure = { err ->
          val message = err.message ?: "linked Bare runtime is not shipped"
          val code = when {
            message.contains("BARE_RUNTIME_MISSING") -> "BARE_RUNTIME_MISSING"
            message.contains("BARE_WORKLET_FAILED") -> "BARE_WORKLET_FAILED"
            else -> "BARE_RUNTIME_MISSING"
          }
          replyError(result, HostError(code, message))
        },
      )
    }
  }

  private fun stopAsync(result: MethodChannel.Result) {
    started = false
    suspended = false
    OrbitsBareRuntime.stopSession {
      replySuccess(result, null)
    }
  }

  private fun publishAsync(call: MethodCall, result: MethodChannel.Result) {
    if (!checkStarted(result)) return
    val deviceId = call.argument<String>("deviceId")
    if (deviceId.isNullOrEmpty()) {
      replyError(result, HostError("MALFORMED", "publish needs deviceId"))
      return
    }
    @Suppress("UNCHECKED_CAST")
    val binding = (call.arguments as? Map<String, Any?>) ?: emptyMap()
    OrbitsBareRuntime.request("publish", mapOf("binding" to binding), 30_000) { res ->
      replyResult(result, res)
    }
  }

  private fun connectAsync(call: MethodCall, result: MethodChannel.Result) {
    if (!checkLive(result)) return
    @Suppress("UNCHECKED_CAST")
    val peer = (call.arguments as? Map<String, Any?>) ?: emptyMap()
    if ((peer["peerId"] as? String).isNullOrEmpty() &&
      (peer["noisePublicKey"] as? String).isNullOrEmpty()
    ) {
      replyError(result, HostError("MALFORMED", "connect needs peerId or noisePublicKey"))
      return
    }
    OrbitsBareRuntime.request("connect", peer, 45_000) { res ->
      replyResult(result, res)
    }
  }

  private fun disconnectAsync(call: MethodCall, result: MethodChannel.Result) {
    if (!checkStarted(result)) return
    val peerId = when (val raw = call.arguments) {
      is String -> raw
      is Map<*, *> -> raw["peerId"] as? String ?: ""
      else -> ""
    }
    OrbitsBareRuntime.request("disconnect", mapOf("peerId" to peerId), 10_000) { res ->
      replyResult(result, res)
    }
  }

  private fun sendAsync(call: MethodCall, result: MethodChannel.Result) {
    if (!checkLive(result)) return
    val frame = call.argument<ByteArray>("frame") ?: ByteArray(0)
    if (frame.size > 256 * 1024) {
      replyError(result, HostError("IPC_FRAME", "IPC frame exceeds cap"))
      return
    }
    val peerId = call.argument<String>("peerId") ?: ""
    val channelName = call.argument<String>("channel") ?: "message"
    OrbitsBareRuntime.request(
      "send",
      mapOf(
        "peerId" to peerId,
        "channel" to channelName,
        "frameB64" to android.util.Base64.encodeToString(frame, android.util.Base64.NO_WRAP),
      ),
      15_000,
    ) { res ->
      replyResult(result, res)
    }
  }

  private fun sendFileAsync(call: MethodCall, result: MethodChannel.Result) {
    if (!checkLive(result)) return
    val path = call.argument<String>("path") ?: ""
    val size = call.argument<Int>("sizeBytes") ?: 0
    if (path.isEmpty()) {
      replyError(result, HostError("PATH_REQUIRED", "sendFile requires a path"))
      return
    }
    if (size > 50 * 1024 * 1024) {
      replyError(result, HostError("OVERSIZE", "attachment exceeds path-transfer cap"))
      return
    }
    val peerId = call.argument<String>("peerId") ?: ""
    OrbitsBareRuntime.request(
      "sendFile",
      mapOf(
        "peerId" to peerId,
        "file" to mapOf(
          "path" to path,
          "sizeBytes" to size,
          "fileName" to FileName.of(path),
        ),
      ),
      10 * 60_000L,
    ) { res ->
      replyResult(result, res)
    }
  }

  private fun suspendAsync(result: MethodChannel.Result) {
    if (!checkStarted(result)) return
    OrbitsBareRuntime.suspendRuntime {
      suspended = true
      replySuccess(result, null)
    }
  }

  private fun resumeAsync(result: MethodChannel.Result) {
    if (!checkStarted(result)) return
    OrbitsBareRuntime.resumeRuntime {
      suspended = false
      replySuccess(result, null)
    }
  }

  private fun runtimeInfoAsync(result: MethodChannel.Result) {
    if (!checkStarted(result)) return
    OrbitsBareRuntime.request("runtime.info", emptyMap(), 8_000) { res ->
      replyResult(result, res)
    }
  }

  private fun ipcAsync(method: String, params: Map<String, Any?>, timeoutMs: Long, result: MethodChannel.Result) {
    if (!checkLive(result)) return
    OrbitsBareRuntime.request(method, params, timeoutMs) { res ->
      replyResult(result, res)
    }
  }

  private fun checkStarted(result: MethodChannel.Result): Boolean {
    if (!started || !OrbitsBareRuntime.isLive()) {
      replyError(result, HostError("NOT_STARTED", "not started"))
      return false
    }
    return true
  }

  private fun checkLive(result: MethodChannel.Result): Boolean {
    if (!checkStarted(result)) return false
    if (suspended) {
      replyError(result, HostError("SUSPENDED", "suspended"))
      return false
    }
    return true
  }

  private fun looksRemote(url: String?): Boolean {
    if (url.isNullOrEmpty()) return false
    return url.startsWith("http://") || url.startsWith("https://")
  }

  private fun replySuccess(result: MethodChannel.Result, value: Any?) {
    main.post { result.success(value) }
  }

  private fun replyError(result: MethodChannel.Result, err: Throwable) {
    val message = err.message ?: "ipc error"
    val code = when {
      err is HostError -> err.code
      message.contains("NOT_STARTED") -> "NOT_STARTED"
      message.contains("SUSPENDED") -> "SUSPENDED"
      message.contains("IPC_TIMEOUT") -> "IPC_TIMEOUT"
      message.contains("IPC_BACKPRESSURE") -> "IPC_BACKPRESSURE"
      message.contains("BARE_RUNTIME_MISSING") -> "BARE_RUNTIME_MISSING"
      message.contains("BARE_WORKLET_FAILED") -> "BARE_WORKLET_FAILED"
      message.contains("IPC_FRAME") -> "IPC_FRAME"
      message.contains("IPC_CLOSED") -> "IPC_CLOSED"
      message.contains("BAD_MAGIC") -> "BAD_MAGIC"
      message.contains("BAD_VERSION") -> "BAD_VERSION"
      message.contains("OVERSIZE_FRAME") -> "OVERSIZE_FRAME"
      message.contains("MALFORMED_JSON") -> "MALFORMED_JSON"
      else -> "BARE_WORKLET_FAILED"
    }
    main.post { result.error(code, message, null) }
  }

  private fun replyResult(result: MethodChannel.Result, res: Result<Map<String, Any?>>) {
    res.fold(
      onSuccess = { replySuccess(result, it) },
      onFailure = { replyError(result, it) },
    )
  }

  private class HostError(val code: String, message: String) : Exception(message)

  private object FileName {
    fun of(path: String): String {
      val idx = path.lastIndexOf('/')
      return if (idx >= 0 && idx + 1 < path.length) path.substring(idx + 1) else path
    }
  }
}
