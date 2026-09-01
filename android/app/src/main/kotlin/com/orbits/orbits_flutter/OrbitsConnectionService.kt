package com.orbits.orbits_flutter

import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager

/// In-app Telecom connection. The address is an opaque call id.
/// Must not be given a Peer ID or message body.
class OrbitsConnectionService : ConnectionService() {
    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection {
        val extras = request?.extras
        if (extras?.containsKey("peerId") == true ||
            extras?.containsKey("text") == true ||
            extras?.containsKey("senderName") == true
        ) {
            val conn = Connection()
            conn.setDisconnected(
                android.telecom.DisconnectCause(android.telecom.DisconnectCause.ERROR),
            )
            conn.destroy()
            return conn
        }
        val conn = Connection()
        conn.setInitializing()
        conn.setCallerDisplayName("Orbits", TelecomManager.PRESENTATION_ALLOWED)
        conn.setActive()
        return conn
    }
}
