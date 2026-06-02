// Thin WebSocket transport for the RelayHub. This is the only file that knows
// about `ws` / sockets; all protocol logic lives in hub.js (which is dep-free
// and unit-tested). Keeping this layer thin means the security-critical code is
// the well-tested part.

import http from 'node:http';
import { pathToFileURL } from 'node:url';
import { WebSocketServer } from 'ws';
import { config as defaultConfig } from './config.js';
import { RelayHub } from './hub.js';

/** Structured stdout logger. NEVER receives or prints frame/payload content —
 * the hub only hands it counts, peer-id tails, and reject reasons. */
function safeLog(event, meta = {}) {
  // eslint-disable-next-line no-console
  console.log(JSON.stringify({ t: new Date().toISOString(), event, ...meta }));
}

/**
 * Create (but do not start) the relay HTTP+WS server.
 * @returns {{ httpServer: import('node:http').Server, wss: WebSocketServer, hub: RelayHub, close: () => Promise<void> }}
 */
export function createRelayServer({ config = defaultConfig, log = safeLog } = {}) {
  const hub = new RelayHub({ config, log });

  const httpServer = http.createServer((req, res) => {
    // Tiny health endpoint for load balancers / uptime checks. Exposes only
    // aggregate counts — never any peer id or frame.
    if (req.method === 'GET' && (req.url === '/healthz' || req.url === '/')) {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        ok: true,
        connections: hub.connectionCount,
        peers: hub.peerCount,
      }));
      return;
    }
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('not found');
  });

  // maxPayload enforces the size cap at the protocol layer: oversized frames
  // are rejected by `ws` itself (the hub double-checks as defense in depth).
  const wss = new WebSocketServer({ server: httpServer, maxPayload: config.maxRawMessageBytes });

  wss.on('connection', (ws) => {
    const conn = {
      send: (str) => ws.send(str),
      close: (code, reason) => {
        try { ws.close(code, reason); } catch { /* already closing */ }
      },
    };
    ws.isAlive = true;

    if (!hub.addConnection(conn)) return; // at capacity → hub closed it

    ws.on('message', (data, isBinary) => {
      // JSON text only. Binary frames are never valid relay traffic (and the
      // client never sends them) — drop without forwarding.
      if (isBinary) {
        log('reject', { reason: 'binary' });
        return;
      }
      try {
        hub.handleMessage(conn, data.toString('utf8'));
      } catch (err) {
        // A bug in routing must never crash the process or the socket loop.
        log('error', { where: 'handleMessage', name: err?.name });
      }
    });

    ws.on('pong', () => { ws.isAlive = true; });
    ws.on('close', () => hub.removeConnection(conn));
    ws.on('error', () => {
      try { ws.terminate(); } catch { /* ignore */ }
    });
  });

  // Liveness heartbeat: ping every heartbeatMs, terminate sockets that missed
  // the previous pong. Catches half-open TCP that `close` never fires for.
  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (ws.isAlive === false) {
        try { ws.terminate(); } catch { /* ignore */ }
        continue;
      }
      ws.isAlive = false;
      try { ws.ping(); } catch { /* ignore */ }
    }
  }, config.heartbeatMs);
  heartbeat.unref?.();

  async function close() {
    clearInterval(heartbeat);
    await new Promise((resolve) => wss.close(() => resolve()));
    await new Promise((resolve) => httpServer.close(() => resolve()));
  }

  return { httpServer, wss, hub, close };
}

/** Start listening. Returns the same handle as createRelayServer plus a ready promise. */
export function startRelayServer(opts = {}) {
  const cfg = opts.config ?? defaultConfig;
  const handle = createRelayServer(opts);
  return new Promise((resolve) => {
    handle.httpServer.listen(cfg.port, cfg.host, () => {
      safeLog('listening', { host: cfg.host, port: cfg.port });
      resolve(handle);
    });
  });
}

// Run directly: `node src/server.js`.
const isMain = process.argv[1]
  ? import.meta.url === pathToFileURL(process.argv[1]).href
  : false;

if (isMain) {
  startRelayServer().then((handle) => {
    const shutdown = () => {
      safeLog('shutdown', {});
      handle.close().finally(() => process.exit(0));
    };
    process.on('SIGINT', shutdown);
    process.on('SIGTERM', shutdown);
  });
}
