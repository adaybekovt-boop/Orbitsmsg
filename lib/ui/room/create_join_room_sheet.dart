// Create / join a room. Room packets are host-plaintext — this sheet is
// the pre-entry surface (A.2). Acknowledgement is added after the red test.

import 'package:flutter/material.dart';

import '../../peer/room_disclaimer.dart';
import '../../peer/room_plaintext_gate.dart';
import '../../peer/room_signaling_host.dart' show kServerHostDesktopOnlyMessage;
import '../../themes/orbits_tokens.dart';
import '../primitives/orbits_glass_button.dart';
import '../primitives/orbits_glass_surface.dart';

/// [isCreate] ? room name : invite code.
class JoinOrCreateResult {
  const JoinOrCreateResult(this.isCreate, this.value);
  final bool isCreate;
  final String value;
}

class CreateJoinRoomSheet extends StatefulWidget {
  const CreateJoinRoomSheet({
    super.key,
    required this.defaultName,
    required this.canCreate,
  });

  final String defaultName;
  final bool canCreate;

  @override
  State<CreateJoinRoomSheet> createState() => _CreateJoinRoomSheetState();
}

class _CreateJoinRoomSheetState extends State<CreateJoinRoomSheet> {
  late final TextEditingController _nameCtl;
  final TextEditingController _codeCtl = TextEditingController();
  bool _acked = false;

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController(
      text: widget.defaultName.isNotEmpty
          ? '${widget.defaultName}: сервер'
          : '',
    );
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _codeCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return OrbitsGlassSurface(
      role: OrbitsGlassRole.sheet,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            16,
            24,
            16 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: tokens.muted.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                kRoomNotE2eBannerRu,
                style: TextStyle(
                  color: tokens.text,
                  fontSize: 13,
                  height: 1.35,
                  fontFamily: tokens.fontBody,
                ),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                key: kRoomPlaintextAckKey,
                value: _acked,
                onChanged: (v) => setState(() => _acked = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  kRoomPlaintextAckLabelRu,
                  style: TextStyle(
                    color: tokens.text,
                    fontSize: 13,
                    fontFamily: tokens.fontBody,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _label('Создать сервер', tokens),
              const SizedBox(height: 8),
              if (widget.canCreate) ...[
                TextField(
                  controller: _nameCtl,
                  decoration: const InputDecoration(
                    hintText: 'Название сервера',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                OrbitsGlassButton(
                  label: 'Создать',
                  icon: Icons.add,
                  variant: OrbitsGlassVariant.primary,
                  expand: true,
                  onPressed: () {
                    final v = _nameCtl.text.trim();
                    if (v.isEmpty) return;
                    if (!roomPlaintextActionAllowed(
                      acknowledgedHostCanRead: _acked,
                    )) {
                      return;
                    }
                    Navigator.of(context).pop(JoinOrCreateResult(true, v));
                  },
                ),
              ] else
                _DesktopOnlyServerNote(tokens: tokens),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: Divider(color: tokens.muted.withValues(alpha: 0.3)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      'или',
                      style: TextStyle(
                        color: tokens.muted,
                        fontFamily: tokens.fontBody,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Divider(color: tokens.muted.withValues(alpha: 0.3)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _label('Подключиться по коду', tokens),
              const SizedBox(height: 8),
              TextField(
                controller: _codeCtl,
                textCapitalization: TextCapitalization.characters,
                style: TextStyle(
                  fontFamily: tokens.fontMono,
                  color: tokens.text,
                ),
                decoration: const InputDecoration(
                  hintText: 'ORBIT-XXXXXX',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              OrbitsGlassButton(
                label: 'Подключиться',
                icon: Icons.login,
                variant: OrbitsGlassVariant.secondary,
                expand: true,
                onPressed: () {
                  final v = _codeCtl.text.trim();
                  if (v.isEmpty) return;
                  if (!roomPlaintextActionAllowed(
                    acknowledgedHostCanRead: _acked,
                  )) {
                    return;
                  }
                  Navigator.of(context).pop(JoinOrCreateResult(false, v));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text, OrbitsTokens tokens) => Text(
    text.toUpperCase(),
    style: TextStyle(
      fontFamily: tokens.fontHeading,
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.8,
      color: tokens.muted,
    ),
  );
}

class _DesktopOnlyServerNote extends StatelessWidget {
  const _DesktopOnlyServerNote({required this.tokens});
  final OrbitsTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tokens.muted.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tokens.muted.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.desktop_windows_rounded, size: 18, color: tokens.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              kServerHostDesktopOnlyMessage,
              style: TextStyle(
                color: tokens.muted,
                fontSize: 12.5,
                height: 1.4,
                fontFamily: tokens.fontBody,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
