// Phase 2.1: transactional ratchet decrypt (clone → AES-GCM → adopt).
//
// These fail on origin/main: ratchetDecrypt removed skipped keys and advanced
// DH / Nr / recvCk before AES-GCM, so a tampered envelope burned state.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final repoRoot = Directory.current;

  String read(String rel) {
    final f = File(
      '${repoRoot.path}${Platform.pathSeparator}'
      '${rel.replaceAll('/', Platform.pathSeparator)}',
    );
    expect(f.existsSync(), isTrue, reason: '$rel is missing');
    return f.readAsStringSync();
  }

  test('ratchetDecrypt clones, decrypts, and adopts only on success', () {
    final src = read('lib/core/double_ratchet.dart');
    expect(src, contains('final work = state.clone()'));
    expect(src, contains('state.adopt(work)'));
    expect(src, contains('_ratchetDecryptInPlace'));
    // Must peek the skipped MK; the old code did remove-then-decrypt.
    expect(
      src,
      isNot(contains('final cachedMk = state.skipped.remove(skKey)')),
    );
    expect(src, contains('final cachedMk = state.skipped[skKey]'));
  });

  test('RatchetState.clone deep-copies skipped keys and chain material', () {
    final src = read('lib/core/double_ratchet.dart');
    expect(src, contains('Uint8List.fromList(e.value)'));
    expect(src, contains('Uint8List.fromList(recvCk!)'));
    expect(src, contains('..clear()'));
    expect(src, contains('..addAll(other.skipped)'));
  });
}
