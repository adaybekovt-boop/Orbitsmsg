import 'package:flutter/material.dart';

import '../../legal/legal_placeholders.dart';
import '../../themes/orbits_tokens.dart';
import '../../ui/primitives/adaptive_page_frame.dart';
import '../../ui/primitives/orbits_glass_app_bar.dart';

/// Slot for counsel-authored offer text. Body is a placeholder on purpose.
class LegalOfferPage extends StatelessWidget {
  const LegalOfferPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Scaffold(
      appBar: OrbitsGlassAppBar(
        title: Text(
          'Оферта',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: AdaptivePageFrame(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            Text(
              'Текст оферты появится после юридической проверки.',
              style: TextStyle(
                fontFamily: tokens.fontBody,
                fontSize: 13,
                height: 1.45,
                color: tokens.muted,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              key: kLegalOfferBodyKey,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: tokens.surface.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(tokens.radiusCard),
                border: Border.all(color: tokens.border),
              ),
              child: Text(
                kLegalPendingPlaceholder,
                style: TextStyle(
                  fontFamily: tokens.fontMono,
                  fontSize: 14,
                  height: 1.5,
                  color: tokens.text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
