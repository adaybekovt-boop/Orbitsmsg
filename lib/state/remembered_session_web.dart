// Web "Remember me": persist the vault KEK across browser restarts WITHOUT
// ever writing it to disk in the clear.
//
// How it stays secure:
//   • A 256-bit AES-GCM "wrapping key" is generated with `extractable: false`
//     and stored DIRECTLY in IndexedDB. Non-extractable CryptoKey objects are
//     structured-cloneable but their raw bytes are NEVER exposed to JS — the
//     browser keeps them opaque. So even with full DevTools/storage access an
//     attacker cannot read the wrapping key.
//   • The 32-byte vault KEK is AES-GCM-encrypted under that wrapping key and
//     the ciphertext (+ a random 12-byte IV) is what we persist. The KEK
//     plaintext never touches storage.
//
// The auth factor for auto-unlock is therefore "possession of this origin's
// non-extractable key in this browser profile" — equivalent to a long-lived
// "stay signed in" cookie. Clearing site data / the browser profile logs the
// user out (expected). `crypto.subtle` requires a secure context (HTTPS or
// localhost); on plain http it's undefined and `isRememberSupported` returns
// false, so the feature silently disables and the password screen stays.
//
// Interop uses raw `dart:js_interop` + hand-rolled extension types, matching
// the repo convention (see `lib/peer/web_lock_web.dart`). Every public entry
// is wrapped in try/catch and degrades to false/null — an interop hiccup must
// never block a legitimate login.

import 'dart:async';
import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';

const String _dbName = 'orbits_remember';
const String _store = 'kv';
const String _kWrapKey = 'wrapKey';
const String _kIv = 'iv';
const String _kCt = 'ct';

final Random _ivRng = Random.secure();

// ─── JS bindings ─────────────────────────────────────────────────────────

@JS('window')
external _Window get _window;

extension type _Window._(JSObject _) implements JSObject {
  external _Crypto? get crypto;
  external _IDBFactory? get indexedDB;
}

extension type _Crypto._(JSObject _) implements JSObject {
  external _SubtleCrypto? get subtle;
}

extension type _SubtleCrypto._(JSObject _) implements JSObject {
  external JSPromise<JSObject> generateKey(
      JSObject algorithm, bool extractable, JSArray<JSString> keyUsages);
  external JSPromise<JSArrayBuffer> encrypt(
      JSObject algorithm, JSObject key, JSAny data);
  external JSPromise<JSArrayBuffer> decrypt(
      JSObject algorithm, JSObject key, JSAny data);
}

extension type _AesKeyGenParams._(JSObject _) implements JSObject {
  external factory _AesKeyGenParams({String name, int length});
}

extension type _AesGcmParams._(JSObject _) implements JSObject {
  external factory _AesGcmParams({String name, JSAny iv});
}

extension type _IDBFactory._(JSObject _) implements JSObject {
  external _IDBOpenDBRequest open(String name, int version);
  external _IDBOpenDBRequest deleteDatabase(String name);
}

extension type _IDBOpenDBRequest._(JSObject _) implements JSObject {
  external JSObject? get result;
  external set onsuccess(JSFunction f);
  external set onerror(JSFunction f);
  external set onupgradeneeded(JSFunction f);
}

extension type _IDBDatabase._(JSObject _) implements JSObject {
  external _IDBTransaction transaction(JSAny storeNames, String mode);
  external _IDBObjectStore createObjectStore(String name);
  external _DOMStringList get objectStoreNames;
  external void close();
}

extension type _DOMStringList._(JSObject _) implements JSObject {
  external bool contains(String s);
}

extension type _IDBTransaction._(JSObject _) implements JSObject {
  external _IDBObjectStore objectStore(String name);
}

extension type _IDBObjectStore._(JSObject _) implements JSObject {
  external _IDBRequest get(JSAny key);
  external _IDBRequest put(JSAny? value, JSAny key);
}

extension type _IDBRequest._(JSObject _) implements JSObject {
  external JSAny? get result;
  external set onsuccess(JSFunction f);
  external set onerror(JSFunction f);
}

// ─── Small async bridges (IndexedDB is event-based, not promise-based) ─────

Future<_IDBDatabase> _openDb(_IDBFactory factory) {
  final c = Completer<_IDBDatabase>();
  final req = factory.open(_dbName, 1);
  req.onupgradeneeded = ((JSObject _) {
    final db = req.result as _IDBDatabase;
    if (!db.objectStoreNames.contains(_store)) {
      db.createObjectStore(_store);
    }
  }).toJS;
  req.onsuccess = ((JSObject _) {
    if (!c.isCompleted) c.complete(req.result as _IDBDatabase);
  }).toJS;
  req.onerror = ((JSObject _) {
    if (!c.isCompleted) c.completeError(StateError('idb open failed'));
  }).toJS;
  return c.future;
}

Future<JSAny?> _reqValue(_IDBRequest req) {
  final c = Completer<JSAny?>();
  req.onsuccess = ((JSObject _) {
    if (!c.isCompleted) c.complete(req.result);
  }).toJS;
  req.onerror = ((JSObject _) {
    if (!c.isCompleted) c.completeError(StateError('idb request failed'));
  }).toJS;
  return c.future;
}

Future<JSAny?> _get(_IDBDatabase db, String key) {
  final store = db.transaction(_store.toJS, 'readonly').objectStore(_store);
  return _reqValue(store.get(key.toJS));
}

Future<void> _put(_IDBDatabase db, String key, JSAny? value) async {
  final store = db.transaction(_store.toJS, 'readwrite').objectStore(_store);
  await _reqValue(store.put(value, key.toJS));
}

Uint8List _randomIv() {
  final out = Uint8List(12);
  for (var i = 0; i < out.length; i++) {
    out[i] = _ivRng.nextInt(256);
  }
  return out;
}

// ─── Public API ────────────────────────────────────────────────────────────

Future<bool> isRememberSupported() async {
  try {
    final crypto = _window.crypto;
    // `subtle` is undefined outside a secure context (plain http) — this is
    // also where we detect that and disable the feature.
    if (crypto == null || crypto.subtle == null) return false;
    if (_window.indexedDB == null) return false;
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> persistKek(List<int> kek) async {
  try {
    final subtle = _window.crypto?.subtle;
    final factory = _window.indexedDB;
    if (subtle == null || factory == null) return;

    final db = await _openDb(factory);
    try {
      // Reuse the wrapping key if one already exists; otherwise mint a fresh
      // non-extractable AES-GCM key and persist it (opaque to JS forever).
      JSObject wrapKey;
      final existing = await _get(db, _kWrapKey);
      if (existing == null) {
        wrapKey = await subtle
            .generateKey(
              _AesKeyGenParams(name: 'AES-GCM', length: 256),
              false,
              <JSString>['encrypt'.toJS, 'decrypt'.toJS].toJS,
            )
            .toDart;
        await _put(db, _kWrapKey, wrapKey);
      } else {
        wrapKey = existing as JSObject;
      }

      final iv = _randomIv();
      final ct = await subtle
          .encrypt(
            _AesGcmParams(name: 'AES-GCM', iv: iv.toJS),
            wrapKey,
            Uint8List.fromList(kek).toJS,
          )
          .toDart;

      await _put(db, _kIv, iv.toJS);
      await _put(db, _kCt, ct);
    } finally {
      db.close();
    }
  } catch (_) {
    // Best-effort — failing to remember must never break a successful login.
  }
}

Future<Uint8List?> loadKek() async {
  try {
    final subtle = _window.crypto?.subtle;
    final factory = _window.indexedDB;
    if (subtle == null || factory == null) return null;

    final db = await _openDb(factory);
    try {
      final keyAny = await _get(db, _kWrapKey);
      final ivAny = await _get(db, _kIv);
      final ctAny = await _get(db, _kCt);
      if (keyAny == null || ivAny == null || ctAny == null) return null;

      // ivAny / ctAny come back as structured-clone copies (a Uint8Array and
      // an ArrayBuffer) — hand them straight to decrypt as BufferSources.
      final pt = await subtle
          .decrypt(
            _AesGcmParams(name: 'AES-GCM', iv: ivAny),
            keyAny as JSObject,
            ctAny,
          )
          .toDart;
      return pt.toDart.asUint8List();
    } finally {
      db.close();
    }
  } catch (_) {
    return null;
  }
}

Future<void> clearRememberedKek() async {
  try {
    final factory = _window.indexedDB;
    if (factory == null) return;
    final c = Completer<void>();
    final req = factory.deleteDatabase(_dbName);
    // Resolve on success OR error — a delete failure on an absent DB is fine,
    // and we never want to hang logout on this.
    req.onsuccess = ((JSObject _) {
      if (!c.isCompleted) c.complete();
    }).toJS;
    req.onerror = ((JSObject _) {
      if (!c.isCompleted) c.complete();
    }).toJS;
    await c.future;
  } catch (_) {}
}
