// Public transport surface. Phase 3 implements this on Bare; Phase 0
// only locks the shape. See docs/migration/transport-api.md.

import 'device_binding.dart';

/// Logical multiplex. Matches the master-plan channel list.
enum TransportChannel {
  control,
  message,
  receipt,
  presence,
  replication,
  attachment,
  call,
  diagnostics,
}

enum TransportPath { direct, relay, unknown }

class TransportFileDescriptor {
  const TransportFileDescriptor({
    required this.path,
    required this.sizeBytes,
    this.mime,
    this.fileName,
    this.resumeOffset = 0,
  });

  /// Local filesystem path or platform handle. Not a byte array over IPC.
  final String path;
  final int sizeBytes;
  final String? mime;
  final String? fileName;

  /// Byte offset already acked. Worklet / loopback skip those bytes.
  final int resumeOffset;

  TransportFileDescriptor copyWith({int? resumeOffset}) =>
      TransportFileDescriptor(
        path: path,
        sizeBytes: sizeBytes,
        mime: mime,
        fileName: fileName,
        resumeOffset: resumeOffset ?? this.resumeOffset,
      );
}

class PeerDescriptor {
  const PeerDescriptor({
    required this.peerId,
    this.binding,
    this.discoverySecret,
    this.noisePublicKey,
  });

  final String peerId;
  final DeviceBinding? binding;

  /// Shared contact-discovery secret. Never the public Peer ID.
  final List<int>? discoverySecret;

  /// Hyperswarm Noise public key. Not the identity key. Used for
  /// `joinPeer` when the worklet is on Hyperswarm.
  final List<int>? noisePublicKey;
}

/// HyperDHT bootstrap address. Empty lists mean "do not start Hyperswarm"
/// — never the public DHT default.
class DhtBootstrapNode {
  const DhtBootstrapNode({required this.host, required this.port});

  final String host;
  final int port;

  Map<String, Object?> toJson() => <String, Object?>{
        'host': host,
        'port': port,
      };

  @override
  bool operator ==(Object other) =>
      other is DhtBootstrapNode && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

class TransportLocalConfiguration {
  const TransportLocalConfiguration({
    required this.peerId,
    this.discoverySecret,
    this.allowPeerjsFallback = true,
    this.relayForced = false,
    this.diagnosticsEnabled = false,
    this.bootstrap = const [],
    this.relayThrough = const [],
    this.transportSeed,
    this.journalDir,
  });

  final String peerId;

  /// Shared contact-discovery secret used to join a topic on [publish].
  /// Never the public Peer ID.
  final List<int>? discoverySecret;
  final bool allowPeerjsFallback;
  final bool relayForced;
  final bool diagnosticsEnabled;

  /// Explicit HyperDHT bootstrap. Required for the Hyperswarm backend.
  final List<DhtBootstrapNode> bootstrap;

  /// HyperDHT node public keys (hex) for Hyperswarm `relayThrough`.
  /// Empty means the swarm may still go direct. Not identity keys.
  final List<String> relayThrough;

  /// 32-byte Hyperswarm Noise seed. Not the identity key, KEK, or
  /// discovery secret.
  final List<int>? transportSeed;

  /// Local directory for the worklet ciphertext journal (Corestore or
  /// JSONL). Never a remote URL. Empty means the worklet may use memory.
  final String? journalDir;
}

sealed class TransportEvent {
  const TransportEvent();
}

class TransportConnected extends TransportEvent {
  const TransportConnected(this.peerId);
  final String peerId;
}

class TransportAuthenticated extends TransportEvent {
  const TransportAuthenticated(this.peerId, this.binding);
  final String peerId;
  final DeviceBinding binding;
}

class TransportFrame extends TransportEvent {
  const TransportFrame(this.peerId, this.channel, this.bytes);
  final String peerId;
  final TransportChannel channel;
  final List<int> bytes;
}

class TransportDeliveryState extends TransportEvent {
  const TransportDeliveryState(this.peerId, this.state);
  final String peerId;
  final String state;
}

class TransportPathChanged extends TransportEvent {
  const TransportPathChanged(this.peerId, this.path);
  final String peerId;
  final TransportPath path;
}

class TransportNetworkChanged extends TransportEvent {
  const TransportNetworkChanged(this.detail);
  final String detail;
}

class TransportSuspended extends TransportEvent {
  const TransportSuspended();
}

class TransportResumed extends TransportEvent {
  const TransportResumed();
}

class TransportDisconnected extends TransportEvent {
  const TransportDisconnected(this.peerId);
  final String peerId;
}

class TransportError extends TransportEvent {
  const TransportError(this.code, this.message);
  final String code;
  final String message;
}

/// Carrier only. Does not encrypt chat or write Drift.
abstract class OrbitsTransport {
  Stream<TransportEvent> get events;

  Future<void> start(TransportLocalConfiguration config);
  Future<void> stop();

  Future<void> publish(DeviceBinding binding);
  Future<void> unpublish();

  Future<void> connect(PeerDescriptor peer);
  Future<void> disconnect(String peerId);

  Future<void> send(String peerId, TransportChannel channel, List<int> frame);
  Future<void> sendFile(String peerId, TransportFileDescriptor file);

  Future<void> suspend();
  Future<void> resume();
  Future<void> refreshNetwork();
}
