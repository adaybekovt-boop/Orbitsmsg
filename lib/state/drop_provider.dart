// Orbits Drop — Riverpod layer over the [DropEngine].
//
// Owns one engine, bridges inbound file-transfer frames in from the connection
// registry, drives outbound sends with DataChannel backpressure, and exposes a
// list of [DropTransfer] rows for the Drop tab. Received files are persisted to
// the `fileBlobs` table so they're openable after the transfer finishes.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachments/file_transfer_session.dart'
    show kCoordinatorCompletionType;
import '../attachments/temp_attachment.dart';
import '../core/orbits_drop.dart';
import '../peer/helpers.dart';
import '../transport/dev_bare_transport.dart';
import '../transport/transport_api.dart';
import '../storage/db.dart' as db;
import 'auth_notifier.dart';
import 'connections_notifier.dart';

enum DropStatus { queued, sent, received, completed, failed }

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
    this.status = DropStatus.queued,
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
      onOutgoingSent: _onOutgoingSent,
      persistIncoming: _persistIncoming,
      onReply: (peerId, packet) {
        _ref.read(connectionsNotifierProvider.notifier).sendDrop(peerId, packet);
      },
    );

    // Forward inbound frames from the connection registry into the engine.
    // We stash the source peerId just before dispatching so the (peer-agnostic)
    // engine's incoming-start callback can attribute the transfer.
    _ref.read(connectionsNotifierProvider.notifier).bindDrop(
          DropBridge(
            handleInbound: (remoteId, packet) {
              _pendingInboundPeer = remoteId;
              if (packet is Map &&
                  packet['type'] == kCoordinatorCompletionType) {
                unawaited(_persistNativeFile(remoteId, packet));
                return;
              }
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
      if (conns.canUseNative(pid) || isDevBareTransportRequested()) {
        final desc = await writeTempAttachment(
          bytes: bytes,
          name: name,
          mime: mime,
        );
        if (desc == null) {
          throw StateError('native attachment path unavailable');
        }
        await conns.sendFile(
          pid,
          TransportFileDescriptor(
            path: desc.path,
            sizeBytes: desc.sizeBytes,
            fileName: name,
            mime: mime,
            transferId: id,
          ),
        );
        _patch(id, (t) => t.copyWith(status: DropStatus.completed, transferred: bytes.length));
        return id;
      }
      await _engine.sendFile(
        bytes: bytes,
        name: name,
        mime: mime,
        fileId: id,
        send: (packet) => conns.sendDrop(pid, packet),
        waitForDrain: () => conns.waitForDropDrain(pid),
        peerId: pid,
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

  void _onOutgoingSent(String fileId) {
    _patch(fileId, (t) => t.copyWith(status: DropStatus.sent));
  }

  void _onComplete(String fileId, DropDirection dir) {
    // Outgoing: only after the receiver's persist ACK (R12).
    // Incoming: persistIncoming already marked received/completed.
    if (dir == DropDirection.outgoing) {
      _patch(fileId,
          (t) => t.copyWith(status: DropStatus.completed, transferred: t.size));
    }
  }

  void _onFailed(String fileId, DropDirection _, String reason) {
    _patch(fileId, (t) => t.copyWith(status: DropStatus.failed, error: reason));
  }

  Future<void> _persistNativeFile(String peerId, Map<dynamic, dynamic> packet) async {
    final path = packet['path'] as String? ?? '';
    final id = packet['id'] as String? ?? '';
    final name = (packet['name'] as String?) ??
        (path.isEmpty ? id : path.split(RegExp(r'[/\\]')).last);
    final size = (packet['size'] as num?)?.toInt() ?? 0;
    final mime = (packet['mime'] as String?) ?? 'application/octet-stream';
    if (path.isEmpty || id.isEmpty) return;
    // Defense in depth: even a local coordinator completion must point
    // inside the jail. No UI row before the persist succeeds.
    if (!isAllowedAttachmentPath(path)) return;
    final normPeer = normalizePeerId(peerId);
    final blobId = 'drop-$normPeer|$id';
    try {
      final ok = await db.saveFileBlob(
        blobId,
        const <int>[],
        mime: mime,
        name: name,
        size: size,
        kind: _kindForMime(mime),
        path: path,
        sha256hex: packet['sha256'] as String? ?? '',
      );
      if (!ok) {
        throw StateError('received file missing');
      }
      _upsert(DropTransfer(
        id: id,
        name: name,
        size: size,
        mime: mime,
        peerId: peerId,
        direction: DropDirection.incoming,
        transferred: size,
        status: DropStatus.completed,
        blobId: blobId,
      ));
    } catch (e) {
      _patch(id, (t) => t.copyWith(status: DropStatus.failed, error: '$e'),
          peerId: peerId);
    }
  }

  Future<bool> _persistIncoming(DropFileMeta meta, Uint8List bytes) async {
    _patch(meta.fileId, (t) => t.copyWith(status: DropStatus.received));
    final peer = normalizePeerId(_pendingInboundPeer);
    final blobId = 'drop-$peer|${meta.fileId}';
    try {
      final desc = await writeTempAttachment(
        bytes: bytes,
        name: meta.name,
        mime: meta.mime,
      );
      await db.saveFileBlob(
        blobId,
        desc == null ? bytes : const <int>[],
        mime: meta.mime,
        name: meta.name,
        size: meta.size,
        kind: _kindForMime(meta.mime),
        path: desc?.path,
        sha256hex: meta.hash,
      );
    } catch (_) {
      _patch(
        meta.fileId,
        (t) => t.copyWith(
          status: DropStatus.failed,
          error: 'Не удалось сохранить файл',
        ),
      );
      return false;
    }
    _patch(
      meta.fileId,
      (t) => t.copyWith(
        transferred: t.size,
        status: DropStatus.completed,
        blobId: blobId,
      ),
    );
    return true;
  }

  // ── State helpers ─────────────────────────────────────────────

  void _upsert(DropTransfer t) {
    final list = state.transfers
        .where((e) => !(e.id == t.id && e.peerId == t.peerId))
        .toList()
      ..insert(0, t);
    state = state.copyWith(transfers: list);
  }

  void _patch(String id, DropTransfer Function(DropTransfer) f,
      {String? peerId}) {
    var changed = false;
    final list = [
      for (final t in state.transfers)
        if (t.id == id && (peerId == null || t.peerId == peerId))
          (changed = true) ? f(t) : t
        else
          t,
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
