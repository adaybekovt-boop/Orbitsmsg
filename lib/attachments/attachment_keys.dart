// Per-transfer 256-bit attachment keys. Never derived from a discovery
// secret. The key itself is delivered inside an already-authenticated
// ratchet / reliable message.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../peer/helpers.dart';

const String kAttachmentKeyMessageType = 'attachment-key-v1';
const int kAttachmentKeyBytes = 32;

class AttachmentKeyStore {
  final Map<String, Uint8List> _keys = <String, Uint8List>{};

  String _id(String peerId, String transferId) =>
      '${normalizePeerId(peerId)}|$transferId';

  Uint8List issue(String peerId, String transferId) {
    final key = _randomKey();
    _keys[_id(peerId, transferId)] = key;
    return key;
  }

  void accept(String peerId, String transferId, List<int> key) {
    if (key.length != kAttachmentKeyBytes) {
      throw StateError('attachment key must be 32 bytes');
    }
    _keys[_id(peerId, transferId)] = Uint8List.fromList(key);
  }

  List<int> require(String peerId, String transferId) {
    final key = _keys[_id(peerId, transferId)];
    if (key == null || key.isEmpty) {
      throw StateError('attachment key missing for $transferId');
    }
    return key;
  }

  bool has(String peerId, String transferId) =>
      _keys.containsKey(_id(peerId, transferId));

  void forgetPeer(String peerId) {
    final prefix = '${normalizePeerId(peerId)}|';
    _keys.removeWhere((key, _) => key.startsWith(prefix));
  }

  void clear() => _keys.clear();

  Uint8List _randomKey() {
    final rng = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(kAttachmentKeyBytes, (_) => rng.nextInt(256)),
    );
  }
}

Map<String, Object?> attachmentKeyMessage({
  required String transferId,
  required List<int> key,
  required String sender,
  required String receiver,
  required String name,
  required int size,
  required String sha256hex,
  int version = 1,
}) {
  return <String, Object?>{
    'type': kAttachmentKeyMessageType,
    'version': version,
    'transferId': transferId,
    'sender': sender,
    'receiver': receiver,
    'name': name,
    'size': size,
    'sha256': sha256hex,
    'keyB64': base64Encode(key),
  };
}

bool tryAcceptAttachmentKeyMessage(
  AttachmentKeyStore store,
  String fromPeer,
  Object? message,
) {
  if (message is! Map) return false;
  final body = Map<String, Object?>.from(message);
  if (body['type'] != kAttachmentKeyMessageType) return false;
  final transferId = body['transferId'] as String? ?? '';
  final raw = body['keyB64'] as String? ?? '';
  final sender = body['sender'] as String? ?? '';
  if (transferId.isEmpty || raw.isEmpty) return false;
  if (sender.isNotEmpty &&
      normalizePeerId(sender) != normalizePeerId(fromPeer)) {
    return false;
  }
  store.accept(fromPeer, transferId, base64Decode(raw));
  return true;
}
