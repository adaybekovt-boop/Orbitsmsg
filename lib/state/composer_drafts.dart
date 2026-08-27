// Per-peer composer drafts. Survive leaving the chat and a process
// restart so a half-written message is not lost (R6-07).

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kComposerDraftsKey = 'orbits_composer_drafts_v1';

class ComposerDraftsNotifier extends StateNotifier<Map<String, String>> {
  ComposerDraftsNotifier() : super(const {}) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kComposerDraftsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final next = <String, String>{};
      decoded.forEach((key, value) {
        if (key is String && value is String && value.isNotEmpty) {
          next[key] = value;
        }
      });
      if (mounted) state = next;
    } catch (_) {}
  }

  String draftFor(String peerId) => state[peerId] ?? '';

  Future<void> setDraft(String peerId, String text) async {
    if (peerId.isEmpty) return;
    final trimmed = text; // keep spaces the user is mid-typing
    final next = Map<String, String>.from(state);
    if (trimmed.trim().isEmpty) {
      next.remove(peerId);
    } else {
      next[peerId] = trimmed;
    }
    state = next;
    await _persist(next);
  }

  Future<void> _persist(Map<String, String> next) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (next.isEmpty) {
        await prefs.remove(kComposerDraftsKey);
        return;
      }
      await prefs.setString(kComposerDraftsKey, jsonEncode(next));
    } catch (_) {}
  }
}

final composerDraftsProvider =
    StateNotifierProvider<ComposerDraftsNotifier, Map<String, String>>(
  (ref) => ComposerDraftsNotifier(),
);
