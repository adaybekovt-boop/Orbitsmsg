package com.orbits.orbits_flutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.orbits/calling")
            .setMethodCallHandler { call, result ->
                val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                if (args["peerId"] != null) {
                    result.error("PEER_ID", "system calling must not receive a peer id", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "reportIncoming", "endCall" -> result.success(null)
                    else -> result.notImplemented()
                }
            }
    }
}
