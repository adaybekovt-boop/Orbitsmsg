// Live dual-stack: same X3DH/ratchet bytes, different carrier.
// Default rollout stays PeerJS. Native path requires an explicit
// discovery secret — never HASH(peerId).

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

import '../attachments/attachment_keys.dart';
import '../attachments/file_transfer_session.dart';
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
    AttachmentKeyStore? attachmentKeys,
    HypercoreLocalStore? hypercore,
  }) : secrets = secrets ?? discoverySecretStore,
       identities = identities ?? TrustedIdentityStore(),
       attachmentKeys = attachmentKeys ?? AttachmentKeyStore(),
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
  final TrustedIdentityStore identities;
  final HypercoreLocalStore hypercore;
  final Future<void> Function(String peerId, {required bool authorized})?
      confirmPeerAuthorization;
  final Future<void> Function(JournalRecord record)? onRemoteRecord;
  final AttachmentKeyStore attachmentKeys;
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

  final Map<String, String> _expectedPeer = <String, String>{};
  final Map<String, DeviceBinding> _bindings = <String, DeviceBinding>{};
  final Map<String, String> _fingerprintOwner = <String, String>{};
  final Map<String, String> _fingerprintTransport = <String, String>{};
  final FileTransferCoordinator files = FileTransferCoordinator();

  void attach() {
    _sub ??= transport.events.listen(_onEvent);
    files.onDrop = (peer, packet) => onDrop?.call(peer, packet);
    files.send = (peer, bytes) => transport.send(
      peer,
      TransportChannel.attachment,
      bytes,
    );
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
    files.fileKeyFor = (peer, transferId) => attachmentKeys.require(peer, transferId);
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
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (isAuthenticated(peerId)) return;
      if (!connecting.contains(peerId) && !isNativeConnected(peerId)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
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
        'ownerPeerId': selfPeerId(),
        'audience': 'owner-devices',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
    unawaited(durableJournal?.append(record));
    hypercore.append(record);
    _fanoutReplication(record);
  }

  void authorizeDevice(AuthorizedDevice device) {
    devices?.authorize(device);
    final record = journal.append(
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
    unawaited(durableJournal?.append(record));
    hypercore.append(record);
    _fanoutReplication(record);
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
    List<int> fileKey, {
    required String fileId,
  }) async {
    if (!isAuthenticated(peerId)) {
      throw StateError('attachment requires an authenticated peer');
    }
    final chunks = ResumableAttachment.chunk(
      plaintext,
      fileKey,
      fileId: fileId,
      totalBytes: plaintext.length,
    );
    for (final chunk in chunks) {
      await transport.send(
        normalizePeerId(peerId),
        TransportChannel.attachment,
        jsonPayload({
          'type': 'attach-chunk',
          'fileId': fileId,
          'index': chunk.index,
          'offset': chunk.offset,
          'totalBytes': plaintext.length,
          'hash': chunk.hash,
          'b64': base64Encode(chunk.ciphertext),
        }),
      );
    }
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
    unawaited(
      transport.send(norm, TransportChannel.control, jsonPayload(packet)),
    );
    return true;
  }

  Future<void> sendCallSignal(String peerId, CallSignal signal) {
    final norm = normalizePeerId(peerId);
    if (!isAuthenticated(norm)) {
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

  void _appendEnvelope(String peerId, List<int> encrypted) {
    final id =
        '${DateTime.now().millisecondsSinceEpoch}-$peerId-${encrypted.length}';
    final record = journal.appendEnvelope(
      MessageEnvelopeCreated(
        eventId: id,
        conversationId: conversationIdForPeers(selfPeerId(), peerId),
        senderIdentity: selfPeerId(),
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
        unawaited(
          _onAuthenticated(peerId, binding, connectionNoisePublicKey),
        );
      case TransportDisconnected(:final peerId):
        final norm = normalizePeerId(peerId);
        connecting.remove(norm);
        connected.remove(norm);
        authenticated.remove(norm);
        _authorizedPending.remove(norm);
        _expectedPeer.remove(norm);
        _bindings.remove(norm);
        _fingerprintTransport.removeWhere((_, id) => id == norm);
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
    if (!await _evaluateBinding(transportId, binding, connectionNoisePublicKey)) {
      await _reject(transportId);
      return;
    }
    _rememberAuthorizedPending(transportId, binding);
    try {
      await confirmPeerAuthorization?.call(transportId, authorized: true);
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
    if (!await _evaluateBinding(transportId, binding, connectionNoisePublicKey)) {
      await _reject(transportId);
      return;
    }
    _rememberAuthorizedPending(transportId, binding);
    try {
      await confirmPeerAuthorization?.call(transportId, authorized: true);
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
    onPresence?.call(logical, true);

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

  Future<void> _reject(String peerId) async {
    connecting.remove(peerId);
    connected.remove(peerId);
    authenticated.remove(peerId);
    _authorizedPending.remove(peerId);
    try {
      await confirmPeerAuthorization?.call(peerId, authorized: false);
    } catch (_) {}
    try {
      await transport.disconnect(peerId);
    } catch (_) {}
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
      if (files.handleInbound(norm, bytes)) return;
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
        final record = hypercore.applyRemote(
          decodeJsonPayload(bytes),
          authenticatedPeerId: norm,
          selfPeerId: selfPeerId(),
          peerIsOwnDevice: _isOwnDevice(norm),
        );
        if (record != null) {
          unawaited(durableJournal?.append(record));
          unawaited(onRemoteRecord?.call(record));
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
        unawaited(() async {
          try {
            final plain = await decryptWirePayload(norm, text);
            tryAcceptAttachmentKeyMessage(attachmentKeys, norm, plain);
          } catch (_) {}
        }());
      } else {
        final decoded = decodeJsonPayload(bytes);
        data = decoded;
        if (tryAcceptAttachmentKeyMessage(attachmentKeys, norm, decoded)) {
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
