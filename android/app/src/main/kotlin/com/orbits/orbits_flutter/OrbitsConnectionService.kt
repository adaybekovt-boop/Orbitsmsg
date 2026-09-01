package com.orbits.orbits_flutter

import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager

/// Concrete Telecom connection. `android.telecom.Connection` is abstract
/// on API 36; callers must subclass it. The address is an opaque call id.
/// Must not be given a Peer ID or message body.
internal class OrbitsConnection : Connection() {
    init {
        setCallerDisplayName("Orbits", TelecomManager.PRESENTATION_ALLOWED)
    }
}

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
            conn.setDisconnected(DisconnectCause(DisconnectCause.ERROR))
            conn.destroy()
            return conn
        }
        val conn = OrbitsConnection()
        conn.setInitializing()
        conn.setActive()
        return conn
    }
}
