// Web implementation of the device-access gate.
//
// The authoritative phone detection runs in `web/index.html` *before* the
// Flutter bundle loads (so the main app never even starts on a phone, and the
// browser shows the block message instead — see the IIFE there). That gate
// also has `navigator.userAgentData` (UA Client Hints), which we can't read
// reliably this late, so index.html is the source of truth. Here we just read
// the verdict it published on `window.__orbitsAccessDenied`.
//
// This Dart gate is belt-and-suspenders: it covers the case where the bundle
// was loaded anyway (cached entry point, an SPA navigation, a hand-crafted
// request) by swapping the UI for a block screen. Uses `dart:js_interop` to
// match the repo convention (see `web_lock_web.dart`).

import 'dart:js_interop';

@JS('window')
external _Window get _window;

extension type _Window._(JSObject _) implements JSObject {
  external JSAny? get __orbitsAccessDenied;
}

/// True when index.html flagged this browser as a blocked mobile phone.
bool isAccessDenied() {
  try {
    final v = _window.__orbitsAccessDenied;
    if (v == null) return false;
    final flag = v.dartify();
    return flag == true;
  } catch (_) {
    // If the verdict is unreadable for any reason, fail open — index.html is
    // the primary gate, and blocking a desktop user on an interop hiccup would
    // be worse than the (already-prevented) phone case slipping through.
    return false;
  }
}
