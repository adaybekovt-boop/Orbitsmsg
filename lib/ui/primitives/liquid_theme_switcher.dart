import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../themes/orbits_tokens.dart';
import '../../themes/theme_notifier.dart';
import 'orbits_glass_surface.dart';
import 'orbits_liquid_optics.dart';

/// React `LiquidThemeSwitcher` — sliding glass pill over moon / sun.
class LiquidThemeSwitcher extends ConsumerStatefulWidget {
  const LiquidThemeSwitcher({super.key, this.compact = false});

  final bool compact;

  @override
  ConsumerState<LiquidThemeSwitcher> createState() =>
      _LiquidThemeSwitcherState();
}

class _LiquidThemeSwitcherState extends ConsumerState<LiquidThemeSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final target = isDark ? 0.0 : 1.0;
    if ((_slide.value - target).abs() < 0.001) return;
    if (reduce) {
      _slide.value = target;
    } else {
      _slide.animateTo(target, curve: const Cubic(0.34, 1.45, 0.64, 1));
    }
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final h = widget.compact ? 32.0 : 38.0;
    final opt = widget.compact ? 28.0 : 32.0;
    final icon = widget.compact ? 15.0 : 17.0;

    return Semantics(
      container: true,
      label: 'Переключение темы оформления',
      child: OrbitsGlassSurface(
        role: OrbitsGlassRole.pill,
        realBlur: true,
        refract: true,
        refractionStrength: 0.18,
        borderRadius: BorderRadius.circular(999),
        padding: EdgeInsets.all(widget.compact ? 2.5 : 3),
        child: SizedBox(
          height: h - (widget.compact ? 5 : 6),
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              AnimatedBuilder(
                animation: _slide,
                builder: (context, _) {
                  final stretch = reduce
                      ? 1.0
                      : 1.0 + 0.18 * (1 - (2 * _slide.value - 1).abs());
                  return Transform.translate(
                    offset: Offset(_slide.value * (opt + 2), 0),
                    child: Transform.scale(
                      scaleX: stretch,
                      scaleY: 2 - stretch,
                      child: _Pill(
                        width: opt,
                        height: h - (widget.compact ? 7 : 8),
                        tokens: tokens,
                        isDark: isDark,
                      ),
                    ),
                  );
                },
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Opt(
                    selected: isDark,
                    size: opt,
                    iconSize: icon,
                    icon: Icons.dark_mode_outlined,
                    label: 'Тёмная тема',
                    onTap: () => ref
                        .read(themeNotifierProvider.notifier)
                        .setThemeId('orbits-dark'),
                  ),
                  _Opt(
                    selected: !isDark,
                    size: opt,
                    iconSize: icon,
                    icon: Icons.light_mode_outlined,
                    label: 'Светлая тема',
                    onTap: () => ref
                        .read(themeNotifierProvider.notifier)
                        .setThemeId('orbits-light'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.width,
    required this.height,
    required this.tokens,
    required this.isDark,
  });

  final double width;
  final double height;
  final OrbitsTokens tokens;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final mode = OrbitsLiquidOptics.instance.refractionReady
        ? OrbitsGlassOpticsMode.refraction
        : OrbitsGlassOpticsMode.blurFallback;
    return Tooltip(
      message: mode == OrbitsGlassOpticsMode.refraction
          ? 'Жидкое стекло: преломление фона'
          : 'Жидкое стекло: blur-fallback',
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: isDark ? const Color(0x73242424) : const Color(0xE0FFFFFF),
          border: Border.all(
            color: isDark ? const Color(0x59FFFFFF) : const Color(0xE6FFFFFF),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.12),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: SizedBox(
          width: width,
          height: height,
          child: CustomPaint(painter: _PillOptics(isDark: isDark)),
        ),
      ),
    );
  }
}

class _PillOptics extends CustomPainter {
  _PillOptics({required this.isDark});
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = RRect.fromRectAndRadius(rect, const Radius.circular(999));
    canvas.drawRRect(
      r.deflate(1),
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.1, -0.6),
          radius: 0.9,
          colors: [
            Colors.white.withValues(alpha: isDark ? 0.28 : 0.7),
            Colors.transparent,
          ],
        ).createShader(rect),
    );
    canvas.drawLine(
      Offset(size.width * 0.28, 3),
      Offset(size.width * 0.72, 3),
      Paint()
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [
            Colors.transparent,
            Colors.white.withValues(alpha: 0.75),
            Colors.transparent,
          ],
        ).createShader(Rect.fromLTWH(0, 0, size.width, 6)),
    );
  }

  @override
  bool shouldRepaint(_PillOptics old) => old.isDark != isDark;
}

class _Opt extends StatelessWidget {
  const _Opt({
    required this.selected,
    required this.size,
    required this.iconSize,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool selected;
  final double size;
  final double iconSize;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final color = selected ? tokens.text : tokens.muted;
    return SizedBox(
      width: size,
      height: size - 2,
      child: IconButton(
        tooltip: label,
        padding: EdgeInsets.zero,
        onPressed: onTap,
        icon: Icon(icon, size: iconSize, color: color),
      ),
    );
  }
}
