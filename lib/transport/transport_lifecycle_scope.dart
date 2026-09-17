import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'native_transport_host.dart'
    if (dart.library.html) 'native_transport_host_stub.dart';

/// Binds app pause/resume to Bare suspend/resume + mailbox drain.
class TransportLifecycleScope extends ConsumerStatefulWidget {
  const TransportLifecycleScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TransportLifecycleScope> createState() =>
      _TransportLifecycleScopeState();
}

class _TransportLifecycleScopeState
    extends ConsumerState<TransportLifecycleScope> with WidgetsBindingObserver {
  static const _lifecycle = MethodChannel('app.orbits/lifecycle');
  static const _push = MethodChannel('app.orbits/push');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb) {
      _lifecycle.setMethodCallHandler(_onNativeLifecycle);
      _push.setMethodCallHandler(_onNativePush);
    }
  }

  @override
  void dispose() {
    if (!kIsWeb) {
      _lifecycle.setMethodCallHandler(null);
      _push.setMethodCallHandler(null);
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _onNativeLifecycle(MethodCall call) async {
    final host = ref.read(nativeTransportHostProvider);
    if (call.method == 'doze') {
      final args = call.arguments;
      final idle = args is Map && args['idle'] == true;
      if (idle) {
        await host.onDoze();
      } else {
        await host.onDozeExit();
      }
      return;
    }
    if (call.method == 'battery') {
      final args = call.arguments;
      final low = args is Map && args['low'] == true;
      if (low) {
        await host.onLowBattery();
      } else {
        await host.onBatteryOkay();
      }
    }
  }

  Future<void> _onNativePush(MethodCall call) async {
    final host = ref.read(nativeTransportHostProvider);
    if (call.method == 'token' && call.arguments is Map) {
      host.acceptPushToken(Map<String, Object?>.from(call.arguments as Map));
      return;
    }
    if (call.method != 'wake' || call.arguments is! Map) return;
    final payload = Map<String, Object?>.from(call.arguments as Map);
    await host.handleWake(payload);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final host = ref.read(nativeTransportHostProvider);
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        host.onBackground();
      case AppLifecycleState.resumed:
        host.onForeground();
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
