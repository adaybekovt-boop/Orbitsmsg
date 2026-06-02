// Chat appearance preferences (Settings → Чаты).
//
// REAL, consumed prefs: showSeconds (timestamp format), fontSize (message text
// scale), bubbleStyle (bubble shape) — all read by MessageBubble. Persisted
// under `orbits_chat_prefs_v1`, survive restart, apply live.
//
// The model still carries autoRead / messageSounds / vibration so older saved
// blobs round-trip, but those have no runtime consumer yet (read receipts and
// the sound/haptic-on-receive paths aren't implemented), so the Чаты screen
// shows them as disabled "СКОРО" rows rather than fake toggles.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kChatPrefsKey = 'orbits_chat_prefs_v1';

class ChatPrefs {
  const ChatPrefs({
    this.showSeconds = false,
    this.autoRead = true,
    this.messageSounds = true,
    this.vibration = true,
    this.fontSize = 'M',
    this.bubbleStyle = 'rounded',
  });

  final bool showSeconds;
  final bool autoRead;
  final bool messageSounds;
  final bool vibration;

  /// One of: 'XS', 'S', 'M', 'L', 'XL'.
  final String fontSize;

  /// One of: 'rounded', 'soft', 'square', 'bubble'.
  final String bubbleStyle;

  /// Multiplier applied to message text size in [MessageBubble].
  double get fontScale {
    switch (fontSize) {
      case 'XS':
        return 0.85;
      case 'S':
        return 0.92;
      case 'L':
        return 1.12;
      case 'XL':
        return 1.25;
      case 'M':
      default:
        return 1.0;
    }
  }

  ChatPrefs copyWith({
    bool? showSeconds,
    bool? autoRead,
    bool? messageSounds,
    bool? vibration,
    String? fontSize,
    String? bubbleStyle,
  }) =>
      ChatPrefs(
        showSeconds: showSeconds ?? this.showSeconds,
        autoRead: autoRead ?? this.autoRead,
        messageSounds: messageSounds ?? this.messageSounds,
        vibration: vibration ?? this.vibration,
        fontSize: fontSize ?? this.fontSize,
        bubbleStyle: bubbleStyle ?? this.bubbleStyle,
      );

  Map<String, Object?> toJson() => {
        'showSeconds': showSeconds,
        'autoRead': autoRead,
        'messageSounds': messageSounds,
        'vibration': vibration,
        'fontSize': fontSize,
        'bubbleStyle': bubbleStyle,
      };

  static ChatPrefs fromJson(Map raw) => ChatPrefs(
        showSeconds: raw['showSeconds'] == true,
        autoRead: raw['autoRead'] != false,
        messageSounds: raw['messageSounds'] != false,
        vibration: raw['vibration'] != false,
        fontSize: (raw['fontSize'] as String?) ?? 'M',
        bubbleStyle: (raw['bubbleStyle'] as String?) ?? 'rounded',
      );
}

class ChatPrefsNotifier extends StateNotifier<ChatPrefs> {
  ChatPrefsNotifier() : super(const ChatPrefs()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kChatPrefsKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map && mounted) state = ChatPrefs.fromJson(decoded);
    } catch (_) {
      // Defaults stand on any read/parse failure.
    }
  }

  Future<void> update(ChatPrefs next) async {
    state = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kChatPrefsKey, jsonEncode(next.toJson()));
    } catch (_) {
      // Non-fatal — in-memory state already updated for this session.
    }
  }
}

final chatPrefsProvider =
    StateNotifierProvider<ChatPrefsNotifier, ChatPrefs>(
  (ref) => ChatPrefsNotifier(),
);
