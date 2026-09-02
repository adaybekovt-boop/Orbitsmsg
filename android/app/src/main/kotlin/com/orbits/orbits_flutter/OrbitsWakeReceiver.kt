package com.orbits.orbits_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Bundle

/// FCM stand-in: only an opaque wake token may arrive.
/// nested walk of Bundle / Map / List (cycle-safe via identityHashCode),
/// aligned with OpaqueWake.forbiddenKeys / kForbiddenReplicationFields.
/// Forbidden keys are dropped so a misconfigured gateway cannot leak
/// plaintext into the OS notification extras. Allowlisted extras are
/// forwarded to Dart on `app.orbits/push` (`wake`). Live FCM send stays off.
class OrbitsWakeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        val extras = intent?.extras ?: return
        if (hasForbiddenKey(extras)) return
        val token = extras.getString("opaqueWakeToken") ?: return
        if (!tokenIsSafe(token)) return
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

    companion object {
        // Must match OpaqueWake.forbiddenKeys / kForbiddenReplicationFields plus UX keys.
        private val forbiddenKeys = setOf(
            "plaintext",
            "password",
            "kek",
            "vaultKek",
            "rootKey",
            "sendCk",
            "recvCk",
            "dhPriv",
            "skipped",
            "discoverySecret",
            "sharedDiscoverySecret",
            "attachmentBytes",
            "fileKey",
            "fileKeyB64",
            "privBytes",
            "text",
            "body",
            "title",
            "senderName",
            "displayName",
            "peerId",
            "conversationId",
            "attachment",
            "mime",
            "fileName",
        )

        /// nested walk. Already-seen identityHashCode values are safe (not forbidden).
        private fun hasForbiddenKey(
            value: Any?,
            seen: MutableSet<Int> = mutableSetOf(),
        ): Boolean {
            if (value == null) return false
            when (value) {
                is Bundle -> {
                    val id = System.identityHashCode(value)
                    if (!seen.add(id)) return false
                    for (key in value.keySet()) {
                        if (key in forbiddenKeys) return true
                        if (hasForbiddenKey(value.get(key), seen)) return true
                    }
                    return false
                }
                is Map<*, *> -> {
                    val id = System.identityHashCode(value)
                    if (!seen.add(id)) return false
                    for ((key, child) in value) {
                        if (key is String && key in forbiddenKeys) return true
                        if (hasForbiddenKey(child, seen)) return true
                    }
                    return false
                }
                is List<*> -> {
                    val id = System.identityHashCode(value)
                    if (!seen.add(id)) return false
                    for (item in value) {
                        if (hasForbiddenKey(item, seen)) return true
                    }
                    return false
                }
                else -> return false
            }
        }

        /// Same fragment rules as Dart opaqueWakeTokenIsSafe.
        private fun tokenIsSafe(token: String): Boolean {
            if (token.isEmpty()) return false
            if (token.contains("://")) return false
            if (token.contains("peerId")) return false
            if (token.contains("fileKey")) return false
            if (token.contains("rootKey")) return false
            if (token.contains("discoverySecret")) return false
            return true
        }
    }
}
