// Desktop Bare stand-in: spawn the shipped worklet over orbits-bare-ipc-v1.
// Never fetches remote JS.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'bare_ipc_client.dart';
import 'bare_runtime.dart';
import 'device_binding.dart';
import 'local_worklet_bundle.dart';
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
  'bare_compat.js',
  'incoming_paths.js',
];

Future<WorkletOrbitsTransport?> spawnWorkletTransport({
  String backend = 'loopback',
}) async {
  inspectLocalWorkletBundle().assertSafeForProduction();
  final script =
      _resolveWorklet(releaseMode: kReleaseMode) ??
      await extractBundledWorklet();
  if (script == null) return null;
  try {
    final launch = resolveBareRuntime(
      script,
      allowNode: !kReleaseMode,
      releaseMode: kReleaseMode,
    );
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
  } on StateError {
    rethrow;
  } catch (_) {
    return null;
  }
}

File? _resolveWorklet({required bool releaseMode}) {
  final fromEnv = Platform.environment['ORBITS_WORKLET_JS'];
  if (fromEnv != null && fromEnv.isNotEmpty) {
    if (releaseMode) {
      throw StateError('ORBITS_WORKLET_JS is disabled in release builds');
    }
    final file = File(fromEnv);
    if (!file.isAbsolute || !file.existsSync()) {
      throw StateError('ORBITS_WORKLET_JS must be an absolute local path');
    }
    return file;
  }
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final packagedCandidates = <String>[
    '$exeDir${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}tool${Platform.pathSeparator}connectivity_harness${Platform.pathSeparator}src${Platform.pathSeparator}worklet.js',
    '$exeDir${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}tool${Platform.pathSeparator}connectivity_harness${Platform.pathSeparator}src${Platform.pathSeparator}worklet.js',
    '$exeDir${Platform.pathSeparator}orbits-worklet${Platform.pathSeparator}worklet.js',
  ];
  for (final c in packagedCandidates) {
    final f = File(c);
    if (f.existsSync()) return f;
  }
  const relative = 'tool/connectivity_harness/src/worklet.js';
  if (File(relative).existsSync()) return File(relative);
  return null;
}

/// Copy the hashed in-app worklet tree to a writable dir. Never downloads JS.
Future<File?> extractBundledWorklet() async {
  try {
    final dir = await getApplicationSupportDirectory();
    final dest = Directory(
      '${dir.path}${Platform.pathSeparator}orbits_worklet',
    );
    await dest.create(recursive: true);
    for (final name in _bundledWorkletFiles) {
      final data = await rootBundle.load('tool/connectivity_harness/src/$name');
      await File(
        '${dest.path}${Platform.pathSeparator}$name',
      ).writeAsBytes(data.buffer.asUint8List());
    }
    final script = File('${dest.path}${Platform.pathSeparator}worklet.js');
    return script.existsSync() ? script : null;
  } catch (_) {
    return null;
  }
}

class WorkletOrbitsTransport implements OrbitsTransport {
  WorkletOrbitsTransport._(this._proc, {this.runtime = 'node'}) {
    _client = BareIpcClient(write: _writeSafe);
    _stdoutSub = _proc.stdout.listen(
      _client.addBytes,
      onDone: () => _client.failAll(StateError('worklet stdout closed')),
      onError: (Object err) => _client.failAll(err),
    );
    _stderrSub = _proc.stderr.listen((_) {});
    _sub = _client.events.listen(_onIpcEvent);
    unawaited(
      _proc.exitCode.then((code) {
        _client.failAll(StateError('worklet exited: $code'));
      }),
    );
  }

  final Process _proc;
  final String runtime;
  late final BareIpcClient _client;
  late final StreamSubscription<Map<String, Object?>> _sub;
  StreamSubscription<List<int>>? _stdoutSub;
  StreamSubscription<List<int>>? _stderrSub;
  final _events = StreamController<TransportEvent>.broadcast();
  Uint8List? lastNoisePublicKey;
  bool _stopped = false;

  void _writeSafe(List<int> bytes) {
    if (_stopped) {
      throw StateError('ipc closed');
    }
    _proc.stdin.add(bytes);
  }

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  Future<void> start(TransportLocalConfiguration config) async {
    final started = await _client.request('start', {
      'peerId': config.peerId,
      'discoverySecret': config.discoverySecret,
      'relayForced': config.relayForced,
      if (config.noiseSeed != null) 'noiseSeed': config.noiseSeed,
    });
    lastNoisePublicKey = parseNoisePublicKey(started['noisePublicKey']);
  }

  @override
  Future<void> stop() async {
    if (_stopped) return;
    try {
      await _client.request('stop', const {}, const Duration(seconds: 3));
    } catch (_) {}
    _stopped = true;
    try {
      try {
        _proc.kill(ProcessSignal.sigterm);
      } catch (_) {
        try {
          _proc.kill();
        } catch (_) {}
      }
      try {
        await _proc.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        try {
          _proc.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    } finally {
      await _stdoutSub?.cancel();
      await _stderrSub?.cancel();
      await _sub.cancel();
      await _client.close();
      if (!_events.isClosed) {
        await _events.close();
      }
    }
  }

  Future<void> confirmAuthorization(
    String peerId, {
    required bool authorized,
  }) {
    return _client.request(authorized ? 'authorize' : 'deny', {
      'peerId': peerId,
    });
  }

  @override
  Future<void> publish(DeviceBinding binding) async {
    await _client.request('publish', {
      'binding': {
        'deviceId': binding.deviceId,
        'capabilities': binding.capabilities,
        'identityPublicKeyB64': base64Encode(binding.identityPublicKey),
        'transportPublicKeyB64': base64Encode(binding.transportPublicKey),
        'hypercorePublicKeyB64': base64Encode(binding.hypercorePublicKey),
        'signatureB64': base64Encode(binding.signatureByIdentityKey),
        'createdAt': binding.createdAt,
        'expiresAt': binding.expiresAt,
        'ownerPeerId': binding.ownerPeerId,
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
  Future<void> send(String peerId, TransportChannel channel, List<int> frame) {
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
        if (file.transferId != null) 'transferId': file.transferId,
        'resumeOffset': file.resumeOffset,
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
    final payload =
        (event['payload'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    switch (name) {
      case 'identity-pending':
        final pending = deviceBindingFromWire(
          (payload['binding'] as Map?)?.cast<String, Object?>(),
        );
        if (pending != null) {
          _events.add(
            TransportIdentityPending(
              payload['peerId'] as String? ?? '',
              pending,
              connectionNoisePublicKey: parseNoisePublicKey(
                payload['connectionNoisePublicKey'],
              ),
            ),
          );
        }
      case 'authenticated':
        final binding = deviceBindingFromWire(
          (payload['binding'] as Map?)?.cast<String, Object?>(),
        );
        if (binding != null) {
          _events.add(
            TransportAuthenticated(
              payload['peerId'] as String? ?? '',
              binding,
              connectionNoisePublicKey: parseNoisePublicKey(
                payload['connectionNoisePublicKey'],
              ),
            ),
          );
        }
      case 'connected':
        _events.add(TransportConnected(payload['peerId'] as String? ?? ''));
      case 'disconnected':
        _events.add(TransportDisconnected(payload['peerId'] as String? ?? ''));
      case 'suspended':
        _events.add(const TransportSuspended());
      case 'resumed':
        _events.add(const TransportResumed());
      case 'networkChanged':
        _events.add(
          TransportNetworkChanged(payload['detail'] as String? ?? ''),
        );
      case 'pathChanged':
        _events.add(
          TransportPathChanged(
            payload['peerId'] as String? ?? '',
            payload['path'] == 'relay'
                ? TransportPath.relay
                : TransportPath.direct,
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
