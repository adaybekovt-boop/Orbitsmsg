// Port of `src/main.jsx` + top of `src/App.jsx` — app bootstrap.
//
// React's `main.jsx` wired up the provider chain:
//   MotionConfig > ThemeProvider > AuthProvider > ErrorBoundary > App
// Flutter's ProviderScope is the Riverpod equivalent root, and individual
// concerns (theme, auth, call overlay) will be migrated piece by piece as
// each of those React contexts gets ported. For the initial UI shell slice
// we only need:
//   - WidgetsFlutterBinding init before anything hits a platform channel
//   - installDriftKeyStore() so crypto hits the real on-disk store
//   - ProviderScope as the Riverpod root
//   - MaterialApp → AppShell (the 4-tab bottom nav)
//
// Theme, auth, and the global error boundary will land in later slices —
// they're intentionally out of scope for the skeleton.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/pointycastle_cryptography.dart';
import 'storage/db.dart' as db;
import 'storage/db_health.dart';
import 'storage/drift_key_store.dart';
import 'storage/drift_sticker_store.dart';
import 'themes/theme_data_factory.dart';
import 'themes/theme_notifier.dart';
import 'ui/auth/auth_gate.dart';

Future<void> main() async {
  // Binding first — required before anything that hits a platform channel
  // (path_provider lookups inside Drift / flutter_secure_storage).
  WidgetsFlutterBinding.ensureInitialized();

  // VM/desktop: DartEcdh/DartEcdsa.newKeyPair is unimplemented. Wire
  // handshake must mint P-256 keys here or 1:1 text stays pending.
  installPointyCastleEcdh();

  // Cap the image cache at 50 MB / 200 entries. The Flutter default is
  // ~100 MB / 1000 entries, which is overkill for a chat where most images
  // are small thumbnails — but also dangerous when a user opens a chat
  // full of multi-megapixel photos and each one decodes to W×H×4 bytes
  // of bitmap regardless of the on-screen size. With this cap a chat list
  // rendering 30 photos at thumbnail resolution stays comfortably under
  // 50 MB; older entries get evicted when newer ones arrive. The 200-entry
  // count limit is a backstop for tiny stickers / avatars that wouldn't
  // hit the byte cap on their own.
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 50 << 20
    ..maximumSize = 200;

  // Point the crypto modules at the on-disk Drift store. Once this is
  // called, identity / prekeys / ratchets survive a cold restart.
  installDriftKeyStore();

  // Persist sticker packs + recents to the same DB so they survive a restart
  // (the manager otherwise falls back to an in-memory store).
  installDriftStickerStore();

  // Corruption gate (audit Round 5 B.3): BEFORE Drift touches the file, run
  // a quick_check and quarantine a damaged database instead of crashing in
  // every later session. The user gets a fresh profile + a loud error trace
  // (error_reporter) rather than a silent guest-mode fallthrough.
  try {
    final health = await ensureDatabaseHealthy();
    if (health.status == DbHealthStatus.quarantined) {
      debugPrint('[orbits] DB quarantined: ${health.detail}');
    }
  } catch (_) {
    // Health check must never block startup; Drift will surface real errors
    // itself when it opens.
  }

  // Retention sweep (audit Round 5 B.4): prune messages past the retention
  // window, reap orphaned blobs, VACUUM — fire-and-forget, never blocks
  // first paint.
  unawaited(db.runRetentionSweep());

  // Reap orphaned voice/file blobs left behind by past chat/message deletions
  // so the SQLite file doesn't bloat over time. Fire-and-forget — never blocks
  // first paint; the DB handle opens lazily on the first query.
  unawaited(db.sweepOrphanBlobs());

  // Windows: turn on real Mica so the OS composites a translucent backdrop
  // behind the window. The desktop shell paints a transparent margin around
  // the centered content panel (see app_shell), so Mica shows there — the
  // in-app fake-glass panels then rest on a true acrylic surface. Guarded to
  // Windows only; never runs on web/mobile (the import is desktop-safe).
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    try {
      await Window.initialize();
      final isDark = WidgetsBinding.instance.platformDispatcher
              .platformBrightness ==
          Brightness.dark;
      await Window.setEffect(effect: WindowEffect.mica, dark: isDark);
    } catch (_) {
      // Older Windows (no Mica) / unsupported — fall back to plain fake-glass.
    }
  }

  runApp(const ProviderScope(child: OrbitsApp()));
}

class OrbitsApp extends ConsumerWidget {
  const OrbitsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the active manifest. Until SharedPreferences resolves we get
    // the default (Graphite), so first paint never flashes the wrong
    // theme. After resolution the picker drives this directly.
    final manifest = ref.watch(themeManifestProvider);
    final background = manifest.background;
    return MaterialApp(
      title: 'Orbits',
      debugShowCheckedModeBanner: false,
      theme: buildOrbitsTheme(manifest),
      // Mount the atmospheric background once at the app root so every
      // route (auth gate, app shell, modal pages) shares the same animated
      // layer — petals don't restart on navigation, orbs don't snap.
      // The manifest's `background` is null for the no-background classic
      // themes (currently only used as a fallback path; all four shipped
      // themes provide one). We use `MaterialApp.builder` instead of
      // wrapping `home:` so dialog/bottom-sheet routes inherit the same
      // backdrop without each page re-mounting it.
      builder: (context, child) {
        if (background == null) return child ?? const SizedBox.shrink();
        return Stack(
          children: [
            Positioned.fill(child: Builder(builder: background)),
            if (child != null) Positioned.fill(child: child),
          ],
        );
      },
      home: const AuthGate(),
    );
  }
}
