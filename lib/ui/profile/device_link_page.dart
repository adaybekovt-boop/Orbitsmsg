// Phase 10: show a device-link QR. The identity key signs; devices do
// not share a ratchet snapshot.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/identity_key.dart';
import '../../devices/device_link.dart';
import '../../devices/device_registry.dart';
import '../../themes/orbits_tokens.dart';
import '../../transport/transport_noise_seed.dart';
import '../primitives/orbits_glass_app_bar.dart';
import '../primitives/orbits_glass_button.dart';
import '../primitives/orbits_glass_list_tile.dart';
import '../primitives/orbits_glass_surface.dart';

class DeviceLinkPage extends StatefulWidget {
  const DeviceLinkPage({super.key, required this.peerId});

  final String peerId;

  @override
  State<DeviceLinkPage> createState() => _DeviceLinkPageState();
}

class _DeviceLinkPageState extends State<DeviceLinkPage> {
  String? _payload;
  String? _error;
  final _paste = TextEditingController();

  @override
  void initState() {
    super.initState();
    _build();
  }

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  Future<void> _build() async {
    try {
      await deviceRegistry.hydrate();
      await transportNoiseSeedStore.hydrate();
      final pub = await exportIdentityPubSpki();
      final keys = localDeviceBindingKeys();
      final link = await issueDeviceLink(
        deviceId: 'local-device',
        transportPublicKey: keys.transport,
        hypercorePublicKey: keys.hypercore,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        identityPublicKey: pub,
        sign: signBytes,
      );
      deviceRegistry.authorize(
        AuthorizedDevice(
          deviceId: link.deviceId,
          transportPublicKey: link.transportPublicKey,
          hypercorePublicKey: link.hypercorePublicKey,
          name: widget.peerId,
          kind: 'this',
          createdAt: link.createdAt,
          status: DeviceStatus.active,
          ownerPeerId: widget.peerId,
          transportPeerId: widget.peerId,
        ),
      );
      if (!mounted) return;
      setState(() => _payload = jsonEncode(link.toQrJson()));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _acceptPasted() async {
    try {
      final raw = jsonDecode(_paste.text) as Map<String, dynamic>;
      final link = DeviceLinkPayload.fromQrJson(Map<String, Object?>.from(raw));
      if (!await verifyDeviceLink(link)) {
        throw StateError('device-link signature failed');
      }
      deviceRegistry.authorize(
        AuthorizedDevice(
          deviceId: link.deviceId,
          transportPublicKey: link.transportPublicKey,
          hypercorePublicKey: link.hypercorePublicKey,
          name: link.deviceId,
          kind: 'linked',
          createdAt: link.createdAt,
          status: DeviceStatus.active,
          ownerPeerId: widget.peerId,
        ),
      );
      if (!mounted) return;
      setState(() {
        _error = null;
        _paste.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Scaffold(
      appBar: OrbitsGlassAppBar(
        title: Text(
          'Привязка устройства',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'QR для второго устройства. Сессии Double Ratchet на каждом '
            'устройстве свои — общий снимок не передаётся.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: tokens.muted,
              fontFamily: tokens.fontBody,
            ),
          ),
          const SizedBox(height: 24),
          if (_error != null)
            Text(_error!, style: TextStyle(color: tokens.danger))
          else if (_payload == null)
            const Center(child: CircularProgressIndicator())
          else
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: OrbitsGlassSurface(
                  role: OrbitsGlassRole.card,
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(16),
                    child: QrImageView(
                      data: _payload!,
                      size: 240,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 24),
          TextField(
            controller: _paste,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'JSON второго устройства',
            ),
          ),
          const SizedBox(height: 12),
          OrbitsGlassButton(
            label: 'Добавить устройство',
            onPressed: _acceptPasted,
          ),
          const SizedBox(height: 16),
          for (final device in deviceRegistry.all)
            OrbitsGlassListTile(
              title: Text(device.name.isEmpty ? device.deviceId : device.name),
              subtitle: Text(
                device.status == DeviceStatus.revoked
                    ? 'отозвано'
                    : device.kind,
              ),
              trailing: device.status == DeviceStatus.active &&
                      device.deviceId != 'local-device'
                  ? TextButton(
                      onPressed: () {
                        deviceRegistry.revoke(device.deviceId);
                        setState(() {});
                      },
                      child: const Text('Отозвать'),
                    )
                  : null,
            ),
        ],
      ),
    );
  }
}
