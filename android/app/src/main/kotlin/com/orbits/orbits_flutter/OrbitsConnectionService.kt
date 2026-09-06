package com.orbits.orbits_flutter

import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager

/// Concrete Telecom connection. `android.telecom.Connection` is abstract
/// on compileSdk 36, so it cannot be constructed directly.
/// The address is an opaque call id. Must not be given a Peer ID or
/// message body.
private class OrbitsConnection : Connection()

/// In-app Telecom connection service.
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
            val conn = OrbitsConnection()
            conn.setDisconnected(
                android.telecom.DisconnectCause(android.telecom.DisconnectCause.ERROR),
            )
            conn.destroy()
            return conn
        }
        val conn = OrbitsConnection()
        conn.setInitializing()
        conn.setCallerDisplayName("Orbits", TelecomManager.PRESENTATION_ALLOWED)
        conn.setActive()
        return conn
    }
}
