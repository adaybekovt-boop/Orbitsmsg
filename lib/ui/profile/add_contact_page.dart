// Add-contact screen — two ways to onboard a new peer:
//   1. Scan QR (`mobile_scanner` live camera feed)
//   2. Type / paste the code by hand
//
// Both paths funnel through `parseContactQrPayload` (peer/helpers.dart), so a
// bare `ORBIT-ABC123`, an `orbits://contact/<id>` deep link, an
// `orbits:contact:<id>` string, or a JSON contact blob all add the same peer.
//
// IMPORTANT — adding a contact is OFFLINE-FIRST: scanning a friend's QR saves
// the `peers` row locally even if they're not reachable right now. The live
// connection (and its "в сети / не в сети" status) is the chat page's job, not
// a precondition for adding.
//
// `mobile_scanner` only ships a camera implementation on Android / iOS / macOS
// / web. On Windows & Linux (and when the camera permission is denied) the scan
// tab degrades to a clear "use manual entry" panel instead of crashing.

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/haptics.dart';
import '../../pages/chat_view_page.dart';
import '../../peer/helpers.dart';
import '../../state/local_profile_provider.dart';
import '../../storage/db.dart' as db;
import '../../themes/orbits_tokens.dart';
import '../primitives/orbits_glass_button.dart';
import '../primitives/orbits_glass_surface.dart';
import 'my_qr_page.dart';

/// Whether `mobile_scanner` has a live-camera implementation on this platform.
/// (Windows / Linux have none — there a QR scan tab would throw, so we hide
/// the live feed and steer the user to manual entry.)
bool get scannerSupported {
  if (kIsWeb) return true;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return true;
    default:
      return false;
  }
}

class AddContactPage extends ConsumerStatefulWidget {
  const AddContactPage({super.key});

  @override
  ConsumerState<AddContactPage> createState() => _AddContactPageState();
}

class _AddContactPageState extends ConsumerState<AddContactPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  /// Scan-first only on phones (the in-person meetup path). On web (flaky
  /// webcam QR) and on desktops without a camera impl, open on manual.
  bool get _preferScan =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: _preferScan ? 0 : 1,
    );
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// Try to add the contact encoded in [raw]. Returns true when a peer was
  /// saved (new OR already-present) so the scanner knows to stop; false on any
  /// recoverable failure (unrecognised code, self, save error) so it can re-arm
  /// and let the user try again. Never throws.
  Future<bool> _accept(String raw) async {
    final pid = parseContactQrPayload(raw);
    if (pid == null) {
      _toast('QR не похож на контакт TK Messenger');
      return false;
    }
    final selfId = normalizePeerId(ref.read(currentPeerIdProvider) ?? '');
    if (pid == selfId) {
      _toast('Это твой собственный код');
      return false;
    }

    final existed = (await db.getPeer(pid)) != null;
    bool saved;
    try {
      saved = await db.savePeer({
        'id': pid,
        'trustLevel': 0,
        'lastSeenAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {
      _toast('Не удалось сохранить контакт');
      return false;
    }
    if (!saved) {
      _toast('Не удалось сохранить контакт');
      return false;
    }

    if (!mounted) return true;
    // Visible result + distinct message; the contact is saved regardless of
    // whether the peer is online. Keep this page in the back stack (don't pop)
    // so the SnackBar stays visible and "add another" is one back-tap away.
    _toast(existed ? 'Контакт уже добавлен' : 'Контакт добавлен');
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatViewPage(peerId: pid)),
    );
    return true;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final peerId = ref.watch(currentPeerIdProvider);
    return Scaffold(
      // Transparent so the app's animated glass backdrop shows through —
      // matches every other pushed page (settings, games, chat…).
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: const OrbitsGlassSurface(
          role: OrbitsGlassRole.appBar,
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
          child: SizedBox.expand(),
        ),
        title: Text(
          'Добавить контакт',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
        actions: [
          if (peerId != null && peerId.isNotEmpty)
            OrbitsGlassIconButton(
              icon: Icons.qr_code_2,
              tooltip: 'Мой QR',
              variant: OrbitsGlassVariant.subtle,
              size: OrbitsGlassSize.small,
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => MyQrPage(peerId: peerId),
                  ),
                );
              },
            ),
          const SizedBox(width: 8),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: tokens.accent,
          unselectedLabelColor: tokens.muted,
          indicatorColor: tokens.accent,
          labelStyle: TextStyle(
            fontFamily: tokens.fontBody,
            fontWeight: FontWeight.w700,
          ),
          unselectedLabelStyle: TextStyle(
            fontFamily: tokens.fontBody,
            fontWeight: FontWeight.w500,
          ),
          tabs: const [
            Tab(icon: Icon(Icons.qr_code_scanner), text: 'Сканировать QR'),
            Tab(icon: Icon(Icons.keyboard), text: 'Ввести вручную'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _ScanTab(
            onResult: _accept,
            onManual: () => _tabs.animateTo(1),
          ),
          _ManualTab(onSubmit: _accept),
        ],
      ),
    );
  }
}

// ─── Tab 1: live camera QR scan ────────────────────────────────────

class _ScanTab extends StatefulWidget {
  const _ScanTab({required this.onResult, required this.onManual});

  /// Returns true if a contact was added (stop scanning), false to re-arm.
  final Future<bool> Function(String) onResult;
  final VoidCallback onManual;

  @override
  State<_ScanTab> createState() => _ScanTabState();
}

class _ScanTabState extends State<_ScanTab> {
  MobileScannerController? _controller;

  /// True while a scan result is being processed — blocks the per-frame
  /// onDetect storm from firing `onResult` dozens of times. Reset (and the
  /// camera restarted) if the result turned out to be unusable, so a single
  /// bad/duplicate scan never permanently wedges the scanner.
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    if (scannerSupported) _controller = MobileScannerController();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) return;
    // Pick the FIRST barcode that actually parses to a contact — ignore any
    // other junk QR that happens to be in frame (a poster, a URL, …).
    String? hit;
    for (final code in capture.barcodes) {
      final raw = code.rawValue;
      if (raw == null || raw.isEmpty) continue;
      if (parseContactQrPayload(raw) != null) {
        hit = raw;
        break;
      }
    }
    if (hit == null) return; // nothing contact-shaped yet — keep scanning

    _handled = true;
    hapticTap();
    await _controller?.stop();
    final ok = await widget.onResult(hit);
    if (!mounted) return;
    if (!ok) {
      // Self / save failure — let the user point at another code.
      _handled = false;
      await _controller?.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      // No camera implementation on this platform (Windows / Linux).
      return _ScanUnavailable(
        title: 'Сканирование недоступно',
        message:
            'На этом устройстве нет камеры для QR. Введите код контакта вручную.',
        onManual: widget.onManual,
      );
    }

    final tokens = OrbitsTokens.of(context);
    return Stack(
      children: [
        MobileScanner(
          controller: controller,
          onDetect: _onDetect,
          errorBuilder: (context, error, child) => _ScanUnavailable(
            title: 'Камера недоступна',
            message:
                'Не удалось открыть камеру (нет доступа?). Введите код вручную '
                'или разрешите доступ к камере в настройках.',
            onManual: widget.onManual,
          ),
        ),
        // Cut-out viewfinder hint.
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: tokens.accent, width: 3),
              borderRadius: BorderRadius.circular(tokens.radiusCard),
            ),
          ),
        ),
        // Caption + manual-entry escape hatch.
        Positioned(
          left: 0,
          right: 0,
          bottom: 28,
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 24),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Наведи камеру на QR-код друга',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              const SizedBox(height: 12),
              OrbitsGlassButton(
                label: 'Ввести вручную',
                icon: Icons.keyboard,
                variant: OrbitsGlassVariant.secondary,
                onPressed: widget.onManual,
              ),
            ],
          ),
        ),
        // Torch + camera-flip controls in the top-right.
        Positioned(
          top: 16,
          right: 16,
          child: Column(
            children: [
              _ScanIconButton(
                icon: Icons.flash_on,
                tooltip: 'Фонарик',
                onTap: () => controller.toggleTorch(),
              ),
              const SizedBox(height: 8),
              _ScanIconButton(
                icon: Icons.cameraswitch_outlined,
                tooltip: 'Сменить камеру',
                onTap: () => controller.switchCamera(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Shown when the live scanner can't run (unsupported platform or denied
/// camera permission). Always offers the manual-entry path.
class _ScanUnavailable extends StatelessWidget {
  const _ScanUnavailable({
    required this.title,
    required this.message,
    required this.onManual,
  });
  final String title;
  final String message;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.no_photography_outlined,
                  size: 48, color: tokens.muted),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  fontFamily: tokens.fontHeading,
                  color: tokens.text,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: tokens.muted,
                  fontFamily: tokens.fontBody,
                ),
              ),
              const SizedBox(height: 20),
              OrbitsGlassButton(
                label: 'Ввести вручную',
                icon: Icons.keyboard,
                variant: OrbitsGlassVariant.primary,
                size: OrbitsGlassSize.large,
                expand: true,
                onPressed: onManual,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScanIconButton extends StatelessWidget {
  const _ScanIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.55),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }
}

// ─── Tab 2: manual code entry ──────────────────────────────────────

class _ManualTab extends StatefulWidget {
  const _ManualTab({required this.onSubmit});

  /// Returns true if a contact was added; false otherwise (error already
  /// surfaced to the user).
  final Future<bool> Function(String) onSubmit;

  @override
  State<_ManualTab> createState() => _ManualTabState();
}

class _ManualTabState extends State<_ManualTab> {
  final TextEditingController _ctl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onSubmit(_ctl.text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Center(
      child: ConstrainedBox(
        // Clamp on desktop/web so the inputs don't stretch across the screen.
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: OrbitsGlassSurface(
            role: OrbitsGlassRole.card,
            borderRadius: BorderRadius.circular(tokens.radiusCard),
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Введи код профиля',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    fontFamily: tokens.fontHeading,
                    color: tokens.text,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Вставь код друга или ссылку из его QR '
                  '(ORBIT-… или orbits://contact/…).',
                  style: TextStyle(
                    color: tokens.muted,
                    fontFamily: tokens.fontBody,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _ctl,
                  autofocus: true,
                  // No hard input formatters: a pasted `orbits://contact/…`
                  // link or JSON blob must survive intact — normalisation +
                  // validation happen in `parseContactQrPayload` on submit.
                  textCapitalization: TextCapitalization.characters,
                  style: TextStyle(
                      fontFamily: tokens.fontMono, color: tokens.text),
                  decoration: InputDecoration(
                    labelText: 'Код профиля',
                    labelStyle: TextStyle(
                        color: tokens.muted, fontFamily: tokens.fontBody),
                    hintText: 'ORBIT-ABC123',
                    hintStyle: TextStyle(
                      color: tokens.muted.withValues(alpha: 0.7),
                      fontFamily: tokens.fontMono,
                    ),
                    filled: true,
                    fillColor: tokens.surface.withValues(alpha: 0.55),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(tokens.radiusButton),
                      borderSide: BorderSide(color: tokens.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(tokens.radiusButton),
                      borderSide: BorderSide(color: tokens.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(tokens.radiusButton),
                      borderSide: BorderSide(color: tokens.accent, width: 1.4),
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 20),
                OrbitsGlassButton(
                  label: 'Добавить',
                  icon: Icons.person_add_alt,
                  variant: OrbitsGlassVariant.primary,
                  size: OrbitsGlassSize.large,
                  expand: true,
                  enabled: !_busy,
                  onPressed: _busy ? null : _submit,
                ),
                if (_busy) ...[
                  const SizedBox(height: 16),
                  Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(tokens.accent),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
