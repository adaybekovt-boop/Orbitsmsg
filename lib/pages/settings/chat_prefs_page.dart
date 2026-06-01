// Settings → Чаты.
//
// All the per-conversation behaviour toggles, plus the bubble-style /
// font-size pickers from `src/components/ChatSettings.jsx`. Stored under
// `orbits_chat_prefs_v1` in SharedPreferences — same key the message
// renderer reads, so the toggles affect message UI immediately.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../themes/orbits_tokens.dart';
import '../../ui/primitives/orbits_glass_button.dart';
import '../../ui/primitives/orbits_glass_list_tile.dart';
import '../../ui/primitives/adaptive_page_frame.dart';
import '../../ui/primitives/orbits_glass_surface.dart';
import '../../ui/primitives/orbits_glass_switch.dart';

const _kChatPrefsKey = 'orbits_chat_prefs_v1';

class ChatPrefs {
  const ChatPrefs({
    this.showSeconds = false,
    this.autoRead = true,
    this.messageSounds = true,
    this.vibration = true,
    this.fontSize = 'M',
    this.bubbleStyle = 'rounded',
  });

  final bool showSeconds;
  final bool autoRead;
  final bool messageSounds;
  final bool vibration;

  /// One of: 'XS', 'S', 'M', 'L', 'XL'.
  final String fontSize;

  /// One of: 'rounded', 'soft', 'square', 'bubble'.
  final String bubbleStyle;

  ChatPrefs copyWith({
    bool? showSeconds,
    bool? autoRead,
    bool? messageSounds,
    bool? vibration,
    String? fontSize,
    String? bubbleStyle,
  }) =>
      ChatPrefs(
        showSeconds: showSeconds ?? this.showSeconds,
        autoRead: autoRead ?? this.autoRead,
        messageSounds: messageSounds ?? this.messageSounds,
        vibration: vibration ?? this.vibration,
        fontSize: fontSize ?? this.fontSize,
        bubbleStyle: bubbleStyle ?? this.bubbleStyle,
      );
}

class ChatPrefsPage extends StatefulWidget {
  const ChatPrefsPage({super.key});

  @override
  State<ChatPrefsPage> createState() => _ChatPrefsPageState();
}

class _ChatPrefsPageState extends State<ChatPrefsPage> {
  ChatPrefs _prefs = const ChatPrefs();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kChatPrefsKey);
    if (raw != null) {
      try {
        final m = jsonDecode(raw);
        if (m is Map) {
          _prefs = ChatPrefs(
            showSeconds: m['showSeconds'] == true,
            autoRead: m['autoRead'] != false,
            messageSounds: m['messageSounds'] != false,
            vibration: m['vibration'] != false,
            fontSize: (m['fontSize'] as String?) ?? 'M',
            bubbleStyle: (m['bubbleStyle'] as String?) ?? 'rounded',
          );
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _save(ChatPrefs next) async {
    setState(() => _prefs = next);
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _kChatPrefsKey,
      jsonEncode({
        'showSeconds': next.showSeconds,
        'autoRead': next.autoRead,
        'messageSounds': next.messageSounds,
        'vibration': next.vibration,
        'fontSize': next.fontSize,
        'bubbleStyle': next.bubbleStyle,
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
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
          // ── Behaviour ────────────────────────────────────────
          const _SectionLabel('Поведение'),
          _ToggleRow(
            icon: Icons.timer_outlined,
            label: 'Показывать секунды',
            subtitle: 'Время сообщений в формате ЧЧ:ММ:СС',
            value: _prefs.showSeconds,
            onChanged: !_loaded
                ? null
                : (v) => _save(_prefs.copyWith(showSeconds: v)),
          ),
          _ToggleRow(
            icon: Icons.mark_chat_read_outlined,
            label: 'Авто-прочтение',
            subtitle: 'Помечать сообщения прочитанными при открытии чата',
            value: _prefs.autoRead,
            onChanged: !_loaded
                ? null
                : (v) => _save(_prefs.copyWith(autoRead: v)),
          ),
          _ToggleRow(
            icon: Icons.volume_up_outlined,
            label: 'Звуки сообщений',
            subtitle: 'Тихий «динь» при получении',
            value: _prefs.messageSounds,
            onChanged: !_loaded
                ? null
                : (v) => _save(_prefs.copyWith(messageSounds: v)),
          ),
          _ToggleRow(
            icon: Icons.vibration,
            label: 'Вибрация',
            subtitle: 'Короткое касание при новом сообщении',
            value: _prefs.vibration,
            onChanged: !_loaded
                ? null
                : (v) => _save(_prefs.copyWith(vibration: v)),
          ),

          // ── Bubble style ─────────────────────────────────────
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
                          selected: _prefs.bubbleStyle == style.$1,
                          size: OrbitsGlassSize.small,
                          onPressed: !_loaded
                              ? null
                              : () => _save(
                                  _prefs.copyWith(bubbleStyle: style.$1)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Применяется ко всем чатам. Конкретный чат может быть '
                    'переопределён через его настройки.',
                    style: TextStyle(
                      fontSize: 12,
                      color: tokens.muted,
                      fontFamily: tokens.fontBody,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Font size ────────────────────────────────────────
          const _SectionLabel('Размер шрифта'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: OrbitsGlassSurface(
              role: OrbitsGlassRole.card,
              borderRadius: BorderRadius.circular(tokens.radiusCard),
              padding: const EdgeInsets.all(14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final size in const ['XS', 'S', 'M', 'L', 'XL'])
                    _SizeButton(
                      label: size,
                      selected: _prefs.fontSize == size,
                      onTap: !_loaded
                          ? null
                          : () => _save(_prefs.copyWith(fontSize: size)),
                      tokens: tokens,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
      ),
    );
  }
}

/// One toggle row inside a settings group — leading glyph, label + subtitle,
/// and a glass switch on the trailing edge. Each row is its own glass card so
/// the list reads as a stack of discrete Liquid-Glass plates.
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
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: OrbitsGlassListTile(
        onTap: onChanged == null ? null : () => onChanged!(!value),
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

/// Section label above each settings group — uppercase monospace caps, muted.
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
  final VoidCallback? onTap;
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
