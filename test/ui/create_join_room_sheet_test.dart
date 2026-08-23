// A.2 — create/join must not complete until the host-plaintext ack is ticked.
// Round 1 only grepped for a missing room_crypto.dart and a banner string.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/room_disclaimer.dart';
import 'package:orbits_flutter/peer/room_plaintext_gate.dart';
import 'package:orbits_flutter/ui/room/create_join_room_sheet.dart';

import '../helpers/test_theme.dart';

void main() {
  testWidgets(
    'create/join stay blocked until the host-can-read box is ticked',
    (tester) async {
      JoinOrCreateResult? result;

      await tester.pumpWidget(
        MaterialApp(
          theme: testOrbitsTheme(),
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showModalBottomSheet<JoinOrCreateResult>(
                    context: ctx,
                    isScrollControlled: true,
                    builder: (_) => const CreateJoinRoomSheet(
                      defaultName: 'Me',
                      canCreate: true,
                    ),
                  );
                },
                child: const Text('open-sheet'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open-sheet'));
      await tester.pumpAndSettle();

      expect(find.text(kRoomNotE2eBannerRu), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'Test Room');
      await tester.tap(find.text('Создать'));
      await tester.pumpAndSettle();

      expect(
        result,
        isNull,
        reason: 'create must not pop before the host-plaintext ack',
      );

      expect(find.byKey(kRoomPlaintextAckKey), findsOneWidget);

      await tester.tap(find.byKey(kRoomPlaintextAckKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Создать'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.isCreate, isTrue);
      expect(result!.value, 'Test Room');
    },
  );

  test('send/create helper is fail-closed without ack', () {
    expect(roomPlaintextActionAllowed(acknowledgedHostCanRead: false), isFalse);
    expect(roomPlaintextActionAllowed(acknowledgedHostCanRead: true), isTrue);
  });
}
