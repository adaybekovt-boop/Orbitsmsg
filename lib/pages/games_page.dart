// Games tab. Adaptive: a single-column glass list on narrow screens, a glass
// card grid (2–3 columns) on wide desktop/web. Content is width-constrained and
// centered so it never stretches edge-to-edge.

import 'package:flutter/material.dart';

import '../core/haptics.dart';
import '../games/blackjack21/blackjack_page.dart';
import '../games/blockblast/block_blast_page.dart';
import '../games/chess/chess_page.dart';
import '../themes/orbits_tokens.dart';
import '../ui/peer/peer_status_pill.dart';
import '../ui/primitives/adaptive_page_frame.dart';
import '../ui/primitives/orbits_glass_list_tile.dart';
import '../ui/primitives/orbits_glass_surface.dart';

class GamesPage extends StatelessWidget {
  const GamesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final desktop = isDesktopLayout(context);

    void open(Widget Function(VoidCallback onExit) builder) {
      hapticTap();
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => builder(() => Navigator.of(context).maybePop()),
        ),
      );
    }

    final games = <_GameItem>[
      _GameItem(
        title: 'Block Blast',
        subtitle: 'Собирай линии, ставь рекорды',
        icon: Icons.grid_view,
        onTap: () => open((onExit) => BlockBlastPage(onExit: onExit)),
      ),
      _GameItem(
        title: '21 очко',
        subtitle: 'Классический блекджек',
        icon: Icons.style,
        onTap: () => open((onExit) => BlackjackPage(onExit: onExit)),
      ),
      _GameItem(
        title: 'Шахматы',
        subtitle: 'Игра вдвоём на одном устройстве',
        icon: Icons.extension,
        onTap: () => open((onExit) => ChessPage(onExit: onExit)),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: const OrbitsGlassSurface(
          role: OrbitsGlassRole.appBar,
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
          child: SizedBox.expand(),
        ),
        title: Text(
          'Игры',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
      ),
      body: AdaptivePageFrame(
        maxWidth: 920,
        child: ListView(
          padding: const EdgeInsets.only(top: kPillReserveHeight + 8, bottom: 24),
          children: [
            _Hero(tokens: tokens),
            const SizedBox(height: 4),
            if (desktop)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [for (final g in games) _GameCard(item: g)],
                ),
              )
            else
              for (final g in games) _GameRow(item: g),
          ],
        ),
      ),
    );
  }
}

class _GameItem {
  const _GameItem({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;
}

class _Hero extends StatelessWidget {
  const _Hero({required this.tokens});
  final OrbitsTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: tokens.accentAlpha(0.16),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(Icons.sports_esports, color: tokens.accent, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Мини-игры',
                  style: TextStyle(
                    fontFamily: tokens.fontHeading,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: tokens.text,
                  ),
                ),
                Text(
                  'Прямо в мессенджере',
                  style: TextStyle(
                    fontFamily: tokens.fontBody,
                    fontSize: 12,
                    color: tokens.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Single-column row (narrow screens).
class _GameRow extends StatelessWidget {
  const _GameRow({required this.item});
  final _GameItem item;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: OrbitsGlassListTile(
        onTap: item.onTap,
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: tokens.accentAlpha(0.16),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: tokens.accentAlpha(0.22)),
          ),
          alignment: Alignment.center,
          child: Icon(item.icon, color: tokens.text, size: 18),
        ),
        title: Text(item.title),
        subtitle: Text(item.subtitle),
        trailing: Icon(Icons.chevron_right, color: tokens.muted),
      ),
    );
  }
}

/// Fixed-size glass card (wide desktop/web grid).
class _GameCard extends StatelessWidget {
  const _GameCard({required this.item});
  final _GameItem item;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final radius = BorderRadius.circular(tokens.radiusCard);
    return SizedBox(
      width: 264,
      height: 156,
      child: OrbitsGlassSurface(
        role: OrbitsGlassRole.card,
        borderRadius: radius,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: item.onTap,
            borderRadius: radius,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: tokens.accentAlpha(0.16),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: tokens.accentAlpha(0.22)),
                    ),
                    alignment: Alignment.center,
                    child: Icon(item.icon, color: tokens.text, size: 22),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: tokens.fontHeading,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: tokens.text,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: Text(
                      item.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: tokens.fontBody,
                        fontSize: 12.5,
                        height: 1.3,
                        color: tokens.muted,
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        'Открыть',
                        style: TextStyle(
                          fontFamily: tokens.fontBody,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: tokens.text,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(Icons.chevron_right, color: tokens.muted, size: 18),
                    ],
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
