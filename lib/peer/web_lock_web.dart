// Web implementation of the cross-tab lock via the browser Web Locks API.
//
// `navigator.locks.request(name, {mode:'exclusive', ifAvailable:true}, cb)`
// invokes `cb(lock)` with a Lock object if granted, or `null` if another tab
// already holds it. To HOLD the lock for this tab's lifetime we return a
// promise from `cb` that stays pending until [releaseWebLock] resolves it —
// the browser also auto-releases when the tab/worker closes. This is immune to
// the cold-start race that SharedPreferences polling suffers from.
//
// Uses `dart:js_interop` (the modern, dart2js+wasm-safe interop) rather than
// `dart:html`, because `navigator.locks` isn't in the legacy typed API.
import 'dart:async';
import 'dart:js_interop';

@JS('navigator')
external _Navigator get _navigator;

extension type _Navigator._(JSObject _) implements JSObject {
  external _LockManager? get locks;
}

extension type _LockManager._(JSObject _) implements JSObject {
  external JSPromise request(
    String name,
    JSObject options,
    JSFunction callback,
  );
}

/// name → completer that, when completed, releases the held lock.
final Map<String, Completer<void>> _held = <String, Completer<void>>{};

Future<bool> acquireWebLock(String name) async {
  try {
    final locks = _navigator.locks;
    // Old browsers without the Web Locks API: let the SharedPreferences
    // fallback in MultiTabLock handle exclusion.
    if (locks == null) return true;

    final granted = Completer<bool>();
    final hold = Completer<void>();
    _held[name] = hold;

    final options =
        <String, Object?>{'mode': 'exclusive', 'ifAvailable': true}.jsify()
            as JSObject;

    JSAny? onLock(JSObject? lock) {
      if (lock == null) {
        // Held by another tab — not granted.
        if (!granted.isCompleted) granted.complete(false);
        _held.remove(name);
        return null;
      }
      if (!granted.isCompleted) granted.complete(true);
      // Returning a pending promise keeps the lock held until we release it.
      return hold.future.toJS;
    }

    locks.request(name, options, onLock.toJS);
    return granted.future;
  } catch (_) {
    // Never let an interop hiccup block a legitimate launch.
    return true;
  }
}

void releaseWebLock(String name) {
  final c = _held.remove(name);
  if (c != null && !c.isCompleted) c.complete();
}
