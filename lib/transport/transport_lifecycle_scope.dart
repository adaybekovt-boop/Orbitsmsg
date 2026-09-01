import 'package:flutter/material.dart';
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
