// Authorisation for inbound chat control (ack / edit / delete).
//
// A peer who completed the wire handshake could previously mark any id as
// delivered or rewrite/tombstone a message they did not send. These helpers
// require the stored row to belong to this conversation and the right
// direction.

import '../peer/helpers.dart';

bool _samePeer(Object? stored, String remoteId) {
  if (stored is! String || stored.isEmpty) return false;
  return normalizePeerId(stored) == normalizePeerId(remoteId);
}

/// [remoteId] may edit/delete this row only if it is an inbound message
/// from that peer (direction `in` in this conversation).
bool remoteOwnsInboundMessage(String remoteId, Map<String, Object?>? row) {
  if (row == null) return false;
  if (!_samePeer(row['peerId'], remoteId)) return false;
  return row['direction'] == 'in';
}

/// [remoteId] may ACK this row only if we sent it to them (direction `out`).
bool remoteCanAckOutbound(String remoteId, Map<String, Object?>? row) {
  if (row == null) return false;
  if (!_samePeer(row['peerId'], remoteId)) return false;
  return row['direction'] == 'out';
}
