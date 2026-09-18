import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/haptics.dart';
import '../core/identity_key.dart';
import '../devices/local_device_material.dart';
import '../peer/helpers.dart' show contactQrPayload;
import '../state/local_profile_provider.dart';
import '../themes/orbits_tokens.dart';
import '../transport/discovery_secret_store.dart';
import '../ui/layout/orbits_breakpoints.dart';
import '../ui/primitives/liquid_glass_sphere.dart';
import '../ui/primitives/orbits_glass_button.dart';
import '../ui/primitives/orbits_glass_surface.dart';
import '../ui/primitives/orbs_card.dart';
import '../ui/profile/my_qr_page.dart';
import '../ui/profile/profile_edit_page.dart';

/// React profile tab, wired to the real authed user and QR payload.
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = OrbitsTokens.of(context);
    final user = ref.watch(localProfileProvider);
    if (user == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LiquidGlassSphere(size: 96),
              const SizedBox(height: 20),
              Text(
                'Профиль недоступен',
                style: TextStyle(
                  fontFamily: tokens.fontHeading,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: tokens.text,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Войдите в локальный профиль, чтобы показать имя и QR.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: tokens.muted,
                  fontFamily: tokens.fontBody,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final avatar = _decodeAvatar(user.avatarDataUrl);
    final initial = user.displayName.trim().isNotEmpty
        ? user.displayName.trim().characters.first.toUpperCase()
        : '?';

    return SafeArea(
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          isPhoneLayout(context) ? 88 : 32,
        ),
        children: [
          Text(
            'Профиль',
            style: TextStyle(
              fontFamily: tokens.fontHeading,
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: tokens.text,
            ),
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked = constraints.maxWidth < 640;
              final userCard = OrbitsGlassSurface(
                role: OrbitsGlassRole.card,
                realBlur: true,
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                child: Column(
                  children: [
                    OrbsAvatar(
                      fallbackInitial: initial,
                      imageBytes: avatar,
                      size: 112,
                      online: true,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      user.displayName.isEmpty ? 'Без имени' : user.displayName,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: tokens.fontHeading,
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        color: tokens.text,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      user.peerId,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: tokens.fontMono,
                        fontSize: 12,
                        color: tokens.muted,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: tokens.success.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: tokens.success.withValues(alpha: 0.28),
                        ),
                      ),
                      child: Text(
                        'Локальный профиль',
                        style: TextStyle(
                          color: tokens.success,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (user.bio.trim().isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'О себе',
                          style: TextStyle(
                            color: tokens.muted,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: tokens.bg.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: tokens.border),
                        ),
                        child: Text(
                          user.bio,
                          style: TextStyle(
                            color: tokens.text,
                            fontFamily: tokens.fontBody,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    OrbitsGlassButton(
                      label: 'Редактировать',
                      icon: Icons.edit_outlined,
                      expand: true,
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const ProfileEditPage(),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              );
              final qrCard = OrbitsGlassSurface(
                role: OrbitsGlassRole.card,
                realBlur: true,
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                child: Column(
                  children: [
                    _ProfileQr(peerId: user.peerId),
                    const SizedBox(height: 16),
                    Text(
                      'QR для контакта',
                      style: TextStyle(
                        fontFamily: tokens.fontHeading,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: tokens.text,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Покажите код, чтобы вас добавили. Это настоящий orbits:// контакт, не макет.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: tokens.muted,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        OrbitsGlassButton(
                          label: 'Открыть QR',
                          icon: Icons.qr_code_2,
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => MyQrPage(peerId: user.peerId),
                              ),
                            );
                          },
                        ),
                        OrbitsGlassButton(
                          label: 'Копировать код',
                          icon: Icons.copy,
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: user.peerId),
                            );
                            hapticTap();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Код профиля скопирован'),
                                ),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              );
              if (stacked) {
                return Column(
                  children: [userCard, const SizedBox(height: 16), qrCard],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: userCard),
                  const SizedBox(width: 16),
                  Expanded(child: qrCard),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Uint8List? _decodeAvatar(String? url) {
    if (url == null || url.isEmpty) return null;
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    try {
      return base64Decode(url.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }
}

class _ProfileQr extends StatefulWidget {
  const _ProfileQr({required this.peerId});
  final String peerId;

  @override
  State<_ProfileQr> createState() => _ProfileQrState();
}

class _ProfileQrState extends State<_ProfileQr> {
  late final Future<String> _future = _payload();

  Future<String> _payload() async {
    Uint8List? identity;
    String? deviceId;
    Uint8List? transport;
    try {
      identity = await exportIdentityPubSpki();
    } catch (_) {}
    try {
      final material = await loadOrCreateLocalDeviceMaterial();
      deviceId = material.deviceId;
      transport = material.transportPublicKey.isEmpty
          ? null
          : material.transportPublicKey;
    } catch (_) {}
    return contactQrPayload(
      widget.peerId,
      discoverySecret: discoverySecretStore.getOrCreateLocal(),
      identityPublicKey: identity,
      deviceId: deviceId,
      transportPublicKey: transport,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _future,
      builder: (context, snap) {
        final data = snap.data;
        return Container(
          width: 180,
          height: 180,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: data == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : QrImageView(
                  data: data,
                  version: QrVersions.auto,
                  backgroundColor: Colors.white,
                ),
        );
      },
    );
  }
}
