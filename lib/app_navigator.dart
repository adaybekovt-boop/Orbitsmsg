import 'package:flutter/material.dart';

/// Root [Navigator] for [MaterialApp]. Lock / logout pop back to the first
/// route so UnlockPage is not covered by a pushed chat or profile (X1).
final GlobalKey<NavigatorState> orbitsRootNavigatorKey =
    GlobalKey<NavigatorState>();

/// Dismiss every route above [AuthGate] so a locked vault cannot sit
/// underneath an open chat.
void popRoutesAboveAuthGate() {
  final nav = orbitsRootNavigatorKey.currentState;
  if (nav == null || !nav.mounted) return;
  nav.popUntil((route) => route.isFirst);
}
