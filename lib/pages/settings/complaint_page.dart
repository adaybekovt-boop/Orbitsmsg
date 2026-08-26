import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../legal/legal_placeholders.dart';
import '../../themes/orbits_tokens.dart';
import '../../ui/primitives/adaptive_page_frame.dart';
import '../../ui/primitives/orbits_glass_app_bar.dart';
import '../../ui/primitives/orbits_glass_button.dart';

/// Complaint slot. Channel and policy text are pending counsel.
class ComplaintPage extends StatefulWidget {
  const ComplaintPage({super.key, this.launchUri});

  /// Tests can inject a no-op. Production opens [kComplaintChannelUrl].
  final Future<bool> Function(Uri uri)? launchUri;

  @override
  State<ComplaintPage> createState() => _ComplaintPageState();
}

class _ComplaintPageState extends State<ComplaintPage> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _openChannel() async {
    final uri = Uri.parse(kComplaintChannelUrl);
    final launch = widget.launchUri ??
        ((u) => launchUrl(u, mode: LaunchMode.externalApplication));
    await launch(uri);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return Scaffold(
      appBar: OrbitsGlassAppBar(
        title: Text(
          'Жалоба',
          style: TextStyle(
            fontFamily: tokens.fontHeading,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: AdaptivePageFrame(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            Text(
              kLegalPendingPlaceholder,
              style: TextStyle(
                fontFamily: tokens.fontMono,
                fontSize: 13,
                color: tokens.muted,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _note,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: 'Описание (необязательно)',
                alignLabelWithHint: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(tokens.radiusButton),
                ),
              ),
            ),
            const SizedBox(height: 16),
            OrbitsGlassButton(
              key: kComplaintOpenChannelKey,
              label: 'Открыть внешний канал',
              icon: Icons.open_in_new,
              onPressed: _openChannel,
              variant: OrbitsGlassVariant.primary,
              size: OrbitsGlassSize.large,
              expand: true,
            ),
          ],
        ),
      ),
    );
  }
}
