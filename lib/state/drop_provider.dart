// Orbits Drop — Riverpod layer over the [DropEngine].
//
// Owns one engine, bridges inbound file-transfer frames in from the connection
// registry, drives outbound sends with DataChannel backpressure, and exposes a
// list of [DropTransfer] rows for the Drop tab. Received files are persisted to
// the `fileBlobs` table so they're openable after the transfer finishes.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/orbits_drop.dart';
import '../peer/helpers.dart';
import '../storage/db.dart' as db;
import 'auth_notifier.dart';
import 'connections_notifier.dart';

enum DropStatus { active, completed, failed }

/// A single transfer row for the UI.
class DropTransfer {
  const DropTransfer({
    required this.id,
    required this.name,
    required this.size,
    required this.mime,
    required this.peerId,
    required this.direction,
    this.transferred = 0,
    this.status = DropStatus.active,
    this.error,
    this.blobId,
  });

  final String id;
  final String name;
  final int size;
  final String mime;
  final String peerId;
  final DropDirection direction;
  final int transferred;
  final DropStatus status;
  final String? error;

  /// `fileBlobs` row id once a received file has been saved (null otherwise).
  final String? blobId;

  double get progress =>
      size == 0 ? 1.0 : (transferred / size).clamp(0.0, 1.0).toDouble();

  DropTransfer copyWith({
    int? transferred,
    DropStatus? status,
    String? error,
    String? blobId,
  }) =>
      DropTransfer(
        id: id,
        name: name,
        size: size,
        mime: mime,
        peerId: peerId,
        direction: direction,
        transferred: transferred ?? this.transferred,
        status: status ?? this.status,
        error: error ?? this.error,
        blobId: blobId ?? this.blobId,
      );
}

class DropState {
  const DropState({this.transfers = const []});

  /// Most-recent first.
  final List<DropTransfer> transfers;

  DropState copyWith({List<DropTransfer>? transfers}) =>
      DropState(transfers: transfers ?? this.transfers);
}

class DropNotifier extends StateNotifier<DropState> {
  DropNotifier(this._ref) : super(const DropState()) {
    _engine = DropEngine(
      onIncomingStart: _onIncomingStart,
      onProgress: _onProgress,
      onComplete: _onComplete,
      onFailed: _onFailed,
      onIncomingReady: _onIncomingReady,
    );

    // Forward inbound frames from the connection registry into the engine.
    // We stash the source peerId just before dispatching so the (peer-agnostic)
    // engine's incoming-start callback can attribute the transfer.
    _ref.read(connectionsNotifierProvider.notifier).bindDrop(
          DropBridge(
            handleInbound: (remoteId, packet) {
              _pendingInboundPeer = remoteId;
              unawaited(_engine.handleInbound(packet, peerId: remoteId));
            },
            resetPeer: (remoteId) => _engine.resetPeer(remoteId),
          ),
        );

    // Clear everything on sign-out.
    _ref.listen<AuthState>(authNotifierProvider, (prev, next) {
      if (prev is AuthAuthed && next is! AuthAuthed) {
        _engine.reset();
        _pendingInboundPeer = '';
        if (mounted) state = const DropState();
      }
    });
  }

  final Ref _ref;
  late final DropEngine _engine;
  String _pendingInboundPeer = '';

  // ── Outbound ──────────────────────────────────────────────────

  /// Send [bytes] to [peerId]. Opens the reliable channel if needed and waits
  /// briefly for it. Returns the transfer id, or null if the channel never
  /// came up.
  Future<String?> sendFile(
    String peerId,
    Uint8List bytes, {
    required String name,
    required String mime,
  }) async {
    final pid = normalizePeerId(peerId);
    final conns = _ref.read(connectionsNotifierProvider.notifier);

    if (!conns.hasReliable(pid)) {
      conns.openReliable(pid);
      final ok = await _waitForReliable(pid);
      if (!ok) return null;
    }

    final id = dropNewFileId();
    _upsert(DropTransfer(
      id: id,
      name: name,
      size: bytes.length,
      mime: mime,
      peerId: pid,
      direction: DropDirection.outgoing,
    ));

    try {
      await _engine.sendFile(
        bytes: bytes,
        name: name,
        mime: mime,
        fileId: id,
        send: (packet) => conns.sendDrop(pid, packet),
        waitForDrain: () => conns.waitForDropDrain(pid),
      );
    } catch (e) {
      _patch(id, (t) => t.copyWith(status: DropStatus.failed, error: '$e'));
    }
    return id;
  }

  /// Abort an in-flight outgoing transfer.
  void cancel(String fileId) {
    _engine.abortOutgoing(fileId);
    _patch(fileId,
        (t) => t.copyWith(status: DropStatus.failed, error: 'Отменено'));
  }

  /// Remove a finished/failed row from the list.
  void dismiss(String fileId) {
    state = state.copyWith(
      transfers: state.transfers.where((t) => t.id != fileId).toList(),
    );
  }

  Future<bool> _waitForReliable(String pid) async {
    final conns = _ref.read(connectionsNotifierProvider.notifier);
    for (var i = 0; i < 80; i++) {
      if (conns.hasReliable(pid)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return conns.hasReliable(pid);
  }

  // ── Engine callbacks ──────────────────────────────────────────

  void _onIncomingStart(DropFileMeta meta) {
    _upsert(DropTransfer(
      id: meta.fileId,
      name: meta.name,
      size: meta.size,
      mime: meta.mime,
      peerId: _pendingInboundPeer,
      direction: DropDirection.incoming,
    ));
  }

  void _onProgress(String fileId, int sent, int total, DropDirection _) {
    _patch(fileId, (t) => t.copyWith(transferred: sent));
  }

  void _onComplete(String fileId, DropDirection dir) {
    // Incoming completion is finalised in [_onIncomingReady] (after the file is
    // saved); only flip outgoing here.
    if (dir == DropDirection.outgoing) {
      _patch(fileId,
          (t) => t.copyWith(status: DropStatus.completed, transferred: t.size));
    }
  }

  void _onFailed(String fileId, DropDirection _, String reason) {
    _patch(fileId, (t) => t.copyWith(status: DropStatus.failed, error: reason));
  }

  Future<void> _onIncomingReady(DropFileMeta meta, Uint8List bytes) async {
    final blobId = 'drop-${meta.fileId}';
    var saved = true;
    try {
      await db.saveFileBlob(
        blobId,
        bytes,
        mime: meta.mime,
        name: meta.name,
        size: meta.size,
        kind: _kindForMime(meta.mime),
      );
    } catch (_) {
      saved = false;
    }
    _patch(
      meta.fileId,
      (t) => t.copyWith(
        transferred: t.size,
        status: saved ? DropStatus.completed : DropStatus.failed,
        error: saved ? null : 'Не удалось сохранить файл',
        blobId: saved ? blobId : null,
      ),
    );
  }

  // ── State helpers ─────────────────────────────────────────────

  void _upsert(DropTransfer t) {
    final list = state.transfers.where((e) => e.id != t.id).toList()
      ..insert(0, t);
    state = state.copyWith(transfers: list);
  }

  void _patch(String id, DropTransfer Function(DropTransfer) f) {
    var changed = false;
    final list = [
      for (final t in state.transfers)
        if (t.id == id) (changed = true) ? f(t) : t else t,
    ];
    if (changed && mounted) state = state.copyWith(transfers: list);
  }

  static String _kindForMime(String mime) {
    final m = mime.toLowerCase();
    if (m.startsWith('image/')) return 'image';
    if (m.startsWith('video/')) return 'video';
    if (m.startsWith('audio/')) return 'audio';
    return 'file';
  }
}

final dropNotifierProvider =
    StateNotifierProvider<DropNotifier, DropState>((ref) => DropNotifier(ref));
