// Auto-lock behavior — AutoLockScope locks on foreground idle and on
// return-from-background, only when enabled. Uses the onLock/clock test seams
// so the full auth stack isn't needed; the autoLockProvider is driven by mocked
// SharedPreferences with a short idle timeout.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:orbits_flutter/state/auto_lock_provider.dart';
import 'package:orbits_flutter/ui/auth/auto_lock_scope.dart';

void main() {
  const short = Duration(milliseconds: 200);

  Future<int> pumpScope(
    WidgetTester tester, {
    required bool enabled,
    DateTime Function()? clock,
    required void Function(int) onLockCount,
  }) async {
    SharedPreferences.setMockInitialValues(
      enabled ? {'orbits_auto_lock': '1'} : <String, Object>{},
    );
    var lockCalls = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          autoLockProvider.overrideWith(
            (ref) => AutoLockNotifier(idleTimeout: short),
          ),
        ],
        child: MaterialApp(
          home: AutoLockScope(
            clock: clock,
            onLock: () async {
              lockCalls++;
              onLockCount(lockCalls);
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    // Let AutoLockNotifier._load() resolve so `enabled` reflects prefs and the
    // scope's ref.listen arms (or leaves disarmed) the idle timer.
    await tester.pump();
    await tester.pump();
    return lockCalls;
  }

  testWidgets('enabled → locks after the idle timeout', (tester) async {
    var calls = 0;
    await pumpScope(tester, enabled: true, onLockCount: (n) => calls = n);
    await tester.pump(const Duration(milliseconds: 250));
    expect(calls, 1);
  });

  testWidgets('disabled → never locks', (tester) async {
    var calls = 0;
    await pumpScope(tester, enabled: false, onLockCount: (n) => calls = n);
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 0);
  });

  testWidgets('activity resets the idle timer', (tester) async {
    var calls = 0;
    await pumpScope(tester, enabled: true, onLockCount: (n) => calls = n);
    await tester.pump(const Duration(milliseconds: 150)); // not yet
    expect(calls, 0);
    // Pointer activity → reset. The translucent Listener (not the SizedBox) is
    // the hit target, so warnIfMissed would false-positive.
    await tester.tap(find.byType(SizedBox), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 150)); // 150 < 200 since reset
    expect(calls, 0);
    await tester.pump(const Duration(milliseconds: 100)); // now past 200
    expect(calls, 1);
  });

  testWidgets('keyboard activity also resets the idle timer (X1)', (tester) async {
    var calls = 0;
    await pumpScope(tester, enabled: true, onLockCount: (n) => calls = n);
    await tester.pump(const Duration(milliseconds: 150));
    expect(calls, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 150));
    expect(calls, 0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(calls, 1);
  });

  testWidgets('locks on resume after being backgrounded longer than timeout',
      (tester) async {
    var now = DateTime(2026, 1, 1, 12, 0, 0);
    var calls = 0;
    await pumpScope(
      tester,
      enabled: true,
      clock: () => now,
      onLockCount: (n) => calls = n,
    );
    // Background, then return 6 minutes later (> 5 min default in real use; here
    // the idle Timer is short but the background path uses the injected clock).
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = DateTime(2026, 1, 1, 12, 6, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(calls, 1);
  });

  testWidgets('short background does NOT lock on resume', (tester) async {
    var now = DateTime(2026, 1, 1, 12, 0, 0);
    var calls = 0;
    await pumpScope(
      tester,
      enabled: true,
      clock: () => now,
      onLockCount: (n) => calls = n,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(milliseconds: 50)); // well under the timeout
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(calls, 0);
    // Clean up the re-armed idle timer.
    await tester.pumpWidget(const SizedBox());
  });
}
