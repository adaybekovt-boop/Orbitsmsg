// Add-contact screen — two ways to onboard a new peer:
//   1. Scan QR (`mobile_scanner` live camera feed)
//   2. Type the peerId by hand
//
// We default to the scan tab because that's the path optimised for the
// in-person meet-up case (same room, "show me your QR"); the manual tab
// is the fallback for desktop/web without a camera or for anyone sharing
// peerIds over an out-of-band channel.
//
// On a successful scan / valid manual entry we:
//   • Refuse self-adds (would create an empty chat with yourself).
//   • Persist a fresh `peers` row via `db.savePeer(...)` — the chat list
//     watcher picks it up automatically.
//   • Push the chat detail page so the user lands directly in the new
//     conversation. This matches the JS UX flow.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class AddContactPage extends ConsumerStatefulWidget {
  const AddContactPage({super.key});

  @override
  ConsumerState<AddContactPage> createState() => _AddContactPageState();
}

class _AddContactPageState extends ConsumerState<AddContactPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    // Web users almost never have webcam-QR access (browsers gate it behind
    // a permission prompt and many never grant it). Default to the manual
    // tab there. On native we open on scan because that's the in-person
    // meetup path.
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: kIsWeb ? 1 : 0,
    );
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _accept(String raw) async {
    final normalized = normalizePeerId(raw);
    if (!isValidPeerId(normalized)) {
      _toast('Код не похож на правильный');
      return;
    }
    final selfId = ref.read(currentPeerIdProvider) ?? '';
    if (normalized == selfId) {
      _toast('Это твой собственный код');
      return;
    }
    try {
      await db.savePeer({
        'id': normalized,
        'trustLevel': 0,
        'lastSeenAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {
      _toast('Не удалось добавить контакт');
      return;
    }
    if (!mounted) return;
    // Close the add-contact page, then push the chat view on top.
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatViewPage(peerId: normalized),
      ),
    );
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
          _ScanTab(onResult: _accept),
          _ManualTab(onSubmit: _accept),
        ],
      ),
    );
  }
}

// ─── Tab 1: live camera QR scan ────────────────────────────────────

class _ScanTab extends StatefulWidget {
  const _ScanTab({required this.onResult});
  final Future<void> Function(String) onResult;

  @override
  State<_ScanTab> createState() => _ScanTabState();
}

class _ScanTabState extends State<_ScanTab> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Stack(
      children: [
        // Camera preview fills the whole tab.
        MobileScanner(
          controller: _controller,
          onDetect: (capture) {
            if (_handled) return;
            for (final code in capture.barcodes) {
              final raw = code.rawValue;
              if (raw == null || raw.isEmpty) continue;
              _handled = true;
              hapticTap();
              // Stop the camera before navigating so we don't keep the
              // sensor warm during the chat-view push animation.
              _controller.stop();
              widget.onResult(raw).then((_) {
                if (mounted) _handled = false;
              });
              return;
            }
          },
        ),
        // Cut-out viewfinder hint — a square in the middle so users know
        // where to point. Pure visual; the scanner itself reads the whole
        // frame.
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
        // Caption below the viewfinder.
        Positioned(
          left: 0,
          right: 0,
          bottom: 32,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                onTap: () => _controller.toggleTorch(),
              ),
              const SizedBox(height: 8),
              _ScanIconButton(
                icon: Icons.cameraswitch_outlined,
                tooltip: 'Сменить камеру',
                onTap: () => _controller.switchCamera(),
              ),
            ],
          ),
        ),
      ],
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

// ─── Tab 2: manual peerId entry ────────────────────────────────────

class _ManualTab extends StatefulWidget {
  const _ManualTab({required this.onSubmit});
  final Future<void> Function(String) onSubmit;

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
                  'Попроси человека открыть свой QR или отправить код профиля.',
                  style: TextStyle(
                    color: tokens.muted,
                    fontFamily: tokens.fontBody,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _ctl,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  style: TextStyle(
                      fontFamily: tokens.fontMono, color: tokens.text),
                  inputFormatters: [
                    // Strip whitespace + force upper-case as the user types,
                    // matching the canonicalisation in `normalizePeerId`.
                    FilteringTextInputFormatter.deny(RegExp(r'\s')),
                    TextInputFormatter.withFunction((_, value) {
                      return value.copyWith(text: value.text.toUpperCase());
                    }),
                  ],
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
                // Inline progress feedback while the contact is being saved —
                // the glass button takes an `IconData`, not a spinner widget, so
                // we surface the busy state below it (logic unchanged: `_busy`
                // also disables the button above).
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
