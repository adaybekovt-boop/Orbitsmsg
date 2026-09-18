import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AppTab { chats, drop, games, rooms, settings, profile }

final activeTabProvider = StateProvider<AppTab>((ref) => AppTab.chats);

/// Phone conversation route is open — hide the floating pill.
final mobileChatOpenProvider = StateProvider<bool>((ref) => false);
