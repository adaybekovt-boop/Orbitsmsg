// Live dual-stack: same X3DH/ratchet bytes, different carrier.
// Default rollout stays PeerJS. Native path requires an explicit
// discovery secret — never HASH(peerId).

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../attachments/resumable_blob.dart';
import '../calls/hyperswarm_signaling.dart';
import '../core/path_byte_stream.dart';
import '../core/feature_flags.dart';
import '../core/peer_pins.dart';
import '../core/wire_crypto.dart';
import '../devices/device_registry.dart';
import '../mailbox/blind_store.dart';
import '../mailbox/mailbox_pump.dart';
import '../mailbox/storage_peer_client.dart';
import '../peer/helpers.dart';
import '../peer/wire_transport.dart' show outboundWireMapIsSendable;
import '../push/opaque_wake.dart';
import '../replication/drift_projector.dart';
import '../replication/file_journal.dart';
import '../replication/hypercore_store.dart';
import '../replication/memory_journal.dart';
import '../rooms/autobase_log.dart';
import '../transport/replication_schema.dart';
import 'capabilities.dart';
import 'connect_binding.dart';
import 'device_binding.dart';
import 'discovery_secret_store.dart';
import 'hello_capabilities.dart';
import 'layers.dart';
import 'mux_frames.dart';
import 'native_rollback.dart';
import 'relay_directory.dart';
import 'signed_capabilities.dart';
import 'transport_api.dart';

typedef PacketSink = Future<void> Function(String peerId, Object? data);
typedef BlockedCheck = bool Function(String peerId);

/// Journal membership hydrate only — not live `room_msg` / Autobase strip.
const _kJournalMembershipBanned = <String>{
  'text',
  'b64',
  'fileKey',
  'fileKeyB64',
  'plaintext',
};

bool _journalMembershipFieldsSafe(Map<String, Object?> fields) {
  if (!replicationValueIsSafe(fields)) return false;
  return !_hasJournalMembershipBanned(fields, HashSet<Object>.identity());
}

bool _hasJournalMembershipBanned(Object? value, Set<Object> seen) {
  if (value == null || value is bool || value is num || value is String) {
    return false;
  }
  if (value is List<int>) return false; // ciphertext leaf
  if (value is Map) {
    if (!seen.add(value)) return false;
    for (final e in value.entries) {
      if (_kJournalMembershipBanned.contains('${e.key}')) return true;
      if (_hasJournalMembershipBanned(e.value, seen)) return true;
    }
    return false;
  }
  if (value is Iterable) {
    if (!seen.add(value)) return false;
    for (final item in value) {
      if (_hasJournalMembershipBanned(item, seen)) return true;
    }
    return false;
  }
  return false;
}

/// Cycle-safe walk of an inbound attach frame. Rejects
/// [kForbiddenReplicationFields] (includes `fileKey` / `fileKeyB64`) at any
/// depth, including nested `{ meta: { fileKey } }`. [List<int>] is a
/// ciphertext leaf. Do not treat `text` as forbidden here.
///
/// `b64` is the chunk ciphertext field — allowed on `_ingestAttachChunk`.
/// Path frames must not carry chunk bytes, so [rejectB64] refuses `b64`
/// at any depth.
bool _attachFrameHasForbiddenKey(
  Object? value, {
  required bool rejectB64,
  Set<Object>? seen,
}) {
  if (value == null || value is bool || value is num || value is String) {
    return false;
  }
  if (value is List<int>) return false; // ciphertext leaf
  final walk = seen ?? HashSet<Object>.identity();
  if (value is Map) {
    if (!walk.add(value)) return false;
    for (final e in value.entries) {
      final key = '${e.key}';
      if (kForbiddenReplicationFields.contains(key) ||
          key == 'fileKey' ||
          key == 'fileKeyB64' ||
          (rejectB64 && key == 'b64')) {
        return true;
      }
      if (_attachFrameHasForbiddenKey(
        e.value,
        rejectB64: rejectB64,
        seen: walk,
      )) {
        return true;
      }
    }
    return false;
  }
  if (value is Iterable) {
    if (!walk.add(value)) return false;
    for (final item in value) {
      if (_attachFrameHasForbiddenKey(
        item,
        rejectB64: rejectB64,
        seen: walk,
      )) {
        return true;
      }
    }
    return false;
  }
  return false;
}

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
    this.localBinding,
    this.devices,
    this.connectionNoiseFor,
    this.tofuCheck,
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
  final DeviceBinding? localBinding;
  final DeviceRegistry? devices;
  final List<int>? Function(String peerId)? connectionNoiseFor;
  final Future<PinCheck> Function(String peerId, List<int> identitySpki)?
      tofuCheck;
  final HypercoreLocalStore hypercore;
  final MailboxPump _mailboxPump = MailboxPump();
  void Function(String peerId, Object packet)? onDrop;
  final Set<String> _drainedMailboxKeys = <String>{};
  Future<void> _durable = Future<void>.value();
  final Map<String, List<AttachmentChunk>> _inboundAttach =
      <String, List<AttachmentChunk>>{};
  final Map<String, String> _inboundAttachPaths = <String, String>{};
  var _inboundAttachBytes = 0;
  static const int _maxInboundAttachBytes = kMaxNativeAttachBytes;
  final AutobaseProjection rooms = AutobaseProjection();
  final List<RoomEvent> roomLog = <RoomEvent>[];
  int _roomSeq = 0;

  final Set<String> connected = <String>{};
  final Set<String> authenticated = <String>{};
  final Map<String, DeviceBinding> remoteBindings = <String, DeviceBinding>{};
  final Map<String, String> bindingFailures = <String, String>{};
  final Map<String, List<_QueuedInbound>> _pendingInbound =
      <String, List<_QueuedInbound>>{};
  static const int _maxPendingInboundFrames = 1024;
  static const int _maxPendingInboundBytes = 4 * 1024 * 1024;
  final List<CapabilityRecord> remoteCapabilities = <CapabilityRecord>[];
  StreamSubscription<TransportEvent>? _sub;
  void Function(CallSignal signal, String from)? onCallSignal;
  void Function(String peerId, bool connected)? onPresence;

  /// Test / host hook: the transport id whose RatchetState was dropped.
  void Function(String peerId)? onRatchetDropped;

  /// After a mailbox deposit of ciphertext. Must stay opaque — no peer
  /// id, body, or attachment metadata. The host may enqueue APNs/FCM
  /// which still refuse while live flags are false.
  Future<void> Function(OpaqueWake wake)? onMailboxWake;

  void Function(String peerId, TransportPath path)? onPathChanged;
  void Function(String detail)? onNetworkChanged;
  void Function(String peerId, String state)? onDeliveryState;
  final Map<String, TransportPath> paths = <String, TransportPath>{};

  void attach() {
    _sub ??= transport.events.listen(_onEvent);
    hydrateFromJournal();
    unawaited(_pushAutobaseToCarrier());
    unawaited(rememberKnownPeers());
  }

  /// Seed the worklet Autobase from local membership rows after restart.
  /// Ciphertext envelopes stay in the journal — not this snapshot.
  Future<void> _pushAutobaseToCarrier() async {
    final rows = <Map<String, Object?>>[];
    for (final rec in journal.records) {
      if (rec.kind != ReplicationEventKind.roomMembershipChanged) continue;
      if (!replicationValueIsSafe(rec.fields)) continue;
      rows.add(journalRecordToWorklet(rec));
    }
    try {
      await transport.hydrateAutobase(rows);
    } catch (_) {}
  }

  /// Restart path: replay the local journal into Hypercore and Autobase.
  /// Ciphertext and membership metadata only — never plaintext, b64, or
  /// fileKey. Does not re-append the journal.
  void hydrateFromJournal() {
    hydrateHypercoreFromJournal();
    hydrateAutobaseFromJournal();
  }

  void hydrateHypercoreFromJournal() {
    for (final rec in journal.records) {
      if (!replicationValueIsSafe(rec.fields)) continue;
      if (rec.writerDeviceId.contains('://')) continue;
      hypercore.append(rec);
    }
  }

  /// Membership only. Message bodies stay out of Autobase's durable log.
  void hydrateAutobaseFromJournal() {
    for (final rec in journal.records) {
      final event = _membershipEventFromJournal(rec);
      if (event == null) continue;
      _applyRoom(event, persist: false);
      if (event.seq >= _roomSeq) _roomSeq = event.seq + 1;
    }
  }

  RoomEvent? _membershipEventFromJournal(JournalRecord rec) {
    if (rec.kind != ReplicationEventKind.roomMembershipChanged) return null;
    if (!_journalMembershipFieldsSafe(rec.fields)) return null;
    final peerId = rec.fields['peerId'] as String?;
    if (peerId == null || peerId.isEmpty || peerId.contains('://')) {
      return null;
    }
    final seq = (rec.fields['seq'] as num?)?.toInt() ?? rec.seq;
    final writer = rec.fields['writerId'] as String? ?? rec.writerDeviceId;
    if (writer.contains('://')) return null;
    final roomId = rec.fields['roomId'];
    if (roomId is String && (roomId.isEmpty || roomId.contains('://'))) {
      return null;
    }
    return RoomEvent(
      writerId: writer.isEmpty ? selfDeviceId : writer,
      seq: seq,
      kind: 'membership',
      payload: {
        if (rec.fields['roomId'] != null) 'roomId': rec.fields['roomId'],
        'peerId': peerId,
        'action': rec.fields['action'] as String? ?? 'join',
        if (rec.fields['displayName'] is String)
          'displayName': rec.fields['displayName'],
      },
    );
  }

  /// Inbound Hyperswarm connections need the Noise→ORBIT map before
  /// [dial]. Discovery secrets stay in Dart — not sent to the worklet.
  Future<void> rememberKnownPeers() async {
    final seen = <String>{};
    Future<void> remember(String id, List<int> noise) async {
      final norm = normalizePeerId(id);
      if (norm.isEmpty ||
          norm.contains('://') ||
          !isValidPeerId(norm) ||
          noise.isEmpty) {
        return;
      }
      if (!seen.add(norm)) return;
      try {
        await transport.rememberPeer(
          PeerDescriptor(
            peerId: norm,
            noisePublicKey: List<int>.from(noise),
          ),
        );
      } catch (_) {}
    }

    for (final id in secrets.knownPeerIds) {
      if (id == normalizePeerId(kLocalDiscoverySecretId)) continue;
      final noise = devices?.noisePublicKeyFor(id);
      if (noise == null || noise.isEmpty) continue;
      await remember(id, noise);
    }
    for (final device in devices?.active ?? const <AuthorizedDevice>[]) {
      final tid = device.transportPeerId;
      if (tid == null || tid.isEmpty) continue;
      if (device.transportPublicKey.isEmpty) continue;
      await remember(tid, device.transportPublicKey);
    }
    unawaited(_dialOwnKnownDevices());
  }

  /// Contact discovery secret for [peerId], or the owner contact's
  /// secret when [peerId] is a linked-device transport id. Never
  /// HASH(peerId). Sibling own-device ids use the local advertise secret.
  List<int>? discoverySecretFor(String peerId) {
    final direct = secrets.get(peerId);
    if (direct != null) return direct;
    // Own devices advertise on the local secret, not HASH(peerId) and not
    // a contact secret stored under the local live id.
    if (_isOwnDeviceTransport(peerId)) {
      return secrets.get(kLocalDiscoverySecretId);
    }
    final owner = _ownerPeerIdForTransport(peerId);
    if (owner != null) {
      return secrets.get(owner);
    }
    return null;
  }

  String? _ownerPeerIdForTransport(String peerId) {
    final norm = normalizePeerId(peerId);
    if (norm.isEmpty || norm.contains('://')) return null;
    final devices = this.devices;
    if (devices == null) return null;
    for (final device in devices.active) {
      final tid = device.transportPeerId;
      if (tid == null || tid.isEmpty) continue;
      if (normalizePeerId(tid) != norm) continue;
      if (device.ownerPeerId.isEmpty || device.ownerPeerId.contains('://')) {
        continue;
      }
      return normalizePeerId(device.ownerPeerId);
    }
    return null;
  }

  bool _isOwnDeviceTransport(String peerId) {
    final owner = _ownerPeerIdForTransport(peerId);
    if (owner == null) return false;
    return owner == normalizePeerId(selfPeerId());
  }

  /// Own-device sync copies join the local advertise topic after
  /// [rememberPeer]. Never HASH(peerId).
  Future<void> _dialOwnKnownDevices() async {
    for (final device in devices?.active ?? const <AuthorizedDevice>[]) {
      final tid = device.transportPeerId;
      if (tid == null || tid.isEmpty) continue;
      if (!_isOwnDeviceTransport(tid)) continue;
      if (discoverySecretFor(tid) == null) continue;
      try {
        await dial(tid);
      } catch (_) {}
    }
  }

  Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
    connected.clear();
    authenticated.clear();
    remoteBindings.clear();
    bindingFailures.clear();
    _pendingInbound.clear();
  }

  bool get nativeEnabled => isHyperswarmTransportEnabled();

  bool get hasMailbox => storagePeer != null || mailbox != null;

  bool isNativeConnected(String peerId) =>
      connected.contains(normalizePeerId(peerId));

  bool canUseNative(String peerId) {
    if (!nativeEnabled) return false;
    if (discoverySecretFor(peerId) == null) return false;
    final norm = normalizePeerId(peerId);
    return connected.contains(norm) && authenticated.contains(norm);
  }

  /// True when the remote advertised `room-voice-v1` on DeviceBinding,
  /// a signed capability record, or a verified hello `caps` sibling.
  /// Missing bit fail-closed: do not send DualStack `rv-` offers.
  bool remoteUnderstandsRoomVoice(String peerId) {
    final norm = normalizePeerId(peerId);
    final binding = remoteBindings[norm];
    if (binding != null && advertisesRoomVoiceV1(binding.capabilities)) {
      return true;
    }
    for (final rec in remoteCapabilities) {
      if (normalizePeerId(rec.peerId) == norm &&
          rec.capabilities.contains(TransportCapability.roomVoiceV1)) {
        return true;
      }
    }
    final cached = remoteCapabilityCache.get(norm);
    return cached?.capabilities.contains(TransportCapability.roomVoiceV1) ==
        true;
  }

  Future<void> dial(String peerId) async {
    final targets = devices?.transportTargets(peerId) ??
        <String>{normalizePeerId(peerId)};
    if (targets.length <= 1) {
      await _dialOne(targets.isEmpty ? peerId : targets.first);
      return;
    }
    for (final tid in targets) {
      try {
        await _dialOne(tid);
      } catch (_) {}
    }
  }

  /// One transport id. [dial] fans this out to recipient devices.
  Future<void> _dialOne(String peerId) async {
    if (!nativeEnabled) return;
    final secret = discoverySecretFor(peerId);
    if (secret == null) return;
    final noise = devices?.noisePublicKeyFor(peerId);
    await transport.connect(
      PeerDescriptor(
        peerId: normalizePeerId(peerId),
        discoverySecret: secret,
        noisePublicKey: noise,
      ),
    );
  }

  /// Recipient devices plus own-device sync copies. Not the sending device.
  Set<String> _sendPeerIds(String peerId) {
    return devices?.sendTargets(
          peerId,
          selfPeerId: selfPeerId(),
          sendingDeviceId: selfDeviceId,
        ) ??
        <String>{normalizePeerId(peerId)};
  }

  Future<bool> sendEncrypted(String peerId, Object? msg) async {
    final targets = _sendPeerIds(peerId);
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
    if (msg is Map && !outboundWireMapIsSendable(msg)) return false;
    if (!isNativeConnected(norm) && discoverySecretFor(norm) != null) {
      try {
        await dial(norm);
      } catch (_) {}
    }
    if (!await _ensureNativeSendReady(norm)) {
      if (msg is Map &&
          (msg['type'] == 'wireHello' || msg['type'] == 'wireRekey')) {
        // Offline hello/rekey must wait for connect. Mailbox is
        // encrypted bytes only — never plaintext JSON hellos.
        return false;
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
    final channel = msg is Map && msg['type'] == 'ack'
        ? TransportChannel.receipt
        : TransportChannel.message;
    await transport.send(
      norm,
      channel,
      utf8.encode(wire),
    );
    _appendEnvelope(norm, utf8.encode(wire));
    return true;
  }

  Future<bool> _waitAuthenticated(String peerId) async {
    final norm = normalizePeerId(peerId);
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (authenticated.contains(norm)) return true;
      if (!connected.contains(norm)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return authenticated.contains(norm);
  }

  /// Native application traffic waits for ADR-0001 DeviceBinding checks.
  /// Mailbox deposit stays immediate when the peer is **not** connected.
  Future<bool> _ensureNativeSendReady(String peerId) async {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm)) return false;
    if (isNativeConnected(norm) && !authenticated.contains(norm)) {
      await _waitAuthenticated(norm);
    }
    return isNativeConnected(norm) && authenticated.contains(norm);
  }

  /// Opaque local capability only — same rules as [mailboxPumpTokenIsSafe].
  bool _mailboxTokenSafe(String token) => mailboxPumpTokenIsSafe(token);

  /// Offline deposit: encrypted bytes only. Used when the recipient is not
  /// currently connected. The storage peer never sees keys.
  Future<bool> depositMailbox(List<int> encryptedEnvelope) async {
    final token = mailboxToken;
    final writer = mailboxWriterKey;
    if (token == null || writer == null) return false;
    if (!_mailboxTokenSafe(token) ||
        writer.isEmpty ||
        encryptedEnvelope.isEmpty) {
      return false;
    }
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
        unawaited(_enqueueMailboxWake());
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
      unawaited(_enqueueMailboxWake());
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

  Future<void> _enqueueMailboxWake() async {
    final token = mailboxToken;
    final hook = onMailboxWake;
    if (hook == null || token == null || !_mailboxTokenSafe(token)) return;
    await hook(
      OpaqueWake(
        opaqueWakeToken: token,
        collapseId: 'mailbox',
        protocolVersion: 1,
      ),
    );
  }

  /// Authorization log: revoked writers are ignored on the next fan-out.
  /// Drops that device's own RatchetState (transportPeerId), never a
  /// sibling device's rootKey.
  void revokeDevice(String deviceId) {
    if (deviceId.isEmpty || deviceId.contains('://')) return;
    final before = devices?.getDevice(deviceId);
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
    _replicateToAuthenticated(record);
    for (final key in ratchetKeysForRevokedDevice(before)) {
      onRatchetDropped?.call(key);
      unawaited(teardownWireSession(key));
    }
  }

  void authorizeDevice(AuthorizedDevice device) {
    if (device.deviceId.isEmpty || device.deviceId.contains('://')) return;
    if (device.ownerPeerId.contains('://')) return;
    final tid = device.transportPeerId;
    if (tid != null && tid.contains('://')) return;
    devices?.authorize(device);
    final rememberId = device.transportPeerId;
    if (rememberId != null &&
        rememberId.isNotEmpty &&
        device.transportPublicKey.isNotEmpty) {
      unawaited(
        transport.rememberPeer(
          PeerDescriptor(
            peerId: normalizePeerId(rememberId),
            noisePublicKey: List<int>.from(device.transportPublicKey),
          ),
        ),
      );
      if (_isOwnDeviceTransport(rememberId) &&
          discoverySecretFor(rememberId) != null) {
        unawaited(() async {
          try {
            await dial(rememberId);
          } catch (_) {}
        }());
      }
    }
    final record = journal.append(
      ReplicationEventKind.deviceAuthorized,
      <String, Object?>{
        'deviceId': device.deviceId,
        'createdAt': device.createdAt,
      },
    );
    unawaited(_persistDurable(record));
    hypercore.append(record);
    _replicateToAuthenticated(record);
  }

  /// Local block list is Drift + the inbound [isBlocked] hook. This
  /// journals the decision so restore can replay it. No secrets.
  void journalContactBlocked({
    required String peerId,
    required bool blocked,
  }) {
    final norm = normalizePeerId(peerId);
    if (norm.isEmpty || peerId.contains('://') || norm.contains('://')) {
      return;
    }
    final record = journal.append(
      ReplicationEventKind.contactBlocked,
      <String, Object?>{
        'conversationId': norm,
        'peerId': norm,
        'blocked': blocked,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
    unawaited(_persistDurable(record));
    hypercore.append(record);
    _replicateToAuthenticated(record);
  }

  /// Inbound delivery receipt after decrypt. Metadata only — no ratchet
  /// scalars or plaintext body.
  void journalDeliveryAcknowledged({
    required String eventId,
    required String conversationId,
  }) {
    if (eventId.isEmpty || eventId.contains('://')) return;
    if (conversationId.isEmpty || conversationId.contains('://')) return;
    final conv = normalizePeerId(conversationId);
    final record = journal.append(
      ReplicationEventKind.deliveryAcknowledged,
      <String, Object?>{
        'eventId': eventId,
        'conversationId': conv,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
    unawaited(_persistDurable(record));
    hypercore.append(record);
    _replicateToSendTargets(conv, record);
    onDeliveryState?.call(conv, 'delivered');
  }

  /// Metadata-only expiry. Ciphertext and fileKey stay out of the journal.
  void journalAttachmentExpired({
    required String eventId,
    String? conversationId,
  }) {
    if (eventId.isEmpty || eventId.contains('://')) return;
    if (conversationId != null &&
        (conversationId.isEmpty || conversationId.contains('://'))) {
      return;
    }
    final record = journal.append(
      ReplicationEventKind.attachmentExpired,
      <String, Object?>{
        'eventId': eventId,
        if (conversationId != null && conversationId.isNotEmpty)
          'conversationId': conversationId,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
    unawaited(_persistDurable(record));
    hypercore.append(record);
    if (conversationId != null && conversationId.isNotEmpty) {
      _replicateToSendTargets(conversationId, record);
    } else {
      _replicateToAuthenticated(record);
    }
  }

  Future<int> drainMailbox({String? fromPeerId}) async {
    final token = mailboxToken;
    final writer = mailboxWriterKey;
    if (token == null || writer == null) return 0;
    if (!_mailboxTokenSafe(token) || writer.isEmpty) return 0;
    final List<EncryptedBlock> blocks;
    try {
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
    } on StateError {
      return 0;
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

  /// Relay set collapsed (unsound / RTT blow-up). Distinct from mailbox
  /// backlog. Never enables native.
  bool noteRelayBlowUp({String detail = 'relay blow-up'}) {
    return rollbackNativeToPeerjs(
      reason: NativeRollbackReason.relayBlowUp,
      detail: detail,
    );
  }

  bool checkRelayDirectory(RelayDirectory directory) {
    if (!directory.relayBlownUp) return false;
    return noteRelayBlowUp(
      detail: 'relay directory unsound or RTT blown up',
    );
  }

  Future<void> _persistDurable(JournalRecord record) {
    _durable = _durable.then((_) async {
      await _persistWorklet(record);
      final durable = durableJournal;
      if (durable != null) await durable.append(record);
    });
    return _durable;
  }

  Future<void> _persistWorklet(JournalRecord record) async {
    try {
      await transport.appendJournal(journalRecordToWorklet(record));
    } catch (_) {
      // Dart FileJournal remains the live/replay source.
    }
  }

  Future<bool> verifyLiveMatchesReplay({EnvelopeDecrypt? decrypt}) async {
    await _durable;
    Future<Map<String, Object?>?> hook(List<int> enc, String conv) async {
      if (decrypt != null) return decrypt(enc, conv);
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
    if (token == null || !_mailboxTokenSafe(token) || writer.isEmpty) return;
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
    List<int> fileKey, {
    String fileId = '',
  }) async {
    return _sendAttachmentChunks(
      peerId,
      ResumableAttachment.chunk(plaintext, fileKey),
      fileId: fileId,
    );
  }

  /// Chunk plaintext from a stream (path `openRead`) so a large file
  /// never becomes one Dart `Uint8List`. [fileKey] stays local — it is
  /// not journaled and must travel in the ratcheted chat envelope, not
  /// on this channel.
  Future<void> sendAttachmentStream(
    String peerId,
    Stream<List<int>> plaintext,
    List<int> fileKey, {
    String fileId = '',
  }) async {
    final id = fileId.isEmpty
        ? 'att-${DateTime.now().millisecondsSinceEpoch}'
        : fileId;
    if (id.contains('://')) return;
    final targets = _sendPeerIds(peerId);
    List<int>? firstCipher;
    var count = 0;
    var total = 0;
    var any = false;
    await for (final chunk
        in ResumableAttachment.chunkStream(plaintext, fileKey)) {
      for (final target in targets) {
        if (!await _ensureNativeSendReady(target)) continue;
        await _sendOneAttachChunk(target, chunk, fileId: id);
        any = true;
      }
      firstCipher ??= List<int>.from(chunk.ciphertext);
      count++;
      total += chunk.ciphertext.length;
    }
    if (firstCipher == null || !any) return;
    _journalAttachmentPublished(
      normalizePeerId(peerId),
      firstCipher: firstCipher,
      chunkCount: count,
      totalBytes: total,
    );
  }

  /// Chat `attach-chunk` from a local **ciphertext** path. Bare / loopback
  /// `sendFile` reads the path; Dart does not send chunk `frameB64` over
  /// IPC. [firstCipher] is the first 64 KiB for the journal. Never a
  /// `fileKey` on the descriptor.
  Future<bool> sendAttachmentCipherPath(
    String peerId,
    TransportFileDescriptor file, {
    required List<int> firstCipher,
    required int chunkCount,
  }) async {
    if (file.path.isEmpty || file.path.contains('://')) {
      throw StateError('sendAttachmentCipherPath needs a local path');
    }
    if (file.protocol != 'attach-chunk') {
      throw StateError('sendAttachmentCipherPath needs attach-chunk');
    }
    final fileId = file.fileId ?? '';
    if (fileId.isEmpty || fileId.contains('://')) {
      throw StateError('sendAttachmentCipherPath needs fileId');
    }
    if (firstCipher.isEmpty || chunkCount <= 0) return false;
    var any = false;
    for (final target in _sendPeerIds(peerId)) {
      if (!await _ensureNativeSendReady(target)) continue;
      await transport.sendFile(target, file);
      any = true;
    }
    if (!any) return false;
    _journalAttachmentPublished(
      normalizePeerId(peerId),
      firstCipher: List<int>.from(firstCipher),
      chunkCount: chunkCount,
      totalBytes: file.sizeBytes,
    );
    return true;
  }

  Future<void> _sendAttachmentChunks(
    String peerId,
    List<AttachmentChunk> chunks, {
    String fileId = '',
  }) async {
    final id = fileId.isEmpty
        ? 'att-${DateTime.now().millisecondsSinceEpoch}'
        : fileId;
    if (id.isEmpty || id.contains('://')) return;
    var any = false;
    for (final target in _sendPeerIds(peerId)) {
      if (!await _ensureNativeSendReady(target)) continue;
      for (final chunk in chunks) {
        await _sendOneAttachChunk(target, chunk, fileId: id);
      }
      any = true;
    }
    if (!any || chunks.isEmpty) return;
    var total = 0;
    for (final chunk in chunks) {
      total += chunk.ciphertext.length;
    }
    _journalAttachmentPublished(
      normalizePeerId(peerId),
      firstCipher: List<int>.from(chunks.first.ciphertext),
      chunkCount: chunks.length,
      totalBytes: total,
    );
  }

  Future<void> _sendOneAttachChunk(
    String norm,
    AttachmentChunk chunk, {
    required String fileId,
  }) {
    if (fileId.contains('://')) return Future<void>.value();
    final body = <String, Object?>{
      'type': 'attach-chunk',
      'fileId': fileId,
      'index': chunk.index,
      'offset': chunk.offset,
      'hash': chunk.hash,
      'b64': base64Encode(chunk.ciphertext),
    };
    if (!replicationValueIsSafe(body)) return Future<void>.value();
    return transport.send(
      norm,
      TransportChannel.attachment,
      jsonPayload(body),
    );
  }

  void _journalAttachmentPublished(
    String norm, {
    required List<int> firstCipher,
    required int chunkCount,
    required int totalBytes,
  }) {
    final record = journal.append(
      ReplicationEventKind.attachmentPublished,
      <String, Object?>{
        'eventId':
            '${DateTime.now().millisecondsSinceEpoch}-$norm-att-$chunkCount',
        'conversationId': norm,
        'encryptedEnvelope': firstCipher,
        'chunkCount': chunkCount,
        'totalBytes': totalBytes,
      },
    );
    unawaited(_persistDurable(record));
    hypercore.append(record);
  }

  /// Decrypt inbound `attach-chunk` ciphertext with the fileKey from the
  /// ratcheted chat envelope. Never journals the key. Prefers a ciphertext
  /// path written by loopback/Bare so Dart does not keep the whole file.
  Future<Uint8List?> decryptInboundAttachment(
    String fromPeerId,
    String fileId,
    List<int> fileKey,
  ) async {
    if (fileId.isEmpty || fileKey.isEmpty) return null;
    if (fileId.contains('://')) return null;
    final key = '${normalizePeerId(fromPeerId)}\x1f$fileId';
    final path = _inboundAttachPaths.remove(key);
    if (path != null) {
      final plain = await xorCipherPathToPlaintext(path, fileKey);
      if (plain == null || plain.isEmpty) return null;
      return Uint8List.fromList(plain);
    }
    final chunks = _inboundAttach.remove(key);
    if (chunks == null || chunks.isEmpty) return null;
    for (final chunk in chunks) {
      _inboundAttachBytes -= chunk.ciphertext.length;
    }
    if (_inboundAttachBytes < 0) _inboundAttachBytes = 0;
    try {
      return ResumableAttachment.decrypt(chunks, fileKey);
    } catch (_) {
      return null;
    }
  }

  /// XOR inbound ciphertext **to a plaintext path**. Never journals the
  /// fileKey. Null if only the in-memory chunk fallback is present.
  Future<String?> decryptInboundAttachmentPath(
    String fromPeerId,
    String fileId,
    List<int> fileKey,
  ) async {
    if (fileId.isEmpty || fileKey.isEmpty) return null;
    if (fileId.contains('://')) return null;
    final key = '${normalizePeerId(fromPeerId)}\x1f$fileId';
    final path = _inboundAttachPaths[key];
    if (path == null || path.isEmpty) return null;
    final dest = await xorCipherPathToPlaintextFile(path, fileKey);
    if (dest == null || dest.isEmpty) return null;
    _inboundAttachPaths.remove(key);
    return dest;
  }

  void _ingestAttachChunk(String fromPeerId, Map<String, Object?> frame) {
    if (_attachFrameHasForbiddenKey(frame, rejectB64: false)) {
      return;
    }
    final fileId = frame['fileId'] as String? ?? '';
    if (fileId.isEmpty || fileId.contains('://')) return;
    final hash = frame['hash'] as String? ?? '';
    final b64 = frame['b64'] as String? ?? '';
    final index = frame['index'];
    final offset = frame['offset'];
    if (hash.isEmpty || b64.isEmpty) return;
    if (index is! num || offset is! num) return;
    List<int> cipher;
    try {
      cipher = base64Decode(b64);
    } catch (_) {
      return;
    }
    if (cipher.isEmpty) return;
    if (_inboundAttachBytes + cipher.length > _maxInboundAttachBytes) return;
    final key = '$fromPeerId\x1f$fileId';
    final list = _inboundAttach.putIfAbsent(key, () => <AttachmentChunk>[]);
    list.add(
      AttachmentChunk(
        index: index.toInt(),
        offset: offset.toInt(),
        ciphertext: Uint8List.fromList(cipher),
        hash: hash,
      ),
    );
    _inboundAttachBytes += cipher.length;
  }

  void _ingestAttachPath(String fromPeerId, Map<String, Object?> frame) {
    if (_attachFrameHasForbiddenKey(frame, rejectB64: true)) {
      return;
    }
    final fileId = frame['fileId'] as String? ?? '';
    final path = frame['path'] as String? ?? '';
    if (fileId.isEmpty || path.isEmpty) return;
    if (path.contains('://') || fileId.contains('://')) return;
    _inboundAttachPaths['$fromPeerId\x1f$fileId'] = path;
  }

  Future<bool> sendEphemeral(String peerId, Object? msg) async {
    if (msg is Map && !outboundWireMapIsSendable(msg)) return false;
    var any = false;
    for (final target in _sendPeerIds(peerId)) {
      if (!await _ensureNativeSendReady(target) || !isWireReady(target)) {
        continue;
      }
      final wire = await encryptWirePayload(target, msg);
      await transport.send(target, TransportChannel.presence, utf8.encode(wire));
      any = true;
    }
    return any;
  }

  bool sendRoomPacket(String peerId, Map<String, Object?> packet) {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm)) return false;
    if (!replicationValueIsSafe(packet)) return false;
    final roomId = packet['roomId'];
    if (roomId is String && roomId.contains('://')) return false;
    final framed = Map<String, Object?>.from(packet)
      ..putIfAbsent('abWriter', () => selfDeviceId)
      ..putIfAbsent('abSeq', () => _roomSeq++);
    if (!replicationValueIsSafe(framed)) return false;
    final event = roomEventFromNativePacket(
      framed,
      fallbackWriter: selfDeviceId,
    );
    if (event != null) _applyRoom(event);
    for (final target in _sendPeerIds(peerId)) {
      unawaited(_sendControlWhenReady(target, framed));
    }
    return true;
  }

  Future<void> _sendControlWhenReady(
    String peerId,
    Map<String, Object?> framed,
  ) async {
    if (!await _ensureNativeSendReady(peerId)) return;
    await transport.send(
      normalizePeerId(peerId),
      TransportChannel.control,
      jsonPayload(framed),
    );
  }

  /// Phase 12 Autobase on the native carrier. Host-plaintext warning stays.
  /// Message bodies stay in the local projection — not Hypercore.
  Future<bool> sendAutobaseEvent(String peerId, RoomEvent event) async {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm)) return false;
    // Refuse before apply/send. toWire() strips secrets, so a nested
    // fileKey would otherwise mutate Autobase and ride a cleaned event.
    if (event.writerId.contains('://') || event.kind.contains('://')) {
      return false;
    }
    if (!replicationValueIsSafe(event.payload) ||
        !replicationValueIsSafe(event.toWire())) {
      return false;
    }
    _applyRoom(event);
    var any = false;
    for (final target in _sendPeerIds(peerId)) {
      if (!await _ensureNativeSendReady(target)) continue;
      await transport.send(
        target,
        TransportChannel.control,
        jsonPayload(event.toWire()),
      );
      any = true;
    }
    return any;
  }

  void _applyRoom(RoomEvent event, {bool persist = true}) {
    if (event.writerId.contains('://') || event.kind.contains('://')) return;
    final key = '${event.writerId}:${event.seq}';
    if (roomLog.any((e) => '${e.writerId}:${e.seq}' == key)) return;
    roomLog.add(event);
    rooms.reset();
    rooms.applyAll(roomLog);
    if (event.seq >= _roomSeq) _roomSeq = event.seq + 1;
    if (event.kind != 'membership') return;
    if (!persist) return;
    final record = journal.append(
      ReplicationEventKind.roomMembershipChanged,
      <String, Object?>{
        if (event.payload['roomId'] != null) 'roomId': event.payload['roomId'],
        'peerId': event.payload['peerId'],
        'action': event.payload['action'],
        if (event.payload['displayName'] != null)
          'displayName': event.payload['displayName'],
        'writerId': event.writerId,
        'seq': event.seq,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
    unawaited(_persistDurable(record));
    hypercore.append(record);
    for (final peer in List<String>.from(authenticated)) {
      _replicateRecord(peer, record);
    }
  }

  Future<void> sendCallSignal(String peerId, CallSignal signal) async {
    if (!replicationValueIsSafe(signal.toJson())) return;
    if (signal.callId.isEmpty || signal.callId.contains('://')) return;
    for (final target in _sendPeerIds(peerId)) {
      if (!await _ensureNativeSendReady(target)) continue;
      await transport.send(
        target,
        TransportChannel.call,
        jsonPayload(signal.toJson()),
      );
    }
  }

  Future<bool> sendDrop(String peerId, Object packet) async {
    if (packet is Map && !replicationValueIsSafe(packet)) return false;
    if (packet is! Map && packet is! List<int>) return false;
    var any = false;
    for (final target in _sendPeerIds(peerId)) {
      if (!await _ensureNativeSendReady(target)) continue;
      if (packet is Map) {
        await transport.send(
          target,
          TransportChannel.attachment,
          jsonPayload(Map<String, Object?>.from(packet)),
        );
      } else {
        await transport.send(
          target,
          TransportChannel.attachment,
          packet as List<int>,
        );
      }
      any = true;
    }
    return any;
  }

  /// Large files ride a path/descriptor into Bare. Never a Dart byte array
  /// over IPC. Control-plane Drop packets still use [sendDrop].
  Future<bool> sendFileFromPath(
    String peerId,
    TransportFileDescriptor file,
  ) async {
    if (file.path.isEmpty || file.path.contains('://')) {
      throw StateError('sendFileFromPath needs a local path');
    }
    var any = false;
    for (final target in _sendPeerIds(peerId)) {
      if (!await _ensureNativeSendReady(target)) continue;
      await transport.sendFile(target, file);
      any = true;
    }
    return any;
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
    _replicateToSendTargets(peerId, record);
  }

  void _replicateToSendTargets(String ownerPeerId, JournalRecord record) {
    for (final target in _sendPeerIds(ownerPeerId)) {
      _replicateRecord(target, record);
    }
  }

  void _replicateToAuthenticated(JournalRecord record) {
    for (final peer in List<String>.from(authenticated)) {
      _replicateRecord(peer, record);
    }
  }

  void _replicateRecord(String peerId, JournalRecord record) {
    final norm = normalizePeerId(peerId);
    if (!authenticated.contains(norm) || !connected.contains(norm)) return;
    if (isBlocked(norm)) return;
    final frame = hypercore.toReplicationFrame(record);
    if (!replicationValueIsSafe(frame)) return;
    unawaited(
      transport.send(
        norm,
        TransportChannel.replication,
        jsonPayload(frame),
      ),
    );
  }

  void _flushReplication(String peerId) {
    final norm = normalizePeerId(peerId);
    if (!authenticated.contains(norm) || !connected.contains(norm)) return;
    if (isBlocked(norm)) return;
    for (final record in hypercore.blocks) {
      final frame = hypercore.toReplicationFrame(record);
      if (!replicationValueIsSafe(frame)) continue;
      unawaited(
        transport.send(
          norm,
          TransportChannel.replication,
          jsonPayload(frame),
        ),
      );
    }
  }

  Future<void> _acceptRemoteBinding(
    String peerId,
    DeviceBinding binding,
  ) async {
    final norm = normalizePeerId(peerId);
    PinCheck? tofu;
    try {
      tofu = tofuCheck != null
          ? await tofuCheck!(norm, binding.identityPublicKey)
          : await checkPin(norm, binding.identityPublicKey);
    } catch (_) {
      tofu = null;
    }
    final noise =
        connectionNoiseFor?.call(norm) ?? devices?.noisePublicKeyFor(norm);
    final result = await evaluateConnectBindingChecks(
      binding: binding,
      connectionNoisePublicKey: noise,
      deviceRevoked: devices?.isRevoked(binding.deviceId) == true,
      contactBlocked: isBlocked(norm),
      tofu: tofu,
    );
    if (!result.ok) {
      bindingFailures[norm] = result.failedCheck ?? 'unknown';
      authenticated.remove(norm);
      remoteBindings.remove(norm);
      connected.remove(norm);
      _pendingInbound.remove(norm);
      try {
        await transport.disconnect(norm);
      } catch (_) {}
      return;
    }
    authenticated.add(norm);
    remoteBindings[norm] = binding;
    bindingFailures.remove(norm);
    if (tofuCheck == null &&
        tofu?.status == PinStatus.newPin &&
        binding.identityPublicKey.isNotEmpty) {
      try {
        await setPin(norm, binding.identityPublicKey);
      } catch (_) {}
    }
    _flushReplication(norm);
    _flushPendingInbound(norm);
  }

  void _onEvent(TransportEvent event) {
    switch (event) {
      case TransportConnected(:final peerId):
        connected.add(normalizePeerId(peerId));
        onPresence?.call(peerId, true);
        final caps = localCapabilities;
        if (caps != null) {
          final payload = <String, Object?>{
            'type': 'capabilities',
            ...caps.toWire(),
          };
          if (helloEnvelopeIsSafe(payload)) {
            unawaited(
              transport.send(
                normalizePeerId(peerId),
                TransportChannel.control,
                jsonPayload(payload),
              ),
            );
          }
        }
        final binding = localBinding;
        if (binding != null) {
          final payload = <String, Object?>{
            'type': kDeviceBindingWireType,
            ...binding.toWire(),
          };
          if (helloEnvelopeIsSafe(payload)) {
            unawaited(
              transport.send(
                normalizePeerId(peerId),
                TransportChannel.control,
                jsonPayload(payload),
              ),
            );
          }
        }
      case TransportAuthenticated(:final peerId, :final binding):
        unawaited(_acceptRemoteBinding(peerId, binding));
      case TransportDisconnected(:final peerId):
        final norm = normalizePeerId(peerId);
        connected.remove(norm);
        authenticated.remove(norm);
        remoteBindings.remove(norm);
        _pendingInbound.remove(norm);
        onPresence?.call(peerId, false);
      case TransportFrame(:final peerId, :final channel, :final bytes):
        _onFrame(peerId, channel, bytes);
      case TransportError(:final code, :final message):
        if (code == 'relay-blow-up') {
          noteRelayBlowUp(detail: message);
        }
      case TransportPathChanged(:final peerId, :final path):
        final norm = normalizePeerId(peerId);
        paths[norm] = path;
        onPathChanged?.call(norm, path);
      case TransportNetworkChanged(:final detail):
        onNetworkChanged?.call(detail);
      case TransportDeliveryState(:final peerId, :final state):
        onDeliveryState?.call(normalizePeerId(peerId), state);
      default:
        break;
    }
  }

  bool _isConnectHandshakeFrame(TransportChannel channel, List<int> bytes) {
    if (channel == TransportChannel.call ||
        channel == TransportChannel.attachment ||
        channel == TransportChannel.replication) {
      return false;
    }
    if (bytes.isEmpty) return false;
    try {
      final decoded = decodeJsonPayload(bytes);
      final type = decoded['type'];
      return type == kDeviceBindingWireType;
    } catch (_) {
      return false;
    }
  }

  void _queueInbound(
    String peerId,
    TransportChannel channel,
    List<int> bytes,
  ) {
    final queue = _pendingInbound.putIfAbsent(peerId, () => <_QueuedInbound>[]);
    var total = 0;
    for (final item in queue) {
      total += item.bytes.length;
    }
    if (queue.length >= _maxPendingInboundFrames ||
        total + bytes.length > _maxPendingInboundBytes) {
      _pendingInbound.remove(peerId);
      noteMessagesLost('inbound auth queue overflow');
      return;
    }
    queue.add(_QueuedInbound(channel, List<int>.from(bytes)));
  }

  void _flushPendingInbound(String peerId) {
    final queued = _pendingInbound.remove(peerId);
    if (queued == null || queued.isEmpty) return;
    for (final item in queued) {
      _dispatchFrame(peerId, item.channel, item.bytes);
    }
  }

  void _onFrame(String peerId, TransportChannel channel, List<int> bytes) {
    final norm = normalizePeerId(peerId);
    if (isBlocked(norm)) return;
    if (!authenticated.contains(norm) &&
        !_isConnectHandshakeFrame(channel, bytes)) {
      _queueInbound(norm, channel, bytes);
      return;
    }
    _dispatchFrame(norm, channel, bytes);
  }

  void _dispatchFrame(String peerId, TransportChannel channel, List<int> bytes) {
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
        final decoded = decodeJsonPayload(bytes);
        if (decoded['type'] == 'attach-chunk') {
          _ingestAttachChunk(norm, decoded);
          return;
        }
        if (decoded['type'] == 'attach-chunk-path') {
          _ingestAttachPath(norm, decoded);
          return;
        }
        if (!replicationValueIsSafe(decoded)) return;
        onDrop?.call(norm, decoded);
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
        if (remote.kind == ReplicationEventKind.roomMembershipChanged) {
          final event = _membershipEventFromJournal(remote);
          if (event != null) _applyRoom(event, persist: false);
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
        // Nested kForbiddenReplicationFields: refuse before Autobase / onPacket.
        if (!replicationValueIsSafe(decoded)) return;
        data = decoded;
        final roomEvent = roomEventFromNativePacket(
          decoded,
          fallbackWriter: norm,
        );
        if (roomEvent != null) _applyRoom(roomEvent);
        if (decoded['type'] == kDeviceBindingWireType) {
          try {
            unawaited(
              _acceptRemoteBinding(norm, DeviceBinding.fromWire(decoded)),
            );
          } catch (_) {}
          return;
        }
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
    if (channel == TransportChannel.receipt) {
      onDeliveryState?.call(norm, 'received');
    }
    unawaited(onPacket(norm, data));
  }
}

class _QueuedInbound {
  _QueuedInbound(this.channel, this.bytes);

  final TransportChannel channel;
  final List<int> bytes;
}
