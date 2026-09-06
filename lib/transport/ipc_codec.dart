// Versioned Flutter ↔ Bare IPC. See docs/migration/pwa-versioning-metrics.md.
//
// Frame:
//   magic u32be = 0x4F545031 ("OTP1")
//   version u8 = 1
//   type u8
//   payload_len u32be
//   payload (UTF-8 JSON; optional binary tail is inside JSON as path refs)

import 'dart:convert';
import 'dart:typed_data';

const int kOrbitsIpcMagic = 0x4F545031;
const int kOrbitsIpcVersion = 1;
const String kOrbitsBareIpcInfo = 'orbits-bare-ipc-v1';
const int kOrbitsIpcMaxPayloadBytes = 256 * 1024;

const int kIpcRequest = 1;
const int kIpcResponse = 2;
const int kIpcEvent = 3;

class OrbitsIpcMessage {
  const OrbitsIpcMessage({required this.type, required this.body});

  final int type;
  final Map<String, Object?> body;
}

class OrbitsIpcCodec {
  final BytesBuilder _buf = BytesBuilder(copy: false);

  static Uint8List encode(OrbitsIpcMessage message) {
    final payload = utf8.encode(jsonEncode(message.body));
    if (payload.length > kOrbitsIpcMaxPayloadBytes) {
      throw FormatException('IPC payload exceeds orbits-bare-ipc-v1 cap');
    }
    final out = BytesBuilder(copy: false);
    final header = ByteData(10);
    header.setUint32(0, kOrbitsIpcMagic);
    header.setUint8(4, kOrbitsIpcVersion);
    header.setUint8(5, message.type);
    header.setUint32(6, payload.length);
    out.add(header.buffer.asUint8List());
    out.add(payload);
    return out.toBytes();
  }

  List<OrbitsIpcMessage> add(List<int> chunk) {
    _buf.add(chunk);
    final data = _buf.takeBytes();
    final view = ByteData.sublistView(Uint8List.fromList(data));
    final out = <OrbitsIpcMessage>[];
    var offset = 0;
    while (offset + 10 <= data.length) {
      final magic = view.getUint32(offset);
      if (magic != kOrbitsIpcMagic) {
        throw FormatException('bad IPC magic: 0x${magic.toRadixString(16)}');
      }
      final version = view.getUint8(offset + 4);
      if (version != kOrbitsIpcVersion) {
        throw FormatException('unsupported IPC version $version');
      }
      final type = view.getUint8(offset + 5);
      final len = view.getUint32(offset + 6);
      if (len > kOrbitsIpcMaxPayloadBytes) {
        throw FormatException('IPC payload exceeds orbits-bare-ipc-v1 cap');
      }
      if (offset + 10 + len > data.length) break;
      final payload = data.sublist(offset + 10, offset + 10 + len);
      final decoded = jsonDecode(utf8.decode(payload));
      if (decoded is! Map) {
        throw FormatException('IPC payload must be a JSON object');
      }
      out.add(
        OrbitsIpcMessage(type: type, body: decoded.cast<String, Object?>()),
      );
      offset += 10 + len;
    }
    if (offset < data.length) {
      if (data.length - offset >= 4) {
        final magic = view.getUint32(offset);
        if (magic != kOrbitsIpcMagic) {
          throw FormatException('bad IPC magic: 0x${magic.toRadixString(16)}');
        }
      }
      _buf.add(data.sublist(offset));
    }
    return out;
  }
}
