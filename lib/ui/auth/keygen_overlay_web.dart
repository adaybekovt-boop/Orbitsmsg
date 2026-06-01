// Web implementation of the crypto-busy loading overlay.
//
// Why this exists: on web the whole app runs on one thread. Deriving/verifying
// the vault key (scrypt) is intentionally CPU-heavy, so for those ~couple
// seconds the main thread is blocked and Flutter can't repaint — a Flutter
// spinner would freeze mid-spin and look like a crash.
//
// This overlay is a plain DOM layer whose spinner animates via a CSS
// `transform` keyframe. Transform/opacity animations run on the browser's
// COMPOSITOR thread, so they keep animating even while the JS main thread is
// blocked by scrypt. The result: a smooth, intentional loading screen instead
// of a frozen UI. Shown just before the KDF and removed after.
//
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
// Web-only DOM interop. `dart:html` is deprecated in favour of package:web +
// dart:js_interop, but this compositor-animated overlay is behaviour-critical
// (it must keep painting while the JS main thread is blocked by scrypt) and a
// migration is a sizeable js_interop rewrite with no functional gain — deferred.

import 'dart:html' as html;

const String _overlayId = 'orbits-crypto-busy-overlay';
const String _styleId = 'orbits-crypto-busy-style';

/// Inject a full-screen, compositor-animated loading overlay. Idempotent.
void showCryptoBusyOverlay({
  required bool isDark,
  required String title,
  required String subtitle,
}) {
  final doc = html.document;
  if (doc.getElementById(_overlayId) != null) return;

  final bg = isDark ? '#0C0D10' : '#F4F6F9';
  final fg = isDark ? '#F2F3F5' : '#14181F';
  final muted = isDark ? '#9BA1AC' : '#697586';
  final track = isDark ? 'rgba(255,255,255,0.14)' : 'rgba(20,24,31,0.12)';

  // Keyframes (compositor-friendly: transform + opacity). Injected once.
  if (doc.getElementById(_styleId) == null) {
    final style = html.StyleElement()
      ..id = _styleId
      ..text = '@keyframes orbits-spin{to{transform:rotate(360deg);}}'
          '@keyframes orbits-fade{from{opacity:0;}to{opacity:1;}}';
    doc.head?.append(style);
  }

  final overlay = html.DivElement()..id = _overlayId;
  overlay.style.cssText = 'position:fixed;inset:0;z-index:2147483600;'
      'display:flex;flex-direction:column;align-items:center;'
      'justify-content:center;background:$bg;'
      'font-family:Inter,system-ui,-apple-system,sans-serif;'
      'animation:orbits-fade 180ms ease-out;';

  final spinner = html.DivElement();
  spinner.style.cssText = 'width:46px;height:46px;border-radius:50%;'
      'border:3px solid $track;border-top-color:$fg;'
      'animation:orbits-spin 0.9s linear infinite;'
      'will-change:transform;transform:translateZ(0);';

  final titleEl = html.DivElement()
    ..text = title
    ..style.cssText =
        'color:$fg;font-size:16px;font-weight:600;margin-top:24px;'
            'text-align:center;padding:0 16px;';

  final subEl = html.DivElement()
    ..text = subtitle
    ..style.cssText = 'color:$muted;font-size:13px;margin-top:8px;'
        'max-width:300px;text-align:center;line-height:1.5;padding:0 16px;';

  overlay
    ..append(spinner)
    ..append(titleEl)
    ..append(subEl);
  doc.body?.append(overlay);
}

/// Remove the overlay (fades out then detaches).
void hideCryptoBusyOverlay() {
  final el = html.document.getElementById(_overlayId);
  if (el == null) return;
  el.style.transition = 'opacity 160ms ease-out';
  el.style.opacity = '0';
  Future<void>.delayed(const Duration(milliseconds: 180), el.remove);
}
