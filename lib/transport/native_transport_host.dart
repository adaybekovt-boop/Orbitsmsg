// Starts the native carrier and binds it into ConnectionsNotifier.
// Default product path stays PeerJS until rollout != off.
// The development-only Bare path never installs LocalWorkletPlatform on
// Android/iOS and never falls back to PeerJS.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:orbits_transport/orbits_transport.dart';

import '../core/feature_flags.dart';
import '../core/identity_key.dart';
import '../devices/device_registry.dart';
import '../devices/local_device_material.dart';
import '../mailbox/blind_store.dart';
import '../peer/signaling.dart';
import '../push/opaque_wake.dart';
import '../push/wake_service.dart';
import '../replication/memory_journal.dart';
import '../state/auth_notifier.dart';
import '../state/connections_notifier.dart';
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
  }) : spawnWorklet = spawnWorklet ?? spawnWorkletTransport;

  final Ref _ref;
  final WorkletSpawner spawnWorklet;
  final bool contactForbidsFallback;
  OrbitsTransport? transport;
  String backend = 'none';
  String lastError = '';
  NativeBackendDecision? lastDecision;
  bool attached = false;
  TransportLifecycle? lifecycle;
  OpaqueWakeService? wake;

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

  Completer<void>? _startCompleter;

  Future<void> ensureStarted() async {
    if (attached) return;
    if (_startCompleter != null) {
      return _startCompleter!.future;
    }
    final completer = Completer<void>();
    _startCompleter = completer;
    try {
      await _doEnsureStarted();
      completer.complete();
    } catch (err, st) {
      completer.completeError(err, st);
      rethrow;
    } finally {
      _startCompleter = null;
    }
  }

  Future<void> _doEnsureStarted() async {
    final devBare = isDevBareTransportRequested();
    if (!isHyperswarmTransportEnabled() && !devBare) {
      lastDecision = selectNativeBackend(
        rollout: hyperswarmRollout(),
        peerjsFallbackEnabled: isPeerjsFallbackEnabled(),
        contactForbidsFallback: contactForbidsFallback,
        probe: const NativeBackendProbe(hyperswarmModuleAvailable: false),
      );
      backend = 'none';
      return;
    }
    if (attached) return;
    final auth = _ref.read(authNotifierProvider);
    if (auth is! AuthAuthed) return;

    await discoverySecretStore.hydrate();
    await deviceRegistry.hydrate();
    await trustedIdentityStore.hydrate();

    _ensurePluginBoundary();
    final chosen = await _chooseTransport(devBare: devBare);
    if (chosen == null) {
      if (devBare) {
        lastError = 'BARE_RUNTIME_MISSING';
        throw StateError('BARE_RUNTIME_MISSING');
      }
      return;
    }

    transport = chosen;

    final material = await loadOrCreateLocalDeviceMaterial();
    await authorizeLocalDevice(material, ownerPeerId: auth.user.peerId);
    trustedIdentityStore.trust(
      peerId: auth.user.peerId,
      identityPublicKey: await exportIdentityPubSpki(),
      isSelf: true,
    );
    final journal = await openLocalFileJournal(material.deviceId);
    final secret = discoverySecretStore.getOrCreateLocal();
    try {
      await transport!.start(
        TransportLocalConfiguration(
          peerId: auth.user.peerId,
          discoverySecret: secret,
          noiseSeed: material.transportSecretSeed,
        ),
      );
    } catch (err) {
      lastError = err.toString();
      transport = null;
      if (devBare) {
        rethrow;
      }
      return;
    }

    var boundMaterial = material;
    final noise = _localNoisePublicKey(transport);
    if (noise != null) {
      boundMaterial = await rememberTransportPublicKey(
        material: material,
        transportPublicKey: noise,
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
    await transport!.publish(binding);

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
          journal: MemoryJournal(boundMaterial.deviceId),
          deviceId: boundMaterial.deviceId,
          durableJournal: journal,
          mailbox: mailbox,
          mailboxToken: 'local-mailbox',
          mailboxWriterKey: auth.user.peerId,
          localCapabilities: caps,
          devices: deviceRegistry,
          identities: trustedIdentityStore,
        );
    lifecycle = TransportLifecycle(
      transport: transport!,
      onResumeDrain: () async {
        return await _ref
                .read(connectionsNotifierProvider.notifier)
                .nativeBridge
                ?.drainMailbox() ??
            0;
      },
    );
    wake = OpaqueWakeService(onAccepted: (_) => lifecycle!.onOpaqueWake());
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

    final decision = selectNativeBackend(
      rollout: hyperswarmRollout(),
      peerjsFallbackEnabled: isPeerjsFallbackEnabled(),
      contactForbidsFallback: contactForbidsFallback,
      probe: NativeBackendProbe(
        hyperswarmModuleAvailable: moduleAvailable,
        hyperswarmStarted: started,
      ),
    );
    lastDecision = decision;

    if (decision.backend == NativeBackendKind.none ||
        decision.backend == NativeBackendKind.peerjs) {
      backend = decision.backend.name;
      return null;
    }

    backend = decision.backend.name;
    return PluginOrbitsTransport(backend: backend);
  }

  Future<void> recoverAfterCrash() async {
    attached = false;
    try {
      await transport?.stop();
    } catch (_) {}
    transport = null;
    lifecycle = null;
    await ensureStarted();
  }

  Future<void> shutdown() async {
    await lifecycle?.onBackground();
    try {
      await transport?.stop();
    } catch (_) {}
    transport = null;
    lifecycle = null;
    attached = false;
    backend = 'none';
  }

  Future<void> onBackground() async {
    await lifecycle?.onBackground();
  }

  Future<void> onForeground() async {
    await lifecycle?.onForeground();
  }

  List<int>? _localNoisePublicKey(OrbitsTransport? carrier) {
    if (carrier is PluginOrbitsTransport) return carrier.lastNoisePublicKey;
    if (carrier is WorkletOrbitsTransport) return carrier.lastNoisePublicKey;
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
    if (next is AuthAuthed) {
      host.ensureStarted();
    }
  }, fireImmediately: true);
  return host;
});
