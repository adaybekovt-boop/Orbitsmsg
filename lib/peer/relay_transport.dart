// Phase 2 — encrypted text/control relay fallback.
//
// When a direct WebRTC DataChannel can't be established, text + control frames
// fall back to a relay server. The relay is a DUMB ROUTER: it forwards an
// opaque [RelayEnvelope.frame] from `from` → `to` and MUST NOT be able to read
// message content. A `frame` is exactly what the DataChannel would carry:
//   • an ENCRYPTED wire-ciphertext String (the Double-Ratchet envelope), or
//   • a signed control map (wireHello / ack) — public keys / acks, never body.
// So the relay never sees plaintext message text. The receive side feeds the
// frame back through the SAME packet router as a DataChannel frame, so
// handshake / decrypt / verify / ack-on-save are identical (no weaker path).
//
// Voice / file / drop / room frames are NOT routed here — only the text-message
// send path opts into the fallback (see messaging_notifier / connections).

import 'dart:async';

/// One routed frame. Carries only routing metadata + an opaque [frame]; never
/// a plaintext message body.
class RelayEnvelope {
  const RelayEnvelope({
    required this.from,
    required this.to,
    required this.id,
    required this.frame,
    required this.ts,
    this.ttlMs = defaultTtlMs,
    this.retry = 0,
  });

  static const int defaultTtlMs = 24 * 60 * 60 * 1000; // 24h

  /// Sender peer id.
  final String from;

  /// Receiver peer id.
  final String to;

  /// Frame/message id — lets the relay + receiver de-duplicate.
  final String id;

  /// Opaque payload: an encrypted wire String or a signed control map. The
  /// relay never interprets it; the receiver routes it through the packet
  /// router. NEVER plaintext message content.
  final Object frame;

  final int ts;
  final int ttlMs;
  final int retry;

  bool isExpired(int nowMs) => ttlMs > 0 && nowMs - ts > ttlMs;

  RelayEnvelope withRetry(int n) => RelayEnvelope(
        from: from,
        to: to,
        id: id,
        frame: frame,
        ts: ts,
        ttlMs: ttlMs,
        retry: n,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'v': 1,
        'type': 'relay',
        'from': from,
        'to': to,
        'id': id,
        'ts': ts,
        'ttl': ttlMs,
        'retry': retry,
        'frame': frame,
      };

  /// Parse a wire JSON map into an envelope, or null if it's malformed /
  /// missing a required field. Rejects anything without an opaque `frame`.
  static RelayEnvelope? tryParse(Object? json) {
    if (json is! Map) return null;
    final from = json['from'];
    final to = json['to'];
    final id = json['id'];
    final frame = json['frame'];
    if (from is! String ||
        to is! String ||
        id is! String ||
        from.isEmpty ||
        to.isEmpty ||
        id.isEmpty ||
        frame == null) {
      return null;
    }
    return RelayEnvelope(
      from: from,
      to: to,
      id: id,
      frame: frame,
      ts: (json['ts'] as num?)?.toInt() ?? 0,
      ttlMs: (json['ttl'] as num?)?.toInt() ?? defaultTtlMs,
      retry: (json['retry'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Transport that routes [RelayEnvelope]s. Optional — when not configured the
/// app uses [DisabledRelayTransport] and behaves exactly as WebRTC-only.
abstract class RelayTransport {
  /// True when a relay endpoint is configured for this build.
  bool get isConfigured;

  /// Connect (register [selfPeerId] so the relay can deliver to us). No-op for
  /// the disabled transport.
  Future<void> start(String selfPeerId);

  Future<void> stop();

  /// Hand [env] to the relay for delivery. Returns true iff the relay ACCEPTED
  /// it for forwarding — this is NOT a delivery confirmation. The receiver's
  /// end-to-end `ack` (routed back through the packet router) is the only thing
  /// that marks a message delivered.
  Future<bool> send(RelayEnvelope env);

  /// Envelopes the relay delivered to us (addressed to our peer id).
  Stream<RelayEnvelope> get inbound;
}

/// The default when no relay is configured: never sends, never receives. Keeps
/// the whole feature opt-in and the app fully functional WebRTC-only.
class DisabledRelayTransport implements RelayTransport {
  const DisabledRelayTransport();

  @override
  bool get isConfigured => false;

  @override
  Future<void> start(String selfPeerId) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<bool> send(RelayEnvelope env) async => false;

  @override
  Stream<RelayEnvelope> get inbound => const Stream<RelayEnvelope>.empty();
}
