// The React app renders either `<Onboarding />` or `<App content>` based
// on `AuthContext.authState`. This widget does the same job: watches
// [authNotifierProvider] and swaps between splash / onboarding / unlock /
// AppShell. Sits directly under `MaterialApp.home` in `main.dart`.
//
// Switching is state-driven, not navigator-driven — that keeps the tree
// flat and avoids a dead route sitting under AppShell when the user logs
// out. When state transitions, the old subtree unmounts and the new one
// takes its place.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_shell.dart';
import '../../state/auth_notifier.dart';
import 'auto_lock_scope.dart';
import 'onboarding_page.dart';
import 'unlock_page.dart';

class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(authNotifierProvider);
    // Use AnimatedSwitcher so the splash-→-shell transition has some polish.
    // Key by runtimeType so identical states (e.g. two AuthLoading ticks)
    // don't trigger a crossfade.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: KeyedSubtree(
        key: ValueKey(state.runtimeType),
        child: switch (state) {
          AuthLoading() => const _SplashScreen(),
          AuthGuest() => const OnboardingPage(),
          AuthLocked() => const UnlockPage(),
          AuthAuthed() => const AutoLockScope(child: AppShell()),
        },
      ),
    );
  }
}

/// Minimal splash while `AuthNotifier._bootstrap` reads SharedPreferences.
/// Kept small on purpose — on a warm boot it's visible for <100 ms.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}
