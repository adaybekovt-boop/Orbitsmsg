// Real call lifecycle on top of [PeerJsClient]'s media-channel API.
//
// Replaces the original "reject every incoming call" stub. The notifier
// now drives a full peer-to-peer audio/video call:
//
//   • `startCall(peerId, video: ...)` opens the local mic + camera via
//     `getUserMedia`, then dials the peer through `PeerJsClient.callPeer`.
//     We transition `idle → calling → in-call` once a remote track lands.
//
//   • `acceptCurrent()` answers the pending incoming call by giving it
//     our local stream. The peer sees their dial flip to `in-call`.
//
//   • `hangUp()` closes the media connection and tears down our local
//     tracks. Both sides return to `idle`.
//
//   • `setMicEnabled` / `setVideoEnabled` toggle the corresponding track
//     `enabled` flag (no track replacement). Native DualStack also emits
//     `CallSignalType.mediaState` so the remote overlay can update.
//
//   • `toggleScreenShare` replaces the outgoing video track with one
//     from `getDisplayMedia` (and back) on the PeerJS or native
//     `RTCPeerConnection`. On unsupported platforms it no-ops and
//     surfaces an error.
//
// Everything platform-specific (getUserMedia, getDisplayMedia, RTC
// peer connection plumbing) lives behind the `flutter_webrtc` package
// — same lib the React app uses via the browser implementation, just
// surfaced through a Dart API.
//
// State shape is intentionally larger than the previous stub. Existing
// readers (`callIsActiveProvider`, `CallOverlayMount`) keep working
// because the old fields (`status`, `remotePeerId`, `lastError`) are
// still there with their original semantics — we just added the media
// fields on top.

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../calls/hyperswarm_signaling.dart';
import '../calls/native_call_media.dart';
import '../calls/system_calling.dart';
import '../peer/peerjs_client.dart';
import '../transport/peerjs_window.dart';
import 'connections_notifier.dart';
import 'peer_connection_provider.dart';

/// Lifecycle phases the UI needs to disambiguate. Names kept aligned
/// with `src/call/state/initialCallState.js` so log parsing across
/// platforms shares a vocabulary.
enum CallStatus {
  /// No active call. Overlay is invisible.
  idle,

  /// Outgoing — we've offered, awaiting answer.
  calling,

  /// Incoming — remote has offered, we haven't picked up yet.
  ringing,

  /// Both sides have signaled; media flowing.
  inCall,
}

/// Immutable snapshot consumed by the overlay + chat header.
class CallState {
  const CallState({
    this.status = CallStatus.idle,
    this.remotePeerId,
    this.lastError,
    this.video = false,
    this.localStream,
    this.remoteStream,
    this.micEnabled = true,
    this.videoEnabled = false,
    this.screenSharing = false,
    this.remoteMicEnabled = true,
    this.remoteVideoEnabled = false,
    this.remoteScreenSharing = false,
  });

  const CallState.idle() : this();

  final CallStatus status;
  final String? remotePeerId;
  final String? lastError;

  /// Whether the call was initiated as audio+video. Audio-only calls
  /// still have this false even mid-call. Determines the UI's default
  /// "video" toggle state.
  final bool video;

  /// Our outbound stream (mic + optional camera). Null while idle.
  final MediaStream? localStream;

  /// Inbound stream from the peer. Null until the remote attaches
  /// their tracks, even mid-call (Firefox sometimes lags here).
  final MediaStream? remoteStream;

  /// Mic track `enabled` flag. Toggling this is a synchronous operation
  /// that doesn't require renegotiation.
  final bool micEnabled;

  /// Camera track `enabled` flag. Same characteristics as `micEnabled`.
  final bool videoEnabled;

  /// True iff we're currently sending a getDisplayMedia track instead of
  /// the camera. Mutually exclusive with `videoEnabled` from the user's
  /// perspective — the UI shows one or the other, never both.
  final bool screenSharing;

  /// Remote mute / camera / screen-share from `CallSignalType.mediaState`.
  /// Defaults assume the peer starts unmuted; PeerJS-only calls never
  /// update these (track `enabled` is enough on a shared PC).
  final bool remoteMicEnabled;
  final bool remoteVideoEnabled;
  final bool remoteScreenSharing;

  bool get isActive => status != CallStatus.idle;

  CallState copyWith({
    CallStatus? status,
    Object? remotePeerId = _unset,
    Object? lastError = _unset,
    bool? video,
    Object? localStream = _unset,
    Object? remoteStream = _unset,
    bool? micEnabled,
    bool? videoEnabled,
    bool? screenSharing,
    bool? remoteMicEnabled,
    bool? remoteVideoEnabled,
    bool? remoteScreenSharing,
  }) {
    return CallState(
      status: status ?? this.status,
      remotePeerId: identical(remotePeerId, _unset)
          ? this.remotePeerId
          : remotePeerId as String?,
      lastError: identical(lastError, _unset)
          ? this.lastError
          : lastError as String?,
      video: video ?? this.video,
      localStream: identical(localStream, _unset)
          ? this.localStream
          : localStream as MediaStream?,
      remoteStream: identical(remoteStream, _unset)
          ? this.remoteStream
          : remoteStream as MediaStream?,
      micEnabled: micEnabled ?? this.micEnabled,
      videoEnabled: videoEnabled ?? this.videoEnabled,
      screenSharing: screenSharing ?? this.screenSharing,
      remoteMicEnabled: remoteMicEnabled ?? this.remoteMicEnabled,
      remoteVideoEnabled: remoteVideoEnabled ?? this.remoteVideoEnabled,
      remoteScreenSharing: remoteScreenSharing ?? this.remoteScreenSharing,
    );
  }
}

const Object _unset = Object();

class CallsNotifier extends StateNotifier<CallState> {
  CallsNotifier(this._ref) : super(const CallState.idle()) {
    _ref.read(connectionsNotifierProvider.notifier).bindCallHandler(
          _onNativeCallSignal,
        );
    _ref.listen<PeerConnectionState>(
      peerConnectionProvider,
      (_, __) => _bindToCurrentPeer(),
      fireImmediately: true,
    );
  }

  final Ref _ref;

  StreamSubscription<PeerMediaConnection>? _callSub;
  StreamSubscription<MediaStream>? _remoteStreamSub;
  StreamSubscription<void>? _closeSub;
  PeerJsClient? _boundPeer;

  /// Active media connection (incoming pending or in-call). Cleared
  /// on hangup. Holds the peer reference for `acceptCurrent` to find
  /// without going back to the bound peer's stream.
  PeerMediaConnection? _conn;

  /// Original camera track kept around while the user is screen-
  /// sharing, so we can restore it without re-asking for permission.
  MediaStreamTrack? _cameraTrackBackup;

  /// The active screen-share track. Held so its `onEnded` callback (which
  /// captures `this`) can be detached on hangup / restore — otherwise it
  /// leaks the notifier and can fire after dispose (audit M7).
  MediaStreamTrack? _shareTrack;
  NativeCallSession? _nativeSession;
  NativeCallMedia? _nativeMedia;

  // ─── Public API ───────────────────────────────────────────────

  /// Dial [remotePeerId]. If [video] is true, requests camera too;
  /// otherwise audio-only. Throws if no peer is connected or media
  /// permissions are denied.
  Future<void> startCall(
    String remotePeerId, {
    bool video = false,
  }) async {
    if (state.status != CallStatus.idle) return;
    final peer = _boundPeer;
    final conns = _ref.read(connectionsNotifierProvider.notifier);
    // Isolation fail-closed before media acquire: leftover PeerJS clients
    // do not count when isolation forbids. Native DualStack still proceeds.
    final takeNative = conns.canUseNative(remotePeerId) &&
        conns.remoteUnderstandsNativeCall(remotePeerId);
    if ((!peerjsAllowedOnNative(isWeb: kIsWeb) || peer == null) &&
        !takeNative) {
      state = state.copyWith(lastError: 'Нет активного P2P-соединения');
      return;
    }
    state = state.copyWith(
      status: CallStatus.calling,
      remotePeerId: remotePeerId,
      video: video,
      videoEnabled: video,
      micEnabled: true,
      screenSharing: false,
      remoteMicEnabled: true,
      remoteVideoEnabled: false,
      remoteScreenSharing: false,
      lastError: null,
      localStream: null,
      remoteStream: null,
    );

    MediaStream? local;
    try {
      local = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': video,
      });
    } catch (e) {
      _resetIdleWithError('Нет доступа к микрофону${video ? '/камере' : ''}');
      return;
    }
    // Disposed mid-acquire (e.g. logout while the permission prompt was up):
    // drop the stream and bail before touching `state` (audit M7).
    if (!mounted) {
      try {
        local.getTracks().forEach((t) => t.stop());
      } catch (_) {}
      return;
    }
    state = state.copyWith(localStream: local);

    if (takeNative) {
      _nativeSession = NativeCallSession(
        send: (signal) => conns.sendCallSignal(remotePeerId, signal),
      );
      _nativeSession!.callId = remotePeerId;
      _nativeMedia = NativeCallMedia(
        session: _nativeSession!,
        onRemoteStream: _onNativeRemoteStream,
      );
      String sdp = 'v=0';
      try {
        await _nativeMedia!.attachLocal(local);
        sdp = await _nativeMedia!.createOfferSdp();
      } catch (_) {}
      await _nativeSession!.startOutgoing(
        callId: remotePeerId,
        sdp: sdp,
        media: {'video': video},
      );
      // Native-only when the remote advertised call-v1. Do not also
      // callPeer — that double-rings / double-audios new DualStack pairs.
      return;
    }

    if (!peerjsAllowedOnNative(isWeb: kIsWeb)) {
      try {
        local.getTracks().forEach((t) => t.stop());
      } catch (_) {}
      _resetIdleWithError('Нет активного P2P-соединения');
      return;
    }

    try {
      final conn = await peer!.callPeer(remotePeerId, local);
      if (!mounted) {
        try {
          await conn.close();
        } catch (_) {}
        try {
          local.getTracks().forEach((t) => t.stop());
        } catch (_) {}
        return;
      }
      _attachConnection(conn);
    } catch (e) {
      // Couldn't reach the peer (signaling failure, peer offline).
      try {
        local.getTracks().forEach((t) => t.stop());
      } catch (_) {}
      _resetIdleWithError('Не удалось дозвониться');
    }
  }

  /// Answer the pending incoming call. Allocates local media (audio +
  /// optionally video) and feeds it back to the connection.
  Future<void> acceptCurrent({bool video = false}) async {
    final conn = _conn;
    if (state.status != CallStatus.ringing) return;
    if (conn == null && _nativeSession == null) return;
    // Isolation fail-closed before media acquire when there is no native
    // session. Leftover PeerJS `_conn` must not open the mic.
    if (!peerjsAllowedOnNative(isWeb: kIsWeb) && _nativeSession == null) {
      try {
        unawaited(conn?.close().catchError((_) {}));
      } catch (_) {}
      _resetIdleWithError('Нет активного P2P-соединения');
      return;
    }
    state = state.copyWith(
      video: video,
      videoEnabled: video,
      micEnabled: true,
    );
    MediaStream? local;
    try {
      local = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': video,
      });
    } catch (e) {
      try {
        await conn?.close();
      } catch (_) {}
      _resetIdleWithError('Нет доступа к микрофону${video ? '/камере' : ''}');
      return;
    }
    if (!mounted) {
      try {
        local.getTracks().forEach((t) => t.stop());
      } catch (_) {}
      try {
        await conn?.close();
      } catch (_) {}
      return;
    }
    state = state.copyWith(localStream: local);
    if (_nativeSession != null) {
      String sdp = 'v=0';
      try {
        _nativeMedia ??= NativeCallMedia(
          session: _nativeSession!,
          onRemoteStream: _onNativeRemoteStream,
        );
        await _nativeMedia!.attachLocal(local);
        for (final ice in _nativeSession!.remoteIce) {
          await _nativeMedia!.addRemoteIce(ice);
        }
        final offer = _nativeSession!.remoteSdp ?? '';
        sdp = await _nativeMedia!.createAnswerSdp(offer);
      } catch (_) {}
      await _nativeSession!.accept(sdp: sdp);
      if (conn != null) {
        _conn = null;
        unawaited(conn.close().catchError((_) {}));
      }
      return;
    }
    if (!peerjsAllowedOnNative(isWeb: kIsWeb)) {
      try {
        local.getTracks().forEach((t) => t.stop());
      } catch (_) {}
      try {
        await conn?.close();
      } catch (_) {}
      _resetIdleWithError('Нет активного P2P-соединения');
      return;
    }
    try {
      await conn?.answer(local);
      // Status flips to inCall once the peer's track lands (see
      // `_attachConnection.onStream`). Until then we stay in `ringing`
      // visually — but the remote's "calling" pill should already be
      // gone because we sent the answer SDP.
    } catch (e) {
      try {
        local.getTracks().forEach((t) => t.stop());
      } catch (_) {}
      _resetIdleWithError('Не удалось ответить');
    }
  }

  /// Decline the pending incoming call without answering. Leaves the
  /// peer's "calling" pill terminated cleanly.
  Future<void> declineCurrent() async {
    if (state.status != CallStatus.ringing) return;
    await hangUp();
  }

  /// Toggle our outgoing audio. Synchronous from the peer's POV — no
  /// renegotiation, just flips the track's `enabled` bit. Native
  /// DualStack also publishes `mediaState` for the remote overlay.
  void setMicEnabled(bool enabled) {
    final stream = state.localStream;
    if (stream == null) return;
    for (final t in stream.getAudioTracks()) {
      t.enabled = enabled;
    }
    state = state.copyWith(micEnabled: enabled);
    _publishNativeMediaState();
  }

  /// Toggle our outgoing camera (or whatever video track we're sending
  /// — works for screen share too). Same no-renegotiation pattern.
  void setVideoEnabled(bool enabled) {
    final stream = state.localStream;
    if (stream == null) return;
    for (final t in stream.getVideoTracks()) {
      t.enabled = enabled;
    }
    state = state.copyWith(videoEnabled: enabled);
    _publishNativeMediaState();
  }

  /// Replace the camera track with a `getDisplayMedia` track, or
  /// restore the camera track. On platforms without screen-share
  /// support (`flutter_webrtc` mobile) this surfaces an error and
  /// the state stays unchanged.
  Future<void> toggleScreenShare() async {
    // Isolation fail-closed: leftover PeerJS `_conn` must not start
    // screen share or re-acquire camera unless native DualStack media
    // already owns the RTCPeerConnection.
    if (!peerjsAllowedOnNative(isWeb: kIsWeb) && _nativeMedia == null) {
      return;
    }
    final local = state.localStream;
    if (local == null) return;
    if (_nativeMedia == null && _conn == null) return;

    if (state.screenSharing) {
      // Restore camera. Use the track we backed up when share started;
      // if it's gone (user disabled video before sharing) re-acquire.
      MediaStreamTrack? cameraTrack = _cameraTrackBackup;
      if (cameraTrack == null) {
        try {
          final tmp = await navigator.mediaDevices.getUserMedia(
              {'audio': false, 'video': true});
          cameraTrack = tmp.getVideoTracks().firstOrNull;
        } catch (_) {
          state = state.copyWith(lastError: 'Не удалось вернуть камеру');
          return;
        }
      }
      try {
        _shareTrack?.onEnded = null;
      } catch (_) {}
      _shareTrack = null;
      if (cameraTrack != null) {
        await _replaceVideoTrack(cameraTrack, local);
      }
      if (!mounted) return;
      _cameraTrackBackup = null;
      state = state.copyWith(
        screenSharing: false,
        videoEnabled: true,
        lastError: null,
      );
      _publishNativeMediaState();
      return;
    }

    // Start screen share. Browser shows the picker dialog; user can
    // cancel it, in which case we just no-op silently.
    MediaStream? display;
    try {
      display = await navigator.mediaDevices.getDisplayMedia({
        'video': true,
        'audio': false,
      });
    } catch (_) {
      // User cancelled or permission denied. Don't surface an error
      // popup for the cancel case — that's not a failure, just a
      // change of mind.
      return;
    }
    final shareTrack = display.getVideoTracks().firstOrNull;
    if (shareTrack == null) {
      state = state.copyWith(lastError: 'Не удалось получить экран');
      return;
    }
    final cameraTrack = local.getVideoTracks().firstOrNull;
    _cameraTrackBackup = cameraTrack;
    await _replaceVideoTrack(shareTrack, local);
    if (!mounted) {
      // Disposed mid-swap — don't leave a dangling onEnded or set state.
      try {
        shareTrack.stop();
      } catch (_) {}
      return;
    }
    _shareTrack = shareTrack;

    // When the user clicks the browser's "Stop sharing" button we want
    // to seamlessly fall back to the camera. The track's `onEnded`
    // hook fires for both cases (user-initiated stop AND we ended it
    // ourselves), so we guard with `screenSharing` to avoid recursion.
    // The `mounted` guard stops a post-dispose callback from touching state.
    shareTrack.onEnded = () {
      if (mounted && state.screenSharing) toggleScreenShare();
    };

    state = state.copyWith(
      screenSharing: true,
      videoEnabled: true,
      lastError: null,
    );
    _publishNativeMediaState();
  }

  /// End the active call (or cancel a still-dialing one). Both sides
  /// return to idle.
  Future<void> hangUp() async {
    final remote = state.remotePeerId;
    if (remote != null) {
      unawaited(
        _ref.read(connectionsNotifierProvider.notifier).sendCallSignal(
              remote,
              CallSignal(type: CallSignalType.hangup, callId: remote),
            ),
      );
    }
    final conn = _conn;
    final stream = state.localStream;
    _conn = null;
    if (remote != null) {
      unawaited(systemCalling.endCall(remote));
    }
    _nativeSession = null;
    final nativeMedia = _nativeMedia;
    _nativeMedia = null;
    if (nativeMedia != null) {
      unawaited(nativeMedia.close());
    }
    _cameraTrackBackup = null;
    try {
      _shareTrack?.onEnded = null;
    } catch (_) {}
    _shareTrack = null;
    try {
      _remoteStreamSub?.cancel();
    } catch (_) {}
    _remoteStreamSub = null;
    try {
      _closeSub?.cancel();
    } catch (_) {}
    _closeSub = null;
    if (conn != null) {
      try {
        await conn.close();
      } catch (_) {}
    }
    if (stream != null) {
      try {
        for (final t in stream.getTracks()) {
          t.stop();
        }
      } catch (_) {}
    }
    // hangUp is also called from dispose() (before super.dispose completes) and
    // from the onClose listener — guard so the final state write can't land
    // after the notifier is torn down (audit M7).
    if (mounted) state = const CallState.idle();
  }

  // ─── Internal helpers ─────────────────────────────────────────

  Future<void> _replaceVideoTrack(
      MediaStreamTrack newTrack, MediaStream stream) async {
    // Prefer the native DualStack PC so leftover PeerJS `_conn` cannot
    // steal replaceTrack under isolation.
    final pc = _nativeMedia?.peerConnection ?? _conn?.peerConnection;
    if (pc == null) return;
    final senders = await pc.getSenders();
    final videoSender = senders.firstWhere(
      (s) => s.track?.kind == 'video',
      orElse: () => senders.first,
    );
    await videoSender.replaceTrack(newTrack);

    // Sync the local stream so the PIP preview shows the right thing.
    for (final t in stream.getVideoTracks()) {
      try {
        await stream.removeTrack(t);
        t.stop();
      } catch (_) {}
    }
    await stream.addTrack(newTrack);
  }

  void _attachConnection(PeerMediaConnection conn) {
    if (!peerjsAllowedOnNative(isWeb: kIsWeb)) {
      unawaited(conn.close().catchError((_) {}));
      return;
    }
    _conn = conn;
    _remoteStreamSub = conn.onStream.listen((remote) {
      if (!mounted) return;
      state = state.copyWith(
        status: CallStatus.inCall,
        remoteStream: remote,
      );
    });
    _closeSub = conn.onClose.listen((_) {
      // Peer hung up — wipe local state too. Best-effort: hangUp is
      // idempotent enough to call regardless of who initiated.
      if (mounted) hangUp();
    });
  }

  void _resetIdleWithError(String message) {
    state = const CallState.idle().copyWith(lastError: message);
  }

  void _onNativeRemoteStream(MediaStream remote) {
    if (!mounted) return;
    state = state.copyWith(
      status: CallStatus.inCall,
      remoteStream: remote,
    );
  }

  void _publishNativeMediaState() {
    final session = _nativeSession;
    if (session == null) return;
    unawaited(
      session.publishMediaState(
        micEnabled: state.micEnabled,
        videoEnabled: state.videoEnabled,
        screenSharing: state.screenSharing,
      ),
    );
  }

  void _onNativeCallSignal(String from, CallSignal signal) {
    if (signal.isRoomVoice) return;
    _nativeSession ??= NativeCallSession(
      send: (next) =>
          _ref.read(connectionsNotifierProvider.notifier).sendCallSignal(from, next),
    );
    _nativeSession!.applyRemote(signal);
    if (signal.type == CallSignalType.iceCandidate && signal.candidate != null) {
      unawaited(_nativeMedia?.addRemoteIce(signal.candidate!));
    }
    if (signal.type == CallSignalType.answer && signal.sdp != null) {
      unawaited(_nativeMedia?.setRemoteAnswer(signal.sdp!));
    }
    if (!mounted) return;
    if (signal.type == CallSignalType.hangup ||
        signal.type == CallSignalType.reject) {
      unawaited(hangUp());
      return;
    }
    if (signal.type == CallSignalType.mediaState) {
      final media = signal.media;
      state = state.copyWith(
        remoteMicEnabled: media?['mic'] != false,
        remoteVideoEnabled: media?['video'] == true,
        remoteScreenSharing: media?['screen'] == true,
      );
      return;
    }
    if (signal.type == CallSignalType.offer && !state.isActive) {
      state = state.copyWith(
        status: CallStatus.ringing,
        remotePeerId: from,
        video: signal.media?['video'] == true,
        lastError: null,
      );
      unawaited(
        systemCalling.reportIncoming(
          callId: signal.callId.isNotEmpty ? signal.callId : from,
          video: signal.media?['video'] == true,
        ),
      );
    }
  }

  // ─── PeerJS binding ───────────────────────────────────────────

  void _bindToCurrentPeer() {
    final current = _ref.read(peerConnectionProvider.notifier).rawPeer;
    if (current == _boundPeer) return;

    try {
      _callSub?.cancel();
    } catch (_) {}
    _callSub = null;

    _boundPeer = current;
    if (current == null) return;
    if (!peerjsAllowedOnNative(isWeb: kIsWeb)) return;

    _callSub = current.onCall.listen((conn) {
      // Room voice calls carry a `room-voice` tag and are owned by RoomManager —
      // never surface them as a 1:1 call (audit item 6). Normal 1:1 calls have
      // no such tag and continue exactly as before.
      if (conn.metadata['channel'] == 'room-voice') return;
      if (_nativeSession != null || _nativeMedia != null) {
        unawaited(conn.close().catchError((_) {}));
        return;
      }
      // Only one call at a time. If we're already busy, decline so
      // the caller's pill clears cleanly.
      if (state.isActive) {
        unawaited(conn.close().catchError((_) {}));
        return;
      }
      _attachConnection(conn);
      state = state.copyWith(
        status: CallStatus.ringing,
        remotePeerId: conn.peer,
        video: false,
        videoEnabled: false,
        micEnabled: true,
        lastError: null,
      );
    });
  }

  @override
  void dispose() {
    try {
      _callSub?.cancel();
    } catch (_) {}
    _callSub = null;
    try {
      _ref.read(connectionsNotifierProvider.notifier).bindCallHandler(null);
    } catch (_) {}
    // Best-effort: tear down any active call on dispose. We don't
    // await — the provider container is going away regardless.
    if (_conn != null || _nativeMedia != null || state.localStream != null) {
      unawaited(hangUp());
    }
    super.dispose();
  }
}

// ─── Providers ────────────────────────────────────────────────────

final callsNotifierProvider =
    StateNotifierProvider<CallsNotifier, CallState>((ref) {
  return CallsNotifier(ref);
});

/// Convenience: are we mid-call? Used by `CallOverlayMount` to decide
/// whether to render its scrim. Selecting only `isActive` keeps the
/// overlay from rebuilding on every track-enabled flip.
final callIsActiveProvider = Provider<bool>((ref) {
  return ref.watch(callsNotifierProvider.select((s) => s.isActive));
});
