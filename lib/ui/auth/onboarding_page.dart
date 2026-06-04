// Port of `src/components/Onboarding.jsx` — the 3-step registration
// wizard. Designed to match the JS visual: a glass card with rounded
// 28-px corners floating on the canvas, a thin progress strip across
// the top, and step-to-step crossfade animations.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth_validation.dart';
import '../../core/haptics.dart';
import '../../core/identity.dart';
import '../../state/auth_notifier.dart';
import '../../state/remembered_session_stub.dart'
    if (dart.library.html) '../../state/remembered_session_web.dart'
    as remembered;
import '../../themes/orbits_tokens.dart';
import '../primitives/orbits_glass_button.dart';
import '../primitives/orbits_glass_surface.dart';
import 'crypto_busy_view.dart';
import 'keygen_overlay_stub.dart'
    if (dart.library.html) 'keygen_overlay_web.dart' as crypto_overlay;
import 'terms_text.dart';

class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final _displayNameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  int _step = 0;
  bool _showPass = false;
  bool _busy = false;
  String? _error;
  LocalIdentity? _identity;
  bool _revealPeerId = false;

  /// Terms acceptance — flips to true when the user ticks the checkbox
  /// on step 3. The «Принять и завершить» button stays disabled until.
  bool _termsAccepted = false;

  /// "Remember me" — offered on the final step only where secure persistence
  /// exists (web with a secure context). Resolved async in initState.
  bool _rememberSupported = false;
  bool _remember = false;

  @override
  void initState() {
    super.initState();
    getOrCreateIdentity().then((id) {
      if (mounted) setState(() => _identity = id);
    });
    remembered.isRememberSupported().then((supported) {
      if (mounted && supported) setState(() => _rememberSupported = true);
    });
  }

  @override
  void dispose() {
    _displayNameCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _setStep(int next) {
    final clamped = next.clamp(0, 3);
    setState(() {
      _step = clamped;
      _error = null;
    });
  }

  bool _validateCreds() {
    final vu = validateUsername(_displayNameCtrl.text);
    if (!vu.ok) {
      setState(() => _error = 'Ник: 3–30 символов, буквы/цифры/подчёркивание');
      return false;
    }
    final vp = validatePassword(_passwordCtrl.text);
    if (!vp.ok) {
      setState(() => _error = 'Пароль: минимум 8 символов');
      return false;
    }
    final vc = validatePasswordConfirm(_passwordCtrl.text, _confirmCtrl.text);
    if (!vc.ok) {
      setState(() => _error = 'Пароли не совпадают');
      return false;
    }
    return true;
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_validateCreds()) return;
    if (!_termsAccepted) {
      setState(() => _error = 'Нужно принять Соглашение, чтобы продолжить');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // Show the loading screen, then let it actually paint/composite before the
    // CPU-heavy scrypt runs. On web scrypt blocks the single UI thread, so:
    //  • the in-Flutter `CryptoBusyView` paints first (native animates it —
    //    the KDF runs in a background isolate there), and
    //  • a compositor-driven CSS overlay is shown on web so something keeps
    //    animating even while the main thread is blocked (no "frozen" look).
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await WidgetsBinding.instance.endOfFrame;
    crypto_overlay.showCryptoBusyOverlay(
      isDark: isDark,
      title: 'Готовим профиль…',
      subtitle: 'Это занимает пару секунд и происходит только на этом устройстве.',
    );
    // Give the browser a beat to commit the overlay and start its compositor
    // animation before scrypt seizes the thread.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    try {
      await ref.read(authNotifierProvider.notifier).completeOnboarding(
            displayName: _displayNameCtrl.text,
            password: _passwordCtrl.text,
            confirm: _confirmCtrl.text,
            remember: _remember,
          );
      // AuthGate listens to auth state and swaps screens — nothing to do.
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Ошибка: $e');
    } finally {
      crypto_overlay.hideCryptoBusyOverlay();
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _maskedPeerId {
    final id = _identity?.peerId ?? '';
    if (id.isEmpty) return '—';
    if (_revealPeerId) return id;
    return id.replaceAll(RegExp(r'[0-9A-F]'), '•');
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    // While the vault key is being derived, take over the whole screen with an
    // explicit loading view so it never reads as a frozen wizard (on web a
    // compositor overlay also animates on top — see `_submit`).
    if (_busy) {
      return const Scaffold(
        body: SafeArea(
          child: CryptoBusyView(
            title: 'Готовим профиль…',
            subtitle:
                'Это занимает пару секунд и происходит только на этом '
                'устройстве.',
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
                children: [
                  _Header(
                    step: _step,
                    onBack: _step > 0
                        ? () {
                            hapticTap();
                            _setStep(_step - 1);
                          }
                        : null,
                  ),
                  const SizedBox(height: 18),
                  _StepProgress(step: _step),
                  const SizedBox(height: 24),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: tokens.durationMedium,
                      switchInCurve: tokens.easing,
                      switchOutCurve: tokens.easing,
                      transitionBuilder: (child, anim) {
                        return FadeTransition(
                          opacity: anim,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0, 0.04),
                              end: Offset.zero,
                            ).animate(anim),
                            child: child,
                          ),
                        );
                      },
                      child: _buildStep(_step, tokens),
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

  Widget _buildStep(int step, OrbitsTokens tokens) {
    switch (step) {
      case 0:
        return _StepWelcome(
          key: const ValueKey('s0'),
          onNext: () {
            hapticTap();
            _setStep(1);
          },
        );
      case 1:
        return _StepCreds(
          key: const ValueKey('s1'),
          displayNameCtrl: _displayNameCtrl,
          passwordCtrl: _passwordCtrl,
          confirmCtrl: _confirmCtrl,
          showPass: _showPass,
          onToggleShowPass: () {
            hapticTap();
            setState(() => _showPass = !_showPass);
          },
          error: _error,
          onNext: () {
            hapticTap();
            if (_validateCreds()) _setStep(2);
          },
        );
      case 2:
        return _StepPeerId(
          key: const ValueKey('s2'),
          maskedPeerId: _maskedPeerId,
          reveal: _revealPeerId,
          onToggleReveal: () {
            hapticTap();
            setState(() => _revealPeerId = !_revealPeerId);
          },
          onCopy: _identity == null || !_revealPeerId
              ? null
              : () async {
                  hapticTap();
                  await Clipboard.setData(
                      ClipboardData(text: _identity!.peerId));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Код скопирован'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
          onNext: () {
            hapticTap();
            _setStep(3);
          },
        );
      default:
        return _StepTerms(
          key: const ValueKey('s3'),
          accepted: _termsAccepted,
          onToggleAccepted: (v) {
            hapticTap();
            setState(() {
              _termsAccepted = v;
              if (v) _error = null;
            });
          },
          rememberSupported: _rememberSupported,
          remember: _remember,
          onToggleRemember: (v) {
            hapticTap();
            setState(() => _remember = v);
          },
          busy: _busy,
          error: _error,
          onFinish: () {
            hapticTap();
            _submit();
          },
        );
    }
  }
}

// ─── Header ──────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.step, this.onBack});
  final int step;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: tokens.accentAlpha(0.18),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(Icons.bubble_chart, size: 20, color: tokens.accent),
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
                'Регистрация (4 шага)',
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
        if (onBack != null)
          OrbitsGlassIconButton(
            icon: Icons.chevron_left,
            tooltip: 'Назад',
            variant: OrbitsGlassVariant.subtle,
            size: OrbitsGlassSize.small,
            onPressed: onBack,
          ),
      ],
    );
  }
}

class _StepProgress extends StatelessWidget {
  const _StepProgress({required this.step});
  final int step;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Row(
      children: List.generate(4, (i) {
        final filled = i <= step;
        return Expanded(
          child: AnimatedContainer(
            duration: tokens.durationShort,
            curve: tokens.easing,
            margin: EdgeInsets.only(right: i == 3 ? 0 : 6),
            height: 4,
            decoration: BoxDecoration(
              color: filled ? tokens.accent : tokens.muted.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
      }),
    );
  }
}

// ─── Step 0: Welcome ─────────────────────────────────────────

class _StepWelcome extends StatelessWidget {
  const _StepWelcome({super.key, required this.onNext});
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _GlassCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: tokens.accentAlpha(0.18),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(Icons.verified_user,
                    color: tokens.accent, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Добро пожаловать',
                      style: TextStyle(
                        fontFamily: tokens.fontHeading,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: tokens.text,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Чаты и звонки идут напрямую между устройствами. '
                      'Мы не просим телефон, не храним сообщения на сервере, '
                      'а переписка надёжно защищена.',
                      style: TextStyle(
                        fontFamily: tokens.fontBody,
                        fontSize: 14,
                        height: 1.45,
                        color: tokens.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _BigButton(
          label: 'Начать',
          onPressed: onNext,
        ),
      ],
    );
  }
}

// ─── Step 1: Credentials ─────────────────────────────────────

class _StepCreds extends StatelessWidget {
  const _StepCreds({
    super.key,
    required this.displayNameCtrl,
    required this.passwordCtrl,
    required this.confirmCtrl,
    required this.showPass,
    required this.onToggleShowPass,
    required this.error,
    required this.onNext,
  });

  final TextEditingController displayNameCtrl;
  final TextEditingController passwordCtrl;
  final TextEditingController confirmCtrl;
  final bool showPass;
  final VoidCallback onToggleShowPass;
  final String? error;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _FormField(
                  controller: displayNameCtrl,
                  label: 'Ник',
                  hint: 'Например: Alex_77',
                ),
                const SizedBox(height: 14),
                _FormField(
                  controller: passwordCtrl,
                  label: 'Пароль',
                  hint: 'Минимум 8 символов',
                  obscure: !showPass,
                  suffix: IconButton(
                    icon: Icon(showPass
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined),
                    color: tokens.muted,
                    onPressed: onToggleShowPass,
                  ),
                ),
                const SizedBox(height: 10),
                _FormField(
                  controller: confirmCtrl,
                  label: 'Повтори пароль',
                  obscure: !showPass,
                  onSubmitted: (_) => onNext(),
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder(
                  valueListenable: passwordCtrl,
                  builder: (_, value, __) {
                    final s = passwordStrength(value.text);
                    return Row(
                      children: [
                        for (var i = 0; i < 5; i++)
                          Expanded(
                            child: Container(
                              margin: EdgeInsets.only(right: i == 4 ? 0 : 4),
                              height: 3,
                              decoration: BoxDecoration(
                                color: i < s
                                    ? tokens.accent
                                    : tokens.muted.withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        const SizedBox(width: 10),
                        Text(
                          'Сила: $s/5',
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: tokens.fontMono,
                            color: tokens.muted,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 14),
            _ErrorBanner(error!),
          ],
          const SizedBox(height: 20),
          _BigButton(label: 'Далее', onPressed: onNext),
        ],
      ),
    );
  }
}

// ─── Step 2: Peer ID ─────────────────────────────────────────

class _StepPeerId extends StatelessWidget {
  const _StepPeerId({
    super.key,
    required this.maskedPeerId,
    required this.reveal,
    required this.onToggleReveal,
    required this.onCopy,
    required this.onNext,
  });

  final String maskedPeerId;
  final bool reveal;
  final VoidCallback onToggleReveal;
  final VoidCallback? onCopy;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Твой код профиля',
                style: TextStyle(
                  fontFamily: tokens.fontHeading,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: tokens.text,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: tokens.bg.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(tokens.radiusButton),
                  border: Border.all(color: tokens.border),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        maskedPeerId,
                        style: TextStyle(
                          fontFamily: tokens.fontMono,
                          fontSize: 16,
                          color: tokens.text,
                          letterSpacing: 0.5,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    OrbitsGlassIconButton(
                      icon: reveal
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      tooltip: reveal ? 'Скрыть' : 'Показать',
                      variant: OrbitsGlassVariant.subtle,
                      size: OrbitsGlassSize.small,
                      onPressed: onToggleReveal,
                    ),
                    OrbitsGlassIconButton(
                      icon: Icons.copy_outlined,
                      tooltip: reveal ? 'Копировать' : 'Сначала покажи',
                      variant: OrbitsGlassVariant.subtle,
                      size: OrbitsGlassSize.small,
                      onPressed: onCopy,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Этот код — адрес твоего профиля. По умолчанию он скрыт. '
                'Показывай и отправляй его только тем, кому доверяешь.',
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
        const SizedBox(height: 20),
        _BigButton(
          label: 'Далее',
          icon: Icons.arrow_forward,
          onPressed: onNext,
        ),
      ],
    );
  }
}

// ─── Step 3: Terms acceptance ─────────────────────────────────

class _StepTerms extends StatelessWidget {
  const _StepTerms({
    super.key,
    required this.accepted,
    required this.onToggleAccepted,
    required this.rememberSupported,
    required this.remember,
    required this.onToggleRemember,
    required this.busy,
    required this.error,
    required this.onFinish,
  });

  final bool accepted;
  final ValueChanged<bool> onToggleAccepted;
  final bool rememberSupported;
  final bool remember;
  final ValueChanged<bool> onToggleRemember;
  final bool busy;
  final String? error;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Соглашение',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Прочитай документ и подтверди, что согласен с условиями.',
          style: TextStyle(
            fontFamily: tokens.fontBody,
            fontSize: 13,
            color: tokens.muted,
          ),
        ),
        const SizedBox(height: 14),

        // Scrollable card with the policy text. Fixed height so the
        // user clearly sees this is an embedded scroll region — the
        // outer page doesn't scroll past it. The border + tinted bg
        // mark it visually as a separate surface.
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: tokens.bg.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: tokens.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: const TermsView(),
          ),
        ),

        const SizedBox(height: 14),

        // Acceptance row — checkbox + label, tapping the row toggles.
        InkWell(
          onTap: () => onToggleAccepted(!accepted),
          borderRadius: BorderRadius.circular(tokens.radiusButton),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            decoration: BoxDecoration(
              color: accepted
                  ? tokens.accentAlpha(0.10)
                  : tokens.surface.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(tokens.radiusButton),
              border: Border.all(
                color: accepted ? tokens.accent : tokens.border,
                width: accepted ? 1.4 : 1,
              ),
            ),
            child: Row(
              children: [
                _Checkbox(checked: accepted, tokens: tokens),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Я ознакомился и принимаю условия Соглашения и '
                    'Политики конфиденциальности',
                    style: TextStyle(
                      fontFamily: tokens.fontBody,
                      fontSize: 13,
                      height: 1.4,
                      color: tokens.text,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        if (rememberSupported) ...[
          const SizedBox(height: 10),
          InkWell(
            onTap: () => onToggleRemember(!remember),
            borderRadius: BorderRadius.circular(tokens.radiusButton),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: remember
                    ? tokens.accentAlpha(0.10)
                    : tokens.surface.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(tokens.radiusButton),
                border: Border.all(
                  color: remember ? tokens.accent : tokens.border,
                  width: remember ? 1.4 : 1,
                ),
              ),
              child: Row(
                children: [
                  _Checkbox(checked: remember, tokens: tokens),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Запомнить меня на этом устройстве',
                      style: TextStyle(
                        fontFamily: tokens.fontBody,
                        fontSize: 13,
                        height: 1.4,
                        color: tokens.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],

        if (error != null) ...[
          const SizedBox(height: 12),
          _ErrorBanner(error!),
        ],
        const SizedBox(height: 14),

        _BigButton(
          // Busy state is handled by the full-screen CryptoBusyView, so the
          // button itself only ever shows its resting label here.
          label: 'Принять и продолжить',
          icon: Icons.login,
          onPressed: (busy || !accepted) ? null : onFinish,
        ),
      ],
    );
  }
}

/// Custom rounded square checkbox tinted to the active theme. Material's
/// stock `Checkbox` looks foreign here — too small + too platform-y.
class _Checkbox extends StatelessWidget {
  const _Checkbox({required this.checked, required this.tokens});
  final bool checked;
  final OrbitsTokens tokens;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: tokens.durationShort,
      curve: tokens.easing,
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: checked ? tokens.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: checked ? tokens.accent : tokens.muted,
          width: 1.6,
        ),
      ),
      alignment: Alignment.center,
      child: checked
          ? Icon(Icons.check, size: 16, color: tokens.bg)
          : const SizedBox.shrink(),
    );
  }
}

// ─── Reusable atoms ──────────────────────────────────────────

/// Glass card wrapper — now a real Liquid-Glass surface. `realBlur: true`
/// opts this large, standalone panel into a BackdropFilter (it isn't inside a
/// scrolling list), so it refracts the monochrome backdrop behind it.
class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return OrbitsGlassSurface(
      role: OrbitsGlassRole.card,
      realBlur: true,
      borderRadius: BorderRadius.circular(28),
      padding: const EdgeInsets.all(20),
      child: child,
    );
  }
}

/// Full-width primary Liquid-Glass CTA.
class _BigButton extends StatelessWidget {
  const _BigButton({required this.label, this.icon, this.onPressed});
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OrbitsGlassButton(
      label: label,
      icon: icon,
      onPressed: onPressed,
      enabled: onPressed != null,
      variant: OrbitsGlassVariant.primary,
      size: OrbitsGlassSize.large,
      expand: true,
    );
  }
}

class _FormField extends StatelessWidget {
  const _FormField({
    required this.controller,
    required this.label,
    this.hint,
    this.obscure = false,
    this.suffix,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscure;
  final Widget? suffix;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return TextField(
      controller: controller,
      obscureText: obscure,
      onSubmitted: onSubmitted,
      style: TextStyle(
        fontFamily: tokens.fontBody,
        fontSize: 15,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixIcon: suffix,
        // Override the global theme's filled background with a subtler
        // tint so the field reads as part of the glass card, not as an
        // opaque slot floating on top.
        filled: true,
        fillColor: tokens.bg.withValues(alpha: 0.45),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: tokens.dangerAlpha(0.12),
        borderRadius: BorderRadius.circular(tokens.radiusButton),
        border: Border.all(color: tokens.dangerAlpha(0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: tokens.danger, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: tokens.danger,
                fontSize: 13,
                fontFamily: tokens.fontBody,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
