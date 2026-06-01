// Sticker picker — modal bottom sheet version of the JS StickerPicker
// popover (`src/components/StickerPicker.jsx`). Opens from the composer's
// emoji button.
//
// Layout: sheet = [title bar, scrollable sticker grid, pack tab strip].
// Tap a sticker → sheet closes, caller gets the sticker payload via
// [onPick] and dispatches through `MessagingNotifier.sendSticker`.
//
// Rendering note: the default packs ship sticker images as
// `data:image/svg+xml;utf8,<svg><text>😀</text></svg>`. Flutter has no
// built-in SVG decoder and we don't want to pull in `flutter_svg` just
// for "render one emoji at 48pt". We render `Text(sticker.emoji, ...)`
// directly — the platform emoji font (Apple Color Emoji on iOS, Segoe /
// Noto Color on Android/desktop) gives a visually-identical result to
// the JS build.
//
// For inbound stickers whose `emoji` field is empty (custom pack from
// another client), we fall back to a generic frame icon. True custom-
// pack image rendering is a post-launch item — the wire format already
// carries the url, we just need a decoder.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/sticker_manager.dart';
import '../primitives/orbits_glass_button.dart';

/// Shape the picker hands back to the caller. Intentionally field-for-
/// field identical to the JS `onPick` payload so `MessagingNotifier.
/// sendSticker` can pass it straight through without re-mapping.
typedef StickerPickResult = Map<String, Object?>;

class StickerPickerSheet extends StatefulWidget {
  const StickerPickerSheet({super.key, required this.onPick});

  /// Fired when the user taps a sticker. The sheet closes itself first
  /// so the callback can run post-pop (e.g. dispatch `sendSticker`).
  final void Function(StickerPickResult sticker) onPick;

  @override
  State<StickerPickerSheet> createState() => _StickerPickerSheetState();
}

class _StickerPickerSheetState extends State<StickerPickerSheet> {
  /// All installed packs, oldest-install first. Populated from the sticker
  /// manager on mount; empty until the future resolves (~sub-frame in
  /// practice since the default packs are inlined).
  List<StickerPack> _packs = const [];

  /// Resolved recent stickers. May be empty (fresh install) or shorter
  /// than [_packs] × their entries — we only keep the last 32.
  List<ResolvedSticker> _recents = const [];

  /// Active tab id. `__recent__` for the recents tab, otherwise a pack
  /// id. Starts on recents; if there are no recents yet, `_activePack`
  /// resolves the first installed pack for the grid.
  String _activeTab = _recentTabId;

  static const String _recentTabId = '__recent__';

  @override
  void initState() {
    super.initState();
    _loadPacks();
  }

  Future<void> _loadPacks() async {
    final packs = await getInstalledPacks();
    final recents = await getRecents(limit: 32);
    if (!mounted) return;
    setState(() {
      _packs = packs;
      _recents = recents;
      // Fresh install: recents empty → jump to first pack so the grid
      // isn't a blank "no recents" screen on first open.
      if (_activeTab == _recentTabId && recents.isEmpty && packs.isNotEmpty) {
        _activeTab = packs.first.id;
      }
    });
  }

  StickerPack? get _activePack {
    if (_activeTab == _recentTabId) return null;
    for (final p in _packs) {
      if (p.id == _activeTab) return p;
    }
    return null;
  }

  Future<void> _handlePick(StickerPack pack, Sticker sticker) async {
    // Record usage before popping so the next picker open reflects this
    // pick in the recents tab. Fire-and-forget is fine — a failed recents
    // write is survivable.
    unawaited(recordStickerUsage(pack.id, sticker.id));

    final payload = <String, Object?>{
      'packId': pack.id,
      'packName': pack.name,
      'stickerId': sticker.id,
      'url': sticker.url,
      'emoji': sticker.emoji.isNotEmpty ? sticker.emoji : sticker.label,
      'label': sticker.label,
    };
    if (!mounted) return;
    Navigator.of(context).pop();
    widget.onPick(payload);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: SizedBox(
        // 60 dvh ceiling — same ratio as the JS popover's `max-h-[42dvh]`
        // plus room for the tab strip underneath, and leaves the composer /
        // keyboard visible above it.
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Title bar ────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'СТИКЕРЫ',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: scheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  OrbitsGlassIconButton(
                    icon: Icons.close,
                    tooltip: 'Закрыть',
                    variant: OrbitsGlassVariant.subtle,
                    size: OrbitsGlassSize.small,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
              thickness: 0.6,
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),

            // ── Grid ─────────────────────────────────────────────
            Expanded(
              child: _buildGrid(scheme),
            ),

            // ── Tab strip ────────────────────────────────────────
            Divider(
              height: 1,
              thickness: 0.6,
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
            SizedBox(
              height: 56,
              child: _buildTabStrip(scheme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(ColorScheme scheme) {
    if (_packs.isEmpty) {
      // Default packs load synchronously from code, so this only flashes
      // on first frame. A spinner would just visually jitter.
      return const SizedBox.shrink();
    }
    if (_activeTab == _recentTabId) {
      if (_recents.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Недавних стикеров пока нет',
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        );
      }
      return _StickerGrid(
        items: _recents
            .map((r) => _GridEntry(pack: r.pack, sticker: r.sticker))
            .toList(growable: false),
        onPick: _handlePick,
      );
    }
    final pack = _activePack;
    if (pack == null) return const SizedBox.shrink();
    return _StickerGrid(
      items: pack.stickers
          .map((s) => _GridEntry(pack: pack, sticker: s))
          .toList(growable: false),
      onPick: _handlePick,
    );
  }

  Widget _buildTabStrip(ColorScheme scheme) {
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      children: [
        _TabButton(
          active: _activeTab == _recentTabId,
          tooltip: 'Недавние',
          onTap: () => setState(() => _activeTab = _recentTabId),
          child: const Icon(Icons.access_time, size: 20),
        ),
        for (final p in _packs)
          _TabButton(
            active: _activeTab == p.id,
            tooltip: p.name,
            onTap: () => setState(() => _activeTab = p.id),
            child: Text(
              // Use the first sticker's emoji as the pack icon — cheaper
              // than decoding the SVG thumbnail and visually matches the
              // grid contents.
              p.stickers.isNotEmpty && p.stickers.first.emoji.isNotEmpty
                  ? p.stickers.first.emoji
                  : '📦',
              style: const TextStyle(fontSize: 20),
            ),
          ),
      ],
    );
  }
}

class _GridEntry {
  const _GridEntry({required this.pack, required this.sticker});
  final StickerPack pack;
  final Sticker sticker;
}

class _StickerGrid extends StatelessWidget {
  const _StickerGrid({required this.items, required this.onPick});

  final List<_GridEntry> items;
  final Future<void> Function(StickerPack pack, Sticker sticker) onPick;

  @override
  Widget build(BuildContext context) {
    // Responsive column count: phones get 6 cols (~60dp each on 360dp
    // width), tablets go wider. Matches the `grid-cols-6 sm:grid-cols-8`
    // from the JS.
    final w = MediaQuery.of(context).size.width;
    final cols = w >= 600 ? 8 : 6;
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final e = items[i];
        return _StickerCell(
          sticker: e.sticker,
          onTap: () => onPick(e.pack, e.sticker),
        );
      },
    );
  }
}

class _StickerCell extends StatelessWidget {
  const _StickerCell({required this.sticker, required this.onTap});
  final Sticker sticker;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Center(
          // LayoutBuilder so the emoji scales with the cell — picks the
          // larger of the two dims so landscape cells still render
          // legibly. `FittedBox` would squish the emoji; explicit font
          // sizing is sharper.
          child: LayoutBuilder(
            builder: (ctx, cons) {
              final side = cons.maxWidth < cons.maxHeight
                  ? cons.maxWidth
                  : cons.maxHeight;
              return Text(
                sticker.emoji.isNotEmpty ? sticker.emoji : '🖼',
                style: TextStyle(fontSize: side * 0.7),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.active,
    required this.onTap,
    required this.child,
    this.tooltip,
  });

  final bool active;
  final VoidCallback onTap;
  final Widget child;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final btn = Material(
      color: active
          ? scheme.primary.withValues(alpha: 0.18)
          : scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: active
                  ? scheme.primary.withValues(alpha: 0.5)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    );
    if (tooltip == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: btn,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Tooltip(message: tooltip, child: btn),
    );
  }
}

