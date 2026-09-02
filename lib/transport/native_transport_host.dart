// Starts the native carrier and binds it into ConnectionsNotifier.
// Default product path stays PeerJS until rollout != off.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/feature_flags.dart';
import '../devices/device_registry.dart';
import '../mailbox/blind_store.dart';
import '../mailbox/storage_peer_client.dart';
import '../mailbox/storage_peer_http.dart';
import '../push/push_gateway.dart';
import '../push/push_registration.dart';
import '../push/push_send.dart';
import '../push/wake_service.dart';
import '../replication/memory_journal.dart';
import '../state/auth_notifier.dart';
import '../state/connections_notifier.dart';
import 'device_binding.dart';
import 'dht_bootstrap.dart';
import 'discovery_secret_store.dart';
import 'hello_capabilities.dart';
import 'journal_file_io.dart' if (dart.library.html) 'journal_file_stub.dart';
import 'loopback_transport.dart';
import 'native_rollback.dart';
import 'relay_directory.dart';
import 'relay_directory_load.dart';
import 'signed_capabilities.dart';
import 'transport_api.dart';
import 'transport_lifecycle.dart';
import 'transport_noise_seed.dart';
import 'worklet_backend.dart';
import 'worklet_orbits_transport.dart';

class NativeTransportHost {
  NativeTransportHost(this._ref);

  final Ref _ref;
  OrbitsTransport? transport;
  String backend = 'none';
  bool attached = false;
  TransportLifecycle? lifecycle;
  OpaqueWakeService? wake;
  PushGateway? push;
  StoragePeerHttp? storageHttp;
  RelayDirectory? directory;
  final PushRegistration pushRegistration = PushRegistration();

  Future<void> ensureStarted() async {
    if (attached) return;
    directory = await loadRelayDirectoryFromEnv();
    if (!isHyperswarmTransportEnabled()) return;
    final auth = _ref.read(authNotifierProvider);
    if (auth is! AuthAuthed) return;

    await discoverySecretStore.hydrate();
    await deviceRegistry.hydrate();
    await transportNoiseSeedStore.hydrate();

    if (directory != null && directory!.relayBlownUp) {
      rollbackNativeToPeerjs(
        reason: NativeRollbackReason.relayBlowUp,
        detail: 'relay directory unsound or RTT blown up',
      );
      return;
    }
    final bootstrap = resolveDhtBootstrap(
      env: Platform.environment,
      directory: directory,
    );

    await _openCarrier(hasBootstrap: bootstrap.isNotEmpty);
    _watchCarrier();

    final journal = await openLocalFileJournal('local-device');
    final journalDir = await localWorkletJournalDir();
    final secret = discoverySecretStore.getOrCreateLocal();
    final seed = transportNoiseSeedStore.getOrCreate();
    try {
      await transport!.start(
        TransportLocalConfiguration(
          peerId: auth.user.peerId,
          discoverySecret: secret,
          bootstrap: bootstrap,
          transportSeed: seed,
          relayForced: isHyperswarmRelayForced(),
          relayThrough: relayThroughKeysFromDirectory(directory),
          diagnosticsEnabled: isHyperswarmDiagnosticsEnabled(),
          allowPeerjsFallback: isPeerjsFallbackEnabled(),
          journalDir: journalDir,
        ),
      );
    } catch (_) {
      if (backend == 'hyperswarm') {
        rollbackNativeToPeerjs(
          reason: NativeRollbackReason.nativeConnectFailed,
          detail: 'hyperswarm start failed',
        );
        await _abandonNativeCarrier();
        return;
      } else {
        rethrow;
      }
    }

    CapabilityRecord? caps;
    try {
      caps = await issueLocalCapabilityRecord(
        peerId: auth.user.peerId,
        deviceId: 'local-device',
        capabilities: advertisedLocalCapabilities(),
        issuedAt: DateTime.now().millisecondsSinceEpoch,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 86400000 * 30,
      );
    } catch (_) {}

    final workletPk = switch (transport) {
      final WorkletOrbitsTransport w => w.noisePublicKey,
      _ => null,
    };
    final transportPublicKey =
        workletPk ?? derivedTransportPublicPlaceholder(seed);
    final hypercorePublicKey = derivedHypercorePublicPlaceholder(seed);
    transportNoiseSeedStore.rememberPublished(transportPublicKey);
    DeviceBinding? issuedBinding;
    try {
      final capNames = advertisedLocalCapabilityWireNames();
      final now = DateTime.now().millisecondsSinceEpoch;
      DeviceBinding binding;
      try {
        binding = await issueLocalDeviceBinding(
          deviceId: 'local-device',
          transportPublicKey: transportPublicKey,
          hypercorePublicKey: hypercorePublicKey,
          capabilities: capNames,
          createdAt: now,
          expiresAt: now + 86400000 * 30,
        );
      } catch (_) {
        binding = DeviceBinding(
          version: kDeviceBindingVersion,
          identityPublicKey: caps?.identityPublicKey ?? Uint8List(0),
          deviceId: 'local-device',
          transportPublicKey: transportPublicKey,
          hypercorePublicKey: hypercorePublicKey,
          capabilities: capNames,
          createdAt: now,
          expiresAt: now + 86400000 * 30,
          signatureByIdentityKey: Uint8List(0),
        );
      }
      issuedBinding = binding;
      await transport!.publish(binding);
    } catch (_) {}

    final cap = MailboxCapability(
      token: 'local-mailbox',
      quotaBytes: 64 * 1024 * 1024,
      retentionMs: 30 * 24 * 3600 * 1000,
      expiresAt: DateTime.now().millisecondsSinceEpoch + 86400000 * 30,
    );
    final mailbox = BlindMailboxStore()..grant(cap);
    final storagePeer = await _bindStoragePeer(mailbox, cap, directory);

    // Replay keeps FileJournal writer seq / writerDeviceId. Do not
    // ingest() those rows — that restamps them as fresh local appends.
    final memory =
        await journal?.replay() ?? MemoryJournal('local-device');
    try {
      ingestWorkletRows(memory, await transport!.listJournal());
    } catch (_) {}

    _ref.read(connectionsNotifierProvider.notifier).bindNativeTransport(
          transport!,
          journal: memory,
          deviceId: 'local-device',
          durableJournal: journal,
          mailbox: mailbox,
          storagePeer: storagePeer,
          mailboxToken: 'local-mailbox',
          mailboxWriterKey: auth.user.peerId,
          localCapabilities: caps,
          localBinding: issuedBinding,
          devices: deviceRegistry,
        );
    await _ref
        .read(connectionsNotifierProvider.notifier)
        .restoreReadModelFromJournal();
    lifecycle = TransportLifecycle(
      transport: transport!,
      onResumeDrain: () async {
        final n = await _ref
                .read(connectionsNotifierProvider.notifier)
                .nativeBridge
                ?.drainMailbox() ??
            0;
        await _ref
            .read(connectionsNotifierProvider.notifier)
            .nativeBridge
            ?.verifyLiveMatchesReplay();
        return n;
      },
    );
    wake = OpaqueWakeService(onAccepted: (_) => lifecycle!.onOpaqueWake());
    push = PushGateway(wake!);
    _ref.read(connectionsNotifierProvider.notifier).nativeBridge?.onMailboxWake =
        (w) async {
      await wake?.handle(w.toJson());
      await const PushSender().sendApns(deviceToken: 'undeployed', wake: w);
      await const PushSender().sendFcm(deviceToken: 'undeployed', wake: w);
    };
    attached = true;
  }

  Future<void> _openCarrier({required bool hasBootstrap}) async {
    final preferred = preferredWorkletBackend(hasBootstrap: hasBootstrap);
    var worklet = await spawnWorkletTransport(backend: preferred);
    if (worklet != null) {
      transport = worklet;
      backend = preferred == 'hyperswarm' ? 'hyperswarm' : 'worklet';
      return;
    }
    if (preferred == 'hyperswarm') {
      worklet = await spawnWorkletTransport(backend: 'loopback');
      if (worklet != null) {
        transport = worklet;
        backend = 'worklet';
        return;
      }
    }
    transport = LoopbackOrbitsTransport();
    backend = 'loopback';
  }

  StreamSubscription<TransportEvent>? _carrierEvents;

  void _watchCarrier() {
    _carrierEvents?.cancel();
    final carrier = transport;
    if (carrier == null) return;
    _carrierEvents = carrier.events.listen((event) {
      if (event is TransportError && event.code == 'worklet-exit') {
        rollbackNativeToPeerjs(
          reason: NativeRollbackReason.bareWorkletCrash,
          detail: event.message,
        );
        unawaited(_abandonNativeCarrier());
      }
      if (event is TransportError && event.code == 'relay-blow-up') {
        rollbackNativeToPeerjs(
          reason: NativeRollbackReason.relayBlowUp,
          detail: event.message,
        );
        unawaited(_abandonNativeCarrier());
      }
    });
  }

  Future<void> _abandonNativeCarrier() async {
    attached = false;
    await _carrierEvents?.cancel();
    _carrierEvents = null;
    lifecycle = null;
    wake = null;
    push = null;
    try {
      await _ref.read(connectionsNotifierProvider.notifier).unbindNativeTransport();
    } catch (_) {}
    try {
      await transport?.stop();
    } catch (_) {}
    transport = null;
    backend = 'none';
    try {
      await storageHttp?.stop();
    } catch (_) {}
    storageHttp = null;
  }

  /// Local HTTP mailbox when possible; env origin for a desktop peer.
  /// Not a public fleet.
  Future<StoragePeerClient> _bindStoragePeer(
    BlindMailboxStore mailbox,
    MailboxCapability cap,
    RelayDirectory? directory,
  ) async {
    final origin = resolveStoragePeerOrigin(
      env: Platform.environment,
      directory: directory,
    );
    if (origin != null && origin.isNotEmpty) {
      try {
        final client = httpStoragePeerClient(origin);
        await client.grant(cap);
        return client;
      } catch (_) {}
    }
    try {
      final http = StoragePeerHttp(mailbox);
      await http.start();
      storageHttp = http;
      return httpStoragePeerClient(http.origin);
    } catch (_) {
      return StoragePeerClient.local(mailbox);
    }
  }

  Future<void> onBackground() async {
    await lifecycle?.onBackground();
  }

  Future<void> onForeground() async {
    await lifecycle?.onForeground();
  }

  Future<void> onDoze() async {
    await lifecycle?.onDoze();
  }

  Future<void> onDozeExit() async {
    await lifecycle?.onDozeExit();
  }

  Future<void> onLowBattery() async {
    await lifecycle?.onLowBattery();
    rollbackNativeToPeerjs(
      reason: NativeRollbackReason.battery,
      detail: 'low battery',
    );
    await _abandonNativeCarrier();
  }

  /// Battery recovered. Do not re-enable native; PeerJS stays the live path.
  Future<void> onBatteryOkay() async {
    await lifecycle?.onBatteryOkay();
  }

  Future<WakeOutcome> handleWake(Map<String, Object?> payload) async {
    final gateway = push;
    if (gateway == null) {
      return const WakeOutcome(accepted: false, reason: 'not-started');
    }
    return gateway.ingestApns(payload);
  }

  Future<WakeOutcome> handleFcmWake(Map<String, Object?> payload) async {
    final gateway = push;
    if (gateway == null) {
      return const WakeOutcome(accepted: false, reason: 'not-started');
    }
    return gateway.ingestFcm(payload);
  }

  /// Device tokens stay on-device. Never journal / Hypercore / mailbox.
  void acceptPushToken(Map<String, Object?> payload) {
    pushRegistration.acceptToken(payload);
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
