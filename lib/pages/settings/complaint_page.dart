import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../legal/legal_placeholders.dart';
import '../../themes/orbits_tokens.dart';
import '../../ui/primitives/adaptive_page_frame.dart';
import '../../ui/primitives/orbits_glass_app_bar.dart';
import '../../ui/primitives/orbits_glass_button.dart';

/// Abuse-report flow required for user-generated messaging content.
class ComplaintPage extends StatefulWidget {
  const ComplaintPage({super.key, this.peerId, this.messageId, this.launchUri});

  final String? peerId;
  final String? messageId;

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
    final uri = buildComplaintUri(
      peerId: widget.peerId,
      messageId: widget.messageId,
      note: _note.text,
    );
    final launch =
        widget.launchUri ??
        ((u) => launchUrl(u, mode: LaunchMode.externalApplication));
    final opened = await launch(uri);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть канал жалоб')),
      );
    }
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
              'Жалоба откроется в GitHub Issues проекта. '
              'Не вставляйте ключи, пароли или личные данные. '
              'Код собеседника будет добавлен автоматически.',
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
              label: 'Отправить жалобу',
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

Uri buildComplaintUri({String? peerId, String? messageId, String note = ''}) {
  final details = <String>[
    '## Жалоба на нарушение',
    '',
    if (peerId != null && peerId.trim().isNotEmpty)
      '- Код собеседника: `${peerId.trim()}`',
    if (messageId != null && messageId.trim().isNotEmpty)
      '- ID сообщения: `${messageId.trim()}`',
    '- Платформа: Orbits',
    '',
    '## Описание',
    note.trim().isEmpty ? 'Опишите нарушение.' : note.trim(),
  ].join('\n');

  final base = Uri.parse(kComplaintChannelUrl);
  return base.replace(
    queryParameters: <String, String>{
      'title': '[Abuse report] Orbits',
      'body': details,
    },
  );
}
