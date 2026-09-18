import 'package:flutter/material.dart';

import '../themes/orbits_tokens.dart';
import '../ui/primitives/liquid_glass_sphere.dart';
import '../ui/primitives/orbits_glass_app_bar.dart';

/// React "Избранное" is a demo saved-messages thread. Orbits has no
/// persisted saved-messages feature yet — this screen is the honest
/// unavailable state, not a fake inbox.
class SavedUnavailablePage extends StatelessWidget {
  const SavedUnavailablePage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: OrbitsGlassAppBar(
        title: Text(
          'Избранное',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LiquidGlassSphere(size: 96),
              const SizedBox(height: 20),
              Text(
                'Избранное пока недоступно',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: tokens.fontHeading,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: tokens.text,
                ),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  'Сохранённые сообщения из макета React не подключены: '
                  'в приложении нет отдельного хранилища избранного. '
                  'Чаты и файлы по-прежнему лежат в существующих локальных данных.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: tokens.muted,
                    fontFamily: tokens.fontBody,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
