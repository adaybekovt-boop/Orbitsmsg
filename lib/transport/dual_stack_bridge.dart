// Live dual-stack: same X3DH/ratchet bytes, different carrier.
// Default rollout stays PeerJS. Native path requires an explicit
// discovery secret — never HASH(peerId).

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';

import '../attachments/attachment_keys.dart';
import '../attachments/file_transfer_session.dart';
import '../calls/hyperswarm_signaling.dart';
import '../core/base64_helpers.dart';
import '../core/double_ratchet.dart' hide isWireCiphertext;
import '../core/feature_flags.dart';
import '../core/wire_crypto.dart';
import '../devices/device_ratchet_sessions.dart';
import '../devices/device_registry.dart';
import '../mailbox/blind_store.dart';
import '../mailbox/mailbox_protocol.dart';
import '../mailbox/mailbox_pump.dart';
import '../mailbox/storage_peer_client.dart';
import '../peer/helpers.dart';
import '../rooms/autobase_log.dart';
import '../replication/conversation_id.dart';
import '../replication/file_journal.dart';
import '../replication/hypercore_store.dart';
import '../replication/memory_journal.dart';
import '../replication/replication_authorization.dart';
import '../transport/replication_schema.dart';
import 'dev_bare_transport.dart';
import 'binding_authorization.dart';
import 'device_binding.dart';
import 'discovery_secret_store.dart';
import 'hello_capabilities.dart';
import 'mux_frames.dart';
import 'signed_capabilities.dart';
import 'transport_api.dart';
import 'trusted_identity_store.dart';

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
    TrustedIdentityStore? identities,
    this.confirmPeerAuthorization,
    this.onRemoteRecord,
    this.signRecord,
    AttachmentKeyStore? attachmentKeys,
    HypercoreLocalStore? hypercore,
    DeviceRatchetSessions? ratchets,
  }) : secrets = secrets ?? discoverySecretStore,
       identities = identities ?? TrustedIdentityStore(),
       attachmentKeys = attachmentKeys ?? AttachmentKeyStore(),
       hypercore = hypercore ?? HypercoreLocalStore(selfDeviceId),
       ratchets = ratchets ?? DeviceRatchetSessions(localDeviceId: selfDeviceId);

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
  final TrustedIdentityStore identities;
  final HypercoreLocalStore hypercore;
  final Future<void> Function(String peerId, {required bool authorized})?
  confirmPeerAuthorization;
  final Future<void> Function(JournalRecord record)? onRemoteRecord;
  final Future<List<int>> Function(List<int> payload)? signRecord;
  final AttachmentKeyStore attachmentKeys;
  final DeviceRatchetSessions ratchets;
  final MailboxPump _mailboxPump = MailboxPump();
  void Function(String peerId, Object packet)? onDrop;

  final Set<String> connecting = <String>{};
  final Set<String> connected = <String>{};
  final Set<String> authenticated = <String>{};
  final Set<String> _authorizedPending = <String>{};
  final List<CapabilityRecord> remoteCapabilities = <CapabilityRecord>[];
  StreamSubscription<TransportEvent>? _sub;
  void Function(CallSignal signal, String from)? onCallSignal;
  void Function(String peerId, bool connected)? onPresence;
  void Function(String peerId)? onAuthorizationRejected;

  final Map<String, String> _expectedPeer = <String, String>{};
  final Map<String, DeviceBinding> _bindings = <String, DeviceBinding>{};
  final Map<String, String> _fingerprintOwner = <String, String>{};
  final Map<String, String> _fingerprintTransport = <String, String>{};
  final Map<String, Completer<void>> _authWaiters = <String, Completer<void>>{};
  final Map<String, EcKeyPair> _ratchetHandshakeEph = <String, EcKeyPair>{};
  final FileTransferCoordinator files = FileTransferCoordinator();

  void attach() {
    _sub ??= transport.events.listen(_onEvent);
    files.onDrop = (peer, packet) => onDrop?.call(peer, packet);
    files.send = (peer, bytes) =>
        transport.send(peer, TransportChannel.attachment, bytes);
    files.keys = attachmentKeys;
    files.announceKey = (peer, transferId, key, meta) async {
      await sendEncrypted(
        peer,
        attachmentKeyMessage(
          transferId: transferId,
          key: key,
          sender: selfPeerId(),
          receiver: peer,
          name: meta['name'] as String? ?? '',
          size: (meta['size'] as num?)?.toInt() ?? 0,
          sha256hex: meta['sha256'] as String? ?? '',
        ),
      );
    };
    files.fileKeyFor = (peer, transferId) =>
        attachmentKeys.require(peer, transferId);
  }

  Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
    connecting.clear();
    connected.clear();
    authenticated.clear();
    _authorizedPending.clear();
    _expectedPeer.clear();
    _bindings.clear();
    _fingerprintOwner.clear();
    _fingerprintTransport.clear();
    for (final waiter in _authWaiters.values) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _authWaiters.clear();
    _ratchetHandshakeEph.clear();
    files.forgetAll();
  }

  /// Test/harness hook: persist a local journal record and fan it out
  /// only to authenticated peers that are allowed to see it.
  void appendAndReplicate(JournalRecord record) {
    hypercore.append(record);
    _fanoutReplication(record);
  }

  bool get nativeEnabled => isHyperswarmTransportEnabled();

  bool isNativeConnected(String peerId) =>
      connected.contains(normalizePeerId(peerId));

  bool isAuthenticated(String peerId) =>
      authenticated.contains(normalizePeerId(peerId));

  /// Own-device privileges. Must never be inferred from a peer-id string.
  bool isOwnDevice(String peerId, [DeviceBinding? binding]) =>
      _isOwnDevice(peerId, binding);

  bool canUseNative(String peerId) {
    if (!nativeEnabled) return false;
    if (secrets.get(peerId) == null) return false;
    return isNativeConnected(peerId) && isAuthenticated(peerId);
  }

  Future<void> dial(String peerId) async {
    if (!nativeEnabled) return;
    final secret = secrets.get(peerId);
    if (secret == null) {
      if (isDevBareTransportRequested()) {
        throw StateError('connect requires a shared discovery secret');
      }
      return;
    }
    final norm = normalizePeerId(peerId);
    connecting.add(norm);
    _expectedPeer[norm] = norm;
    try {
      await transport.connect(
        PeerDescriptor(peerId: norm, discoverySecret: secret),
      );
      await Future<void>.delayed(Duration.zero);
      await _waitForAuth(norm, timeout: const Duration(seconds: 8));
    } catch (_) {
      connecting.remove(norm);
      _expectedPeer.remove(norm);
      rethrow;
    }
  }

  Future<void> _waitForAuth(String peerId, {required Duration timeout}) async {
    final norm = normalizePeerId(peerId);
    if (isAuthenticated(norm)) return;
    if (!connecting.contains(norm) && !isNativeConnected(norm)) {
      return;
    }
    final waiter = _authWaiters.putIfAbsent(norm, Completer<void>.new);
    if (isAuthenticated(norm) ||
        (!connecting.contains(norm) && !isNativeConnected(norm))) {
      _completeAuthWaiter(norm);
      return;
    }
    try {
      await waiter.future.timeout(timeout);
    } on TimeoutException {
      // Same contract as the old 10 ms poller: give up without throwing.
    } finally {
      if (identical(_authWaiters[norm], waiter)) {
        _authWaiters.remove(norm);
      }
    }
  }

  void _completeAuthWaiter(String peerId) {
    final waiter = _authWaiters.remove(normalizePeerId(peerId));
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }

  Future<bool> sendEncrypted(String peerId, Object? msg) async {
    if (msg is Map &&
        (msg['type'] == 'wireHello' || msg['type'] == 'wireRekey')) {
      return _sendEncryptedOne(peerId, msg);
    }
    if (await _sendEncryptedDeviceFanout(peerId, msg)) {
      return true;
    }
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

  Future<bool> _sendEncryptedDeviceFanout(String peerId, Object? msg) async {
    final registry = devices;
    if (registry == null) return false;
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm)) return false;
    final recipient = DeviceRegistry()
      ..replaceAll(
        registry.active.where(
          (d) => normalizePeerId(d.ownerPeerId) == norm,
        ),
      );
    final sender = DeviceRegistry()
      ..replaceAll(
        registry.active.where(
          (d) => normalizePeerId(d.ownerPeerId) == normalizePeerId(selfPeerId()),
        ),
      );
    final targets = registry
        .fanout(
          recipient: recipient,
          sender: sender,
          sendingDeviceId: selfDeviceId,
        )
        .where(
          (d) =>
              !ratchets.isRevoked(d.deviceId) &&
              ratchets.session(selfDeviceId, d.deviceId) != null,
        )
        .toList();
    if (targets.isEmpty) return false;
    final encoded = msg is String ? msg : jsonEncode(msg);
    final wires = await ratchets.fanoutEncrypt(
      sendingDeviceId: selfDeviceId,
      targets: targets,
      plaintext: encoded,
    );
    if (wires.isEmpty) return false;
    var any = false;
    for (final entry in wires.entries) {
      final frame = encodeDeviceRatchetFrame(
        fromDeviceId: selfDeviceId,
        toDeviceId: entry.key,
        wire: entry.value,
      );
      final dest = _transportIdForDevice(entry.key, fallback: norm);
      final sentTo = isAuthenticated(dest) ? dest : norm;
      if (!isAuthenticated(sentTo)) {
        if (await enqueueMailbox(jsonPayload(frame))) any = true;
        continue;
      }
      await transport.send(
        sentTo,
        TransportChannel.message,
        jsonPayload(frame),
      );
      _appendEnvelope(
        sentTo,
        utf8.encode(entry.value),
        senderIdentity: selfPeerId(),
      );
      any = true;
    }
    return any;
  }

  String _transportIdForDevice(String deviceId, {required String fallback}) {
    for (final device in devices?.all ?? const <AuthorizedDevice>[]) {
      if (device.deviceId != deviceId) continue;
      final transportId = device.transportPeerId;
      if (transportId != null && transportId.isNotEmpty) {
        return normalizePeerId(transportId);
      }
    }
    return fallback;
  }

  Future<bool> _sendEncryptedOne(String peerId, Object? msg) async {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm)) return false;
    if (!isAuthenticated(norm)) {
      if (isDevBareTransportRequested() && secrets.get(norm) != null) {
        try {
          await dial(norm);
        } catch (_) {}
      }
      if (!isAuthenticated(norm)) {
        if (isDevBareTransportRequested()) return false;
        if (msg is Map &&
            (msg['type'] == 'wireHello' || msg['type'] == 'wireRekey')) {
          return enqueueMailbox(jsonPayload(Map<String, Object?>.from(msg)));
        }
        if (!isWireReady(norm)) return false;
        final queued = await encryptWirePayload(norm, msg);
        return enqueueMailbox(utf8.encode(queued));
      }
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
  ///
  /// Remote HTTP deposit is async — callers must use [enqueueMailbox] or
  /// [depositMailboxRemote]. This sync helper never pretends a remote
  /// write already finished.
  bool depositMailbox(List<int> encryptedEnvelope, {String? envelopeId}) {
    if (storagePeer != null && mailboxCapability != null) {
      return false;
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
    ratchets.revoke(deviceId);
    _queueOwnAccountRecord(
      ReplicationEventKind.deviceRevoked,
      <String, Object?>{
        'deviceId': deviceId,
        'ownerPeerId': selfPeerId(),
        'audience': 'owner-devices',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  void authorizeDevice(AuthorizedDevice device) {
    devices?.authorize(device);
    _queueOwnAccountRecord(
      ReplicationEventKind.deviceAuthorized,
      <String, Object?>{
        'deviceId': device.deviceId,
        'ownerPeerId': device.ownerPeerId.isNotEmpty
            ? device.ownerPeerId
            : selfPeerId(),
        'audience': 'owner-devices',
        'createdAt': device.createdAt,
      },
    );
  }

  void _queueOwnAccountRecord(
    ReplicationEventKind kind,
    Map<String, Object?> fields,
  ) {
    final record = journal.append(kind, fields);
    unawaited(durableJournal?.append(record));
    hypercore.append(record);
    unawaited(_fanoutSignedOwnAccount(record));
  }

  Future<void> _fanoutSignedOwnAccount(JournalRecord record) async {
    final signedFields = await _signOwnAccountFields(
      kind: record.kind,
      writerDeviceId: record.writerDeviceId,
      fields: record.fields,
    );
    if (isOwnerDeviceScopedKind(record.kind) &&
        decodeReplicationSignature(signedFields['signature']) == null) {
      return;
    }
    _fanoutReplication(
      JournalRecord(
        seq: record.seq,
        writerDeviceId: record.writerDeviceId,
        kind: record.kind,
        fields: signedFields,
      ),
    );
  }

  Future<Map<String, Object?>> _signOwnAccountFields({
    required ReplicationEventKind kind,
    required String writerDeviceId,
    required Map<String, Object?> fields,
  }) async {
    final sign = signRecord;
    if (sign == null) return fields;
    final payload = canonicalReplicationRecordBytes(
      kind: kind,
      writerDeviceId: writerDeviceId,
      fields: fields,
    );
    final signature = await sign(payload);
    if (signature.isEmpty) return fields;
    return <String, Object?>{...fields, 'signature': base64Encode(signature)};
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
    return _projectMailboxBlocks(blocks, fromPeerId: fromPeerId);
  }

  Future<int> drainMailboxRemote({String? fromPeerId}) async {
    final client = storagePeer;
    final cap = mailboxCapability;
    if (client == null || cap == null) return 0;
    final blocks = await _mailboxPump.collectRemote(
      client: client,
      capability: cap,
    );
    return _projectMailboxBlocks(
      blocks,
      fromPeerId: fromPeerId,
      acknowledge: (id) => _mailboxPump.acknowledgeRemote(
        client: client,
        capability: cap,
        envelopeId: id,
      ),
    );
  }

  /// Drain once per known contact. Never invents a sender from the
  /// mailbox writer key. Blocked peers are skipped before collect/project.
  Future<int> drainKnownMailboxes(Iterable<String> peerIds) async {
    var projected = 0;
    for (final raw in peerIds) {
      final peerId = normalizePeerId(raw);
      if (peerId.isEmpty || isBlocked(peerId)) continue;
      projected += await drainMailbox(fromPeerId: peerId);
    }
    return projected;
  }

  /// Project collected envelopes. [fromPeerId] is required — the store is
  /// blind and must not invent a sender from the writer key or mailbox id.
  /// Blocked senders are skipped before journal / Hypercore / onPacket.
  Future<int> _projectMailboxBlocks(
    List<EncryptedBlock> blocks, {
    required String? fromPeerId,
    Future<void> Function(String envelopeId)? acknowledge,
  }) async {
    final from = normalizePeerId(fromPeerId ?? '');
    if (from.isEmpty || isBlocked(from)) return 0;
    var projected = 0;
    for (final block in blocks) {
      final id = block.envelopeId ?? _stableEnvelopeId(block.bytes);
      if (_mailboxPump.projectedEnvelopeIds.contains(id)) continue;
      final text = utf8.decode(block.bytes);
      if (!isWireCiphertext(text)) {
        final decoded = decodeJsonPayload(block.bytes);
        if (decoded['type'] == kDeviceRatchetMessageType) {
          await _onDeviceRatchetFrame(from, decoded);
          _mailboxPump.markProjected(id);
          if (acknowledge != null) await acknowledge(id);
          projected += 1;
          continue;
        }
        _appendEnvelope(from, block.bytes, senderIdentity: from);
        await onPacket(from, decoded);
      } else {
        _appendEnvelope(from, block.bytes, senderIdentity: from);
        await onPacket(from, text);
      }
      _mailboxPump.markProjected(id);
      if (acknowledge != null) await acknowledge(id);
      projected += 1;
    }
    return projected;
  }

  Future<bool> sendEphemeral(String peerId, Object? msg) async {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm) || !isAuthenticated(norm) || !isWireReady(norm)) {
      return false;
    }
    final wire = await encryptWirePayload(norm, msg);
    await transport.send(norm, TransportChannel.presence, utf8.encode(wire));
    return true;
  }

  bool sendRoomPacket(String peerId, Map<String, Object?> packet) {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm) || !isAuthenticated(norm)) return false;
    _maybeRecordRoomMembership(norm, packet);
    unawaited(
      transport.send(norm, TransportChannel.control, jsonPayload(packet)),
    );
    return true;
  }

  /// Membership metadata only. Message bodies stay off Hypercore.
  void _maybeRecordRoomMembership(String peerId, Map<String, Object?> packet) {
    if (packet['type'] != kRoomAutobaseType) return;
    if ((packet['kind'] as String? ?? '') != 'membership') return;
    final roomId = packet['roomId'] as String? ?? '';
    final raw = packet['payload'];
    if (roomId.isEmpty || raw is! Map) return;
    final payload = Map<String, Object?>.from(raw);
    final member = payload['peerId'] as String? ?? '';
    final action = payload['action'] as String? ?? '';
    if (member.isEmpty || action.isEmpty) return;
    final writer = packet['writerId'] as String? ?? selfDeviceId;
    final seq = (packet['seq'] as num?)?.toInt() ?? 0;
    final eventId = '$writer:$seq:$roomId';
    final conversationId = conversationIdForPeers(selfPeerId(), peerId);
    if (journal.records.any(
      (r) =>
          r.kind == ReplicationEventKind.roomMembershipChanged &&
          r.fields['eventId'] == eventId &&
          r.fields['conversationId'] == conversationId,
    )) {
      return;
    }
    try {
      final record = journal.append(
        ReplicationEventKind.roomMembershipChanged,
        <String, Object?>{
          'eventId': eventId,
          'conversationId': conversationId,
          'senderIdentity': selfPeerId(),
          'senderDeviceId': selfDeviceId,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'roomId': roomId,
          'action': action,
          'memberPeerId': member,
          'abWriter': writer,
          'abSeq': seq,
        },
      );
      unawaited(durableJournal?.append(record));
      hypercore.append(record);
      _fanoutReplication(record);
    } catch (_) {}
  }

  Future<void> sendCallSignal(String peerId, CallSignal signal) {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm) || !isAuthenticated(norm)) {
      throw StateError('call signaling requires an authenticated peer');
    }
    return transport.send(
      norm,
      TransportChannel.call,
      jsonPayload(signal.toJson()),
    );
  }

  Future<void> sendFile(String peerId, TransportFileDescriptor file) async {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm) || !isAuthenticated(norm)) {
      throw StateError('file transfer requires an authenticated peer');
    }
    await files.sendPath(norm, file);
  }

  Future<bool> sendDrop(String peerId, Object packet) async {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm) || !isAuthenticated(norm)) return false;
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

  void _appendEnvelope(
    String peerId,
    List<int> encrypted, {
    String? senderIdentity,
  }) {
    final id =
        '${DateTime.now().millisecondsSinceEpoch}-$peerId-${encrypted.length}';
    final record = journal.appendEnvelope(
      MessageEnvelopeCreated(
        eventId: id,
        conversationId: conversationIdForPeers(selfPeerId(), peerId),
        senderIdentity: senderIdentity ?? selfPeerId(),
        senderDeviceId: selfDeviceId,
        logicalSequence: journal.length + 1,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        encryptedEnvelope: encrypted,
      ),
    );
    unawaited(durableJournal?.append(record));
    hypercore.append(record);
    _fanoutReplication(record);
  }

  void _fanoutReplication(JournalRecord record) {
    for (final peer in authenticated.toList(growable: false)) {
      if (!_maySendRecord(record, peer)) continue;
      unawaited(
        transport.send(
          peer,
          TransportChannel.replication,
          jsonPayload(
            hypercore.toReplicationFrame(
              record,
              authenticatedPeerId: peer,
              selfPeerId: selfPeerId(),
              peerIsOwnDevice: _isOwnDevice(peer),
            ),
          ),
        ),
      );
    }
  }

  bool _maySendRecord(JournalRecord record, String peerId) {
    return recordMayReplicateTo(
      record,
      authenticatedPeerId: peerId,
      selfPeerId: selfPeerId(),
      peerIsOwnDevice: _isOwnDevice(peerId),
    );
  }

  bool _isOwnDevice(String peerId, [DeviceBinding? binding]) {
    return registrySaysOwnDevice(
      peerId: peerId,
      selfPeerId: selfPeerId(),
      devices: devices,
      binding: binding ?? _bindings[normalizePeerId(peerId)],
    );
  }

  void _onEvent(TransportEvent event) {
    switch (event) {
      case TransportConnecting(:final peerId):
        connecting.add(normalizePeerId(peerId));
      case TransportConnected():
        break;
      case TransportIdentityPending(
        :final peerId,
        :final binding,
        :final connectionNoisePublicKey,
      ):
        unawaited(
          _onIdentityPending(peerId, binding, connectionNoisePublicKey),
        );
      case TransportAuthenticated(
        :final peerId,
        :final binding,
        :final connectionNoisePublicKey,
      ):
        unawaited(_onAuthenticated(peerId, binding, connectionNoisePublicKey));
      case TransportDisconnected(:final peerId):
        final norm = normalizePeerId(peerId);
        connecting.remove(norm);
        connected.remove(norm);
        authenticated.remove(norm);
        _authorizedPending.remove(norm);
        _expectedPeer.remove(norm);
        _bindings.remove(norm);
        _fingerprintTransport.removeWhere((_, id) => id == norm);
        _completeAuthWaiter(norm);
        files.forgetPeer(norm);
        onPresence?.call(peerId, false);
      case TransportFrame(:final peerId, :final channel, :final bytes):
        _onFrame(peerId, channel, bytes);
      default:
        break;
    }
  }

  Future<void> _onIdentityPending(
    String peerId,
    DeviceBinding binding,
    List<int>? connectionNoisePublicKey,
  ) async {
    final transportId = normalizePeerId(peerId);
    if (authenticated.contains(transportId) ||
        _authorizedPending.contains(transportId)) {
      return;
    }
    if (!await _evaluateBinding(
      transportId,
      binding,
      connectionNoisePublicKey,
    )) {
      await _reject(transportId);
      return;
    }
    _rememberAuthorizedPending(transportId, binding);
    try {
      await _confirmAuthorization(transportId, authorized: true);
    } catch (_) {
      await _reject(transportId);
    }
  }

  Future<void> _onAuthenticated(
    String peerId,
    DeviceBinding binding,
    List<int>? connectionNoisePublicKey,
  ) async {
    final transportId = normalizePeerId(peerId);
    if (authenticated.contains(transportId)) {
      return;
    }
    if (_authorizedPending.contains(transportId)) {
      _admitPeer(transportId, binding);
      return;
    }
    // In-process loopback emits authenticated without a prior pending event.
    if (!await _evaluateBinding(
      transportId,
      binding,
      connectionNoisePublicKey,
    )) {
      await _reject(transportId);
      return;
    }
    _rememberAuthorizedPending(transportId, binding);
    try {
      await _confirmAuthorization(transportId, authorized: true);
    } catch (_) {
      await _reject(transportId);
      return;
    }
    _admitPeer(transportId, binding);
  }

  Future<bool> _evaluateBinding(
    String transportId,
    DeviceBinding binding,
    List<int>? connectionNoisePublicKey,
  ) async {
    final logical = binding.ownerPeerId.isNotEmpty
        ? normalizePeerId(binding.ownerPeerId)
        : '';
    final decided = await authorizeIncomingBinding(
      binding: binding,
      connectionNoisePublicKey: connectionNoisePublicKey,
      transportPeerId: transportId,
      selfPeerId: selfPeerId(),
      identities: identities,
      devices: devices,
    );
    if (!decided.accepted || logical.isEmpty) return false;
    final fp = bindingFingerprint(
      deviceId: binding.deviceId,
      signature: binding.signatureByIdentityKey,
      createdAt: binding.createdAt,
    );
    final previous = _fingerprintOwner[fp];
    if (previous != null && previous != logical) return false;
    final boundTransport = _fingerprintTransport[fp];
    if (boundTransport != null && boundTransport != transportId) {
      return false;
    }
    final expected = _expectedPeer[transportId] ?? _expectedPeer[logical];
    if (expected != null &&
        expected != logical &&
        !decided.ownDevicePrivileges) {
      return false;
    }
    _fingerprintOwner[fp] = logical;
    _fingerprintTransport[fp] = transportId;
    return true;
  }

  void _rememberAuthorizedPending(String transportId, DeviceBinding binding) {
    final logical = binding.ownerPeerId.isNotEmpty
        ? normalizePeerId(binding.ownerPeerId)
        : transportId;
    _bindings[logical] = binding;
    if (transportId != logical) {
      _bindings[transportId] = binding;
    }
    _authorizedPending.add(logical);
    if (transportId != logical) {
      _authorizedPending.add(transportId);
    }
  }

  void _admitPeer(String transportId, DeviceBinding binding) {
    final logical = binding.ownerPeerId.isNotEmpty
        ? normalizePeerId(binding.ownerPeerId)
        : transportId;
    connecting.remove(transportId);
    connecting.remove(logical);
    connected.add(logical);
    authenticated.add(logical);
    _authorizedPending.remove(logical);
    if (transportId != logical) {
      connected.add(transportId);
      authenticated.add(transportId);
      _authorizedPending.remove(transportId);
    }
    _completeAuthWaiter(logical);
    if (transportId != logical) {
      _completeAuthWaiter(transportId);
    }
    onPresence?.call(logical, true);
    if (_expectedPeer.containsKey(transportId) ||
        _expectedPeer.containsKey(logical)) {
      unawaited(_offerDeviceRatchet(logical, binding.deviceId));
    }

    final caps = localCapabilities;
    if (caps != null) {
      unawaited(
        transport.send(
          logical,
          TransportChannel.control,
          jsonPayload({'type': 'capabilities', ...caps.toWire()}),
        ),
      );
    }
    _replayAuthorized(logical);
  }

  void _replayAuthorized(String peerId) {
    final own = _isOwnDevice(peerId);
    for (final record in hypercore.recordsAuthorizedForPeer(
      authenticatedPeerId: peerId,
      selfPeerId: selfPeerId(),
      peerIsOwnDevice: own,
    )) {
      unawaited(
        transport.send(
          peerId,
          TransportChannel.replication,
          jsonPayload(
            hypercore.toReplicationFrame(
              record,
              authenticatedPeerId: peerId,
              selfPeerId: selfPeerId(),
              peerIsOwnDevice: own,
            ),
          ),
        ),
      );
    }
  }

  Future<void> _confirmAuthorization(
    String peerId, {
    required bool authorized,
  }) async {
    if (confirmPeerAuthorization != null) {
      await confirmPeerAuthorization!(peerId, authorized: authorized);
      return;
    }
    await transport.authorizePeer(peerId, authorized: authorized);
  }

  Future<void> _reject(String peerId) async {
    connecting.remove(peerId);
    connected.remove(peerId);
    authenticated.remove(peerId);
    _authorizedPending.remove(peerId);
    try {
      await _confirmAuthorization(peerId, authorized: false);
    } catch (_) {}
    try {
      await transport.disconnect(peerId);
    } catch (_) {}
    onAuthorizationRejected?.call(peerId);
  }

  Future<void> _offerDeviceRatchet(
    String peerId,
    String remoteDeviceId,
  ) async {
    if (remoteDeviceId.isEmpty) return;
    if (ratchets.isRevoked(remoteDeviceId) ||
        ratchets.isRevoked(selfDeviceId)) {
      return;
    }
    if (ratchets.session(selfDeviceId, remoteDeviceId) != null) return;
    try {
      final eph = await generateDhKeyPair();
      _ratchetHandshakeEph[remoteDeviceId] = eph;
      await transport.send(
        peerId,
        TransportChannel.control,
        jsonPayload(<String, Object?>{
          'type': kDeviceRatchetOfferType,
          'fromDeviceId': selfDeviceId,
          'toDeviceId': remoteDeviceId,
          'ephPub': bytesToBase64(await exportSpkiBytes(eph)),
        }),
      );
    } catch (_) {
      _ratchetHandshakeEph.remove(remoteDeviceId);
    }
  }

  Future<void> _onDeviceRatchetOffer(
    String peerId,
    Map<String, Object?> decoded,
  ) async {
    final from = decoded['fromDeviceId'] as String? ?? '';
    final to = decoded['toDeviceId'] as String? ?? '';
    final ephB64 = decoded['ephPub'] as String? ?? '';
    if (from.isEmpty || to != selfDeviceId || ephB64.isEmpty) return;
    if (ratchets.isRevoked(from) || ratchets.isRevoked(to)) return;
    if (ratchets.session(selfDeviceId, from) != null) return;
    if (_ratchetHandshakeEph.containsKey(from) &&
        selfDeviceId.compareTo(from) < 0) {
      return;
    }
    try {
      final remoteEph = base64ToBytes(ephB64);
      final ourEph = await generateDhKeyPair();
      final shared = await ecdhSharedSecret(ourEph, remoteEph);
      final bobDh = await generateDhKeyPair();
      final bobSpki = await exportSpkiBytes(bobDh);
      final bob = await ratchetInitBob(
        sharedSecret: shared,
        dhKeyPair: bobDh,
        dhPubSpki: bobSpki,
      );
      ratchets.bind(
        localDeviceId: selfDeviceId,
        remoteDeviceId: from,
        state: bob,
      );
      _ratchetHandshakeEph.remove(from);
      await transport.send(
        peerId,
        TransportChannel.control,
        jsonPayload(<String, Object?>{
          'type': kDeviceRatchetAcceptType,
          'fromDeviceId': selfDeviceId,
          'toDeviceId': from,
          'ephPub': bytesToBase64(await exportSpkiBytes(ourEph)),
          'ratchetPub': bytesToBase64(bobSpki),
        }),
      );
    } catch (_) {}
  }

  Future<void> _onDeviceRatchetAccept(
    String peerId,
    Map<String, Object?> decoded,
  ) async {
    final from = decoded['fromDeviceId'] as String? ?? '';
    final to = decoded['toDeviceId'] as String? ?? '';
    final ephB64 = decoded['ephPub'] as String? ?? '';
    final ratchetB64 = decoded['ratchetPub'] as String? ?? '';
    if (from.isEmpty || to != selfDeviceId || ephB64.isEmpty || ratchetB64.isEmpty) {
      return;
    }
    if (ratchets.isRevoked(from) || ratchets.isRevoked(to)) return;
    if (ratchets.session(selfDeviceId, from) != null) return;
    final eph = _ratchetHandshakeEph.remove(from);
    if (eph == null) return;
    try {
      final shared = await ecdhSharedSecret(eph, base64ToBytes(ephB64));
      final alice = await ratchetInitAlice(
        sharedSecret: shared,
        remoteDhPubSpki: base64ToBytes(ratchetB64),
      );
      ratchets.bind(
        localDeviceId: selfDeviceId,
        remoteDeviceId: from,
        state: alice,
      );
    } catch (_) {}
  }

  Future<void> _onDeviceRatchetFrame(
    String peerId,
    Map<String, Object?> decoded,
  ) async {
    final fromDevice = decoded['fromDeviceId'] as String? ?? '';
    final toDevice = decoded['toDeviceId'] as String? ?? '';
    final wire = decoded['wire'] as String? ?? '';
    if (fromDevice.isEmpty || toDevice.isEmpty || wire.isEmpty) return;
    if (toDevice != selfDeviceId) return;
    if (ratchets.isRevoked(fromDevice) || ratchets.isRevoked(toDevice)) {
      return;
    }
    try {
      final bytes = await ratchets.decryptFrom(
        localDeviceId: selfDeviceId,
        remoteDeviceId: fromDevice,
        wire: wire,
      );
      final text = utf8.decode(bytes);
      Object? plain;
      try {
        plain = jsonDecode(text);
      } catch (_) {
        return;
      }
      if (plain is! Map) return;
      _appendEnvelope(peerId, utf8.encode(wire), senderIdentity: peerId);
      await onPacket(
        peerId,
        AuthenticatedPlaintext(Map<String, Object?>.from(plain)),
      );
    } catch (_) {}
  }

  Future<void> _onAttachmentFrame(String peerId, List<int> bytes) async {
    if (await files.handleInbound(peerId, bytes)) return;
    if (bytes.isNotEmpty && bytes[0] == 1) {
      onDrop?.call(peerId, bytes);
      return;
    }
    try {
      onDrop?.call(peerId, decodeJsonPayload(bytes));
    } catch (_) {}
  }

  Future<void> _onReplicationFrame(String peerId, List<int> bytes) async {
    try {
      final frame = decodeJsonPayload(bytes);
      if (!await _authorizeInboundReplication(peerId, frame)) return;
      final binding = _bindings[peerId];
      final record = hypercore.applyRemote(
        frame,
        authenticatedPeerId: peerId,
        selfPeerId: selfPeerId(),
        peerIsOwnDevice: _isOwnDevice(peerId),
        expectedWriterDeviceId: binding?.deviceId,
        acceptsWriter: devices?.acceptsWriter,
      );
      if (record != null) {
        unawaited(durableJournal?.append(record));
        unawaited(onRemoteRecord?.call(record));
      }
    } catch (_) {}
  }

  Future<bool> _authorizeInboundReplication(
    String peerId,
    Map<String, Object?> frame,
  ) async {
    final binding = _bindings[peerId];
    if (binding == null) return false;
    final writer = frame['writerDeviceId'] as String? ?? '';
    if (writer.isEmpty || writer != binding.deviceId) return false;
    final kindName = frame['kind'] as String?;
    if (kindName == null) return false;
    final kinds = ReplicationEventKind.values.where((k) => k.name == kindName);
    if (kinds.isEmpty) return false;
    final kind = kinds.first;
    if (!isOwnerDeviceScopedKind(kind)) return true;
    final raw = frame['fields'];
    if (raw is! Map) return false;
    final fields = <String, Object?>{};
    raw.forEach((k, v) {
      fields[k as String] = v;
    });
    final signature = decodeReplicationSignature(fields['signature']);
    if (signature == null || signature.isEmpty) return false;
    final owner =
        normalizedOwnerPeerId(fields) ?? normalizePeerId(binding.ownerPeerId);
    final known = identities.lookup(owner);
    if (known == null || known.tofuOnly) return false;
    if (!identityKeysEqual(
      known.identityPublicKey,
      binding.identityPublicKey,
    )) {
      return false;
    }
    return verifyIdentitySignedBytes(
      known.identityPublicKey,
      canonicalReplicationRecordBytes(
        kind: kind,
        writerDeviceId: writer,
        fields: fields,
      ),
      signature,
    );
  }

  void _onFrame(String peerId, TransportChannel channel, List<int> bytes) {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm)) return;
    if (!isAuthenticated(norm)) return;
    if (channel == TransportChannel.call) {
      try {
        onCallSignal?.call(CallSignal.fromJson(decodeJsonPayload(bytes)), norm);
      } catch (_) {}
      return;
    }
    if (channel == TransportChannel.attachment) {
      unawaited(_onAttachmentFrame(norm, bytes));
      return;
    }
    if (channel == TransportChannel.replication) {
      unawaited(_onReplicationFrame(norm, bytes));
      return;
    }
    Object? data;
    try {
      final text = utf8.decode(bytes);
      if (isWireCiphertext(text)) {
        // Decrypt once, in onPacket / dispatchReliableInbound. A side
        // peek here burns the ratchet and drops the chat plaintext.
        data = text;
        _appendEnvelope(norm, bytes, senderIdentity: norm);
      } else {
        final decoded = decodeJsonPayload(bytes);
        data = decoded;
        if (decoded['type'] == kDeviceRatchetMessageType) {
          unawaited(_onDeviceRatchetFrame(norm, decoded));
          return;
        }
        if (decoded['type'] == kDeviceRatchetOfferType) {
          unawaited(_onDeviceRatchetOffer(norm, decoded));
          return;
        }
        if (decoded['type'] == kDeviceRatchetAcceptType) {
          unawaited(_onDeviceRatchetAccept(norm, decoded));
          return;
        }
        if (decoded['type'] == kAttachmentKeyMessageType) {
          return;
        }
        if (decoded['type'] == 'capabilities' ||
            decoded['type'] == 'wireHello') {
          try {
            if (decoded['type'] == 'capabilities') {
              final record = CapabilityRecord.fromWire(decoded);
              unawaited(
                verifyCapabilityRecord(record).then((ok) {
                  if (ok) {
                    remoteCapabilities.add(record);
                    unawaited(rememberHelloCapabilities(norm, decoded));
                  }
                }),
              );
            } else {
              unawaited(rememberHelloCapabilities(norm, decoded));
            }
          } catch (_) {}
        }
      }
    } catch (_) {
      return;
    }
    unawaited(onPacket(norm, data));
  }
}
