// Web implementation of the connectivity watchdog hook.
//
// The browser WebSocket exposes no `pingInterval` knob (the browser owns
// keepalive), so after a network drop — phone in a lift, tower handoff — a
// half-open socket would otherwise linger until the slow TCP timeout, and the
// user silently stops receiving messages. The browser fires a `window`
// `online` event the instant connectivity returns; we hook it to nudge an
// immediate reconnect instead of waiting. Pairs with the app-lifecycle
// "resumed" observer for the "came back to the tab" case.
//
// Kept on `dart:html` to match the existing web-interop files in this repo
// (`web_download_html.dart`, `keygen_overlay_web.dart`) and avoid adding a
// direct `package:web` dependency.
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

Object? watchOnline(void Function() onOnline) {
  void listener(html.Event _) => onOnline();
  html.window.addEventListener('online', listener);
  return listener;
}

void unwatchOnline(Object? handle) {
  if (handle == null) return;
  try {
    html.window.removeEventListener('online', handle as html.EventListener);
  } catch (_) {
    // Listener identity mismatch across compilers is harmless — the callback
    // is guarded by `_disposed` on the consumer side.
  }
}
