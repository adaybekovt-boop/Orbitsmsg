// Round 5 C.1 — heavy attachment codecs must not block the UI isolate.
//
// Behavioral check: while a ~10 MiB base64 encode runs, a heartbeat timer on
// the MAIN isolate must keep ticking within a sane latency budget. Pre-fix,
// base64Encode(10 MiB) blocked the event loop for the whole conversion and
// heartbeats piled up behind it.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/utils/heavy_codec.dart';

void main() {
  test('b64EncodeHeavy keeps the main isolate responsive on a ~48 MiB input',
      () async {
    // 48 MiB encodes inline in ~130ms+ (measured on this machine) — enough
    // for the event-loop block to be observable. Offloaded, timer gaps stay
    // at scheduler-jitter level.
    final payload = Uint8List.fromList(
      List<int>.generate(48 * 1024 * 1024, (i) => i & 0xff),
    );

    var ticks = 0;
    var worstGapMs = 0;
    var last = DateTime.now();
    final timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      final now = DateTime.now();
      final gap = now.difference(last).inMilliseconds;
      if (gap > worstGapMs) worstGapMs = gap;
      last = now;
      ticks++;
    });

    final encoded = await b64EncodeHeavy(payload);
    timer.cancel();

    expect(worstGapMs, lessThan(100),
        reason:
            'encode must run OFF the main isolate — a $worstGapMs ms event '
            'loop stall means it blocked the UI thread');
    expect(ticks, greaterThan(10));
    // Sanity: the result is real base64 of the payload.
    expect(encoded.length, ((payload.length + 2) ~/ 3) * 4);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('b64DecodeHeavy round-trips a big payload off the UI thread',
      () async {
    final payload = Uint8List.fromList(
      List<int>.generate(10 * 1024 * 1024, (i) => (i * 7) & 0xff),
    );
    final encoded = await b64EncodeHeavy(payload);
    final decoded = await b64DecodeHeavy(encoded);
    expect(decoded, orderedEquals(payload));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('small payloads stay inline (no isolate overhead)', () async {
    final small = Uint8List.fromList([1, 2, 3, 4, 5]);
    final encoded = await b64EncodeHeavy(small);
    expect(encoded, base64Of(small));
    final decoded = await b64DecodeHeavy(encoded);
    expect(decoded, orderedEquals(small));
  });
}

String base64Of(List<int> b) {
  // Local reference implementation to avoid importing dart:convert twice in
  // assertions — alphabet correctness is covered by round-trip tests above.
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final out = StringBuffer();
  for (var i = 0; i < b.length; i += 3) {
    final n1 = b[i];
    final n2 = i + 1 < b.length ? b[i + 1] : null;
    final n3 = i + 2 < b.length ? b[i + 2] : null;
    out.write(chars[n1 >> 2]);
    if (n2 == null) {
      out.write('${chars[(n1 & 3) << 4]}==');
      break;
    }
    out.write(chars[((n1 & 3) << 4) | (n2 >> 4)]);
    if (n3 == null) {
      out.write('${chars[(n2 & 15) << 2]}=');
      break;
    }
    out.write(chars[((n2 & 15) << 2) | (n3 >> 6)]);
    out.write(chars[n3 & 63]);
  }
  return out.toString();
}
