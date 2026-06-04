// Pure-Dart phone detection from a User-Agent string.
//
// Used in two places that can't share the browser's UA-Client-Hints:
//   • the embedded signaling server (`embedded_signaling_server.dart`), which
//     only sees the raw `User-Agent` header on the HTTP upgrade and must reject
//     a phone-browser guest server-side;
//   • as the string-only fallback behind the richer client-side check in
//     `web/index.html` (which also has `navigator.userAgentData`).
//
// SCOPE: we block *phones*, not all touch devices. Tablets (iPad, Android
// tablets) and desktops are allowed. The rules mirror the JS gate in
// index.html so client and server agree:
//   • iPhone / iPod                       → phone
//   • Android *with* the `Mobile` token   → phone (Android tablets omit it)
//   • legacy mobile browsers              → phone
//   • iPad reports a desktop "Macintosh" UA on iPadOS → NOT matched (allowed)
//   • Dart/dart:io UA (native app guests) → NOT matched (allowed)
//
// Deliberately NOT based on screen width — a small laptop window must not be
// mistaken for a phone (audit requirement: don't rely on width alone).

final RegExp _iPhone = RegExp(r'iPhone|iPod', caseSensitive: false);
final RegExp _android = RegExp(r'Android', caseSensitive: false);
final RegExp _mobileToken = RegExp(r'Mobile', caseSensitive: false);
final RegExp _legacyMobile =
    RegExp(r'(BlackBerry|BB10|IEMobile|Opera Mini|webOS|Windows Phone)',
        caseSensitive: false);

/// True when [ua] looks like a mobile-phone web browser. Null / empty / any
/// non-phone UA (desktop, tablet, native Dart client) returns false.
bool isMobilePhoneUserAgent(String? ua) {
  if (ua == null) return false;
  final s = ua.trim();
  if (s.isEmpty) return false;
  if (_iPhone.hasMatch(s)) return true;
  // Android phones carry the `Mobile` token in Chrome's UA; Android *tablets*
  // drop it, so `Android` alone is treated as a tablet (allowed).
  if (_android.hasMatch(s) && _mobileToken.hasMatch(s)) return true;
  if (_legacyMobile.hasMatch(s)) return true;
  return false;
}
