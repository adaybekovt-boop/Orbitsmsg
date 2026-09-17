// Flutter side of orbits-bare-ipc-v1. Production Bare must speak this
// framing. The client never fetches remote JS.

import 'dart:async';
import 'dart:typed_data';

import '../rooms/autobase_log.dart';
import 'ipc_codec.dart';
import 'layers.dart';

typedef IpcWrite = void Function(List<int> bytes);

class BareIpcClient {
  BareIpcClient({required this.write});

  final IpcWrite write;
  final OrbitsIpcCodec _codec = OrbitsIpcCodec();
  final Map<int, Completer<Map<String, Object?>>> _pending =
      <int, Completer<Map<String, Object?>>>{};
  final _events = StreamController<Map<String, Object?>>.broadcast();
  int _nextId = 1;

  Stream<Map<String, Object?>> get events => _events.stream;

  void addBytes(List<int> chunk) {
    for (final message in _codec.add(chunk)) {
      if (message.type == kIpcEvent) {
        _events.add(message.body);
        continue;
      }
      if (message.type != kIpcResponse) continue;
      final id = message.body['id'];
      if (id is! int) continue;
      final pending = _pending.remove(id);
      if (pending == null) continue;
      if (message.body['ok'] == false) {
        pending.completeError(
          StateError(message.body['error'] as String? ?? 'ipc error'),
        );
      } else {
        pending.complete(
          (message.body['result'] as Map?)?.cast<String, Object?>() ??
              const <String, Object?>{},
        );
      }
    }
  }

  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    write(
      OrbitsIpcCodec.encode(
        OrbitsIpcMessage(
          type: kIpcRequest,
          body: <String, Object?>{
            'id': id,
            'method': method,
            'params': params,
          },
        ),
      ),
    );
    return completer.future;
  }

  Future<void> close() async {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('ipc closed'));
      }
    }
    _pending.clear();
    await _events.close();
  }
}

/// Shared registry so two [InProcessBareWorklet]s can route frames
/// without spawning Bare. Not a Hyperswarm / discovery topic.
class InProcessWorkletHub {
  final Map<String, InProcessBareWorklet> published =
      <String, InProcessBareWorklet>{};

  void attach(InProcessBareWorklet worklet) {
    final id = worklet.peerId;
    if (id == null || id.isEmpty || id.contains('://')) return;
    published[id] = worklet;
  }

  void detach(InProcessBareWorklet worklet) {
    published.removeWhere((_, value) => identical(value, worklet));
  }

  InProcessBareWorklet? find(String peerId) => published[peerId];
}

/// In-process worklet that answers the same methods as
/// `tool/connectivity_harness/src/worklet.js`. Used for plugin lifecycle
/// tests without embedding Bare.
class InProcessBareWorklet {
  InProcessBareWorklet({this.hub});

  final InProcessWorkletHub? hub;
  void Function(String name, Map<String, Object?> payload)? onEvent;

  bool started = false;
  bool suspended = false;
  bool published = false;
  String? peerId;
  final Set<String> connectedPeers = <String>{};
  final List<String> methods = <String>[];
  final List<Map<String, Object?>> rememberedPeers = <Map<String, Object?>>[];
  final List<Map<String, Object?>> connects = <Map<String, Object?>>[];
  final List<Map<String, Object?>> sentFrames = <Map<String, Object?>>[];
  final List<Map<String, Object?>> sentFiles = <Map<String, Object?>>[];
  final List<Map<String, Object?>> journal = <Map<String, Object?>>[];
  final AutobaseProjection _autobase = AutobaseProjection();
  Map<String, Object?> autobase = <String, Object?>{};

  Map<String, Object?> _params(Map<String, Object?> body) {
    final raw = body['params'];
    if (raw is Map) return Map<String, Object?>.from(raw);
    return <String, Object?>{};
  }

  void _emit(String name, Map<String, Object?> payload) {
    onEvent?.call(name, payload);
  }

  void _requireLive() {
    if (!started || suspended) {
      throw StateError(suspended ? 'suspended' : 'not started');
    }
  }

  void _link(InProcessBareWorklet other) {
    final local = peerId ?? '';
    final remote = other.peerId ?? '';
    if (local.isEmpty || remote.isEmpty) return;
    connectedPeers.add(remote);
    other.connectedPeers.add(local);
    _emit('connected', <String, Object?>{'peerId': remote, 'path': 'direct'});
    _emit('pathChanged', <String, Object?>{'peerId': remote, 'path': 'direct'});
    other._emit(
      'connected',
      <String, Object?>{'peerId': local, 'path': 'direct'},
    );
    other._emit(
      'pathChanged',
      <String, Object?>{'peerId': local, 'path': 'direct'},
    );
  }

  Map<String, Object?> handle(Map<String, Object?> body) {
    final method = body['method'] as String? ?? '';
    methods.add(method);
    switch (method) {
      case 'start':
        started = true;
        peerId = (body['params'] as Map?)?['peerId'] as String?;
        return {'ok': true, 'result': <String, Object?>{}};
      case 'stop':
        started = false;
        published = false;
        hub?.detach(this);
        connectedPeers.clear();
        return {'ok': true, 'result': <String, Object?>{}};
      case 'publish':
        if (!started) throw StateError('start before publish');
        published = true;
        hub?.attach(this);
        return {'ok': true, 'result': <String, Object?>{}};
      case 'unpublish':
        published = false;
        hub?.detach(this);
        return {'ok': true, 'result': <String, Object?>{}};
      case 'connect':
        _requireLive();
        final connect = _params(body);
        final remoteId = connect['peerId'] as String? ?? '';
        if (remoteId.contains('://')) {
          throw StateError('connect refuses remote id');
        }
        connects.add(connect);
        if (remoteId.isEmpty) {
          return {'ok': true, 'result': <String, Object?>{}};
        }
        if (hub != null) {
          final other = hub!.find(remoteId);
          if (other == null) {
            throw StateError('peer not published');
          }
          _link(other);
        } else {
          connectedPeers.add(remoteId);
        }
        return {'ok': true, 'result': <String, Object?>{}};
      case 'disconnect':
        _requireLive();
        final leaveId = _params(body)['peerId'] as String? ?? '';
        if (leaveId.isEmpty || leaveId.contains('://')) {
          return {'ok': true, 'result': <String, Object?>{}};
        }
        connectedPeers.remove(leaveId);
        final other = hub?.find(leaveId);
        other?.connectedPeers.remove(peerId);
        _emit('disconnected', <String, Object?>{'peerId': leaveId});
        return {'ok': true, 'result': <String, Object?>{}};
      case 'send':
        _requireLive();
        final send = _params(body);
        if (!replicationValueIsSafe(send)) {
          throw StateError('send refuses forbidden fields');
        }
        final sendId = send['peerId'] as String? ?? '';
        if (sendId.isEmpty) {
          return {'ok': true, 'result': <String, Object?>{}};
        }
        if (sendId.contains('://')) {
          throw StateError('send refuses remote id');
        }
        if (!connectedPeers.contains(sendId)) {
          throw StateError('not connected: $sendId');
        }
        sentFrames.add(send);
        final channel = send['channel'] as String? ?? 'message';
        final frameB64 = send['frameB64'] as String? ?? '';
        hub?.find(sendId)?._emit('frame', <String, Object?>{
          'peerId': peerId ?? '',
          'channel': channel,
          if (frameB64.isNotEmpty) 'frameB64': frameB64,
        });
        return {'ok': true, 'result': <String, Object?>{}};
      case 'sendFile':
        _requireLive();
        final fileParams = _params(body);
        final file = fileParams['file'];
        if (file is! Map) {
          throw StateError('sendFile needs a path');
        }
        final fileMap = Map<String, Object?>.from(file);
        final path = fileMap['path'] as String? ?? '';
        if (path.isEmpty) {
          throw StateError('sendFile needs a path');
        }
        if (path.contains('://')) {
          throw StateError('sendFile refuses remote path');
        }
        if (fileMap['bytes'] != null) {
          throw StateError('sendFile takes a path, not bytes');
        }
        if (!replicationValueIsSafe(fileMap)) {
          throw StateError('sendFile refuses fileKey');
        }
        final filePeer = fileParams['peerId'] as String? ?? '';
        if (filePeer.contains('://')) {
          throw StateError('sendFile refuses remote id');
        }
        sentFiles.add(fileParams);
        if (filePeer.isNotEmpty && connectedPeers.contains(filePeer)) {
          hub?.find(filePeer)?._emit('frame', <String, Object?>{
            'peerId': peerId ?? '',
            'channel': 'attachment',
            'body': <String, Object?>{
              'type': fileMap['protocol'] == 'attach-chunk'
                  ? 'attach-chunk-path'
                  : 'harness-file-start',
              'fileName': fileMap['fileName'],
              'fileId': fileMap['fileId'],
            },
          });
        }
        return {'ok': true, 'result': <String, Object?>{}};
      case 'refreshNetwork':
        _requireLive();
        _emit('networkChanged', <String, Object?>{'detail': 'in-process'});
        return {'ok': true, 'result': <String, Object?>{}};
      case 'suspend':
        suspended = true;
        return {'ok': true, 'result': <String, Object?>{}};
      case 'resume':
        suspended = false;
        return {'ok': true, 'result': <String, Object?>{}};
      case 'rememberPeer':
        rememberedPeers.add(_params(body));
        return {'ok': true, 'result': <String, Object?>{}};
      case 'journal.append':
        final record = _params(body);
        journal.add(record);
        _autobase.hydrateFromJournal([record]);
        autobase = _autobase.snapshot();
        return {'ok': true, 'result': record};
      case 'journal.list':
        _autobase.hydrateFromJournal(journal);
        autobase = _autobase.snapshot();
        return {
          'ok': true,
          'result': <String, Object?>{
            'blocks': List<Map<String, Object?>>.from(journal),
          },
        };
      case 'autobase.hydrate':
        final params = _params(body);
        final raw = params['rows'] ?? params['blocks'] ?? journal;
        final rows = <Map<String, Object?>>[
          if (raw is List)
            for (final row in raw)
              if (row is Map) Map<String, Object?>.from(row),
        ];
        final hydrated = _autobase.hydrateFromJournal(rows);
        autobase = <String, Object?>{
          'hydrated': hydrated,
          ..._autobase.snapshot(),
        };
        return {'ok': true, 'result': Map<String, Object?>.from(autobase)};
      case 'autobase.state':
        autobase = _autobase.snapshot();
        return {'ok': true, 'result': Map<String, Object?>.from(autobase)};
      default:
        throw StateError('unknown method $method');
    }
  }
}

({BareIpcClient client, InProcessBareWorklet worklet}) openInProcessIpc({
  InProcessWorkletHub? hub,
}) {
  late final BareIpcClient client;
  final worklet = InProcessBareWorklet(hub: hub);
  client = BareIpcClient(
    write: (bytes) {
      final codec = OrbitsIpcCodec();
      for (final message in codec.add(Uint8List.fromList(bytes))) {
        if (message.type != kIpcRequest) continue;
        try {
          final result = worklet.handle(message.body);
          client.addBytes(
            OrbitsIpcCodec.encode(
              OrbitsIpcMessage(
                type: kIpcResponse,
                body: <String, Object?>{
                  'id': message.body['id'],
                  'ok': true,
                  'result': result['result'],
                },
              ),
            ),
          );
        } catch (err) {
          client.addBytes(
            OrbitsIpcCodec.encode(
              OrbitsIpcMessage(
                type: kIpcResponse,
                body: <String, Object?>{
                  'id': message.body['id'],
                  'ok': false,
                  'error': err.toString(),
                },
              ),
            ),
          );
        }
      }
    },
  );
  worklet.onEvent = (name, payload) {
    client.addBytes(
      OrbitsIpcCodec.encode(
        OrbitsIpcMessage(
          type: kIpcEvent,
          body: <String, Object?>{
            'name': name,
            'payload': payload,
          },
        ),
      ),
    );
  };
  return (client: client, worklet: worklet);
}
