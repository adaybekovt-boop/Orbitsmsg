// Profile editor — set displayName, bio, avatar; show peerId.
//
// Lives off Settings → Профиль. Mirrors the React `<ProfileEditor />`
// from `src/components/settings/ProfileEditor.jsx`:
//
//   • Avatar circle on top with a small "edit" pencil overlay. Tap →
//     native file picker → resize to 256×256 JPEG via `avatar_resize`.
//     Long-press (or a "Удалить" menu item) clears the avatar.
//   • Display name field with the same validation as onboarding (3-30
//     chars, [\p{L}\p{N}_]).
//   • Bio field, 220-char cap (matches `LocalProfile.fromJson` truncation).
//   • Peer ID block — non-editable, copy + show-as-QR buttons.
//   • Save button at the bottom; disabled while there are no diffs.
//
// State flow is plain `setState` because there's exactly one consumer
// (this page) — pulling the auth notifier in is the only Riverpod
// involvement. On save we call `AuthNotifier.updateProfile(...)` which
// persists to SharedPreferences and rebuilds anything reading
// `localProfileProvider`.

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth_validation.dart';
import '../../core/avatar_resize.dart';
import '../../core/haptics.dart';
import '../../state/auth_notifier.dart';
import '../../themes/orbits_tokens.dart';
import '../primitives/orbits_glass_button.dart';
import '../primitives/orbits_glass_app_bar.dart';
import '../primitives/orbits_glass_surface.dart';
import 'my_qr_page.dart';

class ProfileEditPage extends ConsumerStatefulWidget {
  const ProfileEditPage({super.key});

  @override
  ConsumerState<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends ConsumerState<ProfileEditPage> {
  late final TextEditingController _nameCtl;
  late final TextEditingController _bioCtl;

  /// Initial values — used to detect "is the form dirty?" so we can grey
  /// out the save button when nothing's changed.
  late String _initialName;
  late String _initialBio;
  String? _initialAvatar;

  /// Current avatar as a `data:image/jpeg;base64,...` URL, or null when
  /// the user has cleared it. Lives outside the notifier until save so
  /// "cancel" semantics are obvious (just leave the page).
  String? _avatarDataUrl;

  bool _busy = false;
  String? _error;
  String? _peerId;

  @override
  void initState() {
    super.initState();
    final user = ref.read(authNotifierProvider);
    if (user is AuthAuthed) {
      _initialName = user.user.displayName;
      _initialBio = user.user.bio;
      _initialAvatar = user.user.avatarDataUrl;
      _avatarDataUrl = user.user.avatarDataUrl;
      _peerId = user.user.peerId;
    } else {
      _initialName = '';
      _initialBio = '';
      _initialAvatar = null;
    }
    _nameCtl = TextEditingController(text: _initialName);
    _bioCtl = TextEditingController(text: _initialBio);
    _nameCtl.addListener(_onChange);
    _bioCtl.addListener(_onChange);
  }

  @override
  void dispose() {
    _nameCtl.removeListener(_onChange);
    _bioCtl.removeListener(_onChange);
    _nameCtl.dispose();
    _bioCtl.dispose();
    super.dispose();
  }

  void _onChange() {
    // Cheap rebuild — just to update the save-button enabled state.
    setState(() {});
  }

  bool get _dirty {
    if (_nameCtl.text.trim() != _initialName) return true;
    if (_bioCtl.text.trim() != _initialBio) return true;
    if (_avatarDataUrl != _initialAvatar) return true;
    return false;
  }

  Future<void> _pickAvatar() async {
    if (_busy) return;
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) {
        setState(() => _busy = false);
        return;
      }
      final file = picked.files.single;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        setState(() {
          _busy = false;
          _error = 'Не удалось прочитать файл';
        });
        return;
      }
      // Convert the file extension into a MIME hint so `resizeAvatarBytes`
      // can apply its image/* gate. file_picker doesn't always set MIME
      // but extension is reliable.
      final mime = _mimeFromExt(file.extension);
      final resized = await resizeAvatarBytes(bytes, mimeType: mime);
      final dataUrl = 'data:image/jpeg;base64,${base64Encode(resized)}';
      if (!mounted) return;
      setState(() {
        _avatarDataUrl = dataUrl;
        _busy = false;
      });
    } on AvatarError catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _busy = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Не удалось обработать картинку';
          _busy = false;
        });
      }
    }
  }

  String? _mimeFromExt(String? ext) {
    if (ext == null) return null;
    final e = ext.toLowerCase();
    if (e == 'jpg' || e == 'jpeg') return 'image/jpeg';
    if (e == 'png') return 'image/png';
    if (e == 'webp') return 'image/webp';
    if (e == 'heic' || e == 'heif') return 'image/heic';
    return 'image/$e';
  }

  Future<void> _save() async {
    if (_busy || !_dirty) return;

    final nameVal = validateUsername(_nameCtl.text);
    if (!nameVal.ok) {
      setState(() => _error = 'Ник: 3–30 символов, буквы/цифры/подчёркивание');
      return;
    }
    setState(() {
      _error = null;
      _busy = true;
    });

    try {
      final notifier = ref.read(authNotifierProvider.notifier);
      // Differentiate "kept", "changed", "removed" by comparing against
      // initial state rather than letting the notifier guess.
      if (_avatarDataUrl == null && _initialAvatar != null) {
        // User explicitly cleared.
        await notifier.updateProfile(
          displayName: _nameCtl.text,
          bio: _bioCtl.text.trim(),
          removeAvatar: true,
        );
      } else if (_avatarDataUrl != _initialAvatar) {
        // User picked a new one.
        await notifier.updateProfile(
          displayName: _nameCtl.text,
          bio: _bioCtl.text.trim(),
          avatarDataUrl: _avatarDataUrl,
        );
      } else {
        // Avatar unchanged — leave it alone.
        await notifier.updateProfile(
          displayName: _nameCtl.text,
          bio: _bioCtl.text.trim(),
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Профиль сохранён'),
            duration: Duration(seconds: 1),
          ),
        );
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Не удалось сохранить: $e';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final bioLen = _bioCtl.text.length;

    return Scaffold(
      appBar: OrbitsGlassAppBar(
        title: Text(
          'Профиль',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
            color: tokens.text,
          ),
        ),
        actions: [
          OrbitsGlassButton(
            label: 'Сохранить',
            variant: OrbitsGlassVariant.subtle,
            size: OrbitsGlassSize.small,
            enabled: !_busy && _dirty,
            onPressed: (_busy || !_dirty) ? null : _save,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            children: [
              // ── Avatar block ──────────────────────────────────────
              Center(
                child: _AvatarPicker(
                  dataUrl: _avatarDataUrl,
                  fallbackInitial: (_nameCtl.text.trim().isNotEmpty
                          ? _nameCtl.text
                          : (_peerId ?? '?'))
                      .characters
                      .first
                      .toUpperCase(),
                  busy: _busy,
                  onTap: _pickAvatar,
                  onClear: _avatarDataUrl == null
                      ? null
                      : () {
                          hapticTap();
                          setState(() => _avatarDataUrl = null);
                        },
                ),
              ),
              const SizedBox(height: 28),

              // ── Display name ──────────────────────────────────────
              TextField(
                controller: _nameCtl,
                maxLength: 30,
                style: TextStyle(
                  fontFamily: tokens.fontBody,
                  fontSize: 15,
                  color: tokens.text,
                ),
                decoration: _glassInput(
                  tokens,
                  labelText: 'Ник',
                  hintText: 'Как тебя видят собеседники',
                ),
              ),
              const SizedBox(height: 12),

              // ── Bio ───────────────────────────────────────────────
              TextField(
                controller: _bioCtl,
                maxLines: 3,
                maxLength: 220,
                style: TextStyle(
                  fontFamily: tokens.fontBody,
                  fontSize: 15,
                  color: tokens.text,
                ),
                decoration: _glassInput(
                  tokens,
                  labelText: 'О себе',
                  hintText: 'Опционально, 220 символов',
                  counterText: '$bioLen/220',
                ),
              ),

              const SizedBox(height: 20),

              // ── Peer ID ───────────────────────────────────────────
              if (_peerId != null) _PeerIdCard(peerId: _peerId!, tokens: tokens),

              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: tokens.dangerAlpha(0.12),
                    borderRadius: BorderRadius.circular(tokens.radiusButton),
                    border: Border.all(color: tokens.dangerAlpha(0.4)),
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(color: tokens.danger),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Glass-styled [InputDecoration] for the editor's text fields — matches
/// the chat composer (filled translucent surface, hairline border, accent
/// focus ring). Label/hint/counter copy is passed through unchanged.
InputDecoration _glassInput(
  OrbitsTokens t, {
  required String labelText,
  required String hintText,
  String? counterText,
}) {
  final radius = BorderRadius.circular(t.radiusButton);
  return InputDecoration(
    labelText: labelText,
    labelStyle: TextStyle(color: t.muted, fontFamily: t.fontBody),
    hintText: hintText,
    hintStyle: TextStyle(color: t.muted, fontFamily: t.fontBody),
    counterText: counterText,
    counterStyle: TextStyle(color: t.muted, fontFamily: t.fontMono),
    filled: true,
    fillColor: t.surface.withValues(alpha: 0.55),
    border: OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: t.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: t.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: t.accent, width: 1.4),
    ),
  );
}

/// Round avatar with a small "camera/edit" badge in the corner. Tapping
/// the avatar opens the file picker; the long-press / clear option only
/// shows when there's actually an avatar to clear.
class _AvatarPicker extends StatelessWidget {
  const _AvatarPicker({
    required this.dataUrl,
    required this.fallbackInitial,
    required this.busy,
    required this.onTap,
    required this.onClear,
  });

  final String? dataUrl;
  final String fallbackInitial;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    final bytes = _decodeDataUrl(dataUrl);

    Widget avatar;
    if (bytes != null) {
      avatar = ClipOval(
        child: Image.memory(
          bytes,
          width: 120,
          height: 120,
          fit: BoxFit.cover,
          // Match the on-screen size — bytes already encode at 256², so
          // a DPR-aware cacheWidth keeps it from re-decoding for the
          // bigger fullscreen preview if we ever surface that.
          cacheWidth: (120 * MediaQuery.devicePixelRatioOf(context)).round(),
        ),
      );
    } else {
      avatar = Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          color: tokens.accentAlpha(0.18),
          shape: BoxShape.circle,
          border: Border.all(color: tokens.border, width: 2),
        ),
        alignment: Alignment.center,
        child: Text(
          fallbackInitial,
          style: TextStyle(
            fontSize: 48,
            fontWeight: FontWeight.w600,
            fontFamily: tokens.fontHeading,
            color: tokens.accent,
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          if (busy)
            Positioned.fill(
              child: Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black54,
                ),
                child: const Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          // Edit badge — bottom-right.
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: tokens.accent,
                shape: BoxShape.circle,
                border: Border.all(color: tokens.bg, width: 2),
              ),
              child: Icon(
                Icons.camera_alt_outlined,
                size: 18,
                color: tokens.bg,
              ),
            ),
          ),
          // Clear (X) badge — top-right, only when there's an avatar.
          if (onClear != null)
            Positioned(
              right: -8,
              top: -8,
              child: OrbitsGlassIconButton(
                icon: Icons.close,
                tooltip: 'Удалить аватар',
                variant: OrbitsGlassVariant.danger,
                size: OrbitsGlassSize.small,
                onPressed: onClear,
              ),
            ),
        ],
      ),
    );
  }

  /// Pull bytes out of a `data:image/...;base64,...` URL. Returns null
  /// for null input or any malformed payload — the caller falls back to
  /// the initial-letter avatar.
  Uint8List? _decodeDataUrl(String? url) {
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

class _PeerIdCard extends StatelessWidget {
  const _PeerIdCard({required this.peerId, required this.tokens});
  final String peerId;
  final OrbitsTokens tokens;

  @override
  Widget build(BuildContext context) {
    return OrbitsGlassSurface(
      role: OrbitsGlassRole.card,
      borderRadius: BorderRadius.circular(tokens.radiusCard),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'МОЙ КОД',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFamily: tokens.fontMono,
              color: tokens.muted,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  peerId,
                  style: TextStyle(
                    fontFamily: tokens.fontMono,
                    fontSize: 15,
                    color: tokens.text,
                  ),
                ),
              ),
              OrbitsGlassIconButton(
                icon: Icons.copy_outlined,
                tooltip: 'Скопировать',
                variant: OrbitsGlassVariant.subtle,
                size: OrbitsGlassSize.small,
                onPressed: () async {
                  hapticTap();
                  await Clipboard.setData(ClipboardData(text: peerId));
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
              const SizedBox(width: 4),
              OrbitsGlassIconButton(
                icon: Icons.qr_code_2_outlined,
                tooltip: 'QR-код',
                variant: OrbitsGlassVariant.subtle,
                size: OrbitsGlassSize.small,
                onPressed: () {
                  hapticTap();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MyQrPage(peerId: peerId),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Покажи QR другу — это самый быстрый способ обменяться кодом.',
            style: TextStyle(
              fontSize: 12,
              color: tokens.muted,
              fontFamily: tokens.fontBody,
            ),
          ),
        ],
      ),
    );
  }
}
