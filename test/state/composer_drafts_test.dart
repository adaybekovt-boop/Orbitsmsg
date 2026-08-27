import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:orbits_flutter/state/composer_drafts.dart';

void main() {
  test('draft survives a notifier remount (R6-07)', () async {
    SharedPreferences.setMockInitialValues({});
    final a = ComposerDraftsNotifier();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await a.setDraft('ORBIT-PEER01', 'unsent line');
    expect(a.draftFor('ORBIT-PEER01'), 'unsent line');

    final b = ComposerDraftsNotifier();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(b.draftFor('ORBIT-PEER01'), 'unsent line');

    await b.setDraft('ORBIT-PEER01', '   ');
    expect(b.draftFor('ORBIT-PEER01'), isEmpty);
  });
}
