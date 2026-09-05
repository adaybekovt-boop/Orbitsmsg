// Canonical conversation id. Both peers derive the same value from
// their identities. It is not a local remotePeerId alias.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../peer/helpers.dart';

const String kConversationIdInfo = 'orbits-conversation-v1';

/// Domain-separated, order-independent conversation id for two members.
String conversationIdForPeers(String a, String b) {
  final left = normalizePeerId(a);
  final right = normalizePeerId(b);
  if (left.isEmpty || right.isEmpty) {
    throw ArgumentError('conversation members required');
  }
  final pair = left.compareTo(right) <= 0 ? '$left|$right' : '$right|$left';
  return sha256.convert(utf8.encode('$kConversationIdInfo|$pair')).toString();
}

bool conversationIdMatchesMembers(
  String conversationId, {
  required String selfPeerId,
  required String otherPeerId,
}) {
  return conversationId ==
      conversationIdForPeers(selfPeerId, otherPeerId);
}

/// True when [authenticatedPeerId] is a member of the conversation that
/// also includes [selfPeerId].
bool peerIsConversationMember({
  required String conversationId,
  required String selfPeerId,
  required String authenticatedPeerId,
}) {
  if (conversationId.isEmpty) return false;
  return conversationIdMatchesMembers(
    conversationId,
    selfPeerId: selfPeerId,
    otherPeerId: authenticatedPeerId,
  );
}
