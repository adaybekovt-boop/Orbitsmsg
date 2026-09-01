package com.orbits.orbits_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/// FCM stand-in: only an opaque wake token may arrive.
/// Forbidden keys are dropped so a misconfigured gateway cannot leak
/// plaintext into the OS notification extras. Allowlisted extras are
/// forwarded to Dart on `app.orbits/push` (`wake`). Live FCM send stays off.
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
        val token = extras.getString("opaqueWakeToken") ?: return
        if (token.isEmpty()) return
        if (!extras.containsKey("collapseId")) return
        if (!extras.containsKey("protocolVersion")) return
        val collapse = extras.getString("collapseId") ?: extras.get("collapseId")?.toString() ?: return
        val protocol = extras.get("protocolVersion") ?: return
        OrbitsPushBridge.emitWake(
            mapOf(
                "opaqueWakeToken" to token,
                "collapseId" to collapse,
                "protocolVersion" to protocol,
            ),
        )
    }
}
