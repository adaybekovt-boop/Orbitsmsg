// Settings → Чаты.
//
// Real, consumed appearance prefs (read by MessageBubble via chatPrefsProvider):
//   • Показывать секунды → timestamp format HH:MM:SS
//   • Форма пузырей      → bubble corner shape
//   • Размер шрифта      → message text scale (live preview below)
//
// Not-yet-implemented behaviours (read receipts, sound/haptic on receive) are
// shown as disabled "СКОРО" rows instead of fake toggles — there is no runtime
// consumer for them yet (sound core is a no-op stub; no read-receipt path).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/chat_prefs_provider.dart';
import '../../themes/orbits_tokens.dart';
import '../../ui/primitives/orbits_glass_button.dart';
import '../../ui/primitives/orbits_glass_list_tile.dart';
import '../../ui/primitives/adaptive_page_frame.dart';
import '../../ui/primitives/orbits_glass_app_bar.dart';
import '../../ui/primitives/orbits_glass_surface.dart';
import '../../ui/primitives/orbits_glass_switch.dart';

class ChatPrefsPage extends ConsumerWidget {
  const ChatPrefsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = OrbitsTokens.of(context);
    final prefs = ref.watch(chatPrefsProvider);
    final notifier = ref.read(chatPrefsProvider.notifier);

    return Scaffold(
      appBar: OrbitsGlassAppBar(
        title: Text(
          'Чаты',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
      ),
      body: AdaptivePageFrame(
        maxWidth: 760,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            // ── Behaviour (real) ─────────────────────────────────
            const _SectionLabel('Поведение'),
            _ToggleRow(
              icon: Icons.timer_outlined,
              label: 'Показывать секунды',
              subtitle: 'Время сообщений в формате ЧЧ:ММ:СС',
              value: prefs.showSeconds,
              onChanged: (v) =>
                  notifier.update(prefs.copyWith(showSeconds: v)),
            ),

            // ── Bubble style (real) ──────────────────────────────
            const _SectionLabel('Форма пузырей'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: OrbitsGlassSurface(
                role: OrbitsGlassRole.card,
                borderRadius: BorderRadius.circular(tokens.radiusCard),
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final style in const [
                          ('rounded', 'Округлый'),
                          ('soft', 'Мягкий'),
                          ('square', 'Квадрат'),
                          ('bubble', 'Пузырь'),
                        ])
                          OrbitsGlassPillButton(
                            label: style.$2,
                            selected: prefs.bubbleStyle == style.$1,
                            size: OrbitsGlassSize.small,
                            onPressed: () => notifier
                                .update(prefs.copyWith(bubbleStyle: style.$1)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _BubblePreview(prefs: prefs, tokens: tokens),
                  ],
                ),
              ),
            ),

            // ── Font size (real) ─────────────────────────────────
            const _SectionLabel('Размер шрифта'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: OrbitsGlassSurface(
                role: OrbitsGlassRole.card,
                borderRadius: BorderRadius.circular(tokens.radiusCard),
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (final size in const ['XS', 'S', 'M', 'L', 'XL'])
                          _SizeButton(
                            label: size,
                            selected: prefs.fontSize == size,
                            onTap: () =>
                                notifier.update(prefs.copyWith(fontSize: size)),
                            tokens: tokens,
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Пример текста сообщения',
                        style: TextStyle(
                          color: tokens.text,
                          fontFamily: tokens.fontBody,
                          fontSize: 15 * prefs.fontScale,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Not implemented yet — honest disabled rows ───────
            const _SectionLabel('В разработке'),
            const _ComingSoonRow(
              icon: Icons.mark_chat_read_outlined,
              label: 'Авто-прочтение',
              subtitle: 'Отметки о прочтении появятся в обновлении',
            ),
            const _ComingSoonRow(
              icon: Icons.volume_up_outlined,
              label: 'Звуки сообщений',
              subtitle: 'Звук при получении появится вместе со звуковым движком',
            ),
            const _ComingSoonRow(
              icon: Icons.vibration,
              label: 'Вибрация',
              subtitle: 'Тактильный отклик при новом сообщении появится позже',
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

/// Small preview bubble that reflects the chosen shape + font size.
class _BubblePreview extends StatelessWidget {
  const _BubblePreview({required this.prefs, required this.tokens});

  final ChatPrefs prefs;
  final OrbitsTokens tokens;

  BorderRadius get _radius {
    switch (prefs.bubbleStyle) {
      case 'square':
        return BorderRadius.circular(6);
      case 'soft':
        return BorderRadius.circular(14);
      case 'bubble':
        return BorderRadius.circular(22);
      case 'rounded':
      default:
        return const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(6),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: tokens.bubbleOut,
          borderRadius: _radius,
          border: Border.all(color: tokens.accentAlpha(0.22)),
        ),
        child: Text(
          'Пример',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.95),
            fontFamily: tokens.fontBody,
            fontSize: 15 * prefs.fontScale,
          ),
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: OrbitsGlassListTile(
        onTap: () => onChanged(!value),
        leading: Icon(icon, color: tokens.muted, size: 20),
        title: Text(label),
        subtitle: Text(subtitle),
        trailing: OrbitsGlassSwitch(
          value: value,
          onChanged: onChanged,
          semanticLabel: label,
        ),
      ),
    );
  }
}

class _ComingSoonRow extends StatelessWidget {
  const _ComingSoonRow({
    required this.icon,
    required this.label,
    required this.subtitle,
  });

  final IconData icon;
  final String label;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Opacity(
      opacity: 0.6,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: OrbitsGlassListTile(
          leading: Icon(icon, color: tokens.muted, size: 20),
          title: Text(label),
          subtitle: Text(subtitle),
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: tokens.muted.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'СКОРО',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                fontFamily: tokens.fontMono,
                color: tokens.muted,
                letterSpacing: 1.0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          fontFamily: tokens.fontMono,
          color: tokens.muted,
          letterSpacing: 1.6,
        ),
      ),
    );
  }
}

class _SizeButton extends StatelessWidget {
  const _SizeButton({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.tokens,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final OrbitsTokens tokens;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(tokens.radiusButton);
    return OrbitsGlassSurface(
      role: OrbitsGlassRole.button,
      borderRadius: radius,
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected ? tokens.accent : tokens.text,
                  fontFamily: tokens.fontMono,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
