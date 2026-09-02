// Starts the native carrier and binds it into ConnectionsNotifier.
// Default product path stays PeerJS until rollout != off.

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/feature_flags.dart';
import '../devices/device_registry.dart';
import '../mailbox/blind_store.dart';
import '../push/opaque_wake.dart';
import '../push/wake_service.dart';
import '../replication/memory_journal.dart';
import '../state/auth_notifier.dart';
import '../state/connections_notifier.dart';
import 'capabilities.dart';
import 'device_binding.dart';
import 'discovery_secret_store.dart';
import 'journal_file_io.dart' if (dart.library.html) 'journal_file_stub.dart';
import 'loopback_transport.dart';
import 'native_backend_policy.dart';
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
      };

  Future<void> ensureStarted() async {
    if (!isHyperswarmTransportEnabled()) {
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

    final chosen = await _chooseTransport();
    if (chosen == null) return;

    transport = chosen;

    final journal = await openLocalFileJournal('local-device');
    final secret = discoverySecretStore.getOrCreateLocal();
    await transport!.start(
      TransportLocalConfiguration(
        peerId: auth.user.peerId,
        discoverySecret: secret,
      ),
    );

    CapabilityRecord? caps;
    try {
      caps = await issueLocalCapabilityRecord(
        peerId: auth.user.peerId,
        deviceId: 'local-device',
        capabilities: {
          TransportCapability.hyperswarmV1,
          TransportCapability.peerjsV4,
          TransportCapability.mailboxV1,
          TransportCapability.hypercoreV1,
          TransportCapability.multiDeviceV1,
        },
        issuedAt: DateTime.now().millisecondsSinceEpoch,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 86400000 * 30,
      );
    } catch (_) {}

    try {
      await transport!.publish(
        DeviceBinding(
          version: kDeviceBindingVersion,
          identityPublicKey: caps?.identityPublicKey ?? Uint8List(0),
          deviceId: 'local-device',
          transportPublicKey: Uint8List.fromList(List<int>.filled(32, 1)),
          hypercorePublicKey: Uint8List.fromList(List<int>.filled(32, 2)),
          capabilities: const ['hyperswarm-v1', 'peerjs-v4'],
          createdAt: DateTime.now().millisecondsSinceEpoch,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 86400000 * 30,
          signatureByIdentityKey: caps?.signature ?? Uint8List(0),
        ),
      );
    } catch (_) {}

    final mailbox = BlindMailboxStore()
      ..grant(
        MailboxCapability(
          token: 'local-mailbox',
          quotaBytes: 64 * 1024 * 1024,
          retentionMs: 30 * 24 * 3600 * 1000,
          expiresAt: DateTime.now().millisecondsSinceEpoch + 86400000 * 30,
        ),
      );

    _ref
        .read(connectionsNotifierProvider.notifier)
        .bindNativeTransport(
          transport!,
          journal: MemoryJournal('local-device'),
          deviceId: 'local-device',
          durableJournal: journal,
          mailbox: mailbox,
          mailboxToken: 'local-mailbox',
          mailboxWriterKey: auth.user.peerId,
          localCapabilities: caps,
          devices: deviceRegistry,
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
  }

  Future<OrbitsTransport?> _chooseTransport() async {
    WorkletOrbitsTransport? hyperswarm;
    var moduleAvailable = false;
    var started = false;
    try {
      hyperswarm = await spawnWorklet(backend: 'hyperswarm');
      moduleAvailable = hyperswarm != null;
      started = hyperswarm != null;
    } catch (_) {
      moduleAvailable = false;
      started = false;
    }

    var decision = selectNativeBackend(
      rollout: hyperswarmRollout(),
      peerjsFallbackEnabled: isPeerjsFallbackEnabled(),
      contactForbidsFallback: contactForbidsFallback,
      probe: NativeBackendProbe(
        hyperswarmModuleAvailable: moduleAvailable,
        hyperswarmStarted: started,
      ),
    );

    if (decision.backend == NativeBackendKind.hyperswarm &&
        hyperswarm != null) {
      lastDecision = decision;
      backend = 'hyperswarm';
      return hyperswarm;
    }

    if (decision.failure == NativeBackendFailure.fallbackForbidden) {
      lastDecision = decision;
      backend = 'none';
      return null;
    }

    if (decision.backend == NativeBackendKind.peerjs) {
      lastDecision = decision;
      backend = 'peerjs';
      return null;
    }

    try {
      final loopback = await spawnWorklet(backend: 'loopback');
      lastDecision = decision;
      backend = loopback != null ? 'worklet' : 'loopback';
      return loopback ?? LoopbackOrbitsTransport();
    } catch (_) {
      lastDecision = selectNativeBackend(
        rollout: hyperswarmRollout(),
        peerjsFallbackEnabled: isPeerjsFallbackEnabled(),
        contactForbidsFallback: contactForbidsFallback,
        probe: const NativeBackendProbe(
          hyperswarmModuleAvailable: true,
          hyperswarmStarted: false,
        ),
      );
      if (contactForbidsFallback) {
        backend = 'none';
        return null;
      }
      backend = 'loopback';
      return LoopbackOrbitsTransport();
    }
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

final nativeTransportHostProvider = Provider<NativeTransportHost>((ref) {
  final host = NativeTransportHost(ref);
  ref.listen<AuthState>(authNotifierProvider, (prev, next) {
    if (next is AuthAuthed) {
      host.ensureStarted();
    }
  }, fireImmediately: true);
  return host;
});
