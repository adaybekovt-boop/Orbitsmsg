package com.orbits.orbits_flutter

import io.flutter.plugin.common.MethodChannel

/// Local FCM/APNs stand-in. Forwards opaque wakes onto `app.orbits/push`
/// when Flutter is attached. Does not send to Google or Apple.
internal object OrbitsPushBridge {
    @Volatile
    var channel: MethodChannel? = null

    @Volatile
    private var pendingWake: Map<String, Any?>? = null

    fun attach(ch: MethodChannel) {
        channel = ch
        val pending = pendingWake
        pendingWake = null
        if (pending != null) {
            ch.invokeMethod("wake", pending)
        }
    }

    fun detach(ch: MethodChannel) {
        if (channel === ch) {
            channel = null
        }
    }

    fun emitWake(payload: Map<String, Any?>) {
        val ch = channel
        if (ch != null) {
            ch.invokeMethod("wake", payload)
        } else {
            pendingWake = payload
        }
    }
}
