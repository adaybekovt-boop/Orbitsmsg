package app.orbits.transport

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Android Bare host. The worklet bundle is embedded at build time.
/// Production must not fetch remote JS. The Bare binary is not linked
/// in this tree yet — start succeeds only for a local bundle.
class OrbitsTransportPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var channel: MethodChannel

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "app.orbits/transport")
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
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
    result.notImplemented()
  }
}
