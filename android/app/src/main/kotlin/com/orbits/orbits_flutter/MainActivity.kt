package com.orbits.orbits_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var lifecycleChannel: MethodChannel? = null
    private val dozeReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            lifecycleChannel?.invokeMethod(
                "doze",
                mapOf("idle" to pm.isDeviceIdleMode),
            )
        }
    }

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
        lifecycleChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.orbits/lifecycle",
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.orbits/push")
            .setMethodCallHandler { call, result ->
                if (call.method == "register") {
                    // FCM SDK is not a required dependency. Live send stays off.
                    result.success(null)
                    return@setMethodCallHandler
                }
                result.notImplemented()
            }
        val filter = IntentFilter(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(dozeReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(dozeReceiver, filter)
        }
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(dozeReceiver)
        } catch (_: IllegalArgumentException) {
        }
        super.onDestroy()
    }
}
