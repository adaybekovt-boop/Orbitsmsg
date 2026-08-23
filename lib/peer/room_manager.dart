// Temporary private "Discord-style" rooms — network layer (Phase 2).
//
// Topology: a STAR rooted at the host. The host's own peer code doubles as the
// room code, so a guest dials the host directly (`PeerID хоста извлекается из
// кода комнаты` — the code *is* the peerId). Guests never talk to each other
// over data; the host relays every `room_msg`. Voice is the exception: a
// channel of `type == 'voice'` forms a direct WebRTC audio MESH between its
// participants (capped at 6).
//
// Wire packets (all PLAINTEXT maps on the reliable channel — see
// `connections_notifier.sendRoomPacket` / `packet_router.isRoomPacket`; they
// bypass the per-message ratchet on purpose so unverified guests aren't
// blocked by the TOFU/`verified` gate):
//   room_join            guest → host   {roomId, guestName, guestPeerId, avatarDataUrl}
//   room_members_update  host → guests  {roomId, members:[{peerId,name,avatarDataUrl}]}
//   room_msg             both           {id, roomId, channelId, text, fromName, fromPeerId, ts}
//   room_channel_create  host → guests  {roomId, channel:{id,name,type,position}}
//   room_destroy         host → guests  {roomId}
//   room_leave           guest → host   {roomId, guestPeerId}
//   room_spatial_update  both           {roomId, peerId, x, y}  (host relays)
//
// Architecture mirrors `messaging_notifier` / `connections_notifier`: the
// manager registers a [RoomBridge] on the connection registry (no provider
// cycle), sends through `connections.sendRoomPacket`, and persists through
// `storage/db.dart`. It tracks guest *peerIds* (not raw `PeerDataConnection`
// objects) and resolves live connections through the registry on each send —
// the registry owns connection lifecycle (glare/teardown), so holding raw
// refs here would risk using a swapped-out connection.

import 'dart:async';
import 'dart:convert' show base64Decode, base64Encode;
import 'dart:math';
import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../state/connections_notifier.dart';
import '../state/local_profile_provider.dart';
import '../state/peer_connection_provider.dart';
import '../storage/db.dart' as db;
import '../storage/security_log.dart';
import '../utils/common.dart' show safeAvatarDataUrl;
import 'helpers.dart';
import 'peerjs_client.dart';
import 'peer_server_core.dart';
import 'room_invite.dart';
import 'room_scoped_transport.dart';
import 'room_signaling_host.dart';
import 'security_monitor.dart';
import 'spatial_audio_engine.dart';

/// Whether the local user is hosting a room, visiting one as a guest, or in
/// no room at all.
enum RoomRole { none, host, guest }

/// Max participants in a single voice channel (host + guests). Beyond this the
/// mesh gets too heavy, so we warn and cap the calls we initiate.
const int kMaxVoiceParticipants = 6;

/// Max participants in a room INCLUDING the host. The 16th member is rejected
/// with `room_join_reject` (reason 'full').
const int kMaxRoomMembers = 15;

/// Caps for untrusted inbound room strings.
const int kMaxRoomTextLen = 4000;
const int kMaxRoomNameLen = 80;

/// Min interval between broadcast `room_spatial_update` packets during a drag
/// (~10/sec). Local audio + UI update on every move; only the network send is
/// throttled. The final position on pan-end bypasses this (isFinal).
const int kSpatialSendIntervalMs = 100;

/// Ring radius used when auto-arranging / resetting spatial positions. Matches
/// the canvas default layout so reset lands balloons where the radar would.
const double kSpatialRingRadius = 0.62;

/// Caps for room stickers + file attachments. Files are relayed by the host to
/// every guest, so the per-file size is bounded to keep host bandwidth + the
/// reliable DataChannel frame (24 MiB hard cap in peerjs_client) sane. Matches
/// the 1:1 caps so a file that sends in a DM also sends in a room.
const int kMaxRoomStickerUrlLen = 512 * 1024;
const int kMaxRoomFileRawBytes = 12 * 1024 * 1024; // 12 MiB raw
const int kMaxRoomFileB64Len = 16 * 1024 * 1024; // ~12 MiB base64-encoded
const int kMaxRoomFileThumbLen = 256 * 1024; // inline preview data URL

/// The only `room_*` packet types we route. Anything else is ignored without
/// throwing — keeps the allow-list in one place (audit item 8).
const Set<String> kRoomPacketTypes = <String>{
  'room_join',
  'room_join_reject',
  'room_members_update',
  'room_msg',
  'room_channel_create',
  'room_destroy',
  'room_leave',
  'room_spatial_update',
};

/// Pure authorization check for an incoming room-voice media call (audit item
/// 6). Auto-answer only when we're in the matching voice channel, the caller is
/// a known member, and capacity allows. Extracted as a free function so it can
/// be unit-tested without real WebRTC.
bool shouldAnswerRoomVoiceCall({
  required Map<String, Object?> metadata,
  required String fromPeerId,
  required RoomRole role,
  required String? roomId,
  required String? activeChannelId,
  required Set<String> members,
  required int currentVoiceCount,
  int maxVoice = kMaxVoiceParticipants,
}) {
  if (metadata['channel'] != 'room-voice') return false;
  if (role == RoomRole.none || roomId == null) return false;
  if (metadata['roomId'] != roomId) return false;
  final ch = metadata['channelId'];
  if (ch == null || ch != activeChannelId) return false;
  if (fromPeerId.isEmpty || !members.contains(fromPeerId)) return false;
  // -1 reserves the slot for ourselves.
  if (currentVoiceCount >= maxVoice - 1) return false;
  return true;
}

/// Reactive snapshot of the local user's room session.
class RoomState {
  const RoomState({
    this.role = RoomRole.none,
    this.roomId,
    this.hostPeerId,
    this.activeChannelId,
    this.guestPeerIds = const <String>{},
    this.voicePeerIds = const <String>{},
    this.spatialPositions = const <String, Offset>{},
    this.securityAlert,
    this.serverActive = true,
    this.joinError,
    this.voiceChannelId,
    this.micEnabled = true,
    this.micAvailable = false,
    this.selfHostInvite,
  });

  /// Current role.
  final RoomRole role;

  /// Active room id (== host peer code). Null when not in a room.
  final String? roomId;

  /// Host peer code (for a guest, who to send to; for a host, == self).
  final String? hostPeerId;

  /// Channel the user is currently viewing/talking in.
  final String? activeChannelId;

  /// Host-only: peerIds of connected guests (star spokes).
  final Set<String> guestPeerIds;

  /// Peers we currently hold a voice (audio) mesh call with.
  final Set<String> voicePeerIds;

  /// Per-peer positions on the spatial-audio canvas (peerId → offset, each
  /// component in [-1, 1]). Shared across the room: dragging a balloon
  /// broadcasts the new position so every client's canvas + audio update.
  final Map<String, Offset> spatialPositions;

  /// Latest fraud-detector warning (IP collision / IP hop), or null when the
  /// session looks clean. Drives the red glass banner at the top of the chat.
  final String? securityAlert;

  /// Host-only: whether the server is accepting traffic. `setServerActive(false)`
  /// flips it so inbound handlers reject joins + ignore messages even though the
  /// host keeps its own session. Guests keep this `true` (meaningless for them).
  final bool serverActive;

  /// Guest-only: a human-readable join failure/rejection reason (full / offline
  /// / invalid / timeout), or null. The UI surfaces it as a SnackBar/banner.
  final String? joinError;

  /// The voice channel we're currently connected to (mesh up), or null when not
  /// in voice. Drives the compact voice panel — independent of which channel is
  /// merely *viewed*.
  final String? voiceChannelId;

  /// Whether our mic is unmuted (local audio tracks enabled).
  final bool micEnabled;

  /// Whether a local mic stream was actually acquired (false ⇒ "no mic").
  final bool micAvailable;

  /// Self-hosted rooms only: the `orbits-room:` invite string a host shares so
  /// guests can reach the embedded signaling server running on this device.
  /// Null for cloud (peerjs.com) rooms and for guests. Parse with
  /// [RoomInvite.tryParse] to render LAN/public reach in the UI.
  final String? selfHostInvite;

  /// True when this session runs its own embedded signaling server.
  bool get isSelfHosted => selfHostInvite != null;

  /// True when we hold a live voice session.
  bool get inVoice => voiceChannelId != null;

  RoomState copyWith({
    RoomRole? role,
    Object? roomId = _unset,
    Object? hostPeerId = _unset,
    Object? activeChannelId = _unset,
    Set<String>? guestPeerIds,
    Set<String>? voicePeerIds,
    Map<String, Offset>? spatialPositions,
    Object? securityAlert = _unset,
    bool? serverActive,
    Object? joinError = _unset,
    Object? voiceChannelId = _unset,
    bool? micEnabled,
    bool? micAvailable,
    Object? selfHostInvite = _unset,
  }) =>
      RoomState(
        role: role ?? this.role,
        roomId: identical(roomId, _unset) ? this.roomId : roomId as String?,
        hostPeerId: identical(hostPeerId, _unset)
            ? this.hostPeerId
            : hostPeerId as String?,
        activeChannelId: identical(activeChannelId, _unset)
            ? this.activeChannelId
            : activeChannelId as String?,
        guestPeerIds: guestPeerIds ?? this.guestPeerIds,
        voicePeerIds: voicePeerIds ?? this.voicePeerIds,
        spatialPositions: spatialPositions ?? this.spatialPositions,
        securityAlert: identical(securityAlert, _unset)
            ? this.securityAlert
            : securityAlert as String?,
        serverActive: serverActive ?? this.serverActive,
        joinError:
            identical(joinError, _unset) ? this.joinError : joinError as String?,
        voiceChannelId: identical(voiceChannelId, _unset)
            ? this.voiceChannelId
            : voiceChannelId as String?,
        micEnabled: micEnabled ?? this.micEnabled,
        micAvailable: micAvailable ?? this.micAvailable,
        selfHostInvite: identical(selfHostInvite, _unset)
            ? this.selfHostInvite
            : selfHostInvite as String?,
      );
}

const Object _unset = Object();

/// Validated content of a `room_msg`, regardless of kind (text/sticker/file).
/// Built from an inbound packet (after sanitisation) and reused to derive both
/// the DB payload ([payload]) and the host→guest relay fields ([wireFields]).
class _RoomContent {
  _RoomContent({
    required this.kind,
    this.text = '',
    this.sticker,
    this.attachment,
    this.b64,
  });

  final String kind; // 'text' | 'sticker' | 'file'
  final String text;
  final Map<String, Object?>? sticker;
  final Map<String, Object?>? attachment;
  final String? b64;

  /// Extra fields the host folds into the relayed packet for this kind.
  Map<String, Object?> wireFields() {
    switch (kind) {
      case 'sticker':
        return {'sticker': sticker};
      case 'file':
        return {'attachment': attachment, if (b64 != null) 'b64': b64};
      default:
        return {'text': text};
    }
  }

  /// The persisted `payload` map [MessageBubble] reads (`type` + content). Text
  /// keeps the legacy `kind:'text'` shape (renders as default text either way).
  Map<String, Object?> payload(String fromName) {
    switch (kind) {
      case 'sticker':
        return {'type': 'sticker', 'sticker': sticker, 'fromName': fromName};
      case 'file':
        return {'type': 'file', 'attachment': attachment, 'fromName': fromName};
      default:
        return {'kind': 'text', 'text': text, 'fromName': fromName};
    }
  }
}

class RoomManager extends StateNotifier<RoomState> {
  RoomManager(this._ref) : super(const RoomState()) {
    // Transport is behind [RoomTransport] (overridable in tests). Receive
    // inbound `room_*` packets without a provider cycle — same bridge pattern
    // as MessagingNotifier/DropNotifier.
    _defaultTransport = _ref.read(roomTransportProvider);
    _defaultTransport.bindRoom(RoomBridge(handleInbound: _handleInbound));
  }

  final Ref _ref;

  /// The peerjs.com-backed transport (production) or a test fake. Always present.
  late final RoomTransport _defaultTransport;

  /// When a room is *self-hosted*, all room signaling routes through this
  /// transport (a dedicated PeerJS client pointed at the host's embedded
  /// server) instead of [_defaultTransport]. Null for cloud rooms.
  RoomScopedTransport? _selfHostedTransport;

  /// Host-side: the embedded signaling server + UPnP lifecycle. Null unless we
  /// are hosting a self-hosted room.
  RoomSignalingHost? _selfHost;

  /// The transport in effect right now: the self-hosted one when present, else
  /// the default. Everything below talks through [_connections]/[_rawPeer],
  /// which read this — so swapping it transparently redirects all room traffic.
  RoomTransport get _transport => _selfHostedTransport ?? _defaultTransport;

  final Random _rng = Random.secure();

  /// Wall-clock ms of the last `room_spatial_update` we put on the wire. Drag
  /// moves throttle against this (see [kSpatialSendIntervalMs]); the final
  /// position always goes out regardless.
  int _lastSpatialSendMs = 0;

  /// Active voice-mesh calls, keyed by remote peerId.
  final Map<String, PeerMediaConnection> _voiceConns = {};
  MediaStream? _voiceStream;

  /// Per-peer subscriptions to remote-stream arrival; on web the spatial-audio
  /// engine taps the stream when it fires.
  final Map<String, StreamSubscription<MediaStream>> _voiceStreamSubs = {};

  /// Subscription to INCOMING room-voice media calls. Live only while we're in
  /// a voice channel; cancelled in [_stopVoice].
  StreamSubscription<PeerMediaConnection>? _incomingCallSub;

  /// Positional-audio engine — Web Audio (StereoPanner + Gain) on web, a no-op
  /// fallback on mobile/desktop.
  final SpatialAudioEngine _spatialAudio = createSpatialAudioEngine();

  /// Fraud / flood detector (IP collision + IP hop + rate limit). Pure
  /// in-memory; the UI reads [RoomState.securityAlert] for the warning banner.
  final SecurityMonitor _security = SecurityMonitor();

  /// Optional handler for inbound `qr_auth_response` packets, registered by the
  /// desktop QrPairingPage while it displays a code. Routed through here because
  /// the connection layer already bridges plaintext control maps to RoomManager.
  void Function(String remoteId, Map<String, Object?> packet)? _qrAuthListener;

  /// Delegates to the (possibly faked) transport. Named `_connections` for
  /// continuity — the method surface (sendRoomPacket/openReliable/hasReliable)
  /// matches the registry it wraps in production.
  RoomTransport get _connections => _transport;

  PeerJsClient? get _rawPeer => _transport.rawPeer;

  String _selfPeerId() => _ref.read(currentPeerIdProvider) ?? '';

  // ─── Public API ───────────────────────────────────────────────────

  /// Host a new room. The host's own peer code becomes the room code; the two
  /// default channels (#general + 🔊 Голосовой 1) are auto-provisioned by
  /// `db.saveRoom`. Idempotent enough to re-host the same code.
  ///
  /// When [selfHosted] is true (and the platform can host — see
  /// [canHostSignalingServer]), this device runs its OWN embedded signaling
  /// server instead of relying on peerjs.com: an `orbits-room:` invite carrying
  /// the server's LAN address (+ a UPnP public address when available) is
  /// surfaced in [RoomState.selfHostInvite] for the host to share. On a
  /// platform that can't host, the call fails with a [RoomState.joinError]
  /// rather than silently falling back to the cloud.
  Future<void> createRoom(String name, {bool selfHosted = false}) async {
    final self = _ref.read(localProfileProvider);
    final selfId = self?.peerId ?? _selfPeerId();
    if (selfId.isEmpty) {
      debugPrint('[room] createRoom: no local peerId yet');
      // Never fail silently — surface it so the UI shows a hint instead of
      // navigating into an empty room.
      state = const RoomState(
        joinError: 'Профиль ещё не готов. Подождите секунду и попробуйте снова.',
      );
      return;
    }

    if (selfHosted && !canHostSignalingServer) {
      state = const RoomState(joinError: kServerHostDesktopOnlyMessage);
      return;
    }

    final roomId = selfId; // host peer code IS the room code

    // Self-hosted: stand up the embedded signaling server + the host's loopback
    // client BEFORE persisting anything. A start failure must surface a SPECIFIC
    // reason (bind/firewall, no LAN address, loopback timeout) and create
    // NOTHING — never a half-baked "offline" room that looks like success
    // (audit: a failed create must look like a failure, not a working server).
    String? invite;
    if (selfHosted) {
      try {
        // Bounded so a stuck embedded server / loopback client can never hang
        // the create flow forever. host.start + _waitClientOpen are each
        // bounded internally; this is the outer backstop.
        invite =
            await _startSelfHost(roomId).timeout(const Duration(seconds: 15));
      } catch (e) {
        // Keep logs useful but clean: the typed reason already carries the
        // low-level detail (e.g. the OS bind error) via its toString — far more
        // useful than the async stack, which here is mostly test/event-loop noise.
        debugPrint('[room] self-host start failed: $e');
        await _teardownSelfHost();
        state = RoomState(joinError: _selfHostErrorMessage(e));
        return;
      }
    }

    _security.reset(); // fresh fraud/flood state per session

    await db.saveRoom({
      'id': roomId,
      'name': name,
      'hostPeerId': selfId,
      'isHost': true,
      'createdAt': now(),
      'status': 'active',
    });
    // Host is the first member of its own roster.
    await db.saveRoomMember({
      'roomId': roomId,
      'peerId': selfId,
      'displayName': self?.displayName ?? '',
      'avatarDataUrl': self?.avatarDataUrl,
      'isOnline': true,
      'joinedAt': now(),
    });

    final channels = await db.getRoomChannels(roomId);
    final general = channels.firstWhere(
      (c) => c['type'] == 'text',
      orElse: () => channels.isNotEmpty ? channels.first : const {},
    );

    state = RoomState(
      role: RoomRole.host,
      roomId: roomId,
      hostPeerId: selfId,
      activeChannelId: general['id'] as String?,
      serverActive: true,
      selfHostInvite: invite,
    );

    // Best-effort internet exposure runs in the background so room creation is
    // instant and LAN-usable immediately; if UPnP succeeds the invite upgrades.
    if (selfHosted) unawaited(_upgradeToInternet(roomId));
  }

  /// Map a self-host startup failure to a clear, user-facing RU diagnostic.
  /// [SelfHostException] carries a typed reason; a bare [TimeoutException] is
  /// the outer 15s backstop firing. Anything else falls through to a generic —
  /// but still non-silent — message.
  String _selfHostErrorMessage(Object e) {
    if (e is SelfHostException) {
      switch (e.failure) {
        case SelfHostFailure.bind:
          final d = e.detail;
          return 'Не удалось открыть сетевой порт для сервера. Возможно, его '
              'блокирует брандмауэр/антивирус или порт уже занят'
              '${d != null && d.isNotEmpty ? ' ($d)' : ''}.';
        case SelfHostFailure.noLanAddress:
          return 'Не удалось определить адрес компьютера в локальной сети '
              '(LAN). Подключитесь к Wi-Fi или Ethernet и попробуйте снова.';
        case SelfHostFailure.clientTimeout:
          return 'Сервер запущен, но подключиться к нему не удалось (таймаут '
              'локального клиента). Проверьте брандмауэр — он может блокировать '
              'локальные соединения.';
        case SelfHostFailure.unsupported:
          return kServerHostDesktopOnlyMessage;
      }
    }
    if (e is TimeoutException) {
      return 'Сервер не запустился вовремя (таймаут). Проверьте сеть и '
          'брандмауэр, затем попробуйте снова.';
    }
    return 'Не удалось запустить сервер: $e';
  }

  /// Start the embedded server + the host's loopback room-scoped client. Swaps
  /// [_selfHostedTransport] in and returns the (LAN-only) invite string.
  Future<String?> _startSelfHost(String roomId) async {
    final host = _ref.read(roomSignalingHostFactoryProvider)();
    final invite = await host.start(roomId: roomId);
    _selfHost = host;

    // The host connects to its OWN server over loopback using the room key
    // (never the public 'peerjs' default).
    final client = buildRoomScopedClient(
      selfId: roomId,
      host: '127.0.0.1',
      port: host.port,
      key: invite.key ?? generateRoomSignalingKey(),
    );
    final transport = RoomScopedTransport(client)
      ..wire()
      ..bindRoom(RoomBridge(handleInbound: _handleInbound));
    _selfHostedTransport = transport;

    await client.start();
    if (!await _waitClientOpen(client)) {
      throw SelfHostException(SelfHostFailure.clientTimeout);
    }
    return invite.encode();
  }

  /// Background best-effort: open the router port via UPnP and, on success,
  /// re-issue the invite with the public `ip:port` folded in.
  Future<void> _upgradeToInternet(String roomId) async {
    final host = _selfHost;
    if (host == null) return;
    final pub = await host.tryOpenInternet();
    if (pub == null || !mounted) return;
    final current = RoomInvite.tryParse(state.selfHostInvite ?? '');
    if (current == null) return;
    if (state.roomId != roomId || state.role != RoomRole.host) return;
    final upgraded = RoomInvite(
      roomId: current.roomId,
      lanHosts: current.lanHosts,
      port: current.port,
      publicHostPort: pub,
      key: current.key,
    );
    state = state.copyWith(selfHostInvite: upgraded.encode());
  }

  /// Join an existing room. Accepts either a plain host peer code (cloud /
  /// peerjs.com room) OR an `orbits-room:` invite for a self-hosted room — the
  /// latter is detected and routed to [_joinSelfHosted]. For the cloud path we
  /// dial the host's reliable channel, then announce ourselves with `room_join`;
  /// the host replies with the channel list + roster.
  Future<void> joinRoom(String roomCode, String displayName) async {
    final invite = RoomInvite.tryParse(roomCode);
    if (invite != null) {
      await _joinSelfHosted(invite, displayName);
      return;
    }

    final self = _ref.read(localProfileProvider);
    final selfId = self?.peerId ?? _selfPeerId();
    final hostPeerId = normalizePeerId(roomCode);
    if (selfId.isEmpty || !isValidPeerId(hostPeerId) || hostPeerId == selfId) {
      debugPrint('[room] joinRoom: invalid host code "$roomCode"');
      state = const RoomState(joinError: 'Неверный код комнаты.');
      return;
    }
    final roomId = hostPeerId;

    await db.saveRoom({
      'id': roomId,
      'name': '',
      'hostPeerId': hostPeerId,
      'isHost': false,
      'createdAt': now(),
      'status': 'active',
    });
    _security.reset();
    state = RoomState(
      role: RoomRole.guest,
      roomId: roomId,
      hostPeerId: hostPeerId,
    );

    final conns = _connections;
    conns.openReliable(hostPeerId);
    if (!await _waitReliable(hostPeerId)) {
      debugPrint('[room] joinRoom: no reliable channel to host $hostPeerId');
      await db.setRoomStatus(roomId, 'offline');
      state = const RoomState(
        joinError: 'Не удалось подключиться к серверу (таймаут).',
      );
      return;
    }

    final name = _clampName(displayName.trim().isNotEmpty
        ? displayName.trim()
        : (self?.displayName ?? ''));
    conns.sendRoomPacket(hostPeerId, {
      'type': 'room_join',
      'roomId': roomId,
      'guestName': name,
      // guestPeerId is informational only — the host authenticates by the
      // transport's remoteId and rejects a mismatched claim.
      'guestPeerId': selfId,
      if (safeAvatarDataUrl(self?.avatarDataUrl) != null)
        'avatarDataUrl': safeAvatarDataUrl(self?.avatarDataUrl),
    });
  }

  /// Clear the last join error (e.g. after the UI showed its SnackBar).
  void clearJoinError() {
    if (state.joinError != null) {
      state = state.copyWith(joinError: null);
    }
  }

  /// Join a SELF-HOSTED room from an `orbits-room:` invite. Spins up a
  /// room-scoped client pointed at the host's embedded server, trying each
  /// reachable endpoint (public first, then LAN) until both the signaling
  /// client opens AND a reliable channel to the host comes up; then announces
  /// `room_join` exactly like the cloud path.
  Future<void> _joinSelfHosted(RoomInvite invite, String displayName) async {
    final self = _ref.read(localProfileProvider);
    final selfId = self?.peerId ?? _selfPeerId();
    final hostPeerId = invite.roomId;
    if (selfId.isEmpty || !isValidPeerId(hostPeerId) || hostPeerId == selfId) {
      state = const RoomState(joinError: 'Неверный код комнаты.');
      return;
    }
    final endpoints = invite.dialEndpoints;
    if (endpoints.isEmpty) {
      state = const RoomState(joinError: 'В приглашении нет адреса сервера.');
      return;
    }
    if (isForbiddenEmbeddedSignalingKey(invite.key)) {
      state = const RoomState(
        joinError: 'Приглашение без ключа комнаты. Попросите новый код.',
      );
      return;
    }

    final roomId = hostPeerId;
    await db.saveRoom({
      'id': roomId,
      'name': '',
      'hostPeerId': hostPeerId,
      'isHost': false,
      'createdAt': now(),
      'status': 'active',
    });
    _security.reset();
    state = RoomState(
      role: RoomRole.guest,
      roomId: roomId,
      hostPeerId: hostPeerId,
    );

    RoomScopedTransport? connected;
    for (final ep in endpoints) {
      final hp = _splitHostPort(ep);
      if (hp == null) continue;
      final client = buildRoomScopedClient(
        selfId: selfId,
        host: hp.$1,
        port: hp.$2,
        key: invite.key ?? '',
      );
      final transport = RoomScopedTransport(client)
        ..wire()
        ..bindRoom(RoomBridge(handleInbound: _handleInbound));
      // Activate it so _connections/_waitReliable route through this candidate.
      _selfHostedTransport = transport;
      try {
        await client.start();
        if (!await _waitClientOpen(client)) {
          await _discardCandidate(transport);
          continue;
        }
        transport.openReliable(hostPeerId);
        if (await _waitReliable(hostPeerId)) {
          connected = transport;
          break;
        }
        await _discardCandidate(transport);
      } catch (_) {
        await _discardCandidate(transport);
      }
    }

    if (connected == null) {
      await db.setRoomStatus(roomId, 'offline');
      state = const RoomState(
        joinError: 'Не удалось подключиться к серверу (таймаут).',
      );
      return;
    }

    final name = _clampName(displayName.trim().isNotEmpty
        ? displayName.trim()
        : (self?.displayName ?? ''));
    _connections.sendRoomPacket(hostPeerId, {
      'type': 'room_join',
      'roomId': roomId,
      'guestName': name,
      'guestPeerId': selfId,
      if (safeAvatarDataUrl(self?.avatarDataUrl) != null)
        'avatarDataUrl': safeAvatarDataUrl(self?.avatarDataUrl),
    });
  }

  /// Drop a failed join candidate without tearing down a server (guests don't
  /// run one). Clears [_selfHostedTransport] only if it's still this one.
  Future<void> _discardCandidate(RoomScopedTransport t) async {
    if (identical(_selfHostedTransport, t)) _selfHostedTransport = null;
    try {
      await t.dispose();
    } catch (_) {}
  }

  /// Poll until [client] reports `open` (signaling ACK), it's destroyed, or we
  /// time out (~4s). Returns whether it opened.
  Future<bool> _waitClientOpen(PeerJsClient client, {int tries = 40}) async {
    for (var i = 0; i < tries; i++) {
      if (client.open) return true;
      if (client.destroyed) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return client.open;
  }

  /// Split a `host:port` endpoint (IPv4) into its parts, or null if malformed.
  (String, int)? _splitHostPort(String endpoint) {
    final idx = endpoint.lastIndexOf(':');
    if (idx <= 0 || idx >= endpoint.length - 1) return null;
    final host = endpoint.substring(0, idx).trim();
    final port = int.tryParse(endpoint.substring(idx + 1).trim());
    if (host.isEmpty || port == null || port < 1 || port > 65535) return null;
    return (host, port);
  }

  /// Tear down the self-hosted transport + embedded server (host) and rebind the
  /// inbound bridge to the default transport so cloud rooms still receive. When
  /// [rebind] is false (called from dispose) the rebind is skipped.
  Future<void> _teardownSelfHost({bool rebind = true}) async {
    final transport = _selfHostedTransport;
    _selfHostedTransport = null;
    if (transport != null) {
      try {
        await transport.dispose();
      } catch (_) {}
    }
    final host = _selfHost;
    _selfHost = null;
    if (host != null) {
      try {
        await host.stop();
      } catch (_) {}
    }
    if (rebind) {
      _defaultTransport.bindRoom(RoomBridge(handleInbound: _handleInbound));
    }
  }

  /// Send a text message to [channelId] in [roomId]. Saves optimistically as
  /// our own (`direction: 'out'`), then a host broadcasts to all guests while
  /// a guest sends to the host (who relays).
  Future<void> sendRoomMessage(
      String roomId, String channelId, String text) async {
    final trimmed = _clampText(text);
    if (trimmed.isEmpty || roomId.isEmpty || channelId.isEmpty) return;
    final self = _ref.read(localProfileProvider);
    final selfId = self?.peerId ?? _selfPeerId();
    if (selfId.isEmpty) return;

    final ts = now();
    final id = '$selfId:$ts:${_shortRand()}';
    final fromName = self?.displayName ?? '';

    await db.saveMessage({
      'id': id,
      'peerId': selfId,
      'roomId': roomId,
      'channelId': channelId,
      'timestamp': ts,
      'direction': 'out',
      'status': 'sent',
      'payload': {'kind': 'text', 'text': trimmed, 'fromName': fromName},
    });

    _dispatchRoomPacket(<String, Object?>{
      'type': 'room_msg',
      'kind': 'text',
      'id': id,
      'roomId': roomId,
      'channelId': channelId,
      'text': trimmed,
      'fromName': fromName,
      'fromPeerId': selfId,
      'ts': ts,
    });
  }

  /// Send a sticker to [channelId] in [roomId]. Stickers piggyback on the
  /// `room_msg` packet with `kind: 'sticker'`; the host relays them like text
  /// (author/id/ts are host-canonicalised on the relay — see [_onRoomMsg]).
  Future<void> sendRoomSticker(
      String roomId, String channelId, Map<String, Object?> sticker) async {
    if (roomId.isEmpty || channelId.isEmpty) return;
    final clean = _sanitizeRoomSticker(sticker);
    if (clean == null) return;
    final self = _ref.read(localProfileProvider);
    final selfId = self?.peerId ?? _selfPeerId();
    if (selfId.isEmpty) return;

    final ts = now();
    final id = '$selfId:$ts:${_shortRand()}';
    final fromName = self?.displayName ?? '';

    await db.saveMessage({
      'id': id,
      'peerId': selfId,
      'roomId': roomId,
      'channelId': channelId,
      'timestamp': ts,
      'direction': 'out',
      'status': 'sent',
      'payload': {'type': 'sticker', 'sticker': clean, 'fromName': fromName},
    });

    _dispatchRoomPacket(<String, Object?>{
      'type': 'room_msg',
      'kind': 'sticker',
      'id': id,
      'roomId': roomId,
      'channelId': channelId,
      'sticker': clean,
      'fromName': fromName,
      'fromPeerId': selfId,
      'ts': ts,
    });
  }

  /// Send a file attachment to [channelId] in [roomId]. The raw bytes go to
  /// `file_blobs` (keyed by the message id, so [FileTile] can render/download)
  /// and ride the `room_msg` packet as base64 (`b64`); the host relays the full
  /// packet to every other guest, who each persist their own blob copy.
  /// [kind] is `'image' | 'video' | 'audio' | 'file'`. Returns silently on a
  /// validation/size failure.
  Future<void> sendRoomFile(
    String roomId,
    String channelId,
    Uint8List bytes, {
    required String name,
    required String mime,
    required String kind,
    int width = 0,
    int height = 0,
    double durationSec = 0,
    Uint8List? thumbBytes,
  }) async {
    if (roomId.isEmpty || channelId.isEmpty) return;
    if (bytes.isEmpty || bytes.length > kMaxRoomFileRawBytes) return;
    if (name.isEmpty || mime.isEmpty || kind.isEmpty) return;
    final self = _ref.read(localProfileProvider);
    final selfId = self?.peerId ?? _selfPeerId();
    if (selfId.isEmpty) return;

    final ts = now();
    final id = '$selfId:$ts:${_shortRand()}';
    final fromName = self?.displayName ?? '';
    final safeName = _clipField(name, 200);
    final size = bytes.length;

    String? thumbDataUrl;
    if (thumbBytes != null && thumbBytes.isNotEmpty) {
      final candidate = 'data:image/jpeg;base64,${base64Encode(thumbBytes)}';
      if (candidate.length <= kMaxRoomFileThumbLen) thumbDataUrl = candidate;
    }

    await db.saveFileBlob(
      id,
      bytes,
      mime: mime,
      name: safeName,
      kind: kind,
      size: size,
      width: width,
      height: height,
      duration: durationSec.toInt(),
      thumb: thumbBytes,
    );

    final attachment = <String, Object?>{
      'name': safeName,
      'size': size,
      'mime': mime,
      'kind': kind,
      'thumb': thumbDataUrl,
      'width': width,
      'height': height,
      'duration': durationSec,
    };

    await db.saveMessage({
      'id': id,
      'peerId': selfId,
      'roomId': roomId,
      'channelId': channelId,
      'timestamp': ts,
      'direction': 'out',
      'status': 'sent',
      'payload': {'type': 'file', 'attachment': attachment, 'fromName': fromName},
    });

    final b64 = base64Encode(bytes);
    if (b64.length > kMaxRoomFileB64Len) {
      // Too big to ship; the local copy is kept but peers won't receive it.
      debugPrint('[room] file too large to relay (${b64.length} b64 bytes)');
      return;
    }

    _dispatchRoomPacket(<String, Object?>{
      'type': 'room_msg',
      'kind': 'file',
      'id': id,
      'roomId': roomId,
      'channelId': channelId,
      'attachment': attachment,
      'b64': b64,
      'fromName': fromName,
      'fromPeerId': selfId,
      'ts': ts,
    });
  }

  /// Route an outbound `room_msg` packet: a host broadcasts to all guests; a
  /// guest sends to the host (who relays). Shared by text/sticker/file sends.
  void _dispatchRoomPacket(Map<String, Object?> packet) {
    if (state.role == RoomRole.host) {
      _broadcastToGuests(packet);
    } else if (state.role == RoomRole.guest) {
      final host = state.hostPeerId;
      if (host != null) _connections.sendRoomPacket(host, packet);
    }
  }

  /// Validate + clamp an outbound/inbound sticker blob. Returns null if it's
  /// missing the fields needed to render (url, stickerId) or the url is huge.
  Map<String, Object?>? _sanitizeRoomSticker(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, Object?>.from(raw);
    final url = m['url'];
    final stickerId = m['stickerId'];
    if (url is! String || url.isEmpty || url.length > kMaxRoomStickerUrlLen) {
      return null;
    }
    if (stickerId is! String || stickerId.isEmpty) return null;
    return <String, Object?>{
      'stickerId': stickerId,
      'url': url,
      'packId': _clipField(m['packId']?.toString() ?? '', 64),
      'packName': _clipField(m['packName']?.toString() ?? '', 64),
      'emoji': _clipField(m['emoji']?.toString() ?? '', 16),
      'label': _clipField(m['label']?.toString() ?? '', 64),
    };
  }

  String _clipField(String s, int max) =>
      s.length > max ? s.substring(0, max) : s;

  /// Switch the active channel. For a voice channel this (re)builds the audio
  /// mesh with the channel's participants; for a text channel it tears any
  /// mesh down.
  Future<void> switchChannel(String channelId) async {
    final roomId = state.roomId;
    if (channelId.isEmpty || roomId == null) return;
    state = state.copyWith(activeChannelId: channelId);

    final channels = await db.getRoomChannels(roomId);
    final ch = channels.firstWhere(
      (c) => c['id'] == channelId,
      orElse: () => const {},
    );
    if (ch['type'] == 'voice') {
      await _startVoiceMesh(roomId);
    } else {
      await _stopVoice();
    }
  }

  /// Move [peerId]'s balloon on the spatial canvas to [pos] (x,y ∈ [-1,1]).
  /// Updates the local positional audio + UI immediately (every call) and
  /// broadcasts the new coordinate to the room (host → all guests, guest →
  /// host who relays).
  ///
  /// The network broadcast is THROTTLED during a drag ([kSpatialSendIntervalMs])
  /// so a fast drag can't flood the room. The UI must call this with
  /// [isFinal] = true on pan-end so the resting position is always delivered
  /// even if it landed inside a throttle window.
  void setSpatialPosition(String peerId, Offset pos, {bool isFinal = false}) {
    final roomId = state.roomId;
    if (roomId == null || peerId.isEmpty || state.role == RoomRole.none) return;
    final clamped = Offset(
      pos.dx.clamp(-1.0, 1.0).toDouble(),
      pos.dy.clamp(-1.0, 1.0).toDouble(),
    );
    // Local UI + audio are always immediate — only the wire send is throttled.
    state = state.copyWith(
      spatialPositions: {...state.spatialPositions, peerId: clamped},
    );
    _applySpatialAudio(peerId);

    final nowMs = now();
    if (!isFinal && nowMs - _lastSpatialSendMs < kSpatialSendIntervalMs) {
      return; // mid-drag tick inside the throttle window — skip the send
    }
    _lastSpatialSendMs = nowMs;

    final packet = <String, Object?>{
      'type': 'room_spatial_update',
      'roomId': roomId,
      'peerId': peerId,
      'x': clamped.dx,
      'y': clamped.dy,
    };
    if (state.role == RoomRole.host) {
      // Host is the authoritative arranger — may move any balloon.
      _broadcastToGuests(packet);
    } else if (state.role == RoomRole.guest && peerId == _selfPeerId()) {
      // A guest may broadcast only ITS OWN position; dragging another peer's
      // balloon stays a local-only audio adjustment (host owns the shared scene).
      final host = state.hostPeerId;
      if (host != null) _connections.sendRoomPacket(host, packet);
    }
  }

  /// Default ring position for the [i]-th of [n] peers — the auto-arrange /
  /// reset layout. Mirrors the canvas's own default so a reset lands balloons
  /// exactly where the radar would have placed an un-positioned peer.
  static Offset spatialRingPosition(int i, int n) {
    if (n <= 0) return Offset.zero;
    final angle = (2 * pi * i / n) - (pi / 2);
    return Offset(
      kSpatialRingRadius * cos(angle),
      kSpatialRingRadius * sin(angle),
    );
  }

  /// Reset / auto-arrange: place every OTHER voice participant evenly on a ring
  /// around the listener and broadcast each new position (a host pushes to all
  /// guests; a guest only re-arranges its own local audio scene since it can't
  /// move others on the wire). The local self marker stays at the centre.
  Future<void> resetSpatialPositions() async {
    final roomId = state.roomId;
    if (roomId == null || state.role == RoomRole.none) return;
    final selfId = _selfPeerId();
    final members = await db.getRoomMembers(roomId);
    final others = <String>[
      for (final m in members)
        if ((m['peerId'] as String?) != null &&
            (m['peerId'] as String).isNotEmpty &&
            m['peerId'] != selfId)
          m['peerId'] as String,
    ];
    for (var i = 0; i < others.length; i++) {
      // isFinal so each reset position is delivered immediately (not throttled).
      setSpatialPosition(others[i], spatialRingPosition(i, others.length),
          isFinal: true);
    }
  }

  /// Recompute pan/gain for [peerId] from its canvas position and push it to
  /// the audio engine. Pan = x; gain = clamp(1 − √(x²+y²), 0, 1).
  void _applySpatialAudio(String peerId) {
    final pos = state.spatialPositions[peerId] ?? Offset.zero;
    final dist = sqrt(pos.dx * pos.dx + pos.dy * pos.dy);
    final gain = (1.0 - dist).clamp(0.0, 1.0).toDouble();
    _spatialAudio.updatePeer(peerId, pan: pos.dx, gain: gain);
  }

  /// Leave (guest) or destroy (host) the current room, closing every channel.
  Future<void> leaveOrDestroyRoom() async {
    final roomId = state.roomId;
    final role = state.role;
    if (roomId != null) {
      if (role == RoomRole.host) {
        _broadcastToGuests({'type': 'room_destroy', 'roomId': roomId});
        await db.setRoomStatus(roomId, 'offline');
      } else if (role == RoomRole.guest) {
        final host = state.hostPeerId;
        if (host != null) {
          _connections.sendRoomPacket(host, {
            'type': 'room_leave',
            'roomId': roomId,
            'guestPeerId': _selfPeerId(),
          });
        }
        await db.setRoomStatus(roomId, 'offline');
      }
    }
    await _stopVoice();
    // Tear down the embedded server + room-scoped client AFTER voice cleanup
    // (voice uses the room-scoped client as rawPeer).
    await _teardownSelfHost();
    _security.reset();
    state = const RoomState();
  }

  /// Stop the voice mesh + release the mic WITHOUT leaving/destroying the room.
  /// Called when the room page is disposed (navigated away) so a backgrounded
  /// room never keeps the microphone hot (audit item 7).
  Future<void> leaveVoiceChannel() => _stopVoice();

  /// Host: create a new channel and announce it to all guests so they
  /// replicate it (with the host's canonical id). No-op for guests.
  Future<void> createChannelAndAnnounce(String name,
      {String type = 'text'}) async {
    final roomId = state.roomId;
    if (state.role != RoomRole.host || roomId == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final channel = await db.createChannel(roomId, trimmed, type);
    if (channel.isEmpty) return;
    _broadcastToGuests({
      'type': 'room_channel_create',
      'roomId': roomId,
      'channel': channel,
    });
  }

  /// Host: flip the server online ('active') / offline. Turning it off tells
  /// guests to drop (`room_destroy` → they grey out + close their channels)
  /// and clears the guest list, but KEEPS the host's own session so it can be
  /// switched back on. No-op for guests.
  Future<void> setServerActive(bool active) async {
    final roomId = state.roomId;
    if (state.role != RoomRole.host || roomId == null) return;
    if (active) {
      await db.setRoomStatus(roomId, 'active');
      state = state.copyWith(serverActive: true);
    } else {
      _broadcastToGuests({'type': 'room_destroy', 'roomId': roomId});
      await db.setRoomStatus(roomId, 'offline');
      await _stopVoice();
      _security.reset();
      // serverActive:false makes inbound handlers reject joins + ignore msgs,
      // while the host keeps its own (now read-only) session.
      state = state.copyWith(
        serverActive: false,
        guestPeerIds: const <String>{},
      );
    }
  }

  // ─── Inbound routing ──────────────────────────────────────────────

  /// Returns a Future so callers (and tests) can await full settlement —
  /// production wiring fires it forget-style, which is fine.
  Future<void> _handleInbound(
      String remoteId, Map<String, Object?> packet) async {
    final type = packet['type'];
    if (type is! String) return;
    // QR pairing rides the same plaintext bridge but isn't a room packet.
    if (type == 'qr_auth_response') {
      _qrAuthListener?.call(remoteId, packet);
      return;
    }
    // Allow-list: ignore anything that isn't a known room packet (no throw).
    if (!kRoomPacketTypes.contains(type)) return;
    // Active-room gate (audit item 1): every room packet must target the room
    // we're currently in. Anything else is dropped before any handler runs.
    final roomId = packet['roomId'];
    if (roomId is! String || roomId.isEmpty || roomId != state.roomId) return;
    try {
      switch (type) {
        case 'room_join':
          await _onRoomJoin(remoteId, packet);
          break;
        case 'room_join_reject':
          await _onJoinReject(remoteId, packet);
          break;
        case 'room_members_update':
          await _onMembersUpdate(remoteId, packet);
          break;
        case 'room_msg':
          await _onRoomMsg(remoteId, packet);
          break;
        case 'room_channel_create':
          await _onChannelCreate(remoteId, packet);
          break;
        case 'room_destroy':
          await _onRoomDestroy(remoteId, packet);
          break;
        case 'room_leave':
          await _onRoomLeave(remoteId, packet);
          break;
        case 'room_spatial_update':
          await _onSpatialUpdate(remoteId, packet);
          break;
      }
    } catch (e) {
      // Malformed/unexpected room packets must never crash the connection.
      debugPrint('[room] inbound "$type" error: $e');
    }
  }

  /// A peer's balloon moved. Apply it to local state + audio; a host also
  /// relays the move to the other guests (star topology).
  Future<void> _onSpatialUpdate(
      String remoteId, Map<String, Object?> packet) async {
    final x = (packet['x'] as num?)?.toDouble() ?? 0.0;
    final y = (packet['y'] as num?)?.toDouble() ?? 0.0;
    final pos =
        Offset(x.clamp(-1.0, 1.0).toDouble(), y.clamp(-1.0, 1.0).toDouble());

    if (state.role == RoomRole.host) {
      // A guest may move ONLY its own balloon — force the canonical peerId to
      // the authenticated sender, ignoring any spoofed `peerId` in the payload.
      if (!state.guestPeerIds.contains(remoteId)) return;
      state = state.copyWith(
        spatialPositions: {...state.spatialPositions, remoteId: pos},
      );
      _applySpatialAudio(remoteId);
      _broadcastToGuests({
        'type': 'room_spatial_update',
        'roomId': state.roomId,
        'peerId': remoteId,
        'x': pos.dx,
        'y': pos.dy,
      }, except: remoteId);
    } else if (state.role == RoomRole.guest) {
      // Guests accept spatial updates only from the host (canonical relay).
      if (remoteId != state.hostPeerId) return;
      final peerId = (packet['peerId'] as String?) ?? '';
      if (peerId.isEmpty) return;
      state = state.copyWith(
        spatialPositions: {...state.spatialPositions, peerId: pos},
      );
      _applySpatialAudio(peerId);
    }
  }

  /// Host: a guest announced itself. Persist them, send them the channel set
  /// (with the host's ids so messages line up), and broadcast the new roster.
  Future<void> _onRoomJoin(
      String remoteId, Map<String, Object?> packet) async {
    // Only an ACTIVE host accepts joins.
    if (state.role != RoomRole.host) return;
    final roomId = state.roomId;
    if (roomId == null || remoteId.isEmpty) return;
    if (!state.serverActive) {
      _sendJoinReject(remoteId, roomId, 'offline');
      return;
    }
    // Identity = the authenticated transport source. A `guestPeerId` claiming
    // to be someone else is a spoof attempt → reject (audit item 1).
    final claimed = packet['guestPeerId'] as String?;
    if (claimed != null && claimed.isNotEmpty && claimed != remoteId) {
      debugPrint('[room] room_join spoof: claimed=$claimed remote=$remoteId');
      _sendJoinReject(remoteId, roomId, 'invalid');
      return;
    }
    final guestId = remoteId;

    // Capacity (incl. host). A re-join by an existing member is always allowed.
    final alreadyMember = state.guestPeerIds.contains(guestId) ||
        guestId == state.hostPeerId;
    if (!alreadyMember) {
      final members = await db.getRoomMembers(roomId);
      if (members.length >= kMaxRoomMembers) {
        _sendJoinReject(remoteId, roomId, 'full');
        return;
      }
    }

    await db.saveRoomMember({
      'roomId': roomId,
      'peerId': guestId,
      'displayName': _clampName(packet['guestName'] as String?),
      'avatarDataUrl': safeAvatarDataUrl(packet['avatarDataUrl']),
      'isOnline': true,
      'joinedAt': now(),
    });
    state = state.copyWith(guestPeerIds: {...state.guestPeerIds, guestId});

    // Replicate the channel list to the newcomer (host ids are canonical).
    final channels = await db.getRoomChannels(roomId);
    for (final c in channels) {
      _connections.sendRoomPacket(guestId, {
        'type': 'room_channel_create',
        'roomId': roomId,
        'channel': c,
      });
    }
    await _broadcastMembers();
  }

  /// Guest: the host refused our join (full / offline / invalid). Surface it to
  /// the UI and reset to no-room. Only the host may reject us.
  Future<void> _onJoinReject(
      String remoteId, Map<String, Object?> packet) async {
    if (state.role != RoomRole.guest || remoteId != state.hostPeerId) return;
    final roomId = state.roomId;
    if (roomId != null) await db.setRoomStatus(roomId, 'offline');
    await _stopVoice();
    _security.reset();
    state = RoomState(
      joinError: _rejectReasonMessage(packet['reason'] as String?),
    );
  }

  /// Guest: overwrite the local roster so avatars/names appear instantly.
  /// Accepted only from the host.
  Future<void> _onMembersUpdate(
      String remoteId, Map<String, Object?> packet) async {
    if (state.role != RoomRole.guest || remoteId != state.hostPeerId) return;
    final roomId = state.roomId;
    if (roomId == null) return;
    final raw = packet['members'];
    if (raw is! List) return;
    final members = <Map<String, Object?>>[
      for (final m in raw)
        if (m is Map)
          {
            ...Map<String, Object?>.from(m),
            'displayName': _clampName(m['displayName'] as String?),
            'avatarDataUrl': safeAvatarDataUrl(m['avatarDataUrl']),
          },
    ];
    await db.replaceRoomMembers(roomId, members);
  }

  /// A room message arrived. Host saves it and relays to the other guests;
  /// guest just saves it.
  Future<void> _onRoomMsg(
      String remoteId, Map<String, Object?> packet) async {
    // Flood guard ("защита от спама") keyed on the AUTHENTICATED source — not a
    // payload field a sender can forge (audit item 5). Blocked → no save/relay.
    if (_security.recordMessage(remoteId, now())) {
      debugPrint('[room] flood guard: dropped message from $remoteId');
      return;
    }
    final roomId = state.roomId;
    if (roomId == null) return;
    final channelId = (packet['channelId'] as String?) ?? '';
    if (channelId.isEmpty) return;
    final fromName = _clampName(packet['fromName'] as String?);

    // Decode + validate the message content by its `kind` (text/sticker/file).
    // Invalid/oversized content is dropped before any save or relay.
    final content = _roomContentFromPacket(packet);
    if (content == null) return;

    if (state.role == RoomRole.host) {
      if (!state.serverActive) return; // offline server ignores inbound msgs
      // Only joined guests may post (audit item 2).
      if (!state.guestPeerIds.contains(remoteId)) return;
      // channelId must belong to this room (audit item 8).
      if (!await _channelExists(roomId, channelId)) return;
      // Canonical author/id/timestamp are HOST-assigned: a sender can neither
      // impersonate another author nor overwrite another's message id, and the
      // untrusted sender timestamp is replaced with host receive time (items 1/3/8).
      final hostTs = now();
      final canonicalId = _canonicalMsgId(remoteId, hostTs);
      await _saveRoomContent(
        id: canonicalId,
        author: remoteId,
        roomId: roomId,
        channelId: channelId,
        fromName: fromName,
        ts: hostTs,
        content: content,
      );
      _broadcastToGuests({
        'type': 'room_msg',
        'kind': content.kind,
        'id': canonicalId,
        'roomId': roomId,
        'channelId': channelId,
        'fromName': fromName,
        'fromPeerId': remoteId,
        'ts': hostTs,
        ...content.wireFields(),
      }, except: remoteId);
    } else if (state.role == RoomRole.guest) {
      // Guests accept relayed messages ONLY from the host (audit item 1/2).
      if (remoteId != state.hostPeerId) return;
      final author = (packet['fromPeerId'] as String?) ?? '';
      if (author.isEmpty) return;
      final ts = (packet['ts'] as num?)?.toInt() ?? now();
      // Trust the host's canonical id; fall back to an author-namespaced id.
      final id = (packet['id'] as String?) ?? _canonicalMsgId(author, ts);
      await _saveRoomContent(
        id: id,
        author: author,
        roomId: roomId,
        channelId: channelId,
        fromName: fromName,
        ts: ts,
        content: content,
      );
    }
  }

  /// Feed a peer's TRANSPORT-OBSERVED IP (read from the selected ICE candidate
  /// pair on the RTCPeerConnection) to the fraud detector. If it looks like an
  /// IP collision (sybil) or an IP hop, surface the warning via
  /// [RoomState.securityAlert] so the chat shows the red banner.
  ///
  /// SECURITY (audit item 5): callers must ONLY pass an IP the local transport
  /// itself observed. NEVER pass a self-reported address from a `room_*` packet
  /// — an attacker could forge it to raise a fake banner or frame another peer.
  /// TODO: wire a real ICE-candidate IP reader (RTCPeerConnection.getStats) and
  /// call this from there. No caller currently feeds it self-reported IPs.
  void recordPeerConnection(String peerId, String ipAddress) {
    final finding = _security.recordConnection(peerId, ipAddress);
    // Persist to the security audit log (Drift-backed) for after-the-fact review.
    unawaited(appendSecurityLog(SecurityLogEntry(
      peerId: peerId,
      ipAddress: ipAddress,
      timestamp: now(),
      eventType: finding == null ? 'connect' : 'fraud:${finding.kind.name}',
    )));
    if (finding != null) {
      state = state.copyWith(securityAlert: finding.message);
    }
  }

  /// Dismiss the current security banner.
  void clearSecurityAlert() {
    if (state.securityAlert != null) {
      state = state.copyWith(securityAlert: null);
    }
  }

  /// Register (or clear, with null) the handler for inbound `qr_auth_response`
  /// packets — used by the desktop QR-pairing page.
  void setQrAuthListener(
          void Function(String remoteId, Map<String, Object?> packet)? cb) =>
      _qrAuthListener = cb;

  /// Phone side: dial [pcPeerId] and send a signed `qr_auth_response`. Reuses
  /// the reliable plaintext room channel (DTLS-protected). Best-effort: returns
  /// false if the reliable channel never opened.
  Future<bool> sendQrAuthResponse(
      String pcPeerId, Map<String, Object?> packet) async {
    if (pcPeerId.isEmpty) return false;
    _connections.openReliable(pcPeerId);
    if (!await _waitReliable(pcPeerId)) return false;
    return _connections.sendRoomPacket(pcPeerId, packet);
  }

  /// Guest: host created/synced a channel — replicate it with the host's id.
  /// Accepted only from the host (audit items 1/2).
  Future<void> _onChannelCreate(
      String remoteId, Map<String, Object?> packet) async {
    if (state.role != RoomRole.guest || remoteId != state.hostPeerId) return;
    final ch = packet['channel'];
    if (ch is! Map) return;
    final m = Map<String, Object?>.from(ch);
    m['roomId'] = state.roomId;
    m['name'] = _clampName(m['name'] as String?);
    await db.upsertRoomChannel(m);
  }

  /// Guest: host tore the room down. Mark offline, drop voice, reset.
  /// Accepted only from the host (audit items 1/2).
  Future<void> _onRoomDestroy(
      String remoteId, Map<String, Object?> packet) async {
    if (state.role != RoomRole.guest || remoteId != state.hostPeerId) return;
    final roomId = state.roomId;
    if (roomId != null) await db.setRoomStatus(roomId, 'offline');
    await _stopVoice();
    // Guest's room-scoped client (if self-hosted) is torn down here too.
    await _teardownSelfHost();
    _security.reset();
    state = const RoomState();
  }

  /// Host: a guest left. The leaving guest is the AUTHENTICATED sender —
  /// a `guestPeerId` targeting a different peer is ignored (audit item 1).
  Future<void> _onRoomLeave(
      String remoteId, Map<String, Object?> packet) async {
    if (state.role != RoomRole.host) return;
    final roomId = state.roomId;
    if (roomId == null) return;
    final guestId = remoteId;
    if (!state.guestPeerIds.contains(guestId)) return;
    await db.removeRoomMember(roomId, guestId);
    state = state.copyWith(
      guestPeerIds: state.guestPeerIds.where((g) => g != guestId).toSet(),
    );
    await _broadcastMembers();
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  /// Host: push the current roster to every connected guest.
  Future<void> _broadcastMembers() async {
    final roomId = state.roomId;
    if (roomId == null) return;
    final members = await db.getRoomMembers(roomId);
    final slim = [
      for (final m in members)
        <String, Object?>{
          'peerId': m['peerId'],
          'name': m['displayName'],
          'avatarDataUrl': m['avatarDataUrl'],
        },
    ];
    _broadcastToGuests({
      'type': 'room_members_update',
      'roomId': roomId,
      'members': slim,
    });
  }

  void _broadcastToGuests(Map<String, Object?> packet, {String? except}) {
    final conns = _connections;
    for (final g in state.guestPeerIds) {
      if (g == except) continue;
      conns.sendRoomPacket(g, packet);
    }
  }

  /// Persist inbound room content (text / sticker / file) with explicit,
  /// already-validated fields. The caller (host or guest inbound) supplies the
  /// canonical id/author/ts, so nothing here trusts raw packet identity. For a
  /// file, the base64 bytes are decoded into `file_blobs` (keyed by the message
  /// id) so [FileTile] can render/download; redelivery of the same id is
  /// idempotent.
  Future<void> _saveRoomContent({
    required String id,
    required String author,
    required String roomId,
    required String channelId,
    required String fromName,
    required int ts,
    required _RoomContent content,
  }) async {
    if (content.kind == 'file' && content.b64 != null) {
      try {
        final bytes = base64Decode(content.b64!);
        if (bytes.isNotEmpty && bytes.length <= kMaxRoomFileRawBytes) {
          final att = content.attachment ?? const <String, Object?>{};
          await db.saveFileBlob(
            id,
            bytes,
            mime: att['mime']?.toString() ?? 'application/octet-stream',
            name: att['name']?.toString() ?? 'file',
            kind: att['kind']?.toString() ?? 'file',
            size: bytes.length,
            width: (att['width'] as num?)?.toInt() ?? 0,
            height: (att['height'] as num?)?.toInt() ?? 0,
            duration: (att['duration'] as num?)?.toInt() ?? 0,
            thumb: null,
          );
        }
      } catch (_) {
        // Bad base64 → still save the message row; the tile falls back to an
        // icon and the download just won't have bytes.
      }
    }
    await db.saveMessage({
      'id': id,
      'peerId': author,
      'roomId': roomId,
      'channelId': channelId,
      'timestamp': ts,
      'direction': 'in',
      'status': 'delivered',
      'payload': content.payload(fromName),
    });
  }

  /// Parse + validate the content of an inbound `room_msg` by its `kind`.
  /// Returns null when the content is missing required fields or oversized —
  /// the caller then drops the packet (no save, no relay).
  _RoomContent? _roomContentFromPacket(Map<String, Object?> packet) {
    final kind = (packet['kind'] as String?) ?? 'text';
    switch (kind) {
      case 'sticker':
        final s = _sanitizeRoomSticker(packet['sticker']);
        if (s == null) return null;
        return _RoomContent(kind: 'sticker', sticker: s);
      case 'file':
        final b64 = packet['b64'];
        if (b64 is! String ||
            b64.isEmpty ||
            b64.length > kMaxRoomFileB64Len) {
          return null;
        }
        final att = _sanitizeRoomAttachment(packet['attachment']);
        if (att == null) return null;
        return _RoomContent(kind: 'file', attachment: att, b64: b64);
      default:
        final text = _clampText(packet['text'] as String?);
        if (text.isEmpty) return null;
        return _RoomContent(kind: 'text', text: text);
    }
  }

  /// Validate + clamp an inbound file attachment metadata blob.
  Map<String, Object?>? _sanitizeRoomAttachment(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, Object?>.from(raw);
    final name = _clipField(m['name']?.toString() ?? '', 200);
    final mime = _clipField(m['mime']?.toString() ?? '', 128);
    if (name.isEmpty || mime.isEmpty) return null;
    var kind = _clipField(m['kind']?.toString() ?? 'file', 16);
    if (kind.isEmpty) kind = 'file';
    final thumb = m['thumb'];
    final thumbStr =
        (thumb is String && thumb.isNotEmpty && thumb.length <= kMaxRoomFileThumbLen)
            ? thumb
            : null;
    return <String, Object?>{
      'name': name,
      'size': (m['size'] as num?)?.toInt() ?? 0,
      'mime': mime,
      'kind': kind,
      'thumb': thumbStr,
      'width': (m['width'] as num?)?.toInt() ?? 0,
      'height': (m['height'] as num?)?.toInt() ?? 0,
      'duration': (m['duration'] as num?)?.toDouble() ?? 0,
    };
  }

  /// Host-namespaced message id, prefixed with the AUTHENTICATED author so one
  /// sender can never collide with / overwrite another sender's message id.
  String _canonicalMsgId(String author, int ts) =>
      'room:$author:$ts:${_shortRand()}';

  /// Whether [channelId] is a real channel of [roomId].
  Future<bool> _channelExists(String roomId, String channelId) async {
    final channels = await db.getRoomChannels(roomId);
    return channels.any((c) => c['id'] == channelId);
  }

  String _clampText(String? raw) {
    final t = (raw ?? '').trim();
    return t.length > kMaxRoomTextLen ? t.substring(0, kMaxRoomTextLen) : t;
  }

  String _clampName(String? raw) {
    final t = (raw ?? '').trim();
    return t.length > kMaxRoomNameLen ? t.substring(0, kMaxRoomNameLen) : t;
  }

  void _sendJoinReject(String guestId, String roomId, String reason) {
    _connections.sendRoomPacket(guestId, {
      'type': 'room_join_reject',
      'roomId': roomId,
      'reason': reason,
    });
  }

  static String _rejectReasonMessage(String? reason) {
    switch (reason) {
      case 'full':
        return 'Сервер заполнен (максимум $kMaxRoomMembers участников).';
      case 'offline':
        return 'Сервер сейчас не в сети.';
      case 'invalid':
        return 'Не удалось подтвердить личность при входе.';
      default:
        return 'Не удалось войти на сервер.';
    }
  }

  /// Build the audio mesh for a voice channel: call up to
  /// [kMaxVoiceParticipants]-1 other room members directly.
  Future<void> _startVoiceMesh(String roomId) async {
    await _stopVoice();
    // Mark that we've entered this voice channel (drives the compact voice
    // panel) even before the mic / mesh come up.
    state = state.copyWith(
      voiceChannelId: state.activeChannelId,
      micEnabled: true,
      micAvailable: false,
    );
    final selfId = _selfPeerId();
    final members = await db.getRoomMembers(roomId);
    final peers = <String>[
      for (final m in members)
        if ((m['peerId'] as String? ?? '').isNotEmpty &&
            m['peerId'] != selfId)
          m['peerId'] as String,
    ];

    const maxOthers = kMaxVoiceParticipants - 1;
    if (peers.length > maxOthers) {
      debugPrint(
        '[room] voice over capacity: ${peers.length + 1} participants > '
        '$kMaxVoiceParticipants — calling first $maxOthers only',
      );
    }
    final targets = peers.take(maxOthers).toList();

    final peer = _rawPeer;
    if (peer == null) {
      debugPrint('[room] voice: no PeerJS client available');
      return;
    }

    MediaStream stream;
    try {
      stream = await navigator.mediaDevices
          .getUserMedia({'audio': true, 'video': false});
    } catch (e) {
      debugPrint('[room] voice: microphone unavailable: $e');
      return;
    }
    _voiceStream = stream;
    state = state.copyWith(micAvailable: true);

    // Listen for INCOMING room-voice calls (other members dialling us). Live
    // only while the mesh is up; _stopVoice cancels it.
    _incomingCallSub?.cancel();
    _incomingCallSub = peer.onCall.listen(_handleIncomingRoomCall);

    final voiceChannelId = state.activeChannelId;
    final connected = <String>{};
    for (final t in targets) {
      try {
        final mc = await peer.callPeer(t, stream, metadata: {
          'channel': 'room-voice',
          'roomId': roomId,
          'channelId': voiceChannelId,
        });
        _voiceConns[t] = mc;
        connected.add(t);
        _attachVoiceAudio(t, mc);
      } catch (e) {
        debugPrint('[room] voice: call to $t failed: $e');
      }
    }
    state = state.copyWith(voicePeerIds: connected);
  }

  /// Auto-answer an INCOMING room-voice call iff it's for our active voice
  /// channel, from a known member, and capacity allows (audit item 6). A
  /// room-voice call we can't accept is closed; non-room calls fall through to
  /// CallsNotifier untouched.
  Future<void> _handleIncomingRoomCall(PeerMediaConnection call) async {
    final members = <String>{
      ...state.guestPeerIds,
      if (state.hostPeerId != null) state.hostPeerId!,
    };
    final ok = shouldAnswerRoomVoiceCall(
      metadata: call.metadata,
      fromPeerId: call.peer,
      role: state.role,
      roomId: state.roomId,
      activeChannelId: state.activeChannelId,
      members: members,
      currentVoiceCount: _voiceConns.length,
    );
    final stream = _voiceStream;
    if (!ok || stream == null) {
      // Decline room-voice calls we can't accept so the caller doesn't hang.
      // 1:1 calls (no room-voice tag) are left for CallsNotifier.
      if (call.metadata['channel'] == 'room-voice') {
        unawaited(call.close().catchError((_) {}));
      }
      return;
    }
    try {
      await call.answer(stream);
      _voiceConns[call.peer] = call;
      _attachVoiceAudio(call.peer, call);
      state = state.copyWith(voicePeerIds: {...state.voicePeerIds, call.peer});
    } catch (e) {
      debugPrint('[room] voice: answering ${call.peer} failed: $e');
    }
  }

  /// Route a voice peer's remote audio into the spatial engine — now if the
  /// stream is already present, and again whenever a (re)negotiated stream
  /// arrives — then apply the peer's current canvas position to the new nodes.
  void _attachVoiceAudio(String peerId, PeerMediaConnection mc) {
    final existing = mc.remoteStream;
    if (existing != null) {
      _spatialAudio.attachPeer(peerId, existing);
      _applySpatialAudio(peerId);
    }
    _voiceStreamSubs[peerId]?.cancel();
    _voiceStreamSubs[peerId] = mc.onStream.listen((rs) {
      _spatialAudio.attachPeer(peerId, rs);
      _applySpatialAudio(peerId);
    });
  }

  Future<void> _stopVoice() async {
    await _incomingCallSub?.cancel();
    _incomingCallSub = null;
    for (final sub in _voiceStreamSubs.values) {
      await sub.cancel();
    }
    _voiceStreamSubs.clear();
    for (final id in _voiceConns.keys) {
      _spatialAudio.detachPeer(id);
    }
    for (final mc in _voiceConns.values) {
      try {
        await mc.close();
      } catch (_) {}
    }
    _voiceConns.clear();
    final s = _voiceStream;
    _voiceStream = null;
    if (s != null) {
      try {
        for (final track in s.getTracks()) {
          await track.stop();
        }
      } catch (_) {}
      try {
        await s.dispose();
      } catch (_) {}
    }
    // `mounted` guard: _stopVoice is fired unawaited from dispose(), so by the
    // time this runs past its awaits the notifier may already be disposed —
    // reading/writing `state` then would throw.
    if (mounted &&
        (state.voiceChannelId != null ||
            state.voicePeerIds.isNotEmpty ||
            state.spatialPositions.isNotEmpty)) {
      state = state.copyWith(
        voiceChannelId: null,
        micEnabled: true,
        micAvailable: false,
        voicePeerIds: const <String>{},
        spatialPositions: const <String, Offset>{},
      );
    }
  }

  /// Toggle the local mic (mute/unmute) by flipping the live audio tracks'
  /// enabled flag. No-op when not in a voice channel.
  void toggleMic() {
    if (!state.inVoice) return;
    final on = !state.micEnabled;
    final s = _voiceStream;
    if (s != null) {
      for (final track in s.getAudioTracks()) {
        track.enabled = on;
      }
    }
    state = state.copyWith(micEnabled: on);
  }

  /// Poll for the reliable channel to [peerId] to open (~15s budget).
  Future<bool> _waitReliable(String peerId) async {
    final conns = _connections;
    for (var i = 0; i < 60; i++) {
      if (conns.hasReliable(peerId)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return conns.hasReliable(peerId);
  }

  String _shortRand() {
    final b = List<int>.generate(4, (_) => _rng.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  void dispose() {
    unawaited(_stopVoice());
    // Release the embedded server + room-scoped client; skip rebinding the
    // bridge since this manager is going away.
    unawaited(_teardownSelfHost(rebind: false));
    _spatialAudio.dispose();
    super.dispose();
  }
}

// ─── Transport abstraction ──────────────────────────────────────────

/// The slice of the connection layer [RoomManager] needs, behind an interface
/// so tests can inject a fake (and so the manager doesn't reach across the
/// whole [ConnectionsNotifier] surface). The production impl wraps the
/// connection registry + the PeerJS client.
abstract class RoomTransport {
  /// Register the inbound `room_*` handler with the connection registry.
  void bindRoom(RoomBridge bridge);

  /// Send a plaintext room control packet to [peerId] on the reliable channel.
  bool sendRoomPacket(String peerId, Map<String, Object?> packet);

  /// Whether a live reliable channel to [peerId] exists.
  bool hasReliable(String peerId);

  /// Proactively dial [peerId]'s reliable channel.
  void openReliable(String peerId);

  /// The active PeerJS client (for voice-mesh media calls), or null.
  PeerJsClient? get rawPeer;
}

class _ConnRoomTransport implements RoomTransport {
  _ConnRoomTransport(this._ref);
  final Ref _ref;

  ConnectionsNotifier get _c =>
      _ref.read(connectionsNotifierProvider.notifier);

  @override
  void bindRoom(RoomBridge bridge) => _c.bindRoom(bridge);

  @override
  bool sendRoomPacket(String peerId, Map<String, Object?> packet) =>
      _c.sendRoomPacket(peerId, packet);

  @override
  bool hasReliable(String peerId) => _c.hasReliable(peerId);

  @override
  void openReliable(String peerId) => _c.openReliable(peerId);

  @override
  PeerJsClient? get rawPeer =>
      _ref.read(peerConnectionProvider.notifier).rawPeer;
}

/// Production room transport. Overridable in tests with a fake.
final roomTransportProvider =
    Provider<RoomTransport>((ref) => _ConnRoomTransport(ref));

/// Builds the [RoomSignalingHost] used by a self-hosted create. A provider so
/// tests can inject a fake that fails (bind/no-LAN/timeout) or records the call
/// without binding real sockets — the self-host path is otherwise untestable.
typedef RoomSignalingHostFactory = RoomSignalingHost Function();

final roomSignalingHostFactoryProvider =
    Provider<RoomSignalingHostFactory>((ref) => RoomSignalingHost.new);

/// App-wide room session. Created lazily on first read (createRoom/joinRoom or
/// a UI watch); persists for the container lifetime so inbound `room_*`
/// packets are always routed once a session exists.
final roomManagerProvider =
    StateNotifierProvider<RoomManager, RoomState>((ref) {
  return RoomManager(ref);
});
