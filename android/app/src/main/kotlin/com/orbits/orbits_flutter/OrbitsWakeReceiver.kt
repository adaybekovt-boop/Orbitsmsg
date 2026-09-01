package com.orbits.orbits_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/// FCM/APNs stand-in: only an opaque wake token may arrive.
/// Forbidden keys are dropped so a misconfigured gateway cannot leak
/// plaintext into the OS notification extras.
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
        // Flutter isolate is resumed by the activity; extras stay opaque.
    }
}
