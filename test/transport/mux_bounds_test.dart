import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/mux_frames.dart';
import 'package:orbits_flutter/transport/transport_api.dart';

void main() {
  test('frame exactly at the limit decodes', () {
    final payload = Uint8List(kMaxMuxFrameBytes);
    final encoded = encodeMuxFrame(TransportChannel.message, payload);
    final frames = MuxDecoder().add(encoded);
    expect(frames, hasLength(1));
    expect(frames.single.$2.length, kMaxMuxFrameBytes);
  });

  test('frame one byte over the limit is rejected', () {
    expect(
      () => encodeMuxFrame(TransportChannel.message, Uint8List(kMaxMuxFrameBytes + 1)),
      throwsFormatException,
    );
    final header = ByteData(7);
    header.setUint8(0, kMuxVersion);
    header.setUint8(1, channelId(TransportChannel.message));
    header.setUint32(3, kMaxMuxFrameBytes + 1);
    expect(() => MuxDecoder().add(header.buffer.asUint8List()), throwsFormatException);
  });

  test('0xffffffff length is rejected after a complete header', () {
    final header = ByteData(7);
    header.setUint8(0, kMuxVersion);
    header.setUint8(1, channelId(TransportChannel.message));
    header.setUint32(3, 0xffffffff);
    expect(() => MuxDecoder().add(header.buffer.asUint8List()), throwsFormatException);
  });

  test('header arriving in parts waits, then decodes', () {
    final encoded = encodeMuxFrame(TransportChannel.message, utf8ish('hi'));
    final decoder = MuxDecoder();
    expect(decoder.add(encoded.sublist(0, 3)), isEmpty);
    expect(decoder.add(encoded.sublist(3, 7)), isEmpty);
    final frames = decoder.add(encoded.sublist(7));
    expect(frames, hasLength(1));
    expect(frames.single.$2, utf8ish('hi'));
  });

  test('several valid frames in one buffer decode in order', () {
    final a = encodeMuxFrame(TransportChannel.control, utf8ish('one'));
    final b = encodeMuxFrame(TransportChannel.message, utf8ish('two'));
    final frames = MuxDecoder().add(Uint8List.fromList([...a, ...b]));
    expect(frames.map((f) => String.fromCharCodes(f.$2)).toList(), ['one', 'two']);
  });

  test('oversized accumulated buffer is rejected and decoder resets', () {
    final decoder = MuxDecoder();
    expect(
      () => decoder.add(Uint8List(kMaxMuxBufferBytes + 1)),
      throwsFormatException,
    );
    final encoded = encodeMuxFrame(TransportChannel.message, utf8ish('ok'));
    expect(decoder.add(encoded), hasLength(1));
  });

  test('close clears decoder state', () {
    final decoder = MuxDecoder();
    decoder.add(encodeMuxFrame(TransportChannel.message, utf8ish('x')).sublist(0, 3));
    decoder.close();
    expect(decoder.closed, isTrue);
    expect(() => decoder.add(utf8ish('more')), throwsFormatException);
  });
}

Uint8List utf8ish(String value) => Uint8List.fromList(value.codeUnits);
