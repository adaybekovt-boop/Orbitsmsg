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

import '../../peer/helpers.dart';
import '../../state/auth_notifier.dart';
import '../../state/auto_lock_provider.dart';
import '../../state/remembered_session_io.dart'
    if (dart.library.html) '../../state/remembered_session_web.dart'
    as remembered;
import '../../state/strict_verify_provider.dart';
import '../../themes/orbits_tokens.dart';
import '../../ui/primitives/orbits_glass_list_tile.dart';
import '../../ui/primitives/adaptive_page_frame.dart';
import '../../ui/primitives/orbits_glass_app_bar.dart';
import '../../ui/primitives/orbits_glass_switch.dart';
import '../../ui/primitives/orbs_card.dart';

const Key kCryptoE2eOnBadgeKey = Key('crypto-e2e-on');
const Key kCryptoRoomsOffBadgeKey = Key('crypto-rooms-off');

class SecurityPage extends ConsumerStatefulWidget {
  const SecurityPage({super.key});

  @override
  ConsumerState<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends ConsumerState<SecurityPage> {
  bool? _biometricUnlock;
  bool _biometricSupported = false;
  // True where auto-login via "Запомнить меня" exists (desktop OS-backed secure
  // storage, or web with a secure context). Drives the access-row copy so we
  // don't claim "always password" on a device that can actually auto-unlock.
  bool _rememberSupported = false;
  bool? _relayOnly;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final relay = await isRelayOnlyEnabled();
    final bioSupported = ref.read(autoUnlockServiceProvider).isSupported;
    final bioEnabled = bioSupported
        ? await ref.read(authNotifierProvider.notifier).biometricUnlockEnabled()
        : false;
    final rememberSupported = await remembered.isRememberSupported();
    if (!mounted) return;
    setState(() {
      _relayOnly = relay;
      _biometricSupported = bioSupported;
      _biometricUnlock = bioEnabled;
      _rememberSupported = rememberSupported;
    });
  }

  Future<void> _toggleBiometric(bool v) async {
    setState(() => _biometricUnlock = v);
    final ok =
        await ref.read(authNotifierProvider.notifier).setBiometricUnlock(v);
    if (!mounted) return;
    if (v && !ok) {
      // Enabling failed — vault locked or platform can't store the key.
      setState(() => _biometricUnlock = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Не удалось включить биометрию. Разблокируйте профиль и повторите.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final strictVerify = ref.watch(strictVerifyProvider);
    final autoLock = ref.watch(autoLockProvider).enabled;
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
                autoLock
                    ? 'Запрашивать пароль после 5 минут без действий или при '
                        'возвращении из фона. Данные не удаляются.'
                    : 'Профиль остаётся открытым, пока работает приложение',
              ),
              trailing: OrbitsGlassSwitch(
                value: autoLock,
                semanticLabel: 'Блокировка приложения',
                onChanged: (v) =>
                    ref.read(autoLockProvider.notifier).setEnabled(v),
              ),
            ),
          ),
          // Biometric unlock — the honest replacement for the old
          // "remember password" toggle. The password is NEVER stored; on
          // supported devices the vault key lives in the OS biometric keystore.
          // Off-mobile there's no hardware biometric keystore, but desktop (and
          // web) CAN still auto-login via "Запомнить меня" at sign-in (the KEK
          // in OS-backed secure storage), so we describe that instead of
          // claiming the device always asks for the password.
          if (_biometricSupported)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: OrbitsGlassListTile(
                leading: Icon(Icons.fingerprint, color: tokens.text),
                title: const Text('Вход по биометрии'),
                subtitle: Text(
                  _biometricUnlock == true
                      ? 'При запуске вход по Face ID / отпечатку. Пароль не '
                          'хранится — ключ защищён биометрией устройства.'
                      : 'Входить по Face ID / отпечатку вместо пароля. Ключ '
                          'хранится в защищённом хранилище устройства.',
                ),
                trailing: OrbitsGlassSwitch(
                  value: _biometricUnlock ?? false,
                  semanticLabel: 'Вход по биометрии',
                  onChanged: _biometricUnlock == null ? null : _toggleBiometric,
                ),
              ),
            )
          else if (_rememberSupported)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: OrbitsGlassListTile(
                leading: Icon(Icons.vpn_key_outlined, color: tokens.text),
                title: const Text('Автоматический вход'),
                subtitle: const Text(
                  'Отметьте «Запомнить меня» при входе, чтобы открывать профиль '
                  'без пароля. Ключ хранится в защищённом хранилище системы, '
                  'сам пароль не сохраняется.',
                ),
                trailing: _MutedChip(label: 'ПРИ ВХОДЕ', tokens: tokens),
              ),
            )
          else
            Opacity(
              opacity: 0.6,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: OrbitsGlassListTile(
                  leading: Icon(Icons.fingerprint, color: tokens.muted),
                  title: const Text('Вход по биометрии'),
                  subtitle: const Text(
                    'Доступно на телефоне с настроенной биометрией. На этом '
                    'устройстве вход всегда выполняется по паролю.',
                  ),
                  trailing: _MutedChip(label: 'ТЕЛЕФОН', tokens: tokens),
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

          // ── Technical details ────────────────────────────────
          const OrbsSectionTitle('Технические детали'),
          const _CryptoRow(
            title: 'AES-256-GCM',
            subtitle:
                'Личные чаты — Double Ratchet. Ключи в памяти приложения, не в Secure Enclave / Keystore',
          ),
          const _CryptoRow(
            title: 'PBKDF2 + scrypt',
            subtitle: 'Мастер-ключ из пароля. Подбор перебором — годы',
          ),
          const _CryptoRow(
            title: 'X3DH + Double Ratchet',
            subtitle: 'Сессионные ключи на каждое сообщение в личном чате',
          ),
          const _CryptoRow(
            title: 'Комнаты',
            subtitle:
                'Без сквозного шифрования — хост видит содержимое',
            e2eOn: false,
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
    this.e2eOn = true,
  });

  final String title;
  final String subtitle;
  final bool e2eOn;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final badgeColor = e2eOn ? tokens.success : tokens.danger;
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
          key: e2eOn ? kCryptoE2eOnBadgeKey : kCryptoRoomsOffBadgeKey,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: badgeColor.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            e2eOn ? 'ВКЛ' : 'НЕТ E2E',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              fontFamily: tokens.fontMono,
              color: badgeColor,
              letterSpacing: 1.0,
            ),
          ),
        ),
      ),
    );
  }
}

/// Small muted pill used to mark a row as available elsewhere (e.g. phone-only).
class _MutedChip extends StatelessWidget {
  const _MutedChip({required this.label, required this.tokens});

  final String label;
  final OrbitsTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tokens.muted.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          fontFamily: tokens.fontMono,
          color: tokens.muted,
          letterSpacing: 1.0,
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
