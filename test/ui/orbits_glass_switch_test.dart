// Behaviour of the custom Liquid-Glass toggle: tap flips, disabled is inert,
// renders without overflow. (Look is verified visually, not here.)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/ui/primitives/orbits_glass_switch.dart';

import '../helpers/test_theme.dart';

Widget _host(Widget child, {Brightness brightness = Brightness.dark}) =>
    MaterialApp(
      theme: testOrbitsTheme(brightness: brightness),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('tap toggles the value', (tester) async {
    bool? changed;
    await tester.pumpWidget(_host(
      OrbitsGlassSwitch(value: false, onChanged: (v) => changed = v),
    ));
    await tester.tap(find.byType(OrbitsGlassSwitch));
    await tester.pump();
    expect(changed, isTrue);
  });

  testWidgets('on-state tap toggles back off', (tester) async {
    bool? changed;
    await tester.pumpWidget(_host(
      OrbitsGlassSwitch(value: true, onChanged: (v) => changed = v),
    ));
    await tester.tap(find.byType(OrbitsGlassSwitch));
    await tester.pump();
    expect(changed, isFalse);
  });

  testWidgets('disabled switch does not fire onChanged', (tester) async {
    var fired = false;
    await tester.pumpWidget(_host(
      OrbitsGlassSwitch(
        value: false,
        enabled: false,
        onChanged: (_) => fired = true,
      ),
    ));
    await tester.tap(find.byType(OrbitsGlassSwitch), warnIfMissed: false);
    await tester.pump();
    expect(fired, isFalse);
  });

  testWidgets('null onChanged is inert', (tester) async {
    await tester.pumpWidget(
        _host(const OrbitsGlassSwitch(value: true, onChanged: null)));
    await tester.tap(find.byType(OrbitsGlassSwitch), warnIfMissed: false);
    await tester.pump();
    // No throw / no crash is the assertion.
    expect(find.byType(OrbitsGlassSwitch), findsOneWidget);
  });

  testWidgets('renders both sizes and both brightnesses without overflow',
      (tester) async {
    for (final b in Brightness.values) {
      for (final s in OrbitsGlassSwitchSize.values) {
        await tester.pumpWidget(_host(
          OrbitsGlassSwitch(value: true, size: s, onChanged: (_) {}),
          brightness: b,
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    }
  });
}
