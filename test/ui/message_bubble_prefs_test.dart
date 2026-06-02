// MessageBubble honors chat preferences: show-seconds timestamp format and
// font-size scale actually change what is rendered.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/ui/chat/message_bubble.dart';

import '../helpers/test_theme.dart';

void main() {
  // A fixed local time → deterministic HH:MM(:SS) regardless of timezone,
  // because we round-trip local → epoch → local.
  final ts = DateTime(2026, 1, 1, 9, 8, 7).millisecondsSinceEpoch;

  Map<String, Object?> textRow() => {
        'id': 'm1',
        'peerId': 'ORBIT-AAAAAA',
        'direction': 'in',
        'status': 'delivered',
        'timestamp': ts,
        'payload': {'type': 'text', 'text': 'hello'},
      };

  Future<void> pumpBubble(
    WidgetTester tester, {
    double textScale = 1.0,
    String bubbleStyle = 'rounded',
    bool showSeconds = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: testOrbitsTheme(),
        home: Scaffold(
          body: MessageBubble(
            row: textRow(),
            textScale: textScale,
            bubbleStyle: bubbleStyle,
            showSeconds: showSeconds,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('showSeconds=false → HH:MM timestamp', (tester) async {
    await pumpBubble(tester, showSeconds: false);
    expect(find.text('09:08'), findsOneWidget);
    expect(find.text('09:08:07'), findsNothing);
  });

  testWidgets('showSeconds=true → HH:MM:SS timestamp', (tester) async {
    await pumpBubble(tester, showSeconds: true);
    expect(find.text('09:08:07'), findsOneWidget);
  });

  testWidgets('textScale scales the message text size', (tester) async {
    await pumpBubble(tester, textScale: 2.0);
    final t = tester.widget<Text>(find.text('hello'));
    expect(t.style?.fontSize, 30.0); // 15 * 2.0
  });

  testWidgets('default textScale renders the base size', (tester) async {
    await pumpBubble(tester);
    final t = tester.widget<Text>(find.text('hello'));
    expect(t.style?.fontSize, 15.0);
  });
}
