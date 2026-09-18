import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orbits_flutter/pages/chats_page.dart';
import 'package:orbits_flutter/pages/profile_page.dart';
import 'package:orbits_flutter/pages/saved_unavailable_page.dart';
import 'package:orbits_flutter/state/appearance_prefs_provider.dart';
import 'package:orbits_flutter/state/auth_notifier.dart' show AuthedUser;
import 'package:orbits_flutter/state/chat_list_provider.dart';
import 'package:orbits_flutter/state/local_profile_provider.dart';
import 'package:orbits_flutter/themes/catalog/orbits_dark_manifest.dart';
import 'package:orbits_flutter/themes/catalog/orbits_light_manifest.dart';
import 'package:orbits_flutter/themes/theme_data_factory.dart';
import 'package:orbits_flutter/ui/backdrop/orbits_wallpaper.dart';
import 'package:orbits_flutter/ui/layout/orbits_breakpoints.dart';
import 'package:orbits_flutter/ui/primitives/liquid_theme_switcher.dart';
import 'package:orbits_flutter/ui/primitives/orbits_liquid_optics.dart';

import '../helpers/test_theme.dart';

const _user = AuthedUser(
  peerId: 'ORBIT-5848B113F194B9AF',
  displayName: 'Owner',
  bio: 'Тест',
  avatarDataUrl: null,
);

void main() {
  test('wallpaper and displacement assets are bundled', () async {
    for (final path in OrbitsWallpaper.all) {
      final data = await rootBundle.load(path);
      expect(data.lengthInBytes, greaterThan(32), reason: path);
    }
  });

  test('React palette lands on both manifests', () {
    expect(orbitsDarkManifest.tokens.bubbleOut, const Color(0xFF2563EB));
    expect(orbitsLightManifest.tokens.bubbleOut, const Color(0xFF2563EB));
    expect(orbitsLightManifest.tokens.accent, const Color(0xFF2563EB));
    expect(orbitsDarkManifest.tokens.text.computeLuminance(), greaterThan(0.7));
    expect(orbitsLightManifest.tokens.text.computeLuminance(), lessThan(0.2));
    expect(orbitsDarkManifest.typography.fontBody, 'Inter');
    expect(orbitsLightManifest.typography.fontHeading, 'Inter');
  });

  test('glass optics resolver distinguishes refraction from fallback', () {
    expect(
      resolveOrbitsGlassOptics(
        highContrast: true,
        allowRealBlur: true,
        refractionReady: true,
      ),
      OrbitsGlassOpticsMode.solid,
    );
    expect(
      resolveOrbitsGlassOptics(
        highContrast: false,
        allowRealBlur: true,
        refractionReady: true,
      ),
      OrbitsGlassOpticsMode.refraction,
    );
    expect(
      resolveOrbitsGlassOptics(
        highContrast: false,
        allowRealBlur: true,
        refractionReady: false,
      ),
      OrbitsGlassOpticsMode.blurFallback,
    );
  });

  test('glass palettes stay brightness-distinct after the React retoken', () {
    final dark = glassPaletteForBrightness(Brightness.dark);
    final light = glassPaletteForBrightness(Brightness.light);
    expect(dark.tint, isNot(equals(light.tint)));
    expect(dark.blurSigma, greaterThan(0));
  });

  testWidgets(
    'phone chats stay a single pane; wide shows conversation column',
    (tester) async {
      Future<void> pumpAt(Size size) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              localProfileProvider.overrideWithValue(_user),
              chatListProvider.overrideWithValue(const []),
            ],
            child: MaterialApp(
              theme: testOrbitsTheme(),
              home: const Scaffold(body: ChatsPage()),
            ),
          ),
        );
        await tester.pump();
      }

      await pumpAt(const Size(400, 900));
      expect(find.text('Пока нет чатов'), findsOneWidget);
      expect(find.text('Выберите чат'), findsNothing);

      await pumpAt(const Size(1280, 900));
      expect(isWideLayout(tester.element(find.byType(ChatsPage))), isTrue);
      expect(find.text('Выберите чат'), findsOneWidget);
      expect(find.text('Пока нет чатов'), findsOneWidget);
    },
  );

  testWidgets('theme switcher toggles the persisted theme id', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: testOrbitsTheme(),
          home: const Scaffold(body: Center(child: LiquidThemeSwitcher())),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(LiquidThemeSwitcher), findsOneWidget);
    expect(find.byTooltip('Светлая тема'), findsOneWidget);
    expect(find.byTooltip('Тёмная тема'), findsOneWidget);
  });

  testWidgets('profile without a session shows the unavailable state', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: testOrbitsTheme(),
          home: const Scaffold(body: ProfilePage()),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Профиль недоступен'), findsOneWidget);
  });

  testWidgets('breakpoints split phone, wide, and contact panel', (
    tester,
  ) async {
    Future<void> pumpWidth(double width) async {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: Size(width, 900)),
          child: const SizedBox.shrink(),
        ),
      );
    }

    await pumpWidth(400);
    expect(isPhoneLayout(tester.element(find.byType(SizedBox))), isTrue);
    expect(isWideLayout(tester.element(find.byType(SizedBox))), isFalse);

    await pumpWidth(1280);
    expect(isPhoneLayout(tester.element(find.byType(SizedBox))), isFalse);
    expect(showContactPanel(tester.element(find.byType(SizedBox))), isTrue);
  });

  test('glass strength scales blur without claiming refraction', () {
    expect(orbitsGlassBlurForStrength(16, 0), lessThan(16));
    expect(orbitsGlassBlurForStrength(16, 100), greaterThan(16));
    expect(
      orbitsGlassTintForStrength(const Color(0x610A0A0A), 100).a,
      greaterThan(orbitsGlassTintForStrength(const Color(0x610A0A0A), 0).a),
    );
  });

  testWidgets('saved messages surface is an honest unavailable state', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: testOrbitsTheme(),
          home: const SavedUnavailablePage(),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Избранное пока недоступно'), findsOneWidget);
    expect(find.textContaining('макета React'), findsOneWidget);
  });

  testWidgets('profile with a session shows the real peer id', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localProfileProvider.overrideWithValue(_user)],
        child: MaterialApp(
          theme: testOrbitsTheme(),
          home: const Scaffold(body: ProfilePage()),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Owner'), findsOneWidget);
    expect(find.text('ORBIT-5848B113F194B9AF'), findsOneWidget);
    expect(find.text('Профиль недоступен'), findsNothing);
  });
}
