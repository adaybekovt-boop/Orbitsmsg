// Settings → Уведомления.
//
// Mirrors `screen === 'notifications'` from JS Settings: a status row
// for the browser permission, plus a toggle for in-app sounds and a
// note that native push lands later.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../themes/orbits_tokens.dart';
import '../../ui/primitives/orbits_glass_list_tile.dart';
import '../../ui/primitives/adaptive_page_frame.dart';
import '../../ui/primitives/orbits_glass_app_bar.dart';
import '../../ui/primitives/orbits_glass_switch.dart';

const _kNotifPrefsKey = 'orbits_notif_prefs_v1';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  bool _enabled = true;
  bool _showPreview = true;
  bool _sound = true;
  bool _vibration = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kNotifPrefsKey);
    if (raw != null) {
      try {
        final m = jsonDecode(raw);
        if (m is Map) {
          _enabled = m['enabled'] != false;
          _showPreview = m['showPreview'] != false;
          _sound = m['sound'] != false;
          _vibration = m['vibration'] != false;
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _kNotifPrefsKey,
      jsonEncode({
        'enabled': _enabled,
        'showPreview': _showPreview,
        'sound': _sound,
        'vibration': _vibration,
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Scaffold(
      appBar: OrbitsGlassAppBar(
        title: Text(
          'Уведомления',
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
          // ── Permission ────────────────────────────────────────
          const _SectionLabel('Разрешение системы'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: OrbitsGlassListTile(
              leading: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: tokens.accentAlpha(0.16),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: tokens.accentAlpha(0.22)),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.notifications_active,
                    color: tokens.text, size: 18),
              ),
              title: const Text('Статус разрешения'),
              subtitle: const Text(
                'Native push появится после релиза. Сейчас работают '
                'только in-app звуки и вибрация.',
              ),
            ),
          ),

          // ── In-app preferences ───────────────────────────────
          const _SectionLabel('In-app'),
          _ToggleRow(
            icon: Icons.notifications_outlined,
            label: 'Уведомления включены',
            subtitle: _enabled
                ? 'Звук + вибрация при новом сообщении в активном чате'
                : 'Все уведомления отключены',
            value: _enabled,
            onChanged: !_loaded
                ? null
                : (v) {
                    setState(() => _enabled = v);
                    _save();
                  },
          ),
          _ToggleRow(
            icon: Icons.volume_up_outlined,
            label: 'Звук',
            subtitle: 'Тихий «динь» при получении',
            value: _sound,
            onChanged: (!_loaded || !_enabled)
                ? null
                : (v) {
                    setState(() => _sound = v);
                    _save();
                  },
          ),
          _ToggleRow(
            icon: Icons.vibration,
            label: 'Вибрация',
            subtitle: 'Только на телефонах',
            value: _vibration,
            onChanged: (!_loaded || !_enabled)
                ? null
                : (v) {
                    setState(() => _vibration = v);
                    _save();
                  },
          ),
          _ToggleRow(
            icon: Icons.visibility_outlined,
            label: 'Предпросмотр в шторке',
            subtitle: _enabled
                ? 'Показывать текст сообщения, а не «новое сообщение»'
                : 'Сначала включи уведомления',
            value: _showPreview,
            onChanged: (!_loaded || !_enabled)
                ? null
                : (v) {
                    setState(() => _showPreview = v);
                    _save();
                  },
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
