// Settings → Микрофон.
//
// Placeholder until we wire up the call provider's mic-config sub-state.
// JS exposes echo cancellation, noise suppression, AGC + a level test
// meter. Those need a streaming `record` / `webrtc` audio analyser.
// For the MVP we just surface the existing voice-recorder mic — settings
// land in 0.1.1 alongside the full call overlay.

import 'package:flutter/material.dart';

import '../../themes/orbits_tokens.dart';
import '../../ui/primitives/orbits_glass_button.dart';
import '../../ui/primitives/orbits_glass_app_bar.dart';
import '../../ui/primitives/orbits_glass_surface.dart';

class MicPage extends StatelessWidget {
  const MicPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Scaffold(
      appBar: OrbitsGlassAppBar(
        leading: Navigator.of(context).canPop()
            ? Center(
                child: OrbitsGlassIconButton(
                  icon: Icons.arrow_back,
                  tooltip: 'Назад',
                  variant: OrbitsGlassVariant.subtle,
                  size: OrbitsGlassSize.small,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              )
            : null,
        title: Text(
          'Микрофон',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: OrbitsGlassSurface(
              role: OrbitsGlassRole.card,
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: tokens.accentAlpha(0.18),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.mic_none, color: tokens.accent, size: 28),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Настройки микрофона',
                    style: TextStyle(
                      fontFamily: tokens.fontHeading,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: tokens.text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Эхо-подавление, шумоподавление, авто-усиление и тест '
                    'уровня появятся вместе с экраном звонка в обновлении.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: tokens.fontBody,
                      fontSize: 13,
                      color: tokens.muted,
                      height: 1.45,
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
