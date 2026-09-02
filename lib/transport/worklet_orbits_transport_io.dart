// Desktop Bare stand-in: spawn the shipped worklet over orbits-bare-ipc-v1.
// Never fetches remote JS.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException, rootBundle;
import 'package:orbits_transport/orbits_transport.dart';
import 'package:path_provider/path_provider.dart';

import '../replication/corestore_addon.dart';
import 'bare_ipc_client.dart';
import 'bare_runtime.dart';
import 'bare_stdlib.dart';
import 'device_binding.dart';
import 'transport_api.dart';
import 'transport_noise_seed.dart';

const _bundledWorkletFiles = <String>[
  'worklet.js',
  'mux.js',
  'discovery.js',
  'loopback.js',
  'ipc.js',
  'swarm.js',
  'stand.js',
  'corestore_journal.js',
  'autobase.js',
];

Future<WorkletOrbitsTransport?> spawnWorkletTransport({
  String backend = 'loopback',
}) async {
  final script = _resolveWorklet() ?? await extractBundledWorklet();
  if (script == null) return null;
  if (!await _nativeHostAllowsLocalWorklet(script)) return null;
  File? bundled;
  try {
    final pluginPath = await OrbitsTransportPlatform.instance.barePath();
    if (pluginPath != null && isLocalBarePath(pluginPath)) {
      bundled = File(pluginPath);
    }
  } catch (_) {}
  await ensureLocalBareStdlib(script, bundledBare: bundled);
  final launch = resolveBareRuntime(script, bundledBare: bundled);
  final started = await _spawnLaunch(
    launch,
    script,
    backend,
    bundledBare: bundled,
  );
  if (started != null) return started;
  if (launch.kind == 'bare') {
    return _spawnLaunch(
      BareRuntimeLaunch(
        executable: 'node',
        arguments: [script.path],
        kind: 'node',
      ),
      script,
      backend,
      bundledBare: bundled,
    );
  }
  return null;
}

/// Ask the federated plugin to refuse remote JS before a local spawn.
/// Missing registrars (unit tests) are skipped. A native REMOTE_JS
/// error fails closed and does not start Node/Bare.
Future<bool> _nativeHostAllowsLocalWorklet(File script) async {
  try {
    await OrbitsTransportPlatform.instance.start({
      'remoteJs': false,
      'worklet': script.path,
    });
    return true;
  } on UnimplementedError {
    return true;
  } on MissingPluginException {
    return true;
  } on PlatformException catch (e) {
    return e.code != 'REMOTE_JS';
  }
}

Future<WorkletOrbitsTransport?> _spawnLaunch(
  BareRuntimeLaunch launch,
  File script,
  String backend, {
  File? bundledBare,
}) async {
  try {
    final env = Map<String, String>.from(Platform.environment);
    env['ORBITS_HARNESS_BACKEND'] = backend;
    env['ORBITS_RUNTIME'] = launch.kind;
    final leakedAddon = env['ORBITS_CORESTORE_ADDON'];
    if (leakedAddon != null && !isLocalBarePath(leakedAddon)) {
      env.remove('ORBITS_CORESTORE_ADDON');
    }
    env.addAll(
      _corestoreAddonEnv(
        worklet: script,
        bundledBare: bundledBare,
        bareExecutable: launch.kind == 'bare' ? launch.executable : null,
      ),
    );
    final proc = await Process.start(
      launch.executable,
      launch.arguments,
      workingDirectory: script.parent.path,
      environment: env,
    );
    return WorkletOrbitsTransport._(proc, runtime: launch.kind);
  } catch (_) {
    return null;
  }
}

/// Optional Holepunch Corestore native addon (`.bare` / `.node`).
///
/// Order: `ORBITS_CORESTORE_ADDON`, then next to the worklet / bundled
/// Bare binary (app-bundle sidecar after CMake/Gradle/podspec copy),
/// then the repo slot `tool/bare/addons/corestore.bare`. Never a remote
/// URL.
Map<String, String> _corestoreAddonEnv({
  File? worklet,
  File? bundledBare,
  String? bareExecutable,
}) {
  final fromEnv = Platform.environment['ORBITS_CORESTORE_ADDON'];
  if (fromEnv != null && isLocalBarePath(fromEnv)) {
    return {'ORBITS_CORESTORE_ADDON': File(fromEnv).absolute.path};
  }
  final sep = Platform.pathSeparator;
  final candidates = <String>[];
  if (worklet != null) {
    final dir = worklet.parent.path;
    final parent = worklet.parent.parent.path;
    candidates.addAll([
      '$dir${sep}addons${sep}corestore.bare',
      '$parent${sep}addons${sep}corestore.bare',
      '$dir${sep}corestore.bare',
      '$parent${sep}corestore.bare',
    ]);
  }
  void addNextTo(String? p) {
    if (p == null || p.isEmpty) return;
    final dir = File(p).parent.path;
    candidates.add('$dir${sep}corestore.bare');
    candidates.add('$dir${sep}addons${sep}corestore.bare');
  }

  addNextTo(bundledBare?.path);
  addNextTo(bareExecutable);
  if (corestoreBareAddonPresent()) {
    candidates.add(File(kCorestoreBareAddonSlot).absolute.path);
  }
  for (final raw in candidates) {
    if (isLocalBarePath(raw)) {
      return {'ORBITS_CORESTORE_ADDON': File(raw).absolute.path};
    }
  }
  return const <String, String>{};
}

File? _resolveWorklet() {
  final fromEnv = Platform.environment['ORBITS_WORKLET_JS'];
  if (fromEnv != null && isLocalBarePath(fromEnv)) {
    return File(fromEnv);
  }
  const relative = 'tool/connectivity_harness/src/worklet.js';
  if (isLocalBarePath(relative)) return File(relative);
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
    try {
      final pkg = await rootBundle.load(
        'tool/connectivity_harness/package.json',
      );
      await File('${dest.path}${Platform.pathSeparator}package.json')
          .writeAsBytes(pkg.buffer.asUint8List());
    } catch (_) {}
    final script = File('${dest.path}${Platform.pathSeparator}worklet.js');
    if (!script.existsSync()) return null;
    await ensureLocalBareStdlib(script);
    return script;
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
    _proc.exitCode.then((code) {
      if (_stopping) return;
      if (!_events.isClosed) {
        _events.add(TransportError('worklet-exit', 'worklet exited $code'));
      }
    });
  }

  final Process _proc;
  final String runtime;
  late final BareIpcClient _client;
  late final StreamSubscription<Map<String, Object?>> _sub;
  final _events = StreamController<TransportEvent>.broadcast();
  bool _stopping = false;
  Uint8List? noisePublicKey;

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  Future<void> start(TransportLocalConfiguration config) async {
    final result = await _client.request('start', {
      'peerId': config.peerId,
      'discoverySecret': config.discoverySecret,
      'relayForced': config.relayForced,
      if (config.relayThrough.isNotEmpty) 'relayThrough': config.relayThrough,
      'bootstrap': [
        for (final node in config.bootstrap) node.toJson(),
      ],
      if (config.transportSeed != null) 'seed': config.transportSeed,
      if (config.journalDir != null &&
          isLocalFsLocation(config.journalDir!))
        'journalDir': config.journalDir,
    });
    noisePublicKey = noisePublicKeyFromHex(result['noisePublicKey'] as String?);
  }

  @override
  Future<void> stop() async {
    _stopping = true;
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
      'binding': binding.toWire(),
    });
  }

  @override
  Future<void> unpublish() => _client.request('unpublish');

  @override
  Future<void> connect(PeerDescriptor peer) async {
    final noise = peer.noisePublicKey ?? peer.binding?.transportPublicKey;
    await _client.request('connect', {
      'peerId': peer.peerId,
      if (peer.discoverySecret != null) 'discoverySecret': peer.discoverySecret,
      if (noise != null && noise.isNotEmpty) 'noisePublicKey': hexEncode(noise),
    });
  }

  @override
  Future<void> rememberPeer(PeerDescriptor peer) async {
    final noise = peer.noisePublicKey ?? peer.binding?.transportPublicKey;
    if (noise == null || noise.isEmpty) return;
    await _client.request('rememberPeer', {
      'peerId': peer.peerId,
      'noisePublicKey': hexEncode(noise),
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
        'resumeOffset': file.resumeOffset,
        'protocol': file.protocol,
        'fileId': file.fileId,
      },
    });
  }

  @override
  Future<void> suspend() => _client.request('suspend');

  @override
  Future<void> resume() => _client.request('resume');

  @override
  Future<void> refreshNetwork() => _client.request('refreshNetwork');

  @override
  Future<void> appendJournal(Map<String, Object?> record) {
    return _client.request('journal.append', record);
  }

  @override
  Future<List<Map<String, Object?>>> listJournal() async {
    final result = await _client.request('journal.list');
    final blocks = result['blocks'] as List? ?? const [];
    return [
      for (final block in blocks)
        if (block is Map) Map<String, Object?>.from(block),
    ];
  }

  @override
  Future<Map<String, Object?>> listAutobase() async {
    final result = await _client.request('autobase.state');
    return Map<String, Object?>.from(result);
  }

  void _onIpcEvent(Map<String, Object?> event) {
    final name = event['name'] as String? ?? '';
    final payload = (event['payload'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    switch (name) {
      case 'connected':
        _events.add(TransportConnected(payload['peerId'] as String? ?? ''));
      case 'authenticated':
        final peerId = payload['peerId'] as String? ?? '';
        final bindingJson = payload['binding'];
        if (peerId.isNotEmpty && bindingJson is Map) {
          try {
            _events.add(
              TransportAuthenticated(
                peerId,
                DeviceBinding.fromWire(
                  Map<String, Object?>.from(bindingJson),
                ),
              ),
            );
          } catch (_) {}
        }
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
        if (b64 != null && b64.isNotEmpty) {
          bytes = base64Decode(b64);
        } else {
          final body = payload['body'];
          if (body is Map) {
            bytes = utf8.encode(jsonEncode(body));
          }
        }
        _events.add(TransportFrame(peerId, channel, bytes));
      default:
        if (kDebugMode && name.isNotEmpty) {
          debugPrint('[worklet] $name');
        }
    }
  }
}
