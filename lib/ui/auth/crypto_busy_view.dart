// Full-screen "working" view shown while scrypt derives (onboarding) or
// verifies (unlock) the vault key.
//
// On native this animates normally (the KDF runs on a background isolate). On
// web the main thread is blocked during scrypt, so a compositor-driven CSS
// overlay (see keygen_overlay_web) is layered on top — this view is what sits
// underneath. Kept deliberately calm and explicit so the wait never reads as a
// frozen screen.

import 'package:flutter/material.dart';

import '../../themes/orbits_tokens.dart';

class CryptoBusyView extends StatelessWidget {
  const CryptoBusyView({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: tokens.accent,
                ),
              ),
              const SizedBox(height: 26),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: tokens.fontHeading,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: tokens.text,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: tokens.fontBody,
                  fontSize: 13,
                  height: 1.5,
                  color: tokens.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
