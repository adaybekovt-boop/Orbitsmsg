// Flutter side of orbits-bare-ipc-v1. Production Bare must speak this
// framing. The client never fetches remote JS.

import 'dart:async';
import 'dart:typed_data';

import 'ipc_codec.dart';

typedef IpcWrite = void Function(List<int> bytes);

class BareIpcClient {
  BareIpcClient({
    required this.write,
    this.defaultTimeout = const Duration(seconds: 15),
  });

  final IpcWrite write;
  final Duration defaultTimeout;
  final OrbitsIpcCodec _codec = OrbitsIpcCodec();
  final Map<int, Completer<Map<String, Object?>>> _pending =
      <int, Completer<Map<String, Object?>>>{};
  final Map<int, Timer> _timers = <int, Timer>{};
  final _events = StreamController<Map<String, Object?>>.broadcast();
  int _nextId = 1;
  bool _closed = false;
  bool _failed = false;

  Stream<Map<String, Object?>> get events => _events.stream;
  bool get isClosed => _closed;

  void addBytes(List<int> chunk) {
    if (_closed) return;
    try {
      for (final message in _codec.add(chunk)) {
        if (message.type == kIpcEvent) {
          _events.add(message.body);
          continue;
        }
        if (message.type != kIpcResponse) continue;
        final id = message.body['id'];
        if (id is! int) continue;
        final pending = _takePending(id);
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
    } catch (err) {
      failAll(StateError('malformed ipc frame: $err'));
    }
  }

  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) {
    if (_closed || _failed) {
      return Future<Map<String, Object?>>.error(StateError('ipc closed'));
    }
    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _timers[id] = Timer(timeout ?? defaultTimeout, () {
      final pending = _takePending(id);
      if (pending == null || pending.isCompleted) return;
      pending.completeError(TimeoutException('ipc timeout: $method'));
    });
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

  void failAll(Object error) {
    _failed = true;
    final pending = Map<int, Completer<Map<String, Object?>>>.from(_pending);
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _pending.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
  }

  Completer<Map<String, Object?>>? _takePending(int id) {
    _timers.remove(id)?.cancel();
    return _pending.remove(id);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    failAll(StateError('ipc closed'));
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
      case 'authorize':
      case 'deny':
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
