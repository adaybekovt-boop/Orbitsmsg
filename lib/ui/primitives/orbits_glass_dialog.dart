// Liquid-Glass confirm dialog — replaces stock Material `AlertDialog` for the
// app's confirm flows (logout, wipe profile, delete history, …). One soft scrim
// + a glass panel + glass action buttons, so dialogs match the rest of the UI
// instead of standing out as flat Material.
//
// `showOrbitsConfirm` returns `true` if the user confirmed, `false` if they
// cancelled or dismissed by tapping the scrim. Destructive confirms pass
// `danger: true` so the confirm button reads as a danger-glass action.

import 'package:flutter/material.dart';

import '../../themes/orbits_tokens.dart';
import 'orbits_glass_button.dart';
import 'orbits_glass_surface.dart';

Future<bool> showOrbitsConfirm({
  required BuildContext context,
  required String title,
  required String message,
  String confirmLabel = 'OK',
  String cancelLabel = 'Отмена',
  IconData? confirmIcon,
  bool danger = false,
}) async {
  final result = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    // Soft scrim — dim, not black-out.
    barrierColor: Colors.black.withValues(alpha: 0.46),
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (ctx, _, __) => _ConfirmBody(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      confirmIcon: confirmIcon,
      danger: danger,
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
  return result ?? false;
}

class _ConfirmBody extends StatelessWidget {
  const _ConfirmBody({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.confirmIcon,
    required this.danger,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final IconData? confirmIcon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = OrbitsTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          // `dialog` role ⇒ real blur on Impeller platforms, painted glass on
          // web/Windows, plus the live cursor sheen.
          child: OrbitsGlassSurface(
            role: OrbitsGlassRole.dialog,
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: t.fontHeading,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: t.text,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  message,
                  style: TextStyle(
                    fontFamily: t.fontBody,
                    fontSize: 14,
                    height: 1.45,
                    color: t.muted,
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OrbitsGlassButton(
                      label: cancelLabel,
                      variant: OrbitsGlassVariant.subtle,
                      onPressed: () => Navigator.of(context).pop(false),
                    ),
                    const SizedBox(width: 10),
                    OrbitsGlassButton(
                      label: confirmLabel,
                      icon: confirmIcon,
                      variant: danger
                          ? OrbitsGlassVariant.danger
                          : OrbitsGlassVariant.primary,
                      onPressed: () => Navigator.of(context).pop(true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
