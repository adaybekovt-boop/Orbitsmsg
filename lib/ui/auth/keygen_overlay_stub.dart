// Native stub for the conditional-import crypto-busy overlay (see
// onboarding_page / unlock_page).
//
// On mobile/desktop scrypt runs in a background isolate, so the in-Flutter
// `CryptoBusyView` animates normally and no DOM overlay is needed. These
// no-ops let the non-web build compile.

/// Show a compositor-driven loading overlay (web only). No-op on native.
void showCryptoBusyOverlay({
  required bool isDark,
  required String title,
  required String subtitle,
}) {}

/// Remove the loading overlay (web only). No-op on native.
void hideCryptoBusyOverlay() {}
