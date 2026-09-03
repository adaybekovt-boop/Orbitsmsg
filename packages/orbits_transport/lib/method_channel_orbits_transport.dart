import 'dart:async';

import 'package:flutter/services.dart';
import 'package:orbits_transport_platform_interface/orbits_transport_platform_interface.dart';

/// Method-channel host. Platform packages spawn a local Bare/worklet
/// binary. This class refuses remote JS before the channel is invoked.
class MethodChannelOrbitsTransport extends OrbitsTransportPlatform {
  MethodChannelOrbitsTransport({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('app.orbits/transport') {
    _events = StreamController<Map<String, Object?>>.broadcast(
      onListen: _flushBufferedEvents,
    );
    _ensureIncoming();
  }

  final MethodChannel _channel;
  late final StreamController<Map<String, Object?>> _events;
  final List<Map<String, Object?>> _bufferedEvents = [];
  bool _incomingAttached = false;

  @override
  Stream<Map<String, Object?>> get events {
    _ensureIncoming();
    return _events.stream;
  }

  void _ensureIncoming() {
    if (_incomingAttached) return;
    try {
      _channel.setMethodCallHandler(_onIncoming);
      _incomingAttached = true;
    } catch (_) {
      // Defer attaching if BinaryMessenger is not yet initialized in test harness
    }
  }

  void _flushBufferedEvents() {
    while (_bufferedEvents.isNotEmpty) {
      if (_events.isClosed) break;
      _events.add(_bufferedEvents.removeAt(0));
    }
  }

  Future<dynamic> _onIncoming(MethodCall call) async {
    if (call.method == 'event') {
      final raw = call.arguments;
      if (raw is Map) {
        final map = Map<String, Object?>.from(raw);
        if (_events.isClosed) return;
        if (!_events.hasListener) {
          if (_bufferedEvents.length < 64) {
            _bufferedEvents.add(map);
          }
        } else {
          _events.add(map);
        }
      }
    }
  }

  @override
  Future<void> start(Map<String, Object?> config) async {
    assertNoRemoteBareJs(config);
    _ensureIncoming();
    await _channel.invokeMethod<dynamic>('start', config);
  }

  @override
  Future<void> stop() async {
    _bufferedEvents.clear();
    await _channel.invokeMethod<void>('stop');
  }

  @override
  Future<void> publish(Map<String, Object?> binding) =>
      _channel.invokeMethod<void>('publish', binding);

  @override
  Future<void> unpublish() => _channel.invokeMethod<void>('unpublish');

  @override
  Future<void> connect(Map<String, Object?> peer) =>
      _channel.invokeMethod<void>('connect', peer);

  @override
  Future<void> disconnect(String peerId) =>
      _channel.invokeMethod<void>('disconnect', peerId);

  @override
  Future<void> send(String peerId, String channel, List<int> frame) {
    assertIpcFrameSize(frame);
    return _channel.invokeMethod<void>('send', {
      'peerId': peerId,
      'channel': channel,
      'frame': Uint8List.fromList(frame),
    });
  }

  @override
  Future<void> sendFile(String peerId, String path, int sizeBytes) {
    if (path.isEmpty) {
      throw StateError('sendFile requires a path');
    }
    if (sizeBytes > 50 * 1024 * 1024) {
      throw StateError('attachment exceeds path-transfer cap');
    }
    return _channel.invokeMethod<void>('sendFile', {
      'peerId': peerId,
      'path': path,
      'sizeBytes': sizeBytes,
    });
  }

  @override
  Future<void> suspend() => _channel.invokeMethod<void>('suspend');

  @override
  Future<void> resume() => _channel.invokeMethod<void>('resume');

  @override
  Future<void> refreshNetwork() =>
      _channel.invokeMethod<void>('refreshNetwork');

  @override
  Future<Map<String, Object?>> runtimeInfo() async {
    final raw = await _channel.invokeMethod<dynamic>('runtimeInfo');
    if (raw is Map) {
      return Map<String, Object?>.from(raw);
    }
    return const <String, Object?>{};
  }
}
