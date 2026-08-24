import 'package:flutter/material.dart';

import '../../legal/legal_placeholders.dart';
import '../../themes/orbits_tokens.dart';
import '../primitives/orbits_glass_button.dart';
import 'terms_text.dart';

/// Final onboarding step: pending offer body + terms ack + 18+ stub.
class OnboardingAgreementStep extends StatelessWidget {
  const OnboardingAgreementStep({
    super.key,
    required this.termsAccepted,
    required this.ageConfirmed,
    required this.onToggleTerms,
    required this.onToggleAge,
    required this.rememberSupported,
    required this.remember,
    required this.onToggleRemember,
    required this.busy,
    required this.error,
    required this.onFinish,
  });

  final bool termsAccepted;
  final bool ageConfirmed;
  final ValueChanged<bool> onToggleTerms;
  final ValueChanged<bool> onToggleAge;
  final bool rememberSupported;
  final bool remember;
  final ValueChanged<bool> onToggleRemember;
  final bool busy;
  final String? error;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final canFinish = canCompleteOnboarding(
          termsAccepted: termsAccepted,
          ageConfirmed: ageConfirmed,
        ) &&
        !busy;

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
          'Оферта ещё не прошла юридическую проверку. '
          'Плейсхолдер ниже — не текст юриста.',
          style: TextStyle(
            fontFamily: tokens.fontBody,
            fontSize: 13,
            color: tokens.muted,
          ),
        ),
        const SizedBox(height: 14),
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
        _AckRow(
          checked: termsAccepted,
          tokens: tokens,
          onTap: () => onToggleTerms(!termsAccepted),
          label: 'Я ознакомился и принимаю условия Соглашения и '
              'Политики конфиденциальности',
        ),
        const SizedBox(height: 10),
        _AckRow(
          key: kAgeConfirmCheckboxKey,
          checked: ageConfirmed,
          tokens: tokens,
          onTap: () => onToggleAge(!ageConfirmed),
          label: kAgeConfirmLabelRu,
        ),
        if (rememberSupported) ...[
          const SizedBox(height: 10),
          _AckRow(
            checked: remember,
            tokens: tokens,
            onTap: () => onToggleRemember(!remember),
            label: 'Запомнить меня на этом устройстве',
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: tokens.dangerAlpha(0.12),
              borderRadius: BorderRadius.circular(tokens.radiusButton),
              border: Border.all(color: tokens.dangerAlpha(0.4)),
            ),
            child: Text(
              error!,
              style: TextStyle(
                color: tokens.danger,
                fontSize: 13,
                fontFamily: tokens.fontBody,
              ),
            ),
          ),
        ],
        const SizedBox(height: 14),
        OrbitsGlassButton(
          label: 'Принять и продолжить',
          icon: Icons.login,
          onPressed: canFinish ? onFinish : null,
          enabled: canFinish,
          variant: OrbitsGlassVariant.primary,
          size: OrbitsGlassSize.large,
          expand: true,
        ),
      ],
    );
  }
}

class _AckRow extends StatelessWidget {
  const _AckRow({
    super.key,
    required this.checked,
    required this.tokens,
    required this.onTap,
    required this.label,
  });

  final bool checked;
  final OrbitsTokens tokens;
  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(tokens.radiusButton),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: checked
              ? tokens.accentAlpha(0.10)
              : tokens.surface.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(tokens.radiusButton),
          border: Border.all(
            color: checked ? tokens.accent : tokens.border,
            width: checked ? 1.4 : 1,
          ),
        ),
        child: Row(
          children: [
            AnimatedContainer(
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
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
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
    );
  }
}
