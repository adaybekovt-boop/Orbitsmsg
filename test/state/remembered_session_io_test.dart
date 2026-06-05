// Native "Remember me" (remembered_session_io) — unit tests over a fake secret
// store, since the OS secure-storage plugin isn't available under `flutter
// test`. Locks in the desktop/native contract the auth bootstrap relies on:
//   • isRememberSupported reflects the backend's availability;
//   • persist stores ONLY the 32-byte KEK as base64 — nothing else, never a
//     password — and refuses anything that isn't exactly 32 bytes;
//   • load round-trips the KEK and forgets a corrupt / wrong-length value;
//   • clear forgets it; persist/load no-op when the backend is unavailable.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/state/remembered_session_io.dart' as remembered;

/// In-memory stand-in for the OS-backed secret store.
class _FakeStore implements remembered.RememberedKekStore {
  bool isAvailable = true;
  String? value;
  int writes = 0;
  int deletes = 0;

  @override
  Future<bool> available() async => isAvailable;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async {
    writes++;
    value = v;
  }

  @override
  Future<void> delete() async {
    deletes++;
    value = null;
  }
}

void main() {
  late _FakeStore store;

  final kek =
      Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 1) & 0xff));

  setUp(() {
    store = _FakeStore();
    remembered.debugRememberedKekStore = store;
  });

  tearDown(() {
    remembered.debugRememberedKekStore = null; // restore the OS-backed store
  });

  test('isRememberSupported reflects the backend availability', () async {
    store.isAvailable = true;
    expect(await remembered.isRememberSupported(), isTrue);
    store.isAvailable = false;
    expect(await remembered.isRememberSupported(), isFalse);
  });

  test('persist stores ONLY the 32-byte KEK as base64 (no password)', () async {
    await remembered.persistKek(kek);
    expect(store.writes, 1);
    expect(store.value, base64Encode(kek));
    // Whatever we persisted decodes back to exactly the 32 KEK bytes.
    expect(base64Decode(store.value!), kek);
  });

  test('load round-trips the persisted KEK', () async {
    await remembered.persistKek(kek);
    final loaded = await remembered.loadKek();
    expect(loaded, isNotNull);
    expect(loaded, kek);
  });

  test('persist is a no-op when the backend is unavailable', () async {
    store.isAvailable = false;
    await remembered.persistKek(kek);
    expect(store.writes, 0);
    expect(store.value, isNull);
  });

  test('persist refuses a KEK that is not exactly 32 bytes', () async {
    await remembered.persistKek(Uint8List.fromList(List<int>.filled(16, 1)));
    await remembered.persistKek(Uint8List.fromList(List<int>.filled(48, 2)));
    expect(store.writes, 0);
  });

  test('load forgets a wrong-length stored value and returns null', () async {
    store.value = base64Encode(Uint8List.fromList(List<int>.filled(16, 9)));
    final loaded = await remembered.loadKek();
    expect(loaded, isNull);
    expect(store.deletes, 1, reason: 'a corrupt entry must be cleared');
    expect(store.value, isNull);
  });

  test('load forgets a malformed (non-base64) stored value', () async {
    store.value = '!!!!not-base64';
    final loaded = await remembered.loadKek();
    expect(loaded, isNull);
    expect(store.deletes, 1);
  });

  test('load returns null (and does not delete) when nothing is stored',
      () async {
    final loaded = await remembered.loadKek();
    expect(loaded, isNull);
    expect(store.deletes, 0);
  });

  test('load returns null without touching the store when unavailable',
      () async {
    store
      ..value = base64Encode(kek)
      ..isAvailable = false;
    expect(await remembered.loadKek(), isNull);
    expect(store.deletes, 0);
  });

  test('clear forgets the stored KEK', () async {
    await remembered.persistKek(kek);
    await remembered.clearRememberedKek();
    expect(store.deletes, 1);
    expect(store.value, isNull);
    expect(await remembered.loadKek(), isNull);
  });
}
