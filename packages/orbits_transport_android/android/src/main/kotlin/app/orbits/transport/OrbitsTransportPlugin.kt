package app.orbits.transport

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.IdentityHashMap

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
      if (startWantsRemoteJs(call.arguments)) {
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

  private fun startWantsRemoteJs(arguments: Any?): Boolean {
    val args = arguments as? Map<*, *> ?: return false
    if (args["remoteJs"] == true) return true
    val remoteKeys = arrayOf(
      "remoteJsUrl",
      "bundleUrl",
      "scriptUrl",
      "addonUrl",
      "downloadUrl",
      "moduleUrl",
      "jsUrl",
      "workletUrl",
    )
    for (key in remoteKeys) {
      val value = args[key]
      if (value is String && value.isNotEmpty()) return true
    }
    return anyStringContainsScheme(args, IdentityHashMap())
  }

  private fun anyStringContainsScheme(
    value: Any?,
    seen: IdentityHashMap<Any, Boolean>,
  ): Boolean {
    when (value) {
      is String -> return value.contains("://")
      is Map<*, *> -> {
        if (seen.put(value, true) != null) return false
        for (child in value.values) {
          if (anyStringContainsScheme(child, seen)) return true
        }
      }
      is List<*> -> {
        if (seen.put(value, true) != null) return false
        for (child in value) {
          if (anyStringContainsScheme(child, seen)) return true
        }
      }
    }
    return false
  }

  private fun extractBundledBare(): String? {
    val ctx = appContext ?: return null
    return try {
      ctx.assets.open("bare").use { input ->
        val out = File(ctx.cacheDir, "orbits-bare")
        out.outputStream().use { input.copyTo(it) }
        out.setExecutable(true)
        if (out.exists() && out.canExecute()) {
          extractStdlibZip(ctx)
          extractCorestoreAddon(ctx)
          out.absolutePath
        } else null
      }
    } catch (_: Exception) {
      null
    }
  }

  private fun extractStdlibZip(ctx: Context) {
    try {
      ctx.assets.open("bare_stdlib.zip").use { input ->
        File(ctx.cacheDir, "bare_stdlib.zip").outputStream().use { input.copyTo(it) }
      }
    } catch (_: Exception) {
      // optional local zip
    }
  }

  /// Optional local Corestore addon next to orbits-bare. Never fetched.
  private fun extractCorestoreAddon(ctx: Context) {
    val names = arrayOf("corestore.bare", "addons/corestore.bare")
    val out = File(ctx.cacheDir, "corestore.bare")
    for (name in names) {
      try {
        ctx.assets.open(name).use { input ->
          out.outputStream().use { input.copyTo(it) }
        }
        if (out.exists() && out.length() > 0) return
      } catch (_: Exception) {
        // optional local addon
      }
    }
  }
}
