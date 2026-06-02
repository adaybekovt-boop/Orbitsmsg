// Standalone Terms / Privacy page — opened from Settings → О приложении
// → «Соглашение и конфиденциальность» so a returning user can re-read
// the document any time after onboarding.
//
// Just a Scaffold + TermsView. The same widget is reused inside the
// onboarding wizard's 4th step.

import 'package:flutter/material.dart';

import '../../themes/orbits_tokens.dart';
import '../../ui/auth/terms_text.dart';
import '../../ui/primitives/adaptive_page_frame.dart';
import '../../ui/primitives/orbits_glass_app_bar.dart';

class TermsPage extends StatelessWidget {
  const TermsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Scaffold(
      appBar: OrbitsGlassAppBar(
        title: Text(
          'Соглашение',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: const AdaptivePageFrame(child: TermsView()),
    );
  }
}
