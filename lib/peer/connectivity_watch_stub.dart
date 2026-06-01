// Default/native implementation of the connectivity watchdog hook.
//
// On native platforms the underlying WebSocket already gets a protocol-level
// ping (see `peerjs_client.dart` `pingInterval`, audit M4), so a half-open
// TCP link after a network switch is detected and torn down within ~2 ping
// intervals. There's no extra browser-style `online` event to listen for, so
// this is a no-op — the app-lifecycle "resumed" observer in
// `peer_connection_provider.dart` still nudges a reconnect when the app
// returns to the foreground.

/// Register [onOnline] to fire when network connectivity is regained.
/// Returns an opaque handle for [unwatchOnline]. No-op on native.
Object? watchOnline(void Function() onOnline) => null;

/// Tear down a watcher created by [watchOnline]. No-op on native.
void unwatchOnline(Object? handle) {}
