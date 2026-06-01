// Port of the `locked` branch of `src/components/Onboarding.jsx` — the
// password-entry screen shown when a profile exists but the vault is
// locked. Two actions: [AuthNotifier.unlock] for the happy path, and
// [AuthNotifier.wipeLocal] behind an AlertDialog for "забыл пароль".
//
// Visually mirrors the onboarding wizard: same glass card, same header,
// same big-button shape, so the locked → unlocked → onboarded flow
// reads as a single cohesive surface.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/haptics.dart';
import '../../state/auth_notifier.dart';
import '../../themes/orbits_tokens.dart';
import '../primitives/orbits_glass_button.dart';
import '../primitives/orbits_glass_dialog.dart';
import '../primitives/orbits_glass_surface.dart';
import 'crypto_busy_view.dart';
import 'keygen_overlay_stub.dart'
    if (dart.library.html) 'keygen_overlay_web.dart' as crypto_overlay;

class UnlockPage extends ConsumerStatefulWidget {
  const UnlockPage({super.key});

  @override
  ConsumerState<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends ConsumerState<UnlockPage> {
  final _passwordCtrl = TextEditingController();
  bool _showPass = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    // Same scrypt-freeze story as onboarding: show the loading view and (on web)
    // the compositor overlay before the verify KDF seizes the UI thread.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await WidgetsBinding.instance.endOfFrame;
    crypto_overlay.showCryptoBusyOverlay(
      isDark: isDark,
      title: 'Открываем профиль…',
      subtitle: 'Проверяем пароль. Это занимает пару секунд.',
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    try {
      await ref
          .read(authNotifierProvider.notifier)
          .unlock(password: _passwordCtrl.text);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Ошибка: $e');
    } finally {
      crypto_overlay.hideCryptoBusyOverlay();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmWipe() async {
    hapticTap();
    final ok = await showOrbitsConfirm(
      context: context,
      title: 'Сбросить профиль?',
      message: 'Профиль и все его данные на этом устройстве будут удалены. '
          'Отменить действие будет нельзя.',
      confirmLabel: 'Сбросить',
      confirmIcon: Icons.restart_alt,
      danger: true,
    );
    if (ok) {
      await ref.read(authNotifierProvider.notifier).wipeLocal();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authNotifierProvider);
    final displayName = state is AuthLocked ? state.profile.displayName : '';
    final tokens = OrbitsTokens.of(context);

    if (_busy) {
      return const Scaffold(
        body: SafeArea(
          child: CryptoBusyView(
            title: 'Открываем профиль…',
            subtitle:
                'Проверяем пароль. Это занимает пару секунд и происходит '
                'только на этом устройстве.',
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: tokens.accentAlpha(0.18),
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Icon(Icons.lock_outline,
                            size: 20, color: tokens.accent),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'ORBITS',
                              style: TextStyle(
                                fontFamily: tokens.fontHeading,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: tokens.text,
                                letterSpacing: 1.2,
                              ),
                            ),
                            Text(
                              displayName.isEmpty
                                  ? 'Войдите в профиль'
                                  : 'Открыть профиль «$displayName»',
                              style: TextStyle(
                                fontFamily: tokens.fontMono,
                                fontSize: 11,
                                color: tokens.muted,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  // Glass card with password field
                  OrbitsGlassSurface(
                    role: OrbitsGlassRole.card,
                    realBlur: true,
                    borderRadius: BorderRadius.circular(28),
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _passwordCtrl,
                          obscureText: !_showPass,
                          autofocus: true,
                          style: TextStyle(
                            fontFamily: tokens.fontBody,
                            fontSize: 15,
                          ),
                          decoration: InputDecoration(
                            labelText: 'Пароль',
                            hintText: '••••••••',
                            filled: true,
                            fillColor: tokens.bg.withValues(alpha: 0.45),
                            suffixIcon: IconButton(
                              tooltip: _showPass ? 'Скрыть' : 'Показать',
                              icon: Icon(_showPass
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined),
                              color: tokens.muted,
                              onPressed: () {
                                hapticTap();
                                setState(() => _showPass = !_showPass);
                              },
                            ),
                          ),
                          onSubmitted: (_) => _unlock(),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Профиль хранится на этом устройстве. '
                          'Пароль защищает доступ к нему.',
                          style: TextStyle(
                            fontFamily: tokens.fontBody,
                            fontSize: 13,
                            height: 1.4,
                            color: tokens.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: tokens.dangerAlpha(0.12),
                        borderRadius:
                            BorderRadius.circular(tokens.radiusButton),
                        border: Border.all(color: tokens.dangerAlpha(0.4)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline,
                              color: tokens.danger, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: tokens.danger,
                                fontSize: 13,
                                fontFamily: tokens.fontBody,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  OrbitsGlassButton(
                    label: 'Войти',
                    icon: Icons.login,
                    onPressed: _unlock,
                    variant: OrbitsGlassVariant.primary,
                    size: OrbitsGlassSize.large,
                    expand: true,
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: OrbitsGlassButton(
                      label: 'Сбросить профиль',
                      icon: Icons.restart_alt,
                      onPressed: _confirmWipe,
                      variant: OrbitsGlassVariant.danger,
                      size: OrbitsGlassSize.medium,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
