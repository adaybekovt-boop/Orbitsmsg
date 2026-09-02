// Live dual-stack: same X3DH/ratchet bytes, different carrier.
// Default rollout stays PeerJS. Native path requires an explicit
// discovery secret — never HASH(peerId).

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

import '../attachments/resumable_blob.dart';
import '../calls/hyperswarm_signaling.dart';
import '../core/feature_flags.dart';
import '../core/wire_crypto.dart';
import '../devices/device_registry.dart';
import '../mailbox/blind_store.dart';
import '../mailbox/mailbox_protocol.dart';
import '../mailbox/mailbox_pump.dart';
import '../mailbox/storage_peer_client.dart';
import '../peer/helpers.dart';
import '../replication/file_journal.dart';
import '../replication/hypercore_store.dart';
import '../replication/memory_journal.dart';
import '../transport/replication_schema.dart';
import 'discovery_secret_store.dart';
import 'hello_capabilities.dart';
import 'mux_frames.dart';
import 'signed_capabilities.dart';
import 'transport_api.dart';

typedef PacketSink = Future<void> Function(String peerId, Object? data);
typedef BlockedCheck = bool Function(String peerId);

class DualStackBridge {
  DualStackBridge({
    required this.transport,
    required this.journal,
    required this.selfPeerId,
    required this.selfDeviceId,
    required this.onPacket,
    required this.isBlocked,
    DiscoverySecretStore? secrets,
    this.durableJournal,
    this.mailbox,
    this.mailboxToken,
    this.mailboxWriterKey,
    this.storagePeer,
    this.mailboxCapability,
    this.localCapabilities,
    this.devices,
    HypercoreLocalStore? hypercore,
  }) : secrets = secrets ?? discoverySecretStore,
       hypercore = hypercore ?? HypercoreLocalStore(selfDeviceId);

  final OrbitsTransport transport;
  final MemoryJournal journal;
  final String Function() selfPeerId;
  final String selfDeviceId;
  PacketSink onPacket;
  final BlockedCheck isBlocked;
  final DiscoverySecretStore secrets;
  final FileJournal? durableJournal;
  final BlindMailboxStore? mailbox;
  final String? mailboxToken;
  final String? mailboxWriterKey;
  final StoragePeerClient? storagePeer;
  final SignedMailboxCapability? mailboxCapability;
  final CapabilityRecord? localCapabilities;
  final DeviceRegistry? devices;
  final HypercoreLocalStore hypercore;
  final MailboxPump _mailboxPump = MailboxPump();
  void Function(String peerId, Object packet)? onDrop;

  final Set<String> connected = <String>{};
  final List<CapabilityRecord> remoteCapabilities = <CapabilityRecord>[];
  StreamSubscription<TransportEvent>? _sub;
  void Function(CallSignal signal, String from)? onCallSignal;
  void Function(String peerId, bool connected)? onPresence;

  void attach() {
    _sub ??= transport.events.listen(_onEvent);
  }

  Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
    connected.clear();
  }

  bool get nativeEnabled => isHyperswarmTransportEnabled();

  bool isNativeConnected(String peerId) =>
      connected.contains(normalizePeerId(peerId));

  bool canUseNative(String peerId) {
    if (!nativeEnabled) return false;
    if (secrets.get(peerId) == null) return false;
    return isNativeConnected(peerId);
  }

  Future<void> dial(String peerId) async {
    if (!nativeEnabled) return;
    final secret = secrets.get(peerId);
    if (secret == null) return;
    await transport.connect(
      PeerDescriptor(peerId: normalizePeerId(peerId), discoverySecret: secret),
    );
  }

  Future<bool> sendEncrypted(String peerId, Object? msg) async {
    final targets =
        devices?.transportTargets(peerId) ?? <String>{normalizePeerId(peerId)};
    if (targets.length > 1) {
      var any = false;
      for (final target in targets) {
        if (await _sendEncryptedOne(target, msg)) any = true;
      }
      return any;
    }
    return _sendEncryptedOne(peerId, msg);
  }

  Future<bool> _sendEncryptedOne(String peerId, Object? msg) async {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm)) return false;
    if (!isNativeConnected(norm)) {
      if (msg is Map &&
          (msg['type'] == 'wireHello' || msg['type'] == 'wireRekey')) {
        return enqueueMailbox(jsonPayload(Map<String, Object?>.from(msg)));
      }
      if (!isWireReady(norm)) return false;
      final queued = await encryptWirePayload(norm, msg);
      return enqueueMailbox(utf8.encode(queued));
    }
    if (msg is Map &&
        (msg['type'] == 'wireHello' || msg['type'] == 'wireRekey')) {
      await transport.send(
        norm,
        TransportChannel.control,
        jsonPayload(Map<String, Object?>.from(msg)),
      );
      return true;
    }
    if (!isWireReady(norm)) {
      await waitForWireReady(norm, timeout: const Duration(seconds: 8));
    }
    final wire = await encryptWirePayload(norm, msg);
    await transport.send(norm, TransportChannel.message, utf8.encode(wire));
    _appendEnvelope(norm, utf8.encode(wire));
    return true;
  }

  Future<bool> enqueueMailbox(
    List<int> encryptedEnvelope, {
    String? envelopeId,
  }) async {
    if (storagePeer != null && mailboxCapability != null) {
      return depositMailboxRemote(encryptedEnvelope, envelopeId: envelopeId);
    }
    return depositMailbox(encryptedEnvelope, envelopeId: envelopeId);
  }

  /// Offline deposit: encrypted bytes only. Used when the recipient is not
  /// currently connected. The storage peer never sees keys.
  bool depositMailbox(List<int> encryptedEnvelope, {String? envelopeId}) {
    if (storagePeer != null && mailboxCapability != null) {
      unawaited(
        depositMailboxRemote(encryptedEnvelope, envelopeId: envelopeId),
      );
      return true;
    }
    final store = mailbox;
    final token = mailboxToken;
    final writer = mailboxWriterKey;
    if (store == null || token == null || writer == null) return false;
    _mailboxPump.deposit(
      store: store,
      token: token,
      writerKey: writer,
      encryptedEnvelope: encryptedEnvelope,
      envelopeId: envelopeId ?? _stableEnvelopeId(encryptedEnvelope),
    );
    return true;
  }

  Future<bool> depositMailboxRemote(
    List<int> encryptedEnvelope, {
    String? envelopeId,
  }) async {
    final client = storagePeer;
    final cap = mailboxCapability;
    if (client == null || cap == null) return false;
    await _mailboxPump.depositRemote(
      client: client,
      capability: cap,
      envelopeId: envelopeId ?? _stableEnvelopeId(encryptedEnvelope),
      encryptedEnvelope: encryptedEnvelope,
    );
    return true;
  }

  String _stableEnvelopeId(List<int> encryptedEnvelope) {
    return sha256.convert([
      ...utf8.encode(selfDeviceId),
      ...encryptedEnvelope,
    ]).toString();
  }

  /// Authorization log: revoked writers are ignored on the next fan-out.
  void revokeDevice(String deviceId) {
    devices?.revoke(deviceId);
    final record = journal.append(
      ReplicationEventKind.deviceRevoked,
      <String, Object?>{
        'deviceId': deviceId,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
    unawaited(durableJournal?.append(record));
    hypercore.append(record);
  }

  void authorizeDevice(AuthorizedDevice device) {
    devices?.authorize(device);
    final record = journal.append(
      ReplicationEventKind.deviceAuthorized,
      <String, Object?>{
        'deviceId': device.deviceId,
        'createdAt': device.createdAt,
      },
    );
    unawaited(durableJournal?.append(record));
    hypercore.append(record);
  }

  Future<int> drainMailbox({String? fromPeerId}) async {
    if (storagePeer != null && mailboxCapability != null) {
      return drainMailboxRemote(fromPeerId: fromPeerId);
    }
    final store = mailbox;
    final token = mailboxToken;
    final writer = mailboxWriterKey;
    if (store == null || token == null || writer == null) return 0;
    final blocks = _mailboxPump.collect(
      store: store,
      token: token,
      writerKey: writer,
    );
    final from = normalizePeerId(fromPeerId ?? writer);
    var projected = 0;
    for (final block in blocks) {
      final id = block.envelopeId ?? _stableEnvelopeId(block.bytes);
      if (!_mailboxPump.markProjected(id)) continue;
      _appendEnvelope(from, block.bytes);
      final text = utf8.decode(block.bytes);
      await onPacket(
        from,
        isWireCiphertext(text) ? text : decodeJsonPayload(block.bytes),
      );
      projected += 1;
    }
    return projected;
  }

  Future<int> drainMailboxRemote({String? fromPeerId}) async {
    final client = storagePeer;
    final cap = mailboxCapability;
    if (client == null || cap == null) return 0;
    final blocks = await _mailboxPump.collectRemote(
      client: client,
      capability: cap,
    );
    final from = normalizePeerId(fromPeerId ?? cap.mailboxId);
    var projected = 0;
    for (final block in blocks) {
      final id = block.envelopeId ?? _stableEnvelopeId(block.bytes);
      if (!_mailboxPump.markProjected(id)) continue;
      _appendEnvelope(from, block.bytes);
      final text = utf8.decode(block.bytes);
      await onPacket(
        from,
        isWireCiphertext(text) ? text : decodeJsonPayload(block.bytes),
      );
      await _mailboxPump.acknowledgeRemote(
        client: client,
        capability: cap,
        envelopeId: id,
      );
      projected += 1;
    }
    return projected;
  }

  Future<void> sendAttachmentChunks(
    String peerId,
    List<int> plaintext,
    List<int> fileKey,
  ) async {
    final chunks = ResumableAttachment.chunk(plaintext, fileKey);
    for (final chunk in chunks) {
      await transport.send(
        normalizePeerId(peerId),
        TransportChannel.attachment,
        jsonPayload({
          'type': 'attach-chunk',
          'index': chunk.index,
          'offset': chunk.offset,
          'hash': chunk.hash,
          'b64': base64Encode(chunk.ciphertext),
        }),
      );
    }
  }

  Future<bool> sendEphemeral(String peerId, Object? msg) async {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm) || !isWireReady(norm)) return false;
    final wire = await encryptWirePayload(norm, msg);
    await transport.send(norm, TransportChannel.presence, utf8.encode(wire));
    return true;
  }

  bool sendRoomPacket(String peerId, Map<String, Object?> packet) {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm)) return false;
    unawaited(
      transport.send(norm, TransportChannel.control, jsonPayload(packet)),
    );
    return true;
  }

  Future<void> sendCallSignal(String peerId, CallSignal signal) {
    return transport.send(
      normalizePeerId(peerId),
      TransportChannel.call,
      jsonPayload(signal.toJson()),
    );
  }

  Future<bool> sendDrop(String peerId, Object packet) async {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm) || !isNativeConnected(norm)) return false;
    if (packet is Map) {
      await transport.send(
        norm,
        TransportChannel.attachment,
        jsonPayload(Map<String, Object?>.from(packet)),
      );
      return true;
    }
    if (packet is List<int>) {
      await transport.send(norm, TransportChannel.attachment, packet);
      return true;
    }
    return false;
  }

  void _appendEnvelope(String peerId, List<int> encrypted) {
    final id =
        '${DateTime.now().millisecondsSinceEpoch}-$peerId-${encrypted.length}';
    final record = journal.appendEnvelope(
      MessageEnvelopeCreated(
        eventId: id,
        conversationId: peerId,
        senderIdentity: selfPeerId(),
        senderDeviceId: selfDeviceId,
        logicalSequence: journal.length + 1,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        encryptedEnvelope: encrypted,
      ),
    );
    unawaited(durableJournal?.append(record));
    hypercore.append(record);
    if (isNativeConnected(peerId)) {
      unawaited(
        transport.send(
          peerId,
          TransportChannel.replication,
          jsonPayload(hypercore.toReplicationFrame(record)),
        ),
      );
    }
  }

  void _onEvent(TransportEvent event) {
    switch (event) {
      case TransportConnected(:final peerId):
        connected.add(normalizePeerId(peerId));
        onPresence?.call(peerId, true);
        final caps = localCapabilities;
        if (caps != null) {
          unawaited(
            transport.send(
              normalizePeerId(peerId),
              TransportChannel.control,
              jsonPayload({'type': 'capabilities', ...caps.toWire()}),
            ),
          );
        }
        for (final record in hypercore.blocks) {
          unawaited(
            transport.send(
              normalizePeerId(peerId),
              TransportChannel.replication,
              jsonPayload(hypercore.toReplicationFrame(record)),
            ),
          );
        }
      case TransportDisconnected(:final peerId):
        connected.remove(normalizePeerId(peerId));
        onPresence?.call(peerId, false);
      case TransportFrame(:final peerId, :final channel, :final bytes):
        _onFrame(peerId, channel, bytes);
      default:
        break;
    }
  }

  void _onFrame(String peerId, TransportChannel channel, List<int> bytes) {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm)) return;
    if (channel == TransportChannel.call) {
      try {
        onCallSignal?.call(CallSignal.fromJson(decodeJsonPayload(bytes)), norm);
      } catch (_) {}
      return;
    }
    if (channel == TransportChannel.attachment) {
      if (bytes.isNotEmpty && bytes[0] == 1) {
        onDrop?.call(norm, bytes);
        return;
      }
      try {
        onDrop?.call(norm, decodeJsonPayload(bytes));
      } catch (_) {}
      return;
    }
    if (channel == TransportChannel.replication) {
      try {
        hypercore.applyRemote(decodeJsonPayload(bytes));
      } catch (_) {}
      return;
    }
    Object? data;
    try {
      final text = utf8.decode(bytes);
      if (isWireCiphertext(text)) {
        data = text;
        _appendEnvelope(norm, bytes);
      } else {
        final decoded = decodeJsonPayload(bytes);
        data = decoded;
        if (decoded['type'] == 'capabilities' ||
            decoded['type'] == 'wireHello') {
          try {
            if (decoded['type'] == 'capabilities') {
              remoteCapabilities.add(CapabilityRecord.fromWire(decoded));
            }
            unawaited(rememberHelloCapabilities(norm, decoded));
          } catch (_) {}
        }
      }
    } catch (_) {
      return;
    }
    unawaited(onPacket(norm, data));
  }
}
