// Fraud / abuse detector for room connections (Phase 5 — security).
//
// Pure in-memory logic (no I/O) so it stays deterministic and unit-testable.
// The RoomManager feeds it the IP it reads from each peer's ICE candidates and
// the timestamp of every inbound room message; the UI reads [findings] to show
// the red warning banner and [isBlocked] to hide a spamming peer's messages.
//
// Three signals:
//   • IP collision (sybil / cloning) — two or more DISTINCT peerIds connect
//     from the SAME IP. A classic attempt to impersonate several members.
//   • IP hop (session hijack)        — ONE peerId is seen from two different
//     IPs within a single session (its key may have been swapped mid-stream).
//   • Flood                          — more than [maxMessagesPerSecond] in a
//     one-second window from a peer ⇒ block its messages for [blockMs].

enum SecurityFindingKind { ipCollision, ipHop }

class SecurityFinding {
  const SecurityFinding(this.kind, this.peerId, this.message);

  final SecurityFindingKind kind;
  final String peerId;

  /// Human-readable, ready for the warning banner.
  final String message;

  @override
  String toString() => 'SecurityFinding($kind, $peerId, "$message")';
}

class SecurityMonitor {
  SecurityMonitor({
    this.maxMessagesPerSecond = 5,
    this.blockMs = 10000,
    this.windowMs = 1000,
  });

  /// Messages allowed per [windowMs]; the (n+1)-th trips the flood guard.
  final int maxMessagesPerSecond;

  /// How long (ms) a flooding peer stays muted once tripped.
  final int blockMs;

  /// Sliding window (ms) the rate limiter counts messages over.
  final int windowMs;

  final Map<String, Set<String>> _ipsByPeer = {};
  final Map<String, Set<String>> _peersByIp = {};
  final Map<String, List<int>> _msgTimes = {};
  final Map<String, int> _blockedUntil = {};
  final List<SecurityFinding> _findings = [];

  /// All fraud findings raised so far this session (newest last).
  List<SecurityFinding> get findings => List.unmodifiable(_findings);

  bool get hasAlerts => _findings.isNotEmpty;

  /// The latest finding, or null if the session is clean — drives the banner.
  SecurityFinding? get latestAlert =>
      _findings.isEmpty ? null : _findings.last;

  /// Record a connection from [peerId] at [ipAddress]. Returns a [SecurityFinding]
  /// if this connection looks fraudulent (and appends it to [findings]).
  SecurityFinding? recordConnection(String peerId, String ipAddress) {
    final ip = ipAddress.trim();
    if (peerId.isEmpty || ip.isEmpty) return null;

    final ipsForPeer = _ipsByPeer.putIfAbsent(peerId, () => <String>{});
    final peersForIp = _peersByIp.putIfAbsent(ip, () => <String>{});

    // IP hop: this peer was already known on a *different* IP.
    final hopped = ipsForPeer.isNotEmpty && !ipsForPeer.contains(ip);
    ipsForPeer.add(ip);
    peersForIp.add(peerId);

    SecurityFinding? finding;
    if (hopped) {
      finding = SecurityFinding(
        SecurityFindingKind.ipHop,
        peerId,
        'Участник сменил IP-адрес в рамках сессии — возможна подмена сеанса.',
      );
    } else if (peersForIp.length > 1) {
      finding = SecurityFinding(
        SecurityFindingKind.ipCollision,
        peerId,
        'Обнаружено подозрительное подключение! IP совпадает с другим участником.',
      );
    }
    if (finding != null) _findings.add(finding);
    return finding;
  }

  /// Record an inbound message from [peerId] at [nowMs] (epoch millis). Returns
  /// true if the peer is currently rate-limited and the message should be
  /// HIDDEN. Tripping the limit (the message that exceeds it) also returns true.
  bool recordMessage(String peerId, int nowMs) {
    if (peerId.isEmpty) return false;
    if (isBlocked(peerId, nowMs)) return true;

    final times = _msgTimes.putIfAbsent(peerId, () => <int>[]);
    times.add(nowMs);
    times.removeWhere((t) => t <= nowMs - windowMs);
    if (times.length > maxMessagesPerSecond) {
      _blockedUntil[peerId] = nowMs + blockMs;
      times.clear();
      return true;
    }
    return false;
  }

  /// Whether [peerId]'s messages are currently muted by the flood guard.
  bool isBlocked(String peerId, int nowMs) {
    final until = _blockedUntil[peerId];
    if (until == null) return false;
    if (nowMs >= until) {
      _blockedUntil.remove(peerId);
      return false;
    }
    return true;
  }

  /// Forget everything (e.g. on leaving a room).
  void reset() {
    _ipsByPeer.clear();
    _peersByIp.clear();
    _msgTimes.clear();
    _blockedUntil.clear();
    _findings.clear();
  }
}

/// Verification tier of a contact, derived from `PeersTable.trustLevel`.
///   • 2 → personally verified (safety-number confirmed) → green check.
///   • 1 → known/TOFU but not verified.
///   • 0/absent → unverified / suspicious → grey warning.
enum ContactVerification { verified, known, unverified }

ContactVerification verificationFromTrustLevel(int? trustLevel) {
  if (trustLevel == null) return ContactVerification.unverified;
  if (trustLevel >= 2) return ContactVerification.verified;
  if (trustLevel == 1) return ContactVerification.known;
  return ContactVerification.unverified;
}
