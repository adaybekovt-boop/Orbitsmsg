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
  private val io = Executors.newSingleThreadExecutor { r ->
    Thread(r, "orbits-bare-ipc").apply { isDaemon = true }
  }
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
      io.execute {
        try {
          OrbitsBareRuntime.suspendRuntime()
          suspended = true
        } catch (_: Exception) {
        }
      }
    }

    override fun onActivityResumed(activity: Activity) {
      if (activity !== hostActivity || !started || !suspended) return
      io.execute {
        try {
          OrbitsBareRuntime.resumeRuntime()
          suspended = false
        } catch (_: Exception) {
        }
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
    io.execute { OrbitsBareRuntime.stopSession() }
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
      "start" -> runAsync(result) { start(call) }
      "stop" -> runAsync(result) { stop() }
      "publish" -> runAsync(result) { publish(call) }
      "unpublish" -> runAsync(result) { ipc("unpublish") }
      "connect" -> runAsync(result) { connect(call) }
      "disconnect" -> runAsync(result) { disconnect(call) }
      "send" -> runAsync(result) { send(call) }
      "sendFile" -> runAsync(result) { sendFile(call) }
      "suspend" -> runAsync(result) { suspendCall() }
      "resume" -> runAsync(result) { resumeCall() }
      "refreshNetwork" -> runAsync(result) { ipc("refreshNetwork") }
      "runtimeInfo" -> runAsync(result) { runtimeInfo() }
      else -> result.notImplemented()
    }
  }

  private fun start(call: MethodCall): Any? {
    val remoteJs = call.argument<Boolean>("remoteJs")
    val remoteJsUrl = call.argument<String>("remoteJsUrl")
    val bundleUrl = call.argument<String>("bundleUrl")
    val scriptUrl = call.argument<String>("scriptUrl")
    if (remoteJs == true ||
      !remoteJsUrl.isNullOrEmpty() ||
      looksRemote(bundleUrl) ||
      looksRemote(scriptUrl)
    ) {
      throw HostError("REMOTE_JS", "production Bare must not fetch remote JS")
    }
    val ipcVersion = call.argument<String>("ipcVersion")
    if (!ipcVersion.isNullOrEmpty() && ipcVersion != "orbits-bare-ipc-v1") {
      throw HostError("ABI_MISMATCH", "unsupported IPC version")
    }
    if (call.argument<Boolean>("requireLocalBundle") == true &&
      call.argument<Boolean>("localBundlePresent") != true
    ) {
      throw HostError("BUNDLE_MISSING", "local Bare bundle missing")
    }
    val expected = call.argument<String>("expectedBundleSha256")
    val actual = call.argument<String>("localBundleSha256")
    if (!expected.isNullOrEmpty() && !actual.isNullOrEmpty() && expected != actual) {
      throw HostError("BUNDLE_TAMPERED", "local bundle hash mismatch")
    }
    @Suppress("UNCHECKED_CAST")
    val args = (call.arguments as? Map<*, *>)
    val startedInfo = try {
      OrbitsBareRuntime.startSession(args, engineBinding)
    } catch (err: Exception) {
      val message = err.message ?: "linked Bare runtime is not shipped"
      val code = when {
        message.contains("BARE_RUNTIME_MISSING") -> "BARE_RUNTIME_MISSING"
        message.contains("BARE_WORKLET_FAILED") -> "BARE_WORKLET_FAILED"
        else -> "BARE_RUNTIME_MISSING"
      }
      throw HostError(code, message)
    }
    OrbitsBareRuntime.setEventSink { event ->
      if (::channel.isInitialized) {
        channel.invokeMethod("event", event)
      }
    }
    started = true
    suspended = false
    return startedInfo
  }

  private fun stop(): Any? {
    OrbitsBareRuntime.stopSession()
    started = false
    suspended = false
    return null
  }

  private fun publish(call: MethodCall): Any? {
    requireStarted()
    val deviceId = call.argument<String>("deviceId")
    if (deviceId.isNullOrEmpty()) {
      throw HostError("MALFORMED", "publish needs deviceId")
    }
    @Suppress("UNCHECKED_CAST")
    val binding = (call.arguments as? Map<String, Any?>) ?: emptyMap()
    return OrbitsBareRuntime.request("publish", mapOf("binding" to binding), 30_000)
  }

  private fun connect(call: MethodCall): Any? {
    requireLive()
    @Suppress("UNCHECKED_CAST")
    val peer = (call.arguments as? Map<String, Any?>) ?: emptyMap()
    if ((peer["peerId"] as? String).isNullOrEmpty() &&
      (peer["noisePublicKey"] as? String).isNullOrEmpty()
    ) {
      throw HostError("MALFORMED", "connect needs peerId or noisePublicKey")
    }
    return OrbitsBareRuntime.request("connect", peer, 45_000)
  }

  private fun disconnect(call: MethodCall): Any? {
    requireStarted()
    val peerId = when (val raw = call.arguments) {
      is String -> raw
      is Map<*, *> -> raw["peerId"] as? String ?: ""
      else -> ""
    }
    return OrbitsBareRuntime.request("disconnect", mapOf("peerId" to peerId), 10_000)
  }

  private fun send(call: MethodCall): Any? {
    requireLive()
    val frame = call.argument<ByteArray>("frame") ?: ByteArray(0)
    if (frame.size > 256 * 1024) {
      throw HostError("IPC_FRAME", "IPC frame exceeds cap")
    }
    val peerId = call.argument<String>("peerId") ?: ""
    val channelName = call.argument<String>("channel") ?: "message"
    return OrbitsBareRuntime.request(
      "send",
      mapOf(
        "peerId" to peerId,
        "channel" to channelName,
        "frameB64" to android.util.Base64.encodeToString(frame, android.util.Base64.NO_WRAP),
      ),
      15_000,
    )
  }

  private fun sendFile(call: MethodCall): Any? {
    requireLive()
    val path = call.argument<String>("path") ?: ""
    val size = call.argument<Int>("sizeBytes") ?: 0
    if (path.isEmpty()) {
      throw HostError("PATH_REQUIRED", "sendFile requires a path")
    }
    if (size > 50 * 1024 * 1024) {
      throw HostError("OVERSIZE", "attachment exceeds path-transfer cap")
    }
    val peerId = call.argument<String>("peerId") ?: ""
    return OrbitsBareRuntime.request(
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
    )
  }

  private fun suspendCall(): Any? {
    requireStarted()
    OrbitsBareRuntime.suspendRuntime()
    suspended = true
    return null
  }

  private fun resumeCall(): Any? {
    requireStarted()
    OrbitsBareRuntime.resumeRuntime()
    suspended = false
    return null
  }

  private fun runtimeInfo(): Any? {
    requireStarted()
    return OrbitsBareRuntime.runtimeInfo()
  }

  private fun ipc(method: String): Any? {
    requireLive()
    return OrbitsBareRuntime.request(method, emptyMap(), 15_000)
  }

  private fun requireStarted() {
    if (!started || !OrbitsBareRuntime.isLive()) {
      throw HostError("NOT_STARTED", "not started")
    }
  }

  private fun requireLive() {
    requireStarted()
    if (suspended) {
      throw HostError("SUSPENDED", "suspended")
    }
  }

  private fun looksRemote(url: String?): Boolean {
    if (url.isNullOrEmpty()) return false
    return url.startsWith("http://") || url.startsWith("https://")
  }

  private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
    io.execute {
      try {
        val value = block()
        main.post { result.success(value) }
      } catch (err: HostError) {
        main.post { result.error(err.code, err.message, null) }
      } catch (err: Exception) {
        val message = err.message ?: "ipc error"
        val code = when {
          message.contains("NOT_STARTED") -> "NOT_STARTED"
          message.contains("suspended") -> "SUSPENDED"
          message.contains("timeout") -> "IPC_TIMEOUT"
          message.contains("BARE_RUNTIME_MISSING") -> "BARE_RUNTIME_MISSING"
          message.contains("BARE_WORKLET_FAILED") -> "BARE_WORKLET_FAILED"
          message.contains("IPC_FRAME") -> "IPC_FRAME"
          else -> "BARE_WORKLET_FAILED"
        }
        main.post { result.error(code, message, null) }
      }
    }
  }

  private class HostError(val code: String, message: String) : Exception(message)

  private object FileName {
    fun of(path: String): String {
      val idx = path.lastIndexOf('/')
      return if (idx >= 0 && idx + 1 < path.length) path.substring(idx + 1) else path
    }
  }
}
