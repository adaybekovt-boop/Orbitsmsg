// Settings → Безопасность.
//
// Mirrors the JS `screen === 'security'` branch in `src/pages/Settings.jsx`:
//   • Crypto info card (AES-GCM, PBKDF2, ECDH) — informational, no toggles
//   • Auto-lock toggle (vault locks after 5 min idle)
//   • Auto-login toggle (skip the password prompt on launch)
//   • TURN-only / relay-only toggle (paranoid mode)
//   • Blocked-peers list (with unblock buttons)
//
// JS also has Wipe-on-Close + Duress-password + key fingerprint sections;
// those depend on providers we haven't ported yet (lifecycle wipe, dual-
// password store). They land in 0.1.1 — for now their slots are visible
// but disabled with a "В разработке" hint, so the user knows the feature
// will exist without us silently dropping it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../peer/helpers.dart';
import '../../state/strict_verify_provider.dart';
import '../../themes/orbits_tokens.dart';
import '../qr_pairing_page.dart';
import '../../ui/primitives/orbits_glass_list_tile.dart';
import '../../ui/primitives/adaptive_page_frame.dart';
import '../../ui/primitives/orbits_glass_app_bar.dart';
import '../../ui/primitives/orbits_glass_switch.dart';
import '../../ui/primitives/orbs_card.dart';

class SecurityPage extends ConsumerStatefulWidget {
  const SecurityPage({super.key});

  @override
  ConsumerState<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends ConsumerState<SecurityPage> {
  bool? _autoLock;
  bool? _autoLogin;
  bool? _relayOnly;

  static const _kAutoLockKey = 'orbits_auto_lock';
  static const _kAutoLoginKey = 'orbits_auto_login';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final relay = await isRelayOnlyEnabled();
    if (!mounted) return;
    setState(() {
      _autoLock = prefs.getString(_kAutoLockKey) == '1';
      _autoLogin = prefs.getString(_kAutoLoginKey) == '1';
      _relayOnly = relay;
    });
  }

  Future<void> _save(String key, bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, v ? '1' : '0');
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final strictVerify = ref.watch(strictVerifyProvider);
    return Scaffold(
      appBar: OrbitsGlassAppBar(
        title: Text(
          'Защита профиля',
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
          // ── Lock & login ─────────────────────────────────────
          const OrbsSectionTitle('Доступ'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: OrbitsGlassListTile(
              leading: Icon(Icons.lock_clock_outlined, color: tokens.text),
              title: const Text('Блокировка приложения'),
              subtitle: Text(
                _autoLock == true
                    ? 'Приложение запросит пароль через 5 минут без действий'
                    : 'Профиль остаётся открытым пока работает приложение',
              ),
              trailing: OrbitsGlassSwitch(
                value: _autoLock ?? false,
                semanticLabel: 'Блокировка приложения',
                onChanged: _autoLock == null
                    ? null
                    : (v) {
                        setState(() => _autoLock = v);
                        _save(_kAutoLockKey, v);
                      },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: OrbitsGlassListTile(
              leading: Icon(Icons.login_outlined, color: tokens.text),
              title: const Text('Запоминать пароль'),
              subtitle: Text(
                _autoLogin == true
                    ? 'Вход без пароля при запуске. Удобно, но менее безопасно'
                    : 'Запрашивать пароль при каждом запуске',
              ),
              trailing: OrbitsGlassSwitch(
                value: _autoLogin ?? false,
                semanticLabel: 'Запоминать пароль',
                onChanged: _autoLogin == null
                    ? null
                    : (v) {
                        setState(() => _autoLogin = v);
                        _save(_kAutoLoginKey, v);
                      },
              ),
            ),
          ),

          // ── Network privacy ──────────────────────────────────
          const OrbsSectionTitle('Приватность'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: OrbitsGlassListTile(
              leading: Icon(Icons.vpn_lock_outlined, color: tokens.text),
              title: const Text('Скрывать мой IP-адрес'),
              subtitle: const Text(
                'Звонки и файлы идут через промежуточный сервер, '
                'и собеседник не видит твой IP-адрес. Может немного '
                'снижать качество звонков.',
              ),
              trailing: OrbitsGlassSwitch(
                value: _relayOnly ?? false,
                semanticLabel: 'Скрывать мой IP-адрес',
                onChanged: _relayOnly == null
                    ? null
                    : (v) async {
                        setState(() => _relayOnly = v);
                        await setRelayOnlyEnabled(v);
                      },
              ),
            ),
          ),

          // ── Contact verification ─────────────────────────────
          const OrbsSectionTitle('Контакты'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: OrbitsGlassListTile(
              leading: Icon(Icons.verified_user_outlined, color: tokens.text),
              title: const Text('Строгая проверка контактов'),
              subtitle: Text(
                strictVerify
                    ? 'Переписка с новым контактом откроется только после того, '
                        'как вы сверите код безопасности и подтвердите личность'
                    : 'Переписка открывается сразу. Статус проверки виден по '
                        'значку рядом с именем',
              ),
              trailing: OrbitsGlassSwitch(
                value: strictVerify,
                semanticLabel: 'Строгая проверка контактов',
                onChanged: (v) => ref.read(strictVerifyProvider.notifier).set(v),
              ),
            ),
          ),

          // ── Device linking (QR login) ────────────────────────
          const OrbsSectionTitle('Связь устройств'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: OrbitsGlassListTile(
              leading:
                  Icon(Icons.qr_code_scanner_rounded, color: tokens.text),
              title: const Text('Войти на ПК'),
              subtitle: const Text(
                'Отсканируйте QR-код на компьютере, чтобы войти в свой профиль '
                'там. Вход подтверждается вашим личным ключом.',
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const QrScanPage()),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: OrbitsGlassListTile(
              leading: Icon(Icons.qr_code_2_rounded, color: tokens.text),
              title: const Text('Показать QR для входа'),
              subtitle: const Text(
                'Покажите этот код, чтобы войти с компьютера, отсканировав '
                'его телефоном.',
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const QrPairingPage()),
              ),
            ),
          ),

          // ── Coming soon stubs ───────────────────────────────
          const OrbsSectionTitle('В разработке'),
          const _ComingSoonRow(
            icon: Icons.no_encryption_gmailerrorred_outlined,
            label: 'Очистка при выходе',
            subtitle: 'Удалять все данные при закрытии. Режим инкогнито.',
          ),
          const _ComingSoonRow(
            icon: Icons.password_outlined,
            label: 'Тревожный пароль',
            subtitle: 'Отдельный пароль — открывает пустой профиль',
          ),
          const _ComingSoonRow(
            icon: Icons.fingerprint,
            label: 'Биометрия',
            subtitle: 'Face ID или отпечаток вместо пароля',
          ),

          // ── Technical details ────────────────────────────────
          const OrbsSectionTitle('Технические детали'),
          const _CryptoRow(
            title: 'AES-256-GCM',
            subtitle: 'Все сообщения зашифрованы, ключи неэкспортируемые',
          ),
          const _CryptoRow(
            title: 'PBKDF2 + scrypt',
            subtitle: 'Мастер-ключ из пароля. Подбор перебором — годы',
          ),
          const _CryptoRow(
            title: 'X3DH + Double Ratchet',
            subtitle: 'Сессионные ключи на каждое сообщение',
          ),
          const SizedBox(height: 24),
        ],
      ),
      ),
    );
  }
}

class _CryptoRow extends StatelessWidget {
  const _CryptoRow({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: OrbitsGlassListTile(
        leading: Icon(Icons.shield_outlined, color: tokens.text),
        title: Text(
          title,
          style: TextStyle(
            fontFamily: tokens.fontMono,
            color: tokens.text,
          ),
        ),
        subtitle: Text(subtitle),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: tokens.success.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            'ВКЛ',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              fontFamily: tokens.fontMono,
              color: tokens.success,
              letterSpacing: 1.0,
            ),
          ),
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
          leading: Icon(icon, color: tokens.muted),
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
