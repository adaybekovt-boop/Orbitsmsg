// Dedicated theme picker — pulled out of the main Settings page so the
// scroll on Settings stays compact. Pushed via a settings row.
//
// Lays out the 4 manifests in two clearly-labelled groups (Classic /
// Atmospheric), each row a tappable card with a colour-swatch trio
// preview + check icon for the active theme.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../themes/manifest.dart';
import '../themes/orbits_tokens.dart';
import '../themes/registry.dart';
import '../themes/theme_notifier.dart';
import '../ui/primitives/adaptive_page_frame.dart';

class ThemesPage extends ConsumerWidget {
  const ThemesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = OrbitsTokens.of(context);
    final activeId = ref.watch(themeNotifierProvider).value ?? defaultThemeId;
    final manifests = listThemeIds().map((id) => themeCatalog[id]!).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Тема',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: AdaptivePageFrame(
        maxWidth: 760,
        child: ListView(
        padding: const EdgeInsets.only(bottom: 24, top: 8),
        children: [
          // Hero blurb
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Text(
              'Светлая или тёмная — выбери оформление. Меняются цвета, '
              'поверхности и контраст текста.',
              style: TextStyle(
                fontFamily: tokens.fontBody,
                fontSize: 13,
                color: tokens.muted,
                height: 1.5,
              ),
            ),
          ),
          for (final m in manifests)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _ThemeRow(
                manifest: m,
                selected: m.id == activeId,
                onTap: () =>
                    ref.read(themeNotifierProvider.notifier).setThemeId(m.id),
              ),
            ),
        ],
      ),
      ),
    );
  }
}

class _ThemeRow extends StatelessWidget {
  const _ThemeRow({
    required this.manifest,
    required this.selected,
    required this.onTap,
  });

  final ThemeManifest manifest;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final colors = manifest.tokens;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(tokens.radiusCard),
          child: AnimatedContainer(
            duration: tokens.durationShort,
            curve: tokens.easing,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: selected
                  ? tokens.accentAlpha(0.10)
                  : Color.lerp(tokens.bg, tokens.surface, 0.35),
              borderRadius: BorderRadius.circular(tokens.radiusCard),
              border: Border.all(
                color: selected ? tokens.accent : tokens.border,
                width: selected ? 1.4 : 1,
              ),
            ),
            child: Row(
              children: [
                _ThemePreview(colors: colors),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        manifest.name,
                        style: TextStyle(
                          fontFamily: tokens.fontHeading,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: tokens.text,
                        ),
                      ),
                      if (manifest.subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          manifest.subtitle!,
                          style: TextStyle(
                            fontFamily: tokens.fontBody,
                            fontSize: 13,
                            color: tokens.muted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle, color: tokens.accent, size: 22),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Mini preview tile — instead of three overlapping dots, paint a
/// stacked rectangle that shows the actual theme bg → surface gradient
/// with a small accent stripe. Reads as a "themed window" preview.
class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.colors});
  final ThemeTokenColors colors;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 44,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            // Page background
            Container(color: colors.bg),
            // Surface "card" floating in the middle
            Positioned(
              left: 8,
              top: 6,
              right: 8,
              bottom: 6,
              child: Container(
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: colors.border),
                ),
              ),
            ),
            // Accent stripe on the surface (faux "active state")
            Positioned(
              left: 12,
              top: 10,
              child: Container(
                width: 14,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Text-row faux-line
            Positioned(
              left: 12,
              top: 18,
              child: Container(
                width: 28,
                height: 3,
                decoration: BoxDecoration(
                  color: colors.muted.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Positioned(
              left: 12,
              top: 24,
              child: Container(
                width: 22,
                height: 3,
                decoration: BoxDecoration(
                  color: colors.muted.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
