// Starts the native carrier and binds it into ConnectionsNotifier.
// Default product path stays PeerJS until rollout != off.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/feature_flags.dart';
import '../devices/device_registry.dart';
import '../mailbox/blind_store.dart';
import '../mailbox/storage_peer_client.dart';
import '../mailbox/storage_peer_http.dart';
import '../push/push_gateway.dart';
import '../push/wake_service.dart';
import '../replication/memory_journal.dart';
import '../state/auth_notifier.dart';
import '../state/connections_notifier.dart';
import 'capabilities.dart';
import 'device_binding.dart';
import 'discovery_secret_store.dart';
import 'journal_file_io.dart' if (dart.library.html) 'journal_file_stub.dart';
import 'loopback_transport.dart';
import 'native_rollback.dart';
import 'signed_capabilities.dart';
import 'transport_api.dart';
import 'transport_lifecycle.dart';
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

  Future<void> ensureStarted() async {
    if (!isHyperswarmTransportEnabled()) return;
    if (attached) return;
    final auth = _ref.read(authNotifierProvider);
    if (auth is! AuthAuthed) return;

    await discoverySecretStore.hydrate();
    await deviceRegistry.hydrate();

    await _openCarrier();

    final journal = await openLocalFileJournal('local-device');
    final secret = discoverySecretStore.getOrCreateLocal();
    try {
      await transport!.start(
        TransportLocalConfiguration(
          peerId: auth.user.peerId,
          discoverySecret: secret,
        ),
      );
    } catch (_) {
      if (backend == 'hyperswarm') {
        rollbackNativeToPeerjs(
          reason: NativeRollbackReason.nativeConnectFailed,
          detail: 'hyperswarm start failed',
        );
        await _respawnLoopback();
        await transport!.start(
          TransportLocalConfiguration(
            peerId: auth.user.peerId,
            discoverySecret: secret,
          ),
        );
      } else {
        rethrow;
      }
    }

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

    final cap = MailboxCapability(
      token: 'local-mailbox',
      quotaBytes: 64 * 1024 * 1024,
      retentionMs: 30 * 24 * 3600 * 1000,
      expiresAt: DateTime.now().millisecondsSinceEpoch + 86400000 * 30,
    );
    final mailbox = BlindMailboxStore()..grant(cap);
    final storagePeer = await _bindStoragePeer(mailbox, cap);

    _ref.read(connectionsNotifierProvider.notifier).bindNativeTransport(
          transport!,
          journal: MemoryJournal('local-device'),
          deviceId: 'local-device',
          durableJournal: journal,
          mailbox: mailbox,
          storagePeer: storagePeer,
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
    push = PushGateway(wake!);
    attached = true;
  }

  Future<void> _openCarrier() async {
    final preferred = preferredWorkletBackend();
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

  Future<void> _respawnLoopback() async {
    try {
      await transport?.stop();
    } catch (_) {}
    final worklet = await spawnWorkletTransport(backend: 'loopback');
    transport = worklet ?? LoopbackOrbitsTransport();
    backend = worklet != null ? 'worklet' : 'loopback';
  }

  /// Local HTTP mailbox when possible; env origin for a desktop peer.
  /// Not a public fleet.
  Future<StoragePeerClient> _bindStoragePeer(
    BlindMailboxStore mailbox,
    MailboxCapability cap,
  ) async {
    final origin = Platform.environment['ORBITS_STORAGE_PEER_ORIGIN'];
    if (origin != null && origin.isNotEmpty) {
      final client = httpStoragePeerClient(origin);
      await client.grant(cap);
      return client;
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
