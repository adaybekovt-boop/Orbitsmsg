import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Layout breakpoints aligned with the React design, adapted to Flutter
/// (logical pixels, not CSS px).
class OrbitsBreakpoints {
  const OrbitsBreakpoints._();

  /// Phone: list and conversation are separate screens.
  static const double phone = 760;

  /// Wide workspace: nav + list + conversation.
  static const double wide = 900;

  /// Extra-wide: contact panel sits beside the conversation.
  static const double contactPanel = 1180;

  /// Desktop workspace max width (React 1640).
  static const double workspaceMax = 1640;
}

bool isPhoneLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width < OrbitsBreakpoints.phone;

bool isWideLayout(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width < OrbitsBreakpoints.wide) return false;
  if (kIsWeb) return true;
  return switch (defaultTargetPlatform) {
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => true,
    _ => width >= OrbitsBreakpoints.wide,
  };
}

bool showContactPanel(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= OrbitsBreakpoints.contactPanel;
