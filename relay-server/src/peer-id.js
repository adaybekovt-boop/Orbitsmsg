// Peer-id rules — kept logically identical to the Flutter client
// (lib/peer/helpers.dart):
//   normalizePeerId = trim + UPPER-CASE
//   isValidPeerId   = matches ^ORBIT-[0-9A-F]{6}$ after normalization
//
// If the client's id format ever changes, update BOTH sides.

const VALID_PEER_ID = /^ORBIT-[0-9A-F]{6}$/;

export function normalizePeerId(raw) {
  return typeof raw === 'string' ? raw.trim().toUpperCase() : '';
}

export function isValidPeerId(raw) {
  return VALID_PEER_ID.test(normalizePeerId(raw));
}
