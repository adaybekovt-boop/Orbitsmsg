// Orbits Drop — Riverpod layer over the [DropEngine].
//
// Owns one engine, bridges inbound file-transfer frames in from the connection
// registry, drives outbound sends with DataChannel backpressure, and exposes a
// list of [DropTransfer] rows for the Drop tab. Received files are persisted to
// the `fileBlobs` table so they're openable after the transfer finishes.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/orbits_drop.dart';
import '../peer/helpers.dart';
import '../storage/db.dart' as db;
import '../transport/layers.dart';
import '../transport/peerjs_window.dart';
import '../transport/transport_api.dart';
import 'auth_notifier.dart';
import 'connections_notifier.dart';
import 'drop_path_send_stub.dart'
    if (dart.library.io) 'drop_path_send_io.dart' as drop_path_send;
import 'drop_store_factory_stub.dart'
    if (dart.library.io) 'drop_store_factory_io.dart' as drop_store;

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
    this.localPath,
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

  /// Native path-streamed receive: verified file on disk, not Drift bytes.
  final String? localPath;

  double get progress =>
      size == 0 ? 1.0 : (transferred / size).clamp(0.0, 1.0).toDouble();

  DropTransfer copyWith({
    int? transferred,
    DropStatus? status,
    String? error,
    String? blobId,
    String? localPath,
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
        localPath: localPath ?? this.localPath,
      );
}

class DropState {
  const DropState({this.transfers = const []});

  /// Most-recent first.
  final List<DropTransfer> transfers;

  DropState copyWith({List<DropTransfer>? transfers}) =>
      DropState(transfers: transfers ?? this.transfers);
}

/// True when a native `harness-file-*` packet may be upserted or patched.
///
/// Walks nested maps with [replicationValueIsSafe] ([kForbiddenReplicationFields]).
/// For `harness-file-received`, also refuses a remote URL / scheme and path
/// strings that embed `fileKey` or `opaqueWakeToken`.
bool harnessFilePacketIsSafe(Map packet) {
  if (!replicationValueIsSafe(packet)) return false;
  if (packet['type'] == 'harness-file-received') {
    final path = packet['path'];
    if (path is String &&
        (path.contains('://') ||
            path.contains('fileKey') ||
            path.contains('opaqueWakeToken'))) {
      return false;
    }
  }
  return true;
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
      persistIncomingPath: _persistIncomingPath,
      openIncomingStore: drop_store.openPeerJsDropStore,
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
              if (_handleNativePathPacket(remoteId, packet)) return;
              final conns = _ref.read(connectionsNotifierProvider.notifier);
              if (_isolationBlocksPeerjsDrop(conns, remoteId)) return;
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

  /// Isolation fail-closed: PeerJS is forbidden and DualStack cannot take
  /// the file. Product [kPeerjsIsolationMode] stays default-live, so this
  /// is false until the support window closes in writing.
  bool _isolationBlocksPeerjsDrop(ConnectionsNotifier conns, String pid) =>
      !peerjsAllowedOnNative(isWeb: kIsWeb) && !conns.canUseNative(pid);

  String _failOutboundIsolated({
    required String peerId,
    required String name,
    required String mime,
    required int size,
  }) {
    final id = dropNewFileId();
    _upsert(DropTransfer(
      id: id,
      name: name,
      size: size,
      mime: mime,
      peerId: peerId,
      direction: DropDirection.outgoing,
      status: DropStatus.failed,
      error: 'Нет активного P2P-соединения',
    ));
    return id;
  }

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

    if (_isolationBlocksPeerjsDrop(conns, pid)) {
      return _failOutboundIsolated(
        peerId: pid,
        name: name,
        mime: mime,
        size: bytes.length,
      );
    }

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
        peerId: pid,
      );
    } catch (e) {
      _patch(id, (t) => t.copyWith(status: DropStatus.failed, error: '$e'));
    }
    return id;
  }

  /// Web picker `readStream`: hash while sending. Never one Dart `Uint8List`
  /// of the whole file. Native Drop still uses [sendFileFromPath].
  Future<String?> sendFileFromStream(
    String peerId,
    Stream<List<int>> incoming, {
    required String name,
    required String mime,
    required int sizeBytes,
  }) async {
    if (sizeBytes <= 0) return null;
    final pid = normalizePeerId(peerId);
    final conns = _ref.read(connectionsNotifierProvider.notifier);

    if (_isolationBlocksPeerjsDrop(conns, pid)) {
      return _failOutboundIsolated(
        peerId: pid,
        name: name,
        mime: mime,
        size: sizeBytes,
      );
    }

    if (!conns.hasReliable(pid)) {
      conns.openReliable(pid);
      final ok = await _waitForReliable(pid);
      if (!ok) return null;
    }

    final id = dropNewFileId();
    _upsert(DropTransfer(
      id: id,
      name: name,
      size: sizeBytes,
      mime: mime,
      peerId: pid,
      direction: DropDirection.outgoing,
    ));

    try {
      await _engine.sendFileFromIncomingStream(
        incoming: incoming,
        size: sizeBytes,
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

  /// Native carrier first. If Hyperswarm is off, stream the same path over
  /// PeerJS Drop without reading the file into a Dart `Uint8List`.
  Future<String?> sendFileFromPath(
    String peerId, {
    required String path,
    required String name,
    required String mime,
    required int sizeBytes,
    int resumeOffset = 0,
  }) async {
    if (path.isEmpty) return null;
    if (path.contains('://')) return null;
    final pid = normalizePeerId(peerId);
    final conns = _ref.read(connectionsNotifierProvider.notifier);

    if (_isolationBlocksPeerjsDrop(conns, pid)) {
      return _failOutboundIsolated(
        peerId: pid,
        name: name,
        mime: mime,
        size: sizeBytes,
      );
    }

    // Native path-stream does not need a PeerJS reliable channel. Only
    // open one when isolation still allows PeerJS (product default-live).
    if (peerjsAllowedOnNative(isWeb: kIsWeb) && !conns.hasReliable(pid)) {
      conns.openReliable(pid);
      final ok = await _waitForReliable(pid);
      if (!ok) return null;
    }

    final id = dropNewFileId();
    try {
      final ok = await conns.sendFileFromPath(
        pid,
        TransportFileDescriptor(
          path: path,
          sizeBytes: sizeBytes,
          fileName: name,
          mime: mime,
          resumeOffset: resumeOffset,
        ),
      );
      if (ok) {
        _upsert(DropTransfer(
          id: id,
          name: name,
          size: sizeBytes,
          mime: mime,
          peerId: pid,
          direction: DropDirection.outgoing,
          transferred: sizeBytes,
          status: DropStatus.completed,
        ));
        return id;
      }
    } on StateError catch (e) {
      _upsert(DropTransfer(
        id: id,
        name: name,
        size: sizeBytes,
        mime: mime,
        peerId: pid,
        direction: DropDirection.outgoing,
        status: DropStatus.failed,
        error: e.message,
      ));
      return id;
    }

    if (!peerjsAllowedOnNative(isWeb: kIsWeb)) {
      _upsert(DropTransfer(
        id: id,
        name: name,
        size: sizeBytes,
        mime: mime,
        peerId: pid,
        direction: DropDirection.outgoing,
        status: DropStatus.failed,
        error: 'Нет активного P2P-соединения',
      ));
      return id;
    }

    _upsert(DropTransfer(
      id: id,
      name: name,
      size: sizeBytes,
      mime: mime,
      peerId: pid,
      direction: DropDirection.outgoing,
    ));
    try {
      final sent = await drop_path_send.sendDropFileFromFilesystem(
        engine: _engine,
        path: path,
        name: name,
        mime: mime,
        sizeBytes: sizeBytes,
        fileId: id,
        peerId: pid,
        resumeOffset: resumeOffset,
        send: (packet) => conns.sendDrop(pid, packet),
        waitForDrain: () => conns.waitForDropDrain(pid),
      );
      if (sent == null) {
        _patch(
          id,
          (t) => t.copyWith(
            status: DropStatus.failed,
            error: 'Не удалось прочитать файл',
          ),
        );
      }
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

  bool _handleNativePathPacket(String peerId, Object packet) {
    if (packet is! Map) return false;
    if (!harnessFilePacketIsSafe(packet)) return true;
    final type = packet['type'];
    if (type == 'harness-file-start') {
      final id = packet['id'] as String? ?? '';
      if (id.isEmpty) return true;
      _upsert(DropTransfer(
        id: id,
        name: sanitizeDropFileName(packet['name'] as String?),
        size: (packet['size'] as num?)?.toInt() ?? 0,
        mime: (packet['mime'] as String?) ?? 'application/octet-stream',
        peerId: peerId,
        direction: DropDirection.incoming,
      ));
      return true;
    }
    if (type == 'harness-file-chunk') {
      final id = packet['id'] as String? ?? '';
      final offset = (packet['offset'] as num?)?.toInt() ?? 0;
      if (id.isNotEmpty) {
        _patch(id, (t) => t.copyWith(transferred: offset));
      }
      return true;
    }
    if (type == 'harness-file-end' || type == 'harness-file-resume') {
      return true;
    }
    if (type == 'harness-file-received') {
      final id = packet['id'] as String? ?? '';
      final localPath = packet['path'] as String? ?? '';
      final size = (packet['size'] as num?)?.toInt() ?? 0;
      if (id.isEmpty) return true;
      final existing = state.transfers.where((t) => t.id == id);
      if (existing.isEmpty) {
        _upsert(DropTransfer(
          id: id,
          name: sanitizeDropFileName(packet['name'] as String?),
          size: size,
          mime: 'application/octet-stream',
          peerId: peerId,
          direction: DropDirection.incoming,
          transferred: size,
          status: DropStatus.completed,
          localPath: localPath,
        ));
      } else {
        _patch(
          id,
          (t) => t.copyWith(
            transferred: size == 0 ? t.size : size,
            status: DropStatus.completed,
            localPath: localPath,
          ),
        );
      }
      return true;
    }
    return false;
  }

  Future<bool> _persistIncoming(DropFileMeta meta, Uint8List bytes) async {
    _patch(meta.fileId, (t) => t.copyWith(status: DropStatus.received));
    final blobId = 'drop-${meta.fileId}';
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

  Future<bool> _persistIncomingPath(DropFileMeta meta, String path) async {
    _patch(
      meta.fileId,
      (t) => t.copyWith(
        transferred: t.size,
        status: DropStatus.completed,
        localPath: path,
      ),
    );
    return true;
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
