// User-visible route diagnostics. Does not switch the live PeerJS client
// while HyperswarmRollout is off.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/feature_flags.dart';
import '../transport/capabilities.dart';
import '../transport/dual_stack.dart';

final transportRouteProvider =
    Provider.family<DualStackDecision, ({bool remoteIsPwa, bool remoteHasHyperswarm})>(
  (ref, args) {
    final remote = <TransportCapability>{
      TransportCapability.peerjsV4,
      if (args.remoteHasHyperswarm) TransportCapability.hyperswarmV1,
      if (args.remoteIsPwa) TransportCapability.webPwaV1,
    };
    return decideDualStack(
      local: defaultNativeCapabilities(),
      remote: remote,
      localIsPwa: false,
      remoteIsPwa: args.remoteIsPwa,
    );
  },
);

String describeTransportRoute(DualStackDecision decision) {
  final flag = hyperswarmRollout().name;
  return 'route=${decision.route.name} rollout=$flag fallback=${decision.fallbackAllowed}';
}
