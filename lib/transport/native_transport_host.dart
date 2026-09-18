// Starts the native carrier and binds it into ConnectionsNotifier.
// Default product path stays PeerJS until rollout != off.
// The development-only Bare path never installs LocalWorkletPlatform on
// Android/iOS and never falls back to PeerJS.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:orbits_transport/orbits_transport.dart';

import '../core/feature_flags.dart';
import '../core/identity_key.dart';
import '../core/wire_crypto.dart';
import '../devices/device_ratchet_sessions.dart';
import '../devices/device_registry.dart';
import '../devices/local_device_material.dart';
import '../mailbox/blind_store.dart';
import '../peer/room_manager.dart';
import '../peer/signaling.dart';
import '../push/doze_adapter.dart';
import '../push/opaque_wake.dart';
import '../push/opaque_wake_channel.dart';
import '../push/wake_service.dart';
import '../replication/drift_projector.dart';
import '../storage/db.dart' as db;
import '../replication/hypercore_store.dart';
import '../replication/memory_journal.dart';
import '../state/auth_notifier.dart';
import '../state/connections_notifier.dart';
import '../state/messaging_notifier.dart';
import '../state/peer_connection_provider.dart';
import 'capabilities.dart';
import 'dev_bare_transport.dart';
import 'device_binding.dart';
import 'discovery_secret_store.dart';
import 'trusted_identity_store.dart';
import 'journal_file_io.dart' if (dart.library.html) 'journal_file_stub.dart';
import 'local_worklet_platform.dart';
import 'native_backend_policy.dart';
import 'plugin_orbits_transport.dart';
import 'signed_capabilities.dart';
import 'transport_api.dart';
import 'transport_lifecycle.dart';
import 'worklet_orbits_transport.dart';

typedef WorkletSpawner =
    Future<WorkletOrbitsTransport?> Function({String backend});

class NativeTransportHost {
  NativeTransportHost(
    this._ref, {
    WorkletSpawner? spawnWorklet,
    this.contactForbidsFallback = false,
    this.transportOverride,
    this.authStateOverride,
  }) : spawnWorklet = spawnWorklet ?? spawnWorkletTransport;

  final Ref _ref;
  final WorkletSpawner spawnWorklet;
  final bool contactForbidsFallback;
  final OrbitsTransport Function()? transportOverride;
  final AuthState Function()? authStateOverride;
  OrbitsTransport? transport;
  String backend = 'none';
  String lastError = '';
  String lastProjectorError = '';
  NativeBackendDecision? lastDecision;
  bool attached = false;
  TransportLifecycle? lifecycle;
  OpaqueWakeService? wake;
  DozeAdapter? doze;
  DeviceRatchetSessions? ratchets;
  OpaqueWakeChannel? _wakeChannel;

  Map<String, Object?> get routeDiagnostics =>
      lastDecision?.diagnostics() ??
      <String, Object?>{
        'backend': backend,
        'reason': attached ? 'attached' : 'idle',
        'rollout': hyperswarmRollout().name,
        'devBare': isDevBareTransportRequested(),
        if (lastError.isNotEmpty) 'error': lastError,
      };

  String get visibleTransportLabel => orbitsVisibleTransportLabel(
    devBareRequested: isDevBareTransportRequested(),
    attached: attached,
    backend: backend,
    lastError: lastError,
    peerjsLocalTestnet: isAppPeerjsLocalTestnet(),
  );

  Future<void>? _inFlightStart;
  int _sessionGeneration = 0;
  String? _sessionPeerId;
  bool _startCancelled = false;

  String? get sessionPeerId => _sessionPeerId;
  JournalProjector? projector;
  HypercoreLocalStore? hypercore;
  StreamSubscription<TransportEvent>? _staleGuard;

  bool _startupAborted(int generation) =>
      _startCancelled || generation != _sessionGeneration;

  Future<void> onAuthChanged(AuthState next) async {
    if (next is AuthAuthed) {
      if (_sessionPeerId != null && _sessionPeerId != next.user.peerId) {
        await shutdown();
      }
      try {
        await ensureStarted();
      } catch (_) {
        if (_startCancelled) return;
        rethrow;
      }
      return;
    }
    await shutdown();
  }

  Future<void> ensureStarted() async {
    if (attached && _sessionPeerId != null && !_startCancelled) return;
    final existing = _inFlightStart;
    if (existing != null) return existing;
    _startCancelled = false;
    final generation = ++_sessionGeneration;
    final run = () async {
      try {
        await _doEnsureStarted(generation);
      } catch (err) {
        if (_startupAborted(generation)) return;
        rethrow;
      }
    }();
    _inFlightStart = run;
    try {
      await run;
    } finally {
      if (identical(_inFlightStart, run)) {
        _inFlightStart = null;
      }
    }
  }

  Future<void> _doEnsureStarted(int generation) async {
    final devBare = isDevBareTransportRequested();
    if (!devBare && hyperswarmRollout() == HyperswarmRollout.off) {
      lastDecision = selectNativeBackend(
        rollout: hyperswarmRollout(),
        peerjsFallbackEnabled: isPeerjsFallbackEnabled(),
        contactForbidsFallback: contactForbidsFallback,
        probe: const NativeBackendProbe(hyperswarmModuleAvailable: false),
        allowDevBare: false,
      );
      backend = 'none';
      lastError = '';
      return;
    }
    if (attached) return;
    final auth = authStateOverride?.call() ?? _ref.read(authNotifierProvider);
    if (auth is! AuthAuthed) return;
    _sessionPeerId = auth.user.peerId;
    if (_startupAborted(generation)) return;

    await discoverySecretStore.hydrate();
    await deviceRegistry.hydrate();
    await trustedIdentityStore.hydrate();
    if (_startupAborted(generation)) return;

    _ensurePluginBoundary();
    final chosen = await _chooseTransport(devBare: devBare);
    if (await _abortStartup(generation, chosen)) return;
    if (chosen == null) {
      if (devBare) {
        lastError = lastError.isEmpty ? 'BARE_RUNTIME_MISSING' : lastError;
        throw StateError(lastError);
      }
      return;
    }

    transport = chosen;
    if (await _abortStartup(generation, chosen)) return;

    final material = await loadOrCreateLocalDeviceMaterial();
    await authorizeLocalDevice(material, ownerPeerId: auth.user.peerId);
    trustedIdentityStore.trust(
      peerId: auth.user.peerId,
      identityPublicKey: await exportIdentityPubSpki(),
      isSelf: true,
    );
    final durable = await openLocalFileJournal(
      material.deviceId,
      ownerPeerId: auth.user.peerId,
    );
    MemoryJournal memory;
    if (durable != null) {
      memory = await durable.replay();
    } else {
      memory = MemoryJournal(material.deviceId);
    }
    hypercore = HypercoreLocalStore(material.deviceId);
    for (final record in memory.records) {
      hypercore!.append(record);
    }
    ratchets = DeviceRatchetSessions(localDeviceId: material.deviceId);
    await ratchets!.hydrate();
    if (_startupAborted(generation)) return;
    projector = JournalProjector(
      decrypt: _decryptJournalEnvelope,
      isBlocked: (peerId) =>
          _ref.read(messagingNotifierProvider.notifier).isPeerBlocked(peerId),
      persist: (msg) async {
        try {
          await persistProjectedMessage(
            msg,
            selfPeerId: _sessionPeerId ?? '',
            save: db.saveMessage,
          );
          lastProjectorError = '';
        } catch (err) {
          lastProjectorError = err.toString();
        }
      },
      tombstone: (id) async {
        try {
          await db.deleteMessageRow(id);
          lastProjectorError = '';
        } catch (err) {
          lastProjectorError = err.toString();
        }
      },
    );
    await projector!.applyAll(memory);
    final secret = discoverySecretStore.getOrCreateLocal();
    if (await _abortStartup(generation, chosen)) return;
    try {
      await transport!.start(
        TransportLocalConfiguration(
          peerId: auth.user.peerId,
          discoverySecret: secret,
          noiseSeed: material.transportSecretSeed,
        ),
      );
    } catch (err) {
      lastError = 'BARE_START_FAILED';
      transport = null;
      if (devBare) {
        throw StateError('BARE_START_FAILED: $err');
      }
      return;
    }
    if (await _abortStartup(generation, chosen)) return;

    var boundMaterial = material;
    final noise = _localNoisePublicKey(transport);
    if (noise != null) {
      boundMaterial = await rememberTransportPublicKey(
        material: boundMaterial,
        transportPublicKey: noise,
      );
    }
    final writer = _localHypercorePublicKey(transport);
    if (writer != null) {
      boundMaterial = await rememberHypercorePublicKey(
        material: boundMaterial,
        hypercorePublicKey: writer,
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final caps = await issueLocalCapabilityRecord(
      peerId: auth.user.peerId,
      deviceId: material.deviceId,
      capabilities: {
        TransportCapability.hyperswarmV1,
        TransportCapability.peerjsV4,
        TransportCapability.mailboxV1,
        TransportCapability.hypercoreV1,
        TransportCapability.multiDeviceV1,
      },
      issuedAt: now,
      expiresAt: now + 86400000 * 30,
    );
    final binding = await issueLocalDeviceBinding(
      material: boundMaterial,
      capabilities: caps.capabilities.map((c) => c.wireName).toList()..sort(),
      createdAt: now,
      expiresAt: now + 86400000 * 30,
      ownerPeerId: auth.user.peerId,
    );
    if (!deviceBindingClockIsValid(binding, nowMs: now)) {
      throw StateError('local device binding is not valid');
    }
    try {
      await transport!.publish(binding);
    } catch (err) {
      lastError = 'BARE_PROTOCOL_FAILED';
      transport = null;
      if (devBare) {
        throw StateError('BARE_PROTOCOL_FAILED: $err');
      }
      return;
    }
    if (await _abortStartup(generation, chosen)) return;

    final mailbox = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'local-mailbox',
          quotaBytes: 64 * 1024 * 1024,
          retentionMs: 30 * 24 * 3600 * 1000,
          expiresAt: now + 86400000 * 30,
        ),
      );

    _ref
        .read(connectionsNotifierProvider.notifier)
        .bindNativeTransport(
          transport!,
          journal: memory,
          deviceId: boundMaterial.deviceId,
          durableJournal: durable,
          mailbox: mailbox,
          mailboxToken: 'local-mailbox',
          mailboxWriterKey: auth.user.peerId,
          localCapabilities: caps,
          devices: deviceRegistry,
          identities: trustedIdentityStore,
          hypercore: hypercore,
          ratchets: ratchets,
          confirmPeerAuthorization: (peerId, {required authorized}) async {
            final carrier = transport;
            if (carrier == null) {
              throw StateError('transport unavailable during authorization');
            }
            await carrier.authorizePeer(peerId, authorized: authorized);
          },
          onRemoteRecord: (record) async {
            await projector?.apply(record);
          },
          signRecord: signBytes,
        );
    _ref.read(roomManagerProvider.notifier).bindAutobaseSnapshot();
    lifecycle = TransportLifecycle(
      transport: transport!,
      onResumeDrain: () async {
        final bridge = _ref
            .read(connectionsNotifierProvider.notifier)
            .nativeBridge;
        if (bridge == null) return 0;
        try {
          return await bridge.drainKnownMailboxes(
            discoverySecretStore.knownPeerIds,
          );
        } catch (err) {
          bridge.lastReplicationError = err.toString();
          return 0;
        }
      },
    );
    doze = DozeAdapter(lifecycle: lifecycle!);
    wake = OpaqueWakeService(onAccepted: (_) => doze!.onOpaqueWake());
    _wakeChannel?.detach();
    _wakeChannel = OpaqueWakeChannel(onWake: (payload) => wake!.handle(payload))
      ..attach();
    if (_startupAborted(generation)) {
      await _teardownAttached(chosen: chosen, unbind: true);
      return;
    }
    attached = true;
    lastError = '';
  }

  void _ensurePluginBoundary() {
    if (isMobileBareHost()) return;
    final current = OrbitsTransportPlatform.instance;
    if (current is InProcessOrbitsTransportPlatform) return;
    if (current is LocalWorkletPlatform) return;
    if (kReleaseMode) return;
    OrbitsTransportPlatform.instance = LocalWorkletPlatform(
      spawnWorklet: spawnWorklet,
      allowNodeFallback: true,
    );
  }

  Future<OrbitsTransport?> _chooseTransport({required bool devBare}) async {
    final override = transportOverride;
    if (override != null) {
      lastDecision = const NativeBackendDecision(
        backend: NativeBackendKind.loopback,
        attempted: <NativeBackendKind>[NativeBackendKind.loopback],
      );
      backend = 'loopback';
      return override();
    }
    if (isMobileBareHost()) {
      lastDecision = const NativeBackendDecision(
        backend: NativeBackendKind.hyperswarm,
        attempted: <NativeBackendKind>[NativeBackendKind.hyperswarm],
      );
      backend = 'hyperswarm';
      return PluginOrbitsTransport(backend: 'hyperswarm');
    }

    final inProcess =
        OrbitsTransportPlatform.instance is InProcessOrbitsTransportPlatform;
    var moduleAvailable = inProcess;
    var started = inProcess;
    if (!inProcess) {
      try {
        final probe = await spawnWorklet(backend: 'hyperswarm');
        moduleAvailable = probe != null;
        started = probe != null;
        await probe?.stop();
      } catch (_) {
        moduleAvailable = false;
        started = false;
      }
    }

    if (devBare && !kReleaseMode) {
      if (!moduleAvailable) {
        lastError = 'BARE_RUNTIME_MISSING';
        lastDecision = const NativeBackendDecision(
          backend: NativeBackendKind.none,
          failure: NativeBackendFailure.moduleUnavailable,
          attempted: <NativeBackendKind>[NativeBackendKind.hyperswarm],
        );
        backend = 'none';
        return null;
      }
      lastDecision = const NativeBackendDecision(
        backend: NativeBackendKind.hyperswarm,
        attempted: <NativeBackendKind>[NativeBackendKind.hyperswarm],
      );
      backend = 'hyperswarm';
      return PluginOrbitsTransport(backend: 'hyperswarm');
    }

    final decision = selectNativeBackend(
      rollout: hyperswarmRollout(),
      peerjsFallbackEnabled: isPeerjsFallbackEnabled(),
      contactForbidsFallback: contactForbidsFallback,
      allowDevBare: devBare && !kReleaseMode,
      probe: NativeBackendProbe(
        hyperswarmModuleAvailable: moduleAvailable,
        hyperswarmStarted: started,
      ),
    );
    lastDecision = decision;

    if (decision.backend == NativeBackendKind.none ||
        decision.backend == NativeBackendKind.peerjs) {
      backend = decision.backend.name;
      if (decision.failure == NativeBackendFailure.rolloutOff) {
        lastError = 'BARE_DISABLED_BY_POLICY';
      } else if (decision.failure == NativeBackendFailure.moduleUnavailable) {
        lastError = 'BARE_RUNTIME_MISSING';
      } else if (decision.failure == NativeBackendFailure.startupFailed) {
        lastError = 'BARE_START_FAILED';
      }
      return null;
    }

    backend = decision.backend.name;
    return PluginOrbitsTransport(backend: backend);
  }

  Future<void> recoverAfterCrash() async {
    await _teardownAttached(unbind: false, clearSession: false);
    await ensureStarted();
  }

  Future<void> shutdown() async {
    _startCancelled = true;
    _sessionGeneration++;
    final running = _inFlightStart;
    if (running != null) {
      try {
        await running.timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
    await lifecycle?.onBackground();
    await _teardownAttached(
      unbind: true,
      cancelStaleGuard: true,
      clearSession: true,
    );
    trustedIdentityStore.clear();
  }

  Future<void> onBackground() async {
    final adapter = doze;
    if (adapter != null) {
      await adapter.enterBackground();
      return;
    }
    await lifecycle?.onBackground();
  }

  Future<void> onForeground() async {
    final adapter = doze;
    if (adapter != null) {
      await adapter.onForeground();
      return;
    }
    await lifecycle?.onForeground();
  }

  Future<void> _teardownAttached({
    OrbitsTransport? chosen,
    bool unbind = false,
    bool cancelStaleGuard = false,
    bool clearSession = false,
  }) async {
    if (unbind) {
      try {
        await _ref
            .read(connectionsNotifierProvider.notifier)
            .unbindNativeTransport();
      } catch (_) {}
    }
    final running = chosen ?? transport;
    try {
      await running?.stop();
    } catch (_) {}
    if (cancelStaleGuard) {
      await _staleGuard?.cancel();
      _staleGuard = null;
    }
    if (chosen == null || identical(transport, chosen)) {
      transport = null;
    }
    _wakeChannel?.detach();
    _wakeChannel = null;
    lifecycle = null;
    wake = null;
    doze = null;
    ratchets = null;
    projector = null;
    hypercore = null;
    attached = false;
    if (clearSession) {
      backend = 'none';
      _sessionPeerId = null;
      lastError = '';
    }
  }

  Future<bool> _abortStartup(int generation, OrbitsTransport? chosen) async {
    if (!_startupAborted(generation)) return false;
    try {
      await chosen?.stop();
    } catch (_) {}
    if (chosen != null && identical(transport, chosen)) {
      transport = null;
    }
    return true;
  }

  Future<Map<String, Object?>?> _decryptJournalEnvelope(
    List<int> enc,
    JournalRecord record,
  ) async {
    if (enc.isEmpty) return null;
    final sender = record.fields['senderIdentity'] as String? ?? '';
    if (sender.isEmpty) return null;
    final String wire;
    try {
      wire = utf8.decode(enc);
    } catch (err) {
      lastProjectorError = err.toString();
      return null;
    }
    if (record.fields['envelopeCipher'] == kDeviceRatchetMessageType) {
      final sessions = ratchets;
      if (sessions == null) return null;
      final fromDevice = record.fields['fromDeviceId'] as String? ??
          record.fields['senderDeviceId'] as String? ??
          '';
      final toDevice = record.fields['toDeviceId'] as String? ??
          sessions.localDeviceId;
      if (fromDevice.isEmpty || toDevice != sessions.localDeviceId) {
        return null;
      }
      try {
        final bytes = await sessions.decryptFrom(
          localDeviceId: toDevice,
          remoteDeviceId: fromDevice,
          wire: wire,
          commit: false,
        );
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map) {
          return <String, Object?>{
            'text': '${decoded['text'] ?? ''}',
            if (decoded['id'] != null) 'id': decoded['id'],
          };
        }
        if (decoded is String) return <String, Object?>{'text': decoded};
      } catch (err) {
        lastProjectorError = err.toString();
      }
      return null;
    }
    if (!isWireCiphertext(wire)) return null;
    try {
      final plain = await decryptWirePayload(sender, wire, commit: false);
      if (plain is Map) {
        return <String, Object?>{
          'text': '${plain['text'] ?? ''}',
          if (plain['id'] != null) 'id': plain['id'],
        };
      }
      if (plain is String) return <String, Object?>{'text': plain};
    } catch (err) {
      lastProjectorError = err.toString();
    }
    return null;
  }

  List<int>? _localNoisePublicKey(OrbitsTransport? carrier) {
    if (carrier is PluginOrbitsTransport) return carrier.lastNoisePublicKey;
    if (carrier is WorkletOrbitsTransport) return carrier.lastNoisePublicKey;
    return null;
  }

  List<int>? _localHypercorePublicKey(OrbitsTransport? carrier) {
    if (carrier is PluginOrbitsTransport) {
      return carrier.lastHypercorePublicKey;
    }
    if (carrier is WorkletOrbitsTransport) {
      return carrier.lastHypercorePublicKey;
    }
    return null;
  }

  Future<WakeOutcome> handleWake(Map<String, Object?> payload) async {
    final service = wake;
    if (service == null) {
      return const WakeOutcome(accepted: false, reason: 'not-started');
    }
    if (!OpaqueWake.isSafe(payload)) {
      return const WakeOutcome(accepted: false, reason: 'unsafe-keys');
    }
    return service.handle(payload);
  }
}

/// Honest user-visible backend. A dev flag alone must never look "active".
String orbitsVisibleTransportLabel({
  required bool devBareRequested,
  required bool attached,
  required String backend,
  required String lastError,
  bool peerjsLocalTestnet = false,
}) {
  if (devBareRequested) {
    if (attached && backend == 'hyperswarm') {
      return 'Bare/Hyperswarm (dev)';
    }
    if (lastError.isNotEmpty) {
      return 'Bare/Hyperswarm (dev) failed';
    }
    return 'Bare/Hyperswarm (dev) not running';
  }
  if (attached && backend == 'hyperswarm') return 'Bare/Hyperswarm';
  if (lastError.isNotEmpty && backend != 'peerjs' && backend != 'none') {
    return 'unavailable/error';
  }
  if (backend == 'peerjs' || backend == 'none') {
    return peerjsLocalTestnet ? kPeerjsLocalTestnetLabel : 'PeerJS';
  }
  return backend;
}

final nativeTransportHostProvider = Provider<NativeTransportHost>((ref) {
  final host = NativeTransportHost(ref);
  ref.listen<AuthState>(authNotifierProvider, (prev, next) {
    unawaited(host.onAuthChanged(next));
  }, fireImmediately: true);
  ref.onDispose(() {
    unawaited(host.shutdown());
  });
  return host;
});
