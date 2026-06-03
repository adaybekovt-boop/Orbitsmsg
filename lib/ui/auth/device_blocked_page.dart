// Shown when the device-access gate (`device_access_web.dart`) reports a
// blocked mobile phone. This is a fallback: the primary block message is HTML
// rendered by `web/index.html` *before* the Flutter bundle loads. The user
// only reaches this screen if the bundle ran anyway (cached entry, SPA nav).
//
// Kept dependency-light and self-contained so it renders correctly even if
// theme/profile bootstrap hasn't finished.

import 'package:flutter/material.dart';

class DeviceBlockedPage extends StatelessWidget {
  const DeviceBlockedPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.desktop_windows_outlined,
                      size: 32,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'Доступ с мобильных устройств запрещён',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Веб-версия Orbits недоступна на телефонах. '
                    'Пожалуйста, откройте сайт с компьютера или ноутбука.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.5,
                        ),
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
