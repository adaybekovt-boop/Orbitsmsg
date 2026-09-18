package com.orbits.orbits_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.MethodChannel

/// FCM/APNs stand-in: only an opaque wake token may arrive.
/// Forbidden keys are dropped so a misconfigured gateway cannot leak
/// plaintext into the OS notification extras.
///
/// When the Flutter engine is up, extras hop to Dart on `app.orbits/wake`.
/// Otherwise they stay pending until [MainActivity] binds the channel.
class OrbitsWakeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        val extras = intent?.extras ?: return
        val forbidden = arrayOf(
            "text", "body", "title", "senderName", "displayName",
            "peerId", "conversationId", "attachment", "mime", "fileName",
        )
        for (key in forbidden) {
            if (extras.containsKey(key)) return
        }
        if (!extras.containsKey("opaqueWakeToken")) return
        if (!extras.containsKey("collapseId")) return
        if (!extras.containsKey("protocolVersion")) return
        val token = extras.getString("opaqueWakeToken") ?: return
        val collapse = extras.getString("collapseId") ?: return
        val version = extras.getInt("protocolVersion", 0)
        if (token.isEmpty() || version < 1) return
        deliver(
            mapOf(
                "opaqueWakeToken" to token,
                "collapseId" to collapse,
                "protocolVersion" to version,
            ),
        )
    }

    companion object {
        @Volatile
        private var channel: MethodChannel? = null

        @Volatile
        private var pending: Map<String, Any>? = null

        fun bind(wakeChannel: MethodChannel) {
            channel = wakeChannel
            flushPending()
        }

        fun unbind() {
            channel = null
        }

        fun flushPending() {
            val payload = pending ?: return
            val ch = channel ?: return
            pending = null
            ch.invokeMethod("opaqueWake", payload)
        }

        fun deliver(payload: Map<String, Any>) {
            val ch = channel
            if (ch == null) {
                pending = payload
                return
            }
            ch.invokeMethod("opaqueWake", payload)
        }
    }
}
