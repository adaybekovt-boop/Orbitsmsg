// RelayHub — the protocol/routing core of the relay server.
//
// Deliberately has NO transport dependency (no `ws`): it operates on abstract
// "connections" that expose `send(string)` and `close(code, reason)`. This
// keeps all the security-critical logic (validation, size caps, rate limiting,
// routing, anti-spoof) fully unit-testable with `node:test` and zero deps.
// `server.js` is the thin glue that adapts real WebSocket sockets to this API.
//
// CONTRACT THE HUB UPHOLDS (matches docs/relay-server.md):
//   • It is a dumb router. It NEVER inspects, logs, parses, or mutates the
//     opaque `frame` — it only measures its size and forwards it unchanged.
//   • Forwarding a frame is NOT delivery confirmation. End-to-end ack (handled
//     entirely by the clients) is the only proof of delivery.
//   • Only two message types exist: `register` and `relay`. Anything else is
//     rejected without crashing.
//   • A connection must `register` a valid peer id before it can `relay`, and
//     may only relay messages whose `from` equals its registered peer.

import crypto from 'node:crypto';
import { config as defaultConfig } from './config.js';
import { isValidPeerId, normalizePeerId } from './peer-id.js';
import { verifyRegistration } from './verify.js';

function byteLength(value) {
  if (typeof value === 'string') return Buffer.byteLength(value, 'utf8');
  if (value && typeof value.length === 'number') return value.length; // Buffer
  return 0;
}

function isNonEmptyString(v) {
  return typeof v === 'string' && v.length > 0;
}

function tail(id) {
  return id.length >= 4 ? id.slice(-4) : id;
}

export class RelayHub {
  /**
   * @param {object} [opts]
   * @param {object} [opts.config] limit overrides (see config.js)
   * @param {() => number} [opts.now] injectable clock (ms) for tests
   * @param {(event: string, meta?: object) => void} [opts.log] structured log;
   *   the hub NEVER passes frame/payload content to it.
   */
  constructor({ config = defaultConfig, now = () => Date.now(), log = () => {} } = {}) {
    this.config = config;
    this.now = now;
    this.log = log;
    /** @type {Set<object>} every live connection */
    this.connections = new Set();
    /** @type {Map<string, object>} normalized peerId -> connection (one socket per peer) */
    this.peers = new Map();
    /** @type {Map<string, string>} server-side TOFU: peerId -> base64 SPKI of
     * the identity key that first registered it. In-memory; resets on restart
     * (documented). */
    this.peerKeys = new Map();
    /** Monotonic, SAFE counters for /metrics. Never include frames, ids, keys,
     * or signatures — just aggregate counts. */
    this.stats = {
      totalRelayAttempts: 0,
      forwarded: 0,
      offlineRecipient: 0,
      rejectedMalformed: 0,
      rejectedAuth: 0,
      rejectedRateLimit: 0,
    };
  }

  /** A snapshot safe to expose at GET /metrics — counts only, no secrets. */
  metricsSnapshot() {
    return {
      activeConnections: this.connections.size,
      registeredPeers: this.peers.size,
      knownPeerKeys: this.peerKeys.size,
      ...this.stats,
    };
  }

  get connectionCount() {
    return this.connections.size;
  }

  get peerCount() {
    return this.peers.size;
  }

  /** Register a freshly-opened connection. Returns false (and closes it) when
   * the server is at capacity. */
  addConnection(conn) {
    if (this.connections.size >= this.config.maxConnections) {
      this.log('reject', { reason: 'max_connections' });
      this._safeClose(conn, 1013, 'server busy');
      return false;
    }
    conn._peer = null;
    conn._challenge = null;
    conn._rate = { tokens: this.config.rateCapacity, last: this.now() };
    this.connections.add(conn);
    this.log('connect', { connections: this.connections.size });
    // Authenticated registration (relay Phase 2): immediately challenge the
    // socket. It cannot register (or relay) until it answers with a valid
    // signature over the canonical blob bound to THIS nonce.
    this._issueChallenge(conn);
    return true;
  }

  _issueChallenge(conn) {
    const nonce = crypto.randomBytes(this.config.nonceBytes).toString('base64');
    conn._challenge = { nonce, issuedAt: this.now() };
    this._safeSend(conn, {
      type: 'relay_challenge',
      nonce,
      ts: this.now(),
      relay: this.config.serverId,
    });
  }

  /** Tear down a connection (called on socket close). Idempotent. */
  removeConnection(conn) {
    this.connections.delete(conn);
    if (conn._peer && this.peers.get(conn._peer) === conn) {
      this.peers.delete(conn._peer);
    }
    this.log('disconnect', { connections: this.connections.size });
  }

  /**
   * Handle one raw inbound message. Performs side effects (send/close) and
   * returns a small result object for tests: {action, reason?, peer?}.
   * Never throws on bad input.
   */
  handleMessage(conn, raw) {
    // 1) Size guard BEFORE parsing (anti-OOM). Transport also enforces this.
    if (byteLength(raw) > this.config.maxRawMessageBytes) {
      this.log('reject', { reason: 'oversize' });
      return { action: 'rejected', reason: 'oversize' };
    }
    // 2) Per-connection rate limit.
    if (!this._consumeToken(conn)) {
      this.stats.rejectedRateLimit++;
      this.log('reject', { reason: 'rate_limited' });
      this._safeSend(conn, { type: 'relay_error', reason: 'rate_limited' });
      return { action: 'rejected', reason: 'rate_limited' };
    }
    // 3) JSON only.
    let msg;
    try {
      msg = JSON.parse(typeof raw === 'string' ? raw : raw.toString('utf8'));
    } catch {
      this.stats.rejectedMalformed++;
      this.log('reject', { reason: 'bad_json' });
      return { action: 'rejected', reason: 'bad_json' };
    }
    if (msg === null || typeof msg !== 'object' || Array.isArray(msg) ||
        typeof msg.type !== 'string') {
      this.stats.rejectedMalformed++;
      this.log('reject', { reason: 'bad_message' });
      return { action: 'rejected', reason: 'bad_message' };
    }
    switch (msg.type) {
      case 'register': {
        const r = this._handleRegister(conn, msg);
        if (r.action === 'rejected') this.stats.rejectedAuth++;
        return r;
      }
      case 'relay': {
        this.stats.totalRelayAttempts++;
        const r = this._handleRelay(conn, msg);
        if (r.action === 'forwarded') {
          this.stats.forwarded++;
        } else if (r.action === 'offline') {
          this.stats.offlineRecipient++;
        } else if (r.action === 'rejected') {
          // not_registered / from_mismatch are auth failures; the rest
          // (bad_envelope, frame_too_big, expired) are malformed/invalid.
          if (r.reason === 'not_registered' || r.reason === 'from_mismatch') {
            this.stats.rejectedAuth++;
          } else {
            this.stats.rejectedMalformed++;
          }
        }
        return r;
      }
      default:
        this.stats.rejectedMalformed++;
        this.log('reject', { reason: 'unknown_type' });
        return { action: 'rejected', reason: 'unknown_type' };
    }
  }

  _handleRegister(conn, msg) {
    const peer = normalizePeerId(msg.peer);
    if (!peer || peer.length > this.config.maxPeerIdLen || !isValidPeerId(peer)) {
      this.log('reject', { reason: 'invalid_peer' });
      this._safeSend(conn, { type: 'register_error', reason: 'invalid_peer' });
      this._safeClose(conn, 4002, 'invalid peer');
      return { action: 'rejected', reason: 'invalid_peer' };
    }

    // ── Challenge / freshness gates ──
    const ch = conn._challenge;
    if (!ch) {
      this._safeSend(conn, { type: 'register_error', reason: 'no_challenge' });
      return { action: 'rejected', reason: 'no_challenge' };
    }
    if (this.now() - ch.issuedAt > this.config.challengeTtlMs) {
      this.log('reject', { reason: 'challenge_expired' });
      this._safeSend(conn, { type: 'register_error', reason: 'challenge_expired' });
      return { action: 'rejected', reason: 'challenge_expired' };
    }
    if (typeof msg.nonce !== 'string' || msg.nonce !== ch.nonce) {
      this.log('reject', { reason: 'bad_nonce' });
      this._safeSend(conn, { type: 'register_error', reason: 'bad_nonce' });
      return { action: 'rejected', reason: 'bad_nonce' };
    }
    const ts = msg.ts;
    if (typeof ts !== 'number' || !Number.isFinite(ts) ||
        Math.abs(this.now() - ts) > this.config.registerTsSkewMs) {
      this.log('reject', { reason: 'stale_ts' });
      this._safeSend(conn, { type: 'register_error', reason: 'stale_ts' });
      return { action: 'rejected', reason: 'stale_ts' };
    }

    // ── Signature ── (blob bound to OUR issued nonce + serverId)
    const idPubB64 = msg.idPub;
    const v = verifyRegistration({
      peer,
      nonce: ch.nonce,
      ts,
      relay: this.config.serverId,
      idPubB64,
      sigB64: msg.sig,
    });
    if (!v.ok) {
      this.log('reject', { reason: v.reason });
      this._safeSend(conn, { type: 'register_error', reason: v.reason });
      return { action: 'rejected', reason: v.reason };
    }

    // ── Server-side TOFU ── first valid registration pins peer→identity key;
    // a later DIFFERENT key for the same peer is a possible hijack → reject and
    // log a safe warning. (Never logs the key itself.)
    const known = this.peerKeys.get(peer);
    if (known && known !== idPubB64) {
      this.log('warn', { event: 'key_changed', peer: tail(peer) });
      this._safeSend(conn, { type: 'register_error', reason: 'key_changed' });
      return { action: 'rejected', reason: 'key_changed' };
    }
    if (!known) this.peerKeys.set(peer, idPubB64);

    // ── Duplicate registration (same peer + same key): REPLACE old socket ──
    const prior = this.peers.get(peer);
    if (prior && prior !== conn) {
      this.log('replace', { peer: tail(peer) });
      prior._peer = null;
      this.connections.delete(prior);
      this._safeClose(prior, 4001, 'registered elsewhere');
    }
    if (conn._peer && conn._peer !== peer && this.peers.get(conn._peer) === conn) {
      this.peers.delete(conn._peer);
    }
    conn._peer = peer;
    conn._challenge = null; // consumed
    this.peers.set(peer, conn);
    this.log('register', { peer: tail(peer), peers: this.peers.size });
    this._safeSend(conn, { type: 'register_ok', peer });
    return { action: 'registered', peer };
  }

  _handleRelay(conn, msg) {
    // Unregistered sockets cannot relay.
    if (!conn._peer) {
      this._safeSend(conn, {
        type: 'relay_error',
        id: typeof msg.id === 'string' ? msg.id : undefined,
        reason: 'not_registered',
      });
      this.log('reject', { reason: 'not_registered' });
      return { action: 'rejected', reason: 'not_registered' };
    }

    const { from, to, id, frame, ts } = msg;

    // Envelope shape: non-empty bounded strings + a present (non-null) frame.
    if (!isNonEmptyString(from) || from.length > this.config.maxPeerIdLen ||
        !isNonEmptyString(to) || to.length > this.config.maxPeerIdLen ||
        !isNonEmptyString(id) || id.length > this.config.maxIdLen ||
        frame === undefined || frame === null) {
      this.log('reject', { reason: 'bad_envelope' });
      return { action: 'rejected', reason: 'bad_envelope' };
    }

    // Frame size — measured (NEVER inspected). String length for ciphertext, or
    // serialized length for a control map (wireHello/wireRekey).
    const frameBytes = typeof frame === 'string'
      ? Buffer.byteLength(frame, 'utf8')
      : Buffer.byteLength(JSON.stringify(frame), 'utf8');
    if (frameBytes > this.config.maxFrameBytes) {
      this.log('reject', { reason: 'frame_too_big' });
      return { action: 'rejected', reason: 'frame_too_big' };
    }

    // Anti-spoof: a registered peer may only relay as itself.
    if (normalizePeerId(from) !== conn._peer) {
      this._safeSend(conn, { type: 'relay_error', id, reason: 'from_mismatch' });
      this.log('reject', { reason: 'from_mismatch' });
      return { action: 'rejected', reason: 'from_mismatch' };
    }

    // TTL: drop stale frames (clock skew into the future is tolerated).
    if (typeof ts === 'number' && Number.isFinite(ts)) {
      if (this.now() - ts > this.config.maxTtlMs) {
        this._safeSend(conn, { type: 'relay_error', id, reason: 'expired' });
        this.log('reject', { reason: 'expired' });
        return { action: 'rejected', reason: 'expired' };
      }
    }

    // Route to the recipient's live socket, if any.
    const target = this.peers.get(normalizePeerId(to));
    if (!target) {
      // Live-forward only — no persistent queue. Tell the sender (the client
      // safely ignores unknown message types today; see docs).
      this._safeSend(conn, { type: 'relay_error', id, reason: 'offline' });
      this.log('offline', {});
      return { action: 'offline', reason: 'offline' };
    }

    // Forward the ORIGINAL message verbatim — from/to/id/ts/frame preserved
    // exactly, frame untouched. No server metadata is added to client traffic.
    this._safeSend(target, msg);
    this.log('forward', {});
    return { action: 'forwarded' };
  }

  // Token-bucket rate limiter. Refills continuously at rateRefillPerSec.
  _consumeToken(conn) {
    const r = conn._rate;
    const now = this.now();
    const elapsedSec = Math.max(0, (now - r.last) / 1000);
    r.last = now;
    r.tokens = Math.min(
      this.config.rateCapacity,
      r.tokens + elapsedSec * this.config.rateRefillPerSec,
    );
    if (r.tokens < 1) return false;
    r.tokens -= 1;
    return true;
  }

  _safeSend(conn, obj) {
    try {
      conn.send(JSON.stringify(obj));
    } catch {
      // A dead socket throwing on send is not our problem — it'll be cleaned up
      // on close.
    }
  }

  _safeClose(conn, code, reason) {
    try {
      conn.close(code, reason);
    } catch {
      /* ignore */
    }
  }
}
