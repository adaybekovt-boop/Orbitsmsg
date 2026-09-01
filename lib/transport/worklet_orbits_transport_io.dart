// Desktop Bare stand-in: spawn the shipped worklet over orbits-bare-ipc-v1.
// Never fetches remote JS.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'bare_ipc_client.dart';
import 'bare_runtime.dart';
import 'device_binding.dart';
import 'transport_api.dart';

const _bundledWorkletFiles = <String>[
  'worklet.js',
  'mux.js',
  'discovery.js',
  'loopback.js',
  'ipc.js',
  'swarm.js',
  'stand.js',
  'corestore_journal.js',
];

Future<WorkletOrbitsTransport?> spawnWorkletTransport({
  String backend = 'loopback',
}) async {
  final script = _resolveWorklet() ?? await extractBundledWorklet();
  if (script == null) return null;
  try {
    final launch = resolveBareRuntime(script);
    final proc = await Process.start(
      launch.executable,
      launch.arguments,
      environment: {
        ...Platform.environment,
        'ORBITS_HARNESS_BACKEND': backend,
        'ORBITS_RUNTIME': launch.kind,
      },
    );
    return WorkletOrbitsTransport._(proc, runtime: launch.kind);
  } catch (_) {
    return null;
  }
}

File? _resolveWorklet() {
  final fromEnv = Platform.environment['ORBITS_WORKLET_JS'];
  if (fromEnv != null && File(fromEnv).existsSync()) {
    return File(fromEnv);
  }
  const relative = 'tool/connectivity_harness/src/worklet.js';
  if (File(relative).existsSync()) return File(relative);
  return null;
}

/// Copy the hashed in-app worklet tree to a writable dir. Never downloads JS.
Future<File?> extractBundledWorklet() async {
  try {
    final dir = await getApplicationSupportDirectory();
    final dest = Directory('${dir.path}${Platform.pathSeparator}orbits_worklet');
    await dest.create(recursive: true);
    for (final name in _bundledWorkletFiles) {
      final data = await rootBundle.load(
        'tool/connectivity_harness/src/$name',
      );
      await File('${dest.path}${Platform.pathSeparator}$name')
          .writeAsBytes(data.buffer.asUint8List());
    }
    final script = File('${dest.path}${Platform.pathSeparator}worklet.js');
    return script.existsSync() ? script : null;
  } catch (_) {
    return null;
  }
}

class WorkletOrbitsTransport implements OrbitsTransport {
  WorkletOrbitsTransport._(this._proc, {this.runtime = 'node'}) {
    _client = BareIpcClient(write: _proc.stdin.add);
    _proc.stdout.listen(_client.addBytes);
    _proc.stderr.listen((_) {});
    _sub = _client.events.listen(_onIpcEvent);
  }

  final Process _proc;
  final String runtime;
  late final BareIpcClient _client;
  late final StreamSubscription<Map<String, Object?>> _sub;
  final _events = StreamController<TransportEvent>.broadcast();

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  Future<void> start(TransportLocalConfiguration config) async {
    await _client.request('start', {
      'peerId': config.peerId,
      'discoverySecret': config.discoverySecret,
      'relayForced': config.relayForced,
    });
  }

  @override
  Future<void> stop() async {
    try {
      await _client.request('stop');
    } catch (_) {}
    await _sub.cancel();
    await _client.close();
    _proc.kill();
    await _events.close();
  }

  @override
  Future<void> publish(DeviceBinding binding) async {
    await _client.request('publish', {
      'binding': {
        'deviceId': binding.deviceId,
        'capabilities': binding.capabilities,
      },
    });
  }

  @override
  Future<void> unpublish() => _client.request('unpublish');

  @override
  Future<void> connect(PeerDescriptor peer) async {
    await _client.request('connect', {
      'peerId': peer.peerId,
      if (peer.discoverySecret != null) 'discoverySecret': peer.discoverySecret,
    });
  }

  @override
  Future<void> disconnect(String peerId) =>
      _client.request('disconnect', {'peerId': peerId});

  @override
  Future<void> send(
    String peerId,
    TransportChannel channel,
    List<int> frame,
  ) {
    return _client.request('send', {
      'peerId': peerId,
      'channel': channel.name,
      'frameB64': base64Encode(frame),
    });
  }

  @override
  Future<void> sendFile(String peerId, TransportFileDescriptor file) {
    return _client.request('sendFile', {
      'peerId': peerId,
      'file': {
        'path': file.path,
        'sizeBytes': file.sizeBytes,
        'fileName': file.fileName,
        'mime': file.mime,
      },
    });
  }

  @override
  Future<void> suspend() => _client.request('suspend');

  @override
  Future<void> resume() => _client.request('resume');

  @override
  Future<void> refreshNetwork() => _client.request('refreshNetwork');

  void _onIpcEvent(Map<String, Object?> event) {
    final name = event['name'] as String? ?? '';
    final payload = (event['payload'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    switch (name) {
      case 'connected':
        _events.add(TransportConnected(payload['peerId'] as String? ?? ''));
      case 'disconnected':
        _events.add(TransportDisconnected(payload['peerId'] as String? ?? ''));
      case 'suspended':
        _events.add(const TransportSuspended());
      case 'resumed':
        _events.add(const TransportResumed());
      case 'networkChanged':
        _events.add(TransportNetworkChanged(payload['detail'] as String? ?? ''));
      case 'pathChanged':
        _events.add(
          TransportPathChanged(
            payload['peerId'] as String? ?? '',
            payload['path'] == 'relay' ? TransportPath.relay : TransportPath.direct,
          ),
        );
      case 'frame':
        final peerId = payload['peerId'] as String? ?? '';
        final channelName = payload['channel'] as String? ?? 'message';
        final channel = TransportChannel.values.firstWhere(
          (c) => c.name == channelName,
          orElse: () => TransportChannel.message,
        );
        List<int> bytes = const [];
        final b64 = payload['frameB64'] as String?;
        if (b64 != null) {
          bytes = base64Decode(b64);
        }
        _events.add(TransportFrame(peerId, channel, bytes));
      default:
        if (kDebugMode && name.isNotEmpty) {
          debugPrint('[worklet] $name');
        }
    }
  }
}
