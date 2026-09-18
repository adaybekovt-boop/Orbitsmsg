// Shared platform <-> TransportEvent codec. Missing
// connectionNoisePublicKey stays null — never copied from the binding
// transport key. Identity signing is not the Noise key.

import 'dart:convert';

import 'device_binding.dart';
import 'transport_api.dart';

TransportPath pathFromWire(String? raw) {
  return switch (raw) {
    'direct' => TransportPath.direct,
    'relay' => TransportPath.relay,
    _ => TransportPath.unknown,
  };
}

List<int> frameBytesFromWire(Map<String, Object?> event) {
  final raw = (event['bytes'] as List?)?.whereType<int>().toList();
  if (raw != null && raw.isNotEmpty) return raw;
  final b64 = event['frameB64'] as String?;
  if (b64 != null && b64.isNotEmpty) {
    return base64Decode(b64);
  }
  return const <int>[];
}

TransportChannel? channelFromWire(String? name) {
  if (name == null || name.isEmpty) return null;
  for (final channel in TransportChannel.values) {
    if (channel.name == name) return channel;
  }
  return null;
}

/// Decode a flattened platform / IPC map. Does not invent a Noise key
/// from [DeviceBinding.transportPublicKey].
TransportEvent? platformMapToTransportEvent(Map<String, Object?> event) {
  final name = event['name'] as String? ?? '';
  final peerId = event['peerId'] as String? ?? '';
  switch (name) {
    case 'connecting':
      return TransportConnecting(peerId);
    case 'connected':
      return TransportConnected(peerId);
    case 'identity-pending':
      final pending = deviceBindingFromWire(
        (event['binding'] as Map?)?.cast<String, Object?>(),
      );
      if (pending == null) return null;
      return TransportIdentityPending(
        peerId,
        pending,
        connectionNoisePublicKey: parseNoisePublicKey(
          event['connectionNoisePublicKey'],
        ),
      );
    case 'authenticated':
      final binding = deviceBindingFromWire(
        (event['binding'] as Map?)?.cast<String, Object?>(),
      );
      if (binding == null) return null;
      return TransportAuthenticated(
        peerId,
        binding,
        connectionNoisePublicKey: parseNoisePublicKey(
          event['connectionNoisePublicKey'],
        ),
      );
    case 'pathChanged':
      return TransportPathChanged(peerId, pathFromWire(event['path'] as String?));
    case 'networkChanged':
      return TransportNetworkChanged(event['detail'] as String? ?? '');
    case 'disconnected':
      return TransportDisconnected(peerId);
    case 'suspended':
      return const TransportSuspended();
    case 'resumed':
      return const TransportResumed();
    case 'frame':
      final channel = channelFromWire(event['channel'] as String?);
      if (channel == null) return null;
      return TransportFrame(peerId, channel, frameBytesFromWire(event));
    case 'deliveryState':
      return TransportDeliveryState(peerId, event['state'] as String? ?? '');
    case 'error':
      return TransportError(
        event['code'] as String? ?? 'transport',
        event['message'] as String? ?? '',
      );
    default:
      return null;
  }
}

Map<String, Object?> transportEventToPlatformMap(TransportEvent event) {
  switch (event) {
    case TransportConnecting(:final peerId):
      return <String, Object?>{'name': 'connecting', 'peerId': peerId};
    case TransportConnected(:final peerId):
      return <String, Object?>{'name': 'connected', 'peerId': peerId};
    case TransportIdentityPending(
      :final peerId,
      :final binding,
      :final connectionNoisePublicKey,
    ):
      return <String, Object?>{
        'name': 'identity-pending',
        'peerId': peerId,
        if (connectionNoisePublicKey != null)
          'connectionNoisePublicKey': connectionNoisePublicKey,
        'binding': deviceBindingToWire(binding),
      };
    case TransportAuthenticated(
      :final peerId,
      :final binding,
      :final connectionNoisePublicKey,
    ):
      return <String, Object?>{
        'name': 'authenticated',
        'peerId': peerId,
        if (connectionNoisePublicKey != null)
          'connectionNoisePublicKey': connectionNoisePublicKey,
        'binding': deviceBindingToWire(binding),
      };
    case TransportFrame(:final peerId, :final channel, :final bytes):
      return <String, Object?>{
        'name': 'frame',
        'peerId': peerId,
        'channel': channel.name,
        'bytes': bytes,
      };
    case TransportDeliveryState(:final peerId, :final state):
      return <String, Object?>{
        'name': 'deliveryState',
        'peerId': peerId,
        'state': state,
      };
    case TransportPathChanged(:final peerId, :final path):
      return <String, Object?>{
        'name': 'pathChanged',
        'peerId': peerId,
        'path': path.name,
      };
    case TransportNetworkChanged(:final detail):
      return <String, Object?>{'name': 'networkChanged', 'detail': detail};
    case TransportSuspended():
      return const <String, Object?>{'name': 'suspended'};
    case TransportResumed():
      return const <String, Object?>{'name': 'resumed'};
    case TransportDisconnected(:final peerId):
      return <String, Object?>{'name': 'disconnected', 'peerId': peerId};
    case TransportError(:final code, :final message):
      return <String, Object?>{
        'name': 'error',
        'code': code,
        'message': message,
      };
  }
}
