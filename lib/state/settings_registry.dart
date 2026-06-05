// Settings honesty registry — the single source of truth for "what every
// visible setting is and whether it actually does something".
//
// This exists to prevent fake settings from creeping back in. Each visible
// setting is classified, and persisted settings name BOTH their storage key and
// their runtime consumer. The accompanying test
// (test/settings/settings_registry_test.dart) enforces:
//   • working / platform-limited settings that persist MUST name a consumer
//     (so "saved but never read" can't pass review);
//   • coming-soon settings persist NOTHING and have NO consumer (honest);
//   • settings pages never write SharedPreferences directly — they route
//     through registered providers.

import 'auto_lock_provider.dart' show kAutoLockPrefKey;
import 'auto_unlock_service.dart' show kBiometricUnlockPrefKey;
import 'chat_prefs_provider.dart' show kChatPrefsKey;
import 'power_saver_provider.dart' show kPowerSaverPrefKey;

enum SettingStatus {
  /// Works end-to-end on supported platforms.
  working,

  /// Works only where the platform allows it; otherwise an honest disabled UI.
  platformLimited,

  /// Not implemented yet — shown as a clearly disabled "СКОРО" row, persists
  /// nothing, has no runtime consumer.
  comingSoon,
}

class SettingDescriptor {
  const SettingDescriptor({
    required this.id,
    required this.title,
    required this.status,
    this.persistKey,
    this.consumer,
  });

  /// Stable identifier (group.name).
  final String id;

  /// Human title (RU), for docs/diagnostics.
  final String title;

  final SettingStatus status;

  /// SharedPreferences key, when the setting persists. Null when it doesn't.
  final String? persistKey;

  /// Where the persisted value actually changes runtime behavior. Must be
  /// non-null for any persisted working/platform-limited setting.
  final String? consumer;
}

/// Every setting reachable from Settings, classified.
const List<SettingDescriptor> kSettingsRegistry = [
  SettingDescriptor(
    id: 'appearance.theme',
    title: 'Внешний вид — тема',
    status: SettingStatus.working,
    persistKey: 'orbits_theme',
    consumer: 'theme_notifier.dart → MaterialApp theme',
  ),
  SettingDescriptor(
    id: 'security.biometricUnlock',
    title: 'Вход по биометрии',
    status: SettingStatus.platformLimited,
    persistKey: kBiometricUnlockPrefKey,
    consumer: 'auth_notifier._tryBiometricUnlock (mobile only)',
  ),
  SettingDescriptor(
    id: 'security.autoLock',
    title: 'Блокировка приложения',
    status: SettingStatus.working,
    persistKey: kAutoLockPrefKey,
    consumer: 'auto_lock_scope.dart → AuthNotifier.lock',
  ),
  SettingDescriptor(
    id: 'security.hideIp',
    title: 'Скрывать IP (только ретранслятор)',
    status: SettingStatus.working,
    persistKey: 'orbits_relay_only',
    consumer: 'peer/helpers.dart → WebRTC ICE policy',
  ),
  SettingDescriptor(
    id: 'security.strictVerify',
    title: 'Строгая проверка контактов',
    status: SettingStatus.working,
    persistKey: 'orbits_strict_verify_v1',
    consumer: 'chat_view_page.dart → unverified-chat gate',
  ),
  SettingDescriptor(
    id: 'security.wipeOnClose',
    title: 'Очистка при выходе',
    status: SettingStatus.comingSoon,
  ),
  SettingDescriptor(
    id: 'security.duress',
    title: 'Тревожный пароль',
    status: SettingStatus.comingSoon,
  ),
  SettingDescriptor(
    id: 'chat.appearance',
    title: 'Чаты — вид (шрифт / форма пузыря / секунды)',
    status: SettingStatus.working,
    persistKey: kChatPrefsKey,
    consumer: 'message_bubble.dart (textScale / bubbleStyle / showSeconds)',
  ),
  SettingDescriptor(
    id: 'chat.autoRead',
    title: 'Авто-прочтение',
    status: SettingStatus.comingSoon,
  ),
  SettingDescriptor(
    id: 'chat.messageSounds',
    title: 'Звуки сообщений',
    status: SettingStatus.comingSoon,
  ),
  SettingDescriptor(
    id: 'chat.vibration',
    title: 'Вибрация при сообщении',
    status: SettingStatus.comingSoon,
  ),
  SettingDescriptor(
    id: 'powerSaver',
    title: 'Энергосбережение (лёгкий режим)',
    status: SettingStatus.working,
    persistKey: kPowerSaverPrefKey,
    consumer: 'perf_budget.dart → applyPowerSaver (frozen tier)',
  ),
  SettingDescriptor(
    id: 'notifications',
    title: 'Уведомления',
    status: SettingStatus.comingSoon,
  ),
  SettingDescriptor(
    id: 'mic',
    title: 'Микрофон',
    status: SettingStatus.comingSoon,
  ),
  SettingDescriptor(
    id: 'network',
    title: 'Соединение (диагностика)',
    status: SettingStatus.working,
    consumer: 'network_page.dart → live connection/relay state (read-only)',
  ),
  SettingDescriptor(
    id: 'settings.updates',
    title: 'Обновления',
    status: SettingStatus.platformLimited,
    consumer: 'updates_page.dart → update_notifier (check; Windows download + '
        'install flow, release link elsewhere)',
  ),
];
