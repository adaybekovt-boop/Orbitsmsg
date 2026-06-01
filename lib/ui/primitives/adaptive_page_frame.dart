import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AdaptivePageFrame extends StatelessWidget {
  const AdaptivePageFrame({
    super.key,
    required this.child,
    this.maxWidth = 760,
    this.desktopPadding = const EdgeInsets.symmetric(horizontal: 24),
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry desktopPadding;

  @override
  Widget build(BuildContext context) {
    if (!isDesktopLayout(context)) return child;

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: desktopPadding,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      ),
    );
  }
}

bool isDesktopLayout(BuildContext context) {
  // Desktop layout is decided by viewport width, NOT by platform — a wide Web
  // window must get the constrained desktop treatment too.
  final width = MediaQuery.sizeOf(context).width;
  if (width < 900) return false;
  if (kIsWeb) return true;
  return switch (defaultTargetPlatform) {
    TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux =>
      true,
    _ => false,
  };
}
