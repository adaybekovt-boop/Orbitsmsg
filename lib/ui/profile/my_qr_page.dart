// "My Peer ID" QR screen.
//
// Renders the user's peerId as a scannable QR code on a clean theme-aware
// canvas. The receiving side scans it via `AddContactPage` (which uses
// `mobile_scanner`), parses the URI, and lands directly on the new chat.
//
// Wire format: the QR carries a stable `orbits://contact/<peerId>` deep link
// (built by `contactQrPayload`). The reader (`parseContactQrPayload`) still
// accepts a bare peerId too, so older QRs keep scanning. The plain-text code
// shown below the QR stays the bare id — that's what a human copies/types.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/haptics.dart';
import '../../peer/helpers.dart' show contactQrPayload;
import '../../transport/discovery_secret_store.dart';
import '../../themes/orbits_tokens.dart';
import '../primitives/orbits_glass_button.dart';
import '../primitives/orbits_glass_app_bar.dart';
import '../primitives/orbits_glass_surface.dart';

class MyQrPage extends StatelessWidget {
  const MyQrPage({super.key, required this.peerId});

  final String peerId;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Scaffold(
      appBar: OrbitsGlassAppBar(
        title: Text(
          'Мой QR',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Мой QR',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    fontFamily: tokens.fontHeading,
                    color: tokens.text,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Покажи этот QR, чтобы тебя добавили в контакты.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: tokens.muted,
                    fontFamily: tokens.fontBody,
                  ),
                ),
                const SizedBox(height: 28),
                // Glass panel framing the QR. The QR itself sits on its own
                // white plate inside — many scanners have trouble reading
                // dark-on-dark codes, so it stays black-on-white regardless
                // of the active theme.
                OrbitsGlassSurface(
                  role: OrbitsGlassRole.card,
                  borderRadius: BorderRadius.circular(tokens.radiusCard + 6),
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(tokens.radiusCard),
                    ),
                    child: QrImageView(
                      data: contactQrPayload(
                        peerId,
                        discoverySecret: discoverySecretStore.getOrCreateLocal(),
                      ),
                      version: QrVersions.auto,
                      size: 240,
                      backgroundColor: Colors.white,
                      eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: Colors.black,
                      ),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // Plain-text code underneath — fallback for when
                // scanning isn't available (e.g. desktop without camera).
                OrbitsGlassSurface(
                  role: OrbitsGlassRole.card,
                  borderRadius: BorderRadius.circular(tokens.radiusButton),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Мой код',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          fontFamily: tokens.fontBody,
                          color: tokens.muted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: SelectableText(
                              peerId,
                              style: TextStyle(
                                fontFamily: tokens.fontMono,
                                fontSize: 15,
                                color: tokens.text,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OrbitsGlassIconButton(
                            icon: Icons.copy_outlined,
                            tooltip: 'Скопировать код',
                            variant: OrbitsGlassVariant.subtle,
                            size: OrbitsGlassSize.small,
                            onPressed: () async {
                              hapticTap();
                              await Clipboard.setData(
                                ClipboardData(text: peerId),
                              );
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context)
                                ..clearSnackBars()
                                ..showSnackBar(
                                  const SnackBar(
                                    content: Text('Код скопирован'),
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
