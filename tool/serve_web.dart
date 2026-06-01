// Local dev server for the Flutter-web build with the Cross-Origin headers
// that Drift's wasm-backed sqlite3 needs to access SharedArrayBuffer.
//
// Why this exists:
//   Drift on web uses sqlite3.wasm + a dedicated drift worker. Both rely
//   on `SharedArrayBuffer` for fast cross-isolate transfers. Browsers
//   gate `SharedArrayBuffer` behind cross-origin isolation, which requires
//   two response headers on every document/script load:
//
//     Cross-Origin-Embedder-Policy: require-corp
//     Cross-Origin-Opener-Policy:   same-origin
//
//   `flutter run -d chrome` does NOT set these headers — so on every cold
//   start the worker fails over to the IndexedDB fallback, which is an
//   order of magnitude slower (each query is a round-trip to IDB instead
//   of an in-memory sqlite call). That's the "очень долго открывается"
//   we've been seeing.
//
// How to use:
//   1. Build the web bundle:   `flutter build web --release`
//      (or `flutter build web` for a debug bundle that's still faster
//       than `flutter run`)
//   2. Run this server:        `dart run tool/serve_web.dart`
//   3. Open http://localhost:8080
//
//   For hot-reload-style development without rebuild, point this server
//   at `flutter run -d web-server --web-port=8081` upstream — but the
//   simpler workflow is to rebuild (~10 s) when you want to perf-test.
//
// In production: configure the same headers on whatever hosts the
// `build/web` directory (nginx `add_header`, Cloudflare Pages `_headers`,
// Caddy `header`, etc.). This file is dev-only.

import 'dart:io';

const int _port = 8080;
const String _root = 'build/web';

Future<void> main(List<String> args) async {
  final port = int.tryParse(_envOr('PORT', '$_port')) ?? _port;
  final root = _envOr('WEB_ROOT', _root);

  final dir = Directory(root);
  if (!dir.existsSync()) {
    stderr.writeln(
      '[serve_web] $root not found. Run `flutter build web` first '
      '(or set WEB_ROOT=path/to/your/build/web).',
    );
    exit(1);
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('[serve_web] http://localhost:$port  (root: $root)');
  stdout.writeln(
    '[serve_web] COEP=require-corp  COOP=same-origin  '
    '→ SharedArrayBuffer enabled',
  );

  await for (final req in server) {
    // Each request runs concurrently — we don't await `_handle` so a slow
    // wasm download doesn't block subsequent requests sitting on the
    // accept queue. The function is structured to never throw out of its
    // catch — any unexpected error closes the response itself.
    unawaited(_handle(req, root));
  }
}

/// Silence the linter's `unawaited_futures` warning without pulling in
/// `package:async` for one helper.
void unawaited(Future<void> _) {}

Future<void> _handle(HttpRequest req, String root) async {
  try {
    // Always set the cross-origin isolation headers — they're cheap and
    // browsers ignore them on responses that don't matter (image bytes etc).
    req.response.headers
      ..set('Cross-Origin-Embedder-Policy', 'require-corp')
      ..set('Cross-Origin-Opener-Policy', 'same-origin')
      // `cross-origin` lets sub-resources (the wasm + worker scripts that
      // Drift loads) be embedded into a require-corp document. Without
      // this, Chrome refuses to instantiate the worker even with COEP set.
      ..set('Cross-Origin-Resource-Policy', 'cross-origin');

    // Map URL → file. Treat `/` as `/index.html`. Strip query strings.
    var path = req.uri.path;
    if (path.endsWith('/')) path += 'index.html';
    // Reject path traversal attempts so we never serve outside `root`.
    if (path.contains('..')) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    final file = File('$root$path');
    if (!file.existsSync()) {
      req.response
        ..statusCode = HttpStatus.notFound
        ..write('404: $path');
      await req.response.close();
      return;
    }

    // Set Content-Type from the extension. The browser will refuse to run
    // .wasm without `application/wasm`, refuse to import `.js` modules
    // without `text/javascript`, etc.
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    final mime = _mimeFor(ext);
    if (mime != null) req.response.headers.contentType = ContentType.parse(mime);

    // Stream the file directly — `pipe` handles backpressure for big assets
    // (canvaskit.wasm is ~3 MB, the main.dart.js bundle in debug mode can
    // run much larger).
    await file.openRead().pipe(req.response);
  } catch (e) {
    // Gracefully catch and ignore socket/disconnect errors from the client
    // so the server doesn't crash on page refreshes or quick exits.
    try {
      await req.response.close();
    } catch (_) {}
  }
}

String _envOr(String key, String fallback) {
  final v = Platform.environment[key];
  return v == null || v.isEmpty ? fallback : v;
}

String? _mimeFor(String ext) => switch (ext) {
      'html' => 'text/html; charset=utf-8',
      'js' => 'text/javascript; charset=utf-8',
      'mjs' => 'text/javascript; charset=utf-8',
      'json' => 'application/json; charset=utf-8',
      'wasm' => 'application/wasm',
      'css' => 'text/css; charset=utf-8',
      'svg' => 'image/svg+xml',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'ico' => 'image/x-icon',
      'woff' => 'font/woff',
      'woff2' => 'font/woff2',
      'ttf' => 'font/ttf',
      'otf' => 'font/otf',
      'map' => 'application/json',
      _ => null,
    };
