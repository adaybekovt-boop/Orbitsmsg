// Binary multiplex on a Hyperswarm (or loopback) stream.
// Transport only — no chat / ratchet / rooms.

import 'dart:convert';
import 'dart:typed_data';

import 'transport_api.dart';

const String kOrbitsTransportFrameInfo = 'orbits-transport-v1';
const int kMuxVersion = 1;
const int kFileChunkSize = 64 * 1024;
const int kMaxMuxFrameBytes = 256 * 1024;
const int kMaxMuxBufferBytes = 512 * 1024;

int channelId(TransportChannel channel) => channel.index;

TransportChannel? channelFromId(int id) {
  if (id < 0 || id >= TransportChannel.values.length) return null;
  return TransportChannel.values[id];
}

/// mux frame: version u8 | channel u8 | flags u8 | length u32be | payload
Uint8List encodeMuxFrame(TransportChannel channel, List<int> payload) {
  if (payload.length > kMaxMuxFrameBytes) {
    throw FormatException('mux frame too large');
  }
  final header = ByteData(7);
  header.setUint8(0, kMuxVersion);
  header.setUint8(1, channelId(channel));
  header.setUint8(2, 0);
  header.setUint32(3, payload.length);
  final out = BytesBuilder(copy: false);
  out.add(header.buffer.asUint8List());
  out.add(payload);
  return out.toBytes();
}

class MuxDecoder {
  final BytesBuilder _buf = BytesBuilder(copy: false);
  bool closed = false;

  void reset() {
    _buf.clear();
  }

  void close() {
    closed = true;
    reset();
  }

  List<(TransportChannel, Uint8List)> add(List<int> chunk) {
    if (closed) {
      throw FormatException('mux decoder closed');
    }
    if (_buf.length + chunk.length > kMaxMuxBufferBytes) {
      reset();
      throw FormatException('mux buffer exceeded');
    }
    _buf.add(chunk);
    final data = _buf.takeBytes();
    final view = ByteData.sublistView(Uint8List.fromList(data));
    final out = <(TransportChannel, Uint8List)>[];
    var offset = 0;
    while (offset + 7 <= data.length) {
      final version = view.getUint8(offset);
      if (version != kMuxVersion) {
        reset();
        throw FormatException('bad mux version $version');
      }
      final channel = channelFromId(view.getUint8(offset + 1));
      if (channel == null) {
        reset();
        throw FormatException('bad mux channel');
      }
      final len = view.getUint32(offset + 3);
      if (len > kMaxMuxFrameBytes) {
        reset();
        throw FormatException('mux frame too large');
      }
      if (offset + 7 + len > data.length) break;
      out.add((
        channel,
        Uint8List.fromList(data.sublist(offset + 7, offset + 7 + len)),
      ));
      offset += 7 + len;
    }
    if (offset < data.length) {
      _buf.add(data.sublist(offset));
    }
    return out;
  }
}

Uint8List jsonPayload(Map<String, Object?> body) =>
    Uint8List.fromList(utf8.encode(jsonEncode(body)));

Map<String, Object?> decodeJsonPayload(List<int> bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map) {
    throw FormatException('mux JSON payload must be an object');
  }
  return decoded.cast<String, Object?>();
}
