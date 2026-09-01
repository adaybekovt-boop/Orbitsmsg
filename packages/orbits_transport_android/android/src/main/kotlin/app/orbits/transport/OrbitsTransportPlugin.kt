package app.orbits.transport

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Android Bare host. The worklet bundle is embedded at build time.
/// Production must not fetch remote JS. A local `assets/bare` slot is
/// copied into cache when present — never downloaded.
class OrbitsTransportPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var channel: MethodChannel
  private var appContext: Context? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    appContext = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "app.orbits/transport")
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    appContext = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method == "start") {
      val remoteJs = call.argument<Boolean>("remoteJs")
      val remoteJsUrl = call.argument<String>("remoteJsUrl")
      if (remoteJs == true || !remoteJsUrl.isNullOrEmpty()) {
        result.error("REMOTE_JS", "production Bare must not fetch remote JS", null)
        return
      }
      result.success(null)
      return
    }
    if (call.method == "stop") {
      result.success(null)
      return
    }
    if (call.method == "barePath") {
      result.success(extractBundledBare())
      return
    }
    result.notImplemented()
  }

  private fun extractBundledBare(): String? {
    val ctx = appContext ?: return null
    return try {
      ctx.assets.open("bare").use { input ->
        val out = File(ctx.cacheDir, "orbits-bare")
        out.outputStream().use { input.copyTo(it) }
        out.setExecutable(true)
        if (out.exists() && out.canExecute()) out.absolutePath else null
      }
    } catch (_: Exception) {
      null
    }
  }
}
