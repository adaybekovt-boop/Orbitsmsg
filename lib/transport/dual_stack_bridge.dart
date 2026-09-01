// Live dual-stack: same X3DH/ratchet bytes, different carrier.
// Default rollout stays PeerJS. Native path requires an explicit
// discovery secret — never HASH(peerId).

import 'dart:async';
import 'dart:convert';

import '../attachments/resumable_blob.dart';
import '../calls/hyperswarm_signaling.dart';
import '../core/feature_flags.dart';
import '../core/wire_crypto.dart';
import '../devices/device_registry.dart';
import '../mailbox/blind_store.dart';
import '../mailbox/mailbox_pump.dart';
import '../mailbox/storage_peer_client.dart';
import '../peer/helpers.dart';
import '../replication/drift_projector.dart';
import '../replication/file_journal.dart';
import '../replication/hypercore_store.dart';
import '../replication/memory_journal.dart';
import '../rooms/autobase_log.dart';
import '../transport/replication_schema.dart';
import 'discovery_secret_store.dart';
import 'hello_capabilities.dart';
import 'mux_frames.dart';
import 'native_rollback.dart';
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
    this.storagePeer,
    this.mailboxToken,
    this.mailboxWriterKey,
    this.localCapabilities,
    this.devices,
    HypercoreLocalStore? hypercore,
  })  : secrets = secrets ?? discoverySecretStore,
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
  final StoragePeerClient? storagePeer;
  final String? mailboxToken;
  final String? mailboxWriterKey;
  final CapabilityRecord? localCapabilities;
  final DeviceRegistry? devices;
  final HypercoreLocalStore hypercore;
  final MailboxPump _mailboxPump = MailboxPump();
  void Function(String peerId, Object packet)? onDrop;
  final Set<String> _drainedMailboxKeys = <String>{};
  Future<void> _durable = Future<void>.value();
  final AutobaseProjection rooms = AutobaseProjection();
  final List<RoomEvent> roomLog = <RoomEvent>[];
  int _roomSeq = 0;

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

  bool get hasMailbox => storagePeer != null || mailbox != null;

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
    final targets = devices?.transportTargets(peerId) ??
        <String>{normalizePeerId(peerId)};
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
        return await depositMailbox(jsonPayload(Map<String, Object?>.from(msg)));
      }
      if (!isWireReady(norm)) return false;
      final queued = await encryptWirePayload(norm, msg);
      final bytes = utf8.encode(queued);
      _appendEnvelope(norm, bytes);
      return await depositMailbox(bytes);
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
    await transport.send(
      norm,
      TransportChannel.message,
      utf8.encode(wire),
    );
    _appendEnvelope(norm, utf8.encode(wire));
    return true;
  }

  /// Offline deposit: encrypted bytes only. Used when the recipient is not
  /// currently connected. The storage peer never sees keys.
  Future<bool> depositMailbox(List<int> encryptedEnvelope) async {
    final token = mailboxToken;
    final writer = mailboxWriterKey;
    if (token == null || writer == null) return false;
    try {
      final client = storagePeer;
      if (client != null) {
        await _mailboxPump.depositClient(
          client: client,
          token: token,
          writerKey: writer,
          encryptedEnvelope: encryptedEnvelope,
        );
        await checkMailboxBacklog();
        return true;
      }
      final store = mailbox;
      if (store == null) return false;
      _mailboxPump.deposit(
        store: store,
        token: token,
        writerKey: writer,
        encryptedEnvelope: encryptedEnvelope,
      );
      await checkMailboxBacklog();
      return true;
    } on StateError catch (e) {
      if ('$e'.contains('quota')) {
        rollbackNativeToPeerjs(
          reason: NativeRollbackReason.relayMailboxBacklog,
          detail: '$e',
        );
      }
      return false;
    }
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
    unawaited(_persistDurable(record));
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
    unawaited(_persistDurable(record));
    hypercore.append(record);
  }

  Future<int> drainMailbox({String? fromPeerId}) async {
    final token = mailboxToken;
    final writer = mailboxWriterKey;
    if (token == null || writer == null) return 0;
    final List<EncryptedBlock> blocks;
    final client = storagePeer;
    if (client != null) {
      blocks = await _mailboxPump.collectClient(
        client: client,
        token: token,
        writerKey: writer,
      );
    } else {
      final store = mailbox;
      if (store == null) return 0;
      blocks = _mailboxPump.collect(
        store: store,
        token: token,
        writerKey: writer,
      );
    }
    final from = normalizePeerId(fromPeerId ?? writer);
    if (isBlocked(from)) {
      for (final block in blocks) {
        await _tombstoneMailbox(token, writer, block.seq);
      }
      return 0;
    }
    var delivered = 0;
    for (final block in blocks) {
      final key = '$writer:${block.seq}';
      if (_drainedMailboxKeys.contains(key)) {
        await _tombstoneMailbox(token, writer, block.seq);
        continue;
      }
      _drainedMailboxKeys.add(key);
      _appendEnvelope(from, block.bytes);
      final text = utf8.decode(block.bytes);
      await onPacket(
        from,
        isWireCiphertext(text) ? text : decodeJsonPayload(block.bytes),
      );
      await _tombstoneMailbox(token, writer, block.seq);
      delivered++;
    }
    await verifyLiveMatchesReplay();
    await checkMailboxBacklog();
    return delivered;
  }

  Future<void> _tombstoneMailbox(String token, String writer, int seq) async {
    final client = storagePeer;
    if (client != null) {
      await client.tombstone(token, writer, seq);
      return;
    }
    mailbox?.tombstone(token, writer, seq);
  }

  /// Force PeerJS when native delivery is known lost. Never enables native.
  bool noteMessagesLost(String detail) {
    return rollbackNativeToPeerjs(
      reason: NativeRollbackReason.messagesLost,
      detail: detail,
    );
  }

  Future<void> _persistDurable(JournalRecord record) {
    final durable = durableJournal;
    if (durable == null) return Future<void>.value();
    _durable = _durable.then((_) => durable.append(record));
    return _durable;
  }

  Future<bool> verifyLiveMatchesReplay({EnvelopeDecrypt? decrypt}) async {
    await _durable;
    Future<Map<String, Object?>?> hook(List<int> enc) async {
      if (decrypt != null) return decrypt(enc);
      return {'text': base64Encode(enc)};
    }

    final live = JournalProjector(decrypt: hook);
    await live.applyAll(journal);
    final replaySource =
        durableJournal != null ? await durableJournal!.replay() : journal;
    final replay = JournalProjector(decrypt: hook);
    await replay.applyAll(replaySource);
    if (!live.matches(replay)) {
      rollbackNativeToPeerjs(
        reason: NativeRollbackReason.journalReplayMismatch,
        detail: 'journal live/replay fingerprint mismatch',
      );
      return false;
    }
    if (!hypercoreMatchesJournal()) {
      rollbackNativeToPeerjs(
        reason: NativeRollbackReason.driftJournalDiverge,
        detail: 'hypercore envelope ids diverge from journal',
      );
      return false;
    }
    return true;
  }

  bool hypercoreMatchesJournal() {
    Set<Object?> idsOf(Iterable<JournalRecord> records) => records
        .where((r) => r.kind == ReplicationEventKind.messageEnvelopeCreated)
        .map((r) => r.fields['eventId'])
        .whereType<String>()
        .toSet();
    return idsOf(journal.records).containsAll(idsOf(hypercore.blocks)) &&
        idsOf(hypercore.blocks).containsAll(idsOf(journal.records));
  }

  Future<void> checkMailboxBacklog({
    int maxBytes = kMailboxBacklogRollbackBytes,
    int maxCount = kMailboxBacklogRollbackCount,
  }) async {
    final writer = mailboxWriterKey;
    if (writer == null) return;
    final token = mailboxToken;
    final store = mailbox;
    if (store != null &&
        store.isBacklogged(writer, maxBytes: maxBytes, maxCount: maxCount)) {
      rollbackNativeToPeerjs(
        reason: NativeRollbackReason.relayMailboxBacklog,
        detail: 'mailbox backlog ${store.usedBytes(writer)} bytes',
      );
      return;
    }
    if (token == null) return;
    final stats = await storagePeer?.stats(token: token, writerKey: writer);
    if (stats != null &&
        (stats.usedBytes >= maxBytes || stats.pendingCount >= maxCount)) {
      rollbackNativeToPeerjs(
        reason: NativeRollbackReason.relayMailboxBacklog,
        detail: 'mailbox backlog ${stats.usedBytes} bytes',
      );
    }
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
    final framed = Map<String, Object?>.from(packet)
      ..putIfAbsent('abWriter', () => selfDeviceId)
      ..putIfAbsent('abSeq', () => _roomSeq++);
    final event = roomEventFromNativePacket(
      framed,
      fallbackWriter: selfDeviceId,
    );
    if (event != null) _applyRoom(event);
    unawaited(
      transport.send(norm, TransportChannel.control, jsonPayload(framed)),
    );
    return true;
  }

  /// Phase 12 Autobase on the native carrier. Host-plaintext warning stays.
  /// Message bodies stay in the local projection — not Hypercore.
  Future<bool> sendAutobaseEvent(String peerId, RoomEvent event) async {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm)) return false;
    _applyRoom(event);
    if (!isNativeConnected(norm)) return false;
    await transport.send(
      norm,
      TransportChannel.control,
      jsonPayload(event.toWire()),
    );
    return true;
  }

  void _applyRoom(RoomEvent event) {
    final key = '${event.writerId}:${event.seq}';
    if (roomLog.any((e) => '${e.writerId}:${e.seq}' == key)) return;
    roomLog.add(event);
    rooms.reset();
    rooms.applyAll(roomLog);
    if (event.kind != 'membership') return;
    final record = journal.append(
      ReplicationEventKind.roomMembershipChanged,
      <String, Object?>{
        'peerId': event.payload['peerId'],
        'action': event.payload['action'],
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
    unawaited(_persistDurable(record));
    hypercore.append(record);
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

  /// Large files ride a path/descriptor into Bare. Never a Dart byte array
  /// over IPC. Control-plane Drop packets still use [sendDrop].
  Future<bool> sendFileFromPath(
    String peerId,
    TransportFileDescriptor file,
  ) async {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm) || !isNativeConnected(norm)) return false;
    if (file.path.isEmpty) {
      throw StateError('sendFileFromPath needs a path');
    }
    await transport.sendFile(norm, file);
    return true;
  }

  void _appendEnvelope(String peerId, List<int> encrypted) {
    if (journal.hasEncryptedEnvelope(encrypted)) {
      if (!hypercore.blocks.any(
        (r) =>
            encryptedEnvelopeEquals(r.fields['encryptedEnvelope'], encrypted),
      )) {
        // Keep Hypercore aligned with the journal ciphertext set.
        final existing = journal.records.firstWhere(
          (r) =>
              encryptedEnvelopeEquals(r.fields['encryptedEnvelope'], encrypted),
        );
        hypercore.append(existing);
      }
      return;
    }
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
    unawaited(_persistDurable(record));
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
              jsonPayload({
                'type': 'capabilities',
                ...caps.toWire(),
              }),
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
      if (isBlocked(norm)) return;
      try {
        final frame = decodeJsonPayload(bytes);
        final writerId = frame['writerDeviceId'] as String? ?? '';
        if (devices?.isRevoked(writerId) == true) return;
        final remote = hypercore.applyRemote(frame);
        if (remote == null) return;
        final ingested = journal.ingest(remote);
        if (ingested != null) {
          unawaited(_persistDurable(ingested));
        }
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
        final roomEvent = roomEventFromNativePacket(
          decoded,
          fallbackWriter: norm,
        );
        if (roomEvent != null) _applyRoom(roomEvent);
        if (decoded['type'] == 'capabilities' || decoded['type'] == 'wireHello') {
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
