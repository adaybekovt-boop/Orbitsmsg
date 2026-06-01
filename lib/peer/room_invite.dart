// Invite code for a *self-hosted* room — the string a host shares so guests can
// reach the embedded signaling server running on the host's device.
//
// In the peerjs.com model the "room code" was simply the host's ORBIT id, and
// the public cloud knew how to reach that id. With the host running its own
// signaling server (embedded_signaling_server.dart) the cloud is out of the
// loop, so the invite must also carry *where* that server lives: the host's
// LAN address(es) + port, optionally a public ip:port (when UPnP/port-forward
// made the server reachable from the internet), and optionally a per-room key.
//
// The logical room identity does NOT change: `roomId` is still the host's ORBIT
// id, and the host-authoritative protocol still keys everything off
// `hostPeerId == roomId`. The extra fields only tell a guest's room-scoped
// PeerJsClient which WebSocket to dial.
//
// Wire format (v1), designed to survive copy/paste and QR with no ambiguity:
//
//   orbits-room:1;id=<ORBIT-XXXXXX>;h=<ip1,ip2,...>;p=<port>[;pub=<ip:port>][;k=<key>]
//
// • leading literal `orbits-room:` scheme, then `;`-separated tokens
// • first token is the format version (`1`)
// • remaining tokens are key=value; order-independent; unknown keys ignored
// • `h` is a comma-separated list of IPv4 LAN addresses (IPv6 deferred — the
//   server only enumerates IPv4 today, and `;`/`,` keep IPv4 unambiguous)
// • `pub` is a single `ip:port` reachable from the internet, omitted when LAN-only
//
// This module is pure (no dart:io / Flutter) so it is fully unit-testable.

import 'helpers.dart' show isValidPeerId, normalizePeerId;

const String _scheme = 'orbits-room:';
const int _formatVersion = 1;

/// A parsed/buildable self-hosted room invite.
class RoomInvite {
  RoomInvite({
    required String roomId,
    required List<String> lanHosts,
    required this.port,
    this.publicHostPort,
    this.key,
  })  : roomId = normalizePeerId(roomId),
        lanHosts = List<String>.unmodifiable(
          lanHosts.map((h) => h.trim()).where((h) => h.isNotEmpty),
        );

  /// The host's ORBIT id — also the logical room id (`hostPeerId == roomId`).
  final String roomId;

  /// IPv4 addresses on the host's local network(s); a LAN guest dials one.
  final List<String> lanHosts;

  /// Port the embedded signaling server bound to.
  final int port;

  /// `ip:port` reachable from the internet, or null when LAN-only.
  final String? publicHostPort;

  /// Per-room signaling key (the PeerJS `key`). Null → the default 'peerjs'.
  final String? key;

  bool get hasPublic =>
      publicHostPort != null && publicHostPort!.trim().isNotEmpty;

  /// True when this invite carries at least one way to reach the host.
  bool get isReachable => lanHosts.isNotEmpty || hasPublic;

  /// Candidate `ip:port` endpoints a guest should try, public first (works
  /// across networks), then LAN. De-duplicated, order preserved.
  List<String> get dialEndpoints {
    final out = <String>[];
    if (hasPublic) out.add(publicHostPort!.trim());
    for (final h in lanHosts) {
      final e = '$h:$port';
      if (!out.contains(e)) out.add(e);
    }
    return out;
  }

  /// Serialize to the wire string.
  String encode() {
    final sb = StringBuffer(_scheme)
      ..write(_formatVersion)
      ..write(';id=')
      ..write(roomId)
      ..write(';h=')
      ..write(lanHosts.join(','))
      ..write(';p=')
      ..write(port);
    if (hasPublic) sb.write(';pub=${publicHostPort!.trim()}');
    final k = key;
    if (k != null && k.isNotEmpty && k != 'peerjs') sb.write(';k=$k');
    return sb.toString();
  }

  /// Parse a wire string, or return null if it isn't a valid v1 invite.
  /// Lenient about surrounding whitespace; strict about the scheme, version,
  /// a valid ORBIT id, and a port in range.
  static RoomInvite? tryParse(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (!s.startsWith(_scheme)) return null;
    final body = s.substring(_scheme.length);
    if (body.isEmpty) return null;

    final tokens = body.split(';');
    // First token must be the supported version.
    if (int.tryParse(tokens.first.trim()) != _formatVersion) return null;

    final kv = <String, String>{};
    for (final tok in tokens.skip(1)) {
      final eq = tok.indexOf('=');
      if (eq <= 0) continue;
      kv[tok.substring(0, eq).trim()] = tok.substring(eq + 1).trim();
    }

    final id = normalizePeerId(kv['id']);
    if (!isValidPeerId(id)) return null;

    final port = int.tryParse(kv['p'] ?? '');
    if (port == null || port < 1 || port > 65535) return null;

    final hosts = (kv['h'] ?? '')
        .split(',')
        .map((h) => h.trim())
        .where((h) => h.isNotEmpty)
        .toList();

    final pub = kv['pub'];
    final hasPub = pub != null && pub.isNotEmpty;
    // Reject an invite that gives no way to reach the host at all.
    if (hosts.isEmpty && !hasPub) return null;

    return RoomInvite(
      roomId: id,
      lanHosts: hosts,
      port: port,
      publicHostPort: hasPub ? pub : null,
      key: (kv['k'] != null && kv['k']!.isNotEmpty) ? kv['k'] : null,
    );
  }

  @override
  String toString() => encode();
}
