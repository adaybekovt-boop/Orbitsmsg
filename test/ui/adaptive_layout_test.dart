// Locks in the desktop/mobile layout decision (the bugfix): width-driven, and
// a wide Web window must count as desktop. Mirrors `_isDesktopHost` in
// app_shell.dart which uses the identical rule.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/ui/primitives/adaptive_page_frame.dart';

Future<bool> _resolve(WidgetTester tester, double width) async {
  late bool result;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: Size(width, 800)),
      child: Builder(
        builder: (context) {
          result = isDesktopLayout(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return result;
}

void main() {
  testWidgets('desktop platform: narrow (<900) → mobile', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      expect(await _resolve(tester, 390), isFalse);
      expect(await _resolve(tester, 820), isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('desktop platform: wide (>=900) → desktop', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      expect(await _resolve(tester, 900), isTrue);
      expect(await _resolve(tester, 1440), isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('mobile platform: wide Android stays mobile', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      expect(await _resolve(tester, 1440), isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
