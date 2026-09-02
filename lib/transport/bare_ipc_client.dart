// Flutter side of orbits-bare-ipc-v1. Production Bare must speak this
// framing. The client never fetches remote JS.

import 'dart:async';
import 'dart:typed_data';

import 'ipc_codec.dart';

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

/// In-process worklet that answers the same methods as
/// `tool/connectivity_harness/src/worklet.js`. Used for plugin lifecycle
/// tests without embedding Bare.
class InProcessBareWorklet {
  InProcessBareWorklet();

  bool started = false;
  bool suspended = false;
  bool published = false;
  String? peerId;
  final List<String> methods = <String>[];
  final List<Map<String, Object?>> rememberedPeers = <Map<String, Object?>>[];
  final List<Map<String, Object?>> journal = <Map<String, Object?>>[];
  Map<String, Object?> autobase = <String, Object?>{};

  Map<String, Object?> _params(Map<String, Object?> body) {
    final raw = body['params'];
    if (raw is Map) return Map<String, Object?>.from(raw);
    return <String, Object?>{};
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
        return {'ok': true, 'result': <String, Object?>{}};
      case 'publish':
        if (!started) throw StateError('start before publish');
        published = true;
        return {'ok': true, 'result': <String, Object?>{}};
      case 'unpublish':
        published = false;
        return {'ok': true, 'result': <String, Object?>{}};
      case 'connect':
      case 'disconnect':
      case 'send':
      case 'sendFile':
      case 'refreshNetwork':
        if (!started || suspended) {
          throw StateError(suspended ? 'suspended' : 'not started');
        }
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
        return {'ok': true, 'result': record};
      case 'journal.list':
        return {
          'ok': true,
          'result': <String, Object?>{
            'blocks': List<Map<String, Object?>>.from(journal),
          },
        };
      case 'autobase.hydrate':
        autobase = <String, Object?>{
          'hydrated': true,
          'members': <String, Object?>{},
          'roles': <String, Object?>{},
          'channels': <String, Object?>{},
          'messages': <Object?>[],
          'attachments': <String, Object?>{},
          'applied': <Object?>[],
        };
        return {'ok': true, 'result': Map<String, Object?>.from(autobase)};
      case 'autobase.state':
        return {'ok': true, 'result': Map<String, Object?>.from(autobase)};
      default:
        throw StateError('unknown method $method');
    }
  }
}

({BareIpcClient client, InProcessBareWorklet worklet}) openInProcessIpc() {
  late final BareIpcClient client;
  final worklet = InProcessBareWorklet();
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
  return (client: client, worklet: worklet);
}
