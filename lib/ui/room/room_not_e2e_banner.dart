// Persistent notice that room text/files are host-visible, not 1:1 E2E.

import 'package:flutter/material.dart';

import '../../peer/room_disclaimer.dart';
import '../../themes/orbits_tokens.dart';
import '../primitives/orbits_glass_surface.dart';

class RoomNotE2eBanner extends StatelessWidget {
  const RoomNotE2eBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      child: OrbitsGlassSurface(
        role: OrbitsGlassRole.card,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: tokens.accent2.withValues(alpha: 0.14),
            border: Border.all(color: tokens.accent2.withValues(alpha: 0.45)),
          ),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.visibility_outlined, color: tokens.accent2, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  kRoomNotE2eBannerRu,
                  style: TextStyle(
                    color: tokens.text,
                    fontSize: 12.5,
                    height: 1.35,
                    fontFamily: tokens.fontBody,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
