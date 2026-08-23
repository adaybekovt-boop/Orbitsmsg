// QR device linking — phone signs a one-time token shown on the PC.
//
//   • [QrPairingPage]  (PC): shows `orbits_pairing:<pcPeerId>:<token>` and
//     waits for a signed `qr_auth_response`. A valid signature proves the
//     phone holds that identity key. It does not unlock the PC vault.
//   • [QrScanPage]     (phone): scans the QR, signs the token, sends it.
//
// The cryptographic core is in `core/qr_pairing.dart`; the reliable transport
// reuses RoomManager's plaintext channel (sendQrAuthResponse / qr listener).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/qr_pairing.dart';
import '../peer/room_manager.dart';
import '../state/local_profile_provider.dart';
import '../themes/orbits_tokens.dart';
import '../ui/primitives/adaptive_page_frame.dart';
import '../ui/primitives/orbits_glass_button.dart';
import '../ui/primitives/orbits_glass_app_bar.dart';
import '../ui/primitives/orbits_glass_surface.dart';

// ─── PC side: show the QR, wait for the phone ─────────────────────────

class QrPairingPage extends ConsumerStatefulWidget {
  const QrPairingPage({super.key});

  @override
  ConsumerState<QrPairingPage> createState() => _QrPairingPageState();
}

enum _PairStatus { waiting, verifying, success, rejected }

class _QrPairingPageState extends ConsumerState<QrPairingPage> {
  String? _token;
  _PairStatus _status = _PairStatus.waiting;
  String? _pairedPeerId;

  RoomManager get _rooms => ref.read(roomManagerProvider.notifier);

  @override
  void initState() {
    super.initState();
    if (!kQrDeviceLinkingEnabled) return;
    _token = generateSessionToken();
    _rooms.setQrAuthListener(_onAuthPacket);
  }

  @override
  void dispose() {
    _rooms.setQrAuthListener(null);
    super.dispose();
  }

  Future<void> _onAuthPacket(
      String remoteId, Map<String, Object?> packet) async {
    if (!mounted || _status == _PairStatus.success) return;
    setState(() => _status = _PairStatus.verifying);
    final token = _token;
    if (token == null) return;
    final result = await verifyAuthResponse(packet, token);
    if (!mounted) return;
    if (result == null) {
      setState(() => _status = _PairStatus.rejected);
      return;
    }
    // Signature valid + token fresh → adopt the session and head to the app.
    setState(() {
      _status = _PairStatus.success;
      _pairedPeerId = result.peerId;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    if (!kQrDeviceLinkingEnabled) {
      return _qrLinkingUnavailableScaffold(tokens, title: 'QR-связка устройств');
    }
    final pcPeerId = ref.watch(currentPeerIdProvider) ?? '';
    final qrData = buildPairingUri(pcPeerId, _token!);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: OrbitsGlassAppBar(
        iconTheme: IconThemeData(color: tokens.text),
        title: Text(
          'QR-связка устройств',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
      ),
      body: AdaptivePageFrame(
        maxWidth: 460,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: _status == _PairStatus.success
                ? _success(tokens)
                : _qrCard(tokens, qrData, pcPeerId.isNotEmpty),
          ),
        ),
      ),
    );
  }

  Widget _qrCard(OrbitsTokens tokens, String qrData, bool ready) {
    return OrbitsGlassSurface(
      role: OrbitsGlassRole.card,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Отсканируйте код телефоном',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: tokens.fontHeading,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: tokens.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Откройте Orbits на телефоне → «Связать с ПК» и наведите камеру '
              'на этот код. Телефон подпишет одноразовый токен своим ключом — '
              'это не вход в профиль и не разблокировка сейфа на компьютере.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: tokens.fontBody,
                fontSize: 13,
                height: 1.4,
                color: tokens.muted,
              ),
            ),
            const SizedBox(height: 22),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
              ),
              child: ready
                  ? QrImageView(
                      data: qrData,
                      version: QrVersions.auto,
                      size: 232,
                      gapless: false,
                      backgroundColor: Colors.white,
                    )
                  : const SizedBox(
                      width: 232,
                      height: 232,
                      child: Center(child: CircularProgressIndicator()),
                    ),
            ),
            const SizedBox(height: 20),
            _statusLine(tokens),
          ],
        ),
      ),
    );
  }

  Widget _statusLine(OrbitsTokens tokens) {
    final (icon, text, color) = switch (_status) {
      _PairStatus.waiting => (
          Icons.hourglass_empty_rounded,
          'Ожидание подтверждения с телефона…',
          tokens.muted,
        ),
      _PairStatus.verifying => (
          Icons.sync_rounded,
          'Проверка подписи…',
          tokens.accent,
        ),
      _PairStatus.rejected => (
          Icons.gpp_bad_rounded,
          'Подпись недействительна. Попробуйте снова.',
          tokens.danger,
        ),
      _PairStatus.success => (
          Icons.verified_rounded,
          'Готово!',
          tokens.success,
        ),
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: color,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              fontFamily: tokens.fontBody,
            ),
          ),
        ),
      ],
    );
  }

  Widget _success(OrbitsTokens tokens) {
    return OrbitsGlassSurface(
      role: OrbitsGlassRole.card,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.verified_user_rounded, size: 56, color: tokens.success),
            const SizedBox(height: 16),
            Text(
              'Подпись телефона принята',
              style: TextStyle(
                fontFamily: tokens.fontHeading,
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: tokens.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _pairedPeerId == null
                  ? 'Ключ телефона проверен. Сейф компьютера не открывался.'
                  : 'Проверен ключ •'
                      '${_pairedPeerId!.length >= 4 ? _pairedPeerId!.substring(_pairedPeerId!.length - 4) : _pairedPeerId}. '
                      'Это не вход в профиль на этом ПК.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: tokens.fontBody,
                fontSize: 13,
                color: tokens.muted,
              ),
            ),
            const SizedBox(height: 24),
            OrbitsGlassButton(
              label: 'Продолжить',
              icon: Icons.arrow_forward_rounded,
              variant: OrbitsGlassVariant.primary,
              size: OrbitsGlassSize.large,
              expand: true,
              onPressed: () =>
                  Navigator.of(context).popUntil((r) => r.isFirst),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Phone side: scan the QR, sign, send ──────────────────────────────

class QrScanPage extends ConsumerStatefulWidget {
  const QrScanPage({super.key});

  @override
  ConsumerState<QrScanPage> createState() => _QrScanPageState();
}

enum _ScanStatus { scanning, sending, sent, failed }

class _QrScanPageState extends ConsumerState<QrScanPage> {
  final MobileScannerController _controller = MobileScannerController();
  _ScanStatus _status = _ScanStatus.scanning;
  bool _handling = false;

  RoomManager get _rooms => ref.read(roomManagerProvider.notifier);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handling || _status != _ScanStatus.scanning) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
    if (raw == null) return;
    final req = parsePairingUri(raw);
    if (req == null) return; // not our QR — keep scanning

    _handling = true;
    setState(() => _status = _ScanStatus.sending);
    await _controller.stop();

    final myPeerId = ref.read(currentPeerIdProvider) ?? '';
    if (myPeerId.isEmpty) {
      if (mounted) setState(() => _status = _ScanStatus.failed);
      return;
    }
    final packet = await buildAuthResponse(
      sessionToken: req.sessionToken,
      myPeerId: myPeerId,
    );
    final ok = await _rooms.sendQrAuthResponse(req.pcPeerId, packet);
    if (!mounted) return;
    setState(() => _status = ok ? _ScanStatus.sent : _ScanStatus.failed);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    if (!kQrDeviceLinkingEnabled) {
      return _qrLinkingUnavailableScaffold(tokens, title: 'Связать с ПК');
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Связать с ПК', style: TextStyle(color: Colors.white)),
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_status == _ScanStatus.scanning)
            MobileScanner(controller: _controller, onDetect: _onDetect)
          else
            Container(color: Colors.black),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
              child: OrbitsGlassSurface(
                role: OrbitsGlassRole.card,
                borderRadius: BorderRadius.circular(18),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: _statusBody(tokens),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBody(OrbitsTokens tokens) {
    switch (_status) {
      case _ScanStatus.scanning:
        return Text(
          'Наведите камеру на QR-код на экране компьютера.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: tokens.text,
            fontFamily: tokens.fontBody,
            fontSize: 14,
          ),
        );
      case _ScanStatus.sending:
        return _line(tokens, Icons.sync_rounded, tokens.accent,
            'Подписываем и отправляем…');
      case _ScanStatus.sent:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _line(tokens, Icons.check_circle_rounded, tokens.success,
                kQrScanSentUserMessage),
            const SizedBox(height: 12),
            OrbitsGlassButton(
              label: 'Готово',
              variant: OrbitsGlassVariant.primary,
              expand: true,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        );
      case _ScanStatus.failed:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _line(tokens, Icons.error_rounded, tokens.danger,
                'Не удалось связаться с компьютером.'),
            const SizedBox(height: 12),
            OrbitsGlassButton(
              label: 'Закрыть',
              variant: OrbitsGlassVariant.secondary,
              expand: true,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        );
    }
  }

  Widget _line(OrbitsTokens tokens, IconData icon, Color color, String text) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            style: TextStyle(
              color: tokens.text,
              fontFamily: tokens.fontBody,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

Widget _qrLinkingUnavailableScaffold(OrbitsTokens tokens, {required String title}) {
  return Scaffold(
    backgroundColor: Colors.transparent,
    appBar: OrbitsGlassAppBar(
      iconTheme: IconThemeData(color: tokens.text),
      title: Text(
        title,
        style: TextStyle(
          fontFamily: tokens.fontHeading,
          fontWeight: FontWeight.w600,
          color: tokens.text,
        ),
      ),
    ),
    body: AdaptivePageFrame(
      maxWidth: 460,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Связка устройств пока недоступна. Подпись QR-токена не переносит '
            'ключи и не открывает сессию на другом устройстве.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: tokens.fontBody,
              fontSize: 14,
              height: 1.4,
              color: tokens.muted,
            ),
          ),
        ),
      ),
    ),
  );
}
