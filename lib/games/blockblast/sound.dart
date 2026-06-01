// Port of src/games/blockblast/sound.js — Block Blast SFX helper.
//
// The JS version is a tiny WebAudio synthesizer: every effect is a short
// oscillator envelope, no asset files. There's no equivalent low-level audio
// graph API shipped with Flutter, and the current pubspec doesn't depend on
// a synth/audio package, so this is a NO-OP STUB that preserves the public
// API (`sfx.place()`, `sfx.clear1()`, etc. and `setSoundEnabled`).
//
// TODO to make these actually play:
//   1. Add `audioplayers: ^6.0.0` (or `just_audio`) to pubspec.yaml.
//   2. Ship short WAV/OGG samples in `assets/sfx/blockblast/`.
//   3. Replace the `_noop` bodies below with `AudioPlayer().play(...)` calls.
// Until then the game is silent; haptics (HapticFeedback via haptics.dart)
// still fire so placement/clear feedback is not completely missing.

bool _enabled = true;

void setSoundEnabled(bool v) {
  _enabled = v;
}

bool isSoundEnabled() => _enabled;

void _noop() {
  // If sound were wired up this is where the check would branch. Left as a
  // single function so future `if (!_enabled) return;` guards live in one
  // place when we swap the stub for real playback.
}

/// Block Blast SFX bank. Every method mirrors a callable on the JS `sfx`
/// object in `sound.js`. All are no-ops for now — see file header for how
/// to hook up real audio.
class BlockBlastSfx {
  const BlockBlastSfx();

  void pickUp() => _noop();   // tone 520Hz, 40ms, triangle
  void place() => _noop();    // tone 200Hz, 50ms, sawtooth
  void invalid() => _noop();  // tone 110Hz, 80ms, square
  void clear1() => _noop();   // sweep 440 → 660, 140ms, triangle
  void clear2() => _noop();   // two-step sweep 440 → 880 then 660 → 1100
  void clearBig() => _noop(); // three-step sweep climax for >= 3 lines
  void combo() => _noop();    // tone 660 then 990, triangle
  void levelUp() => _noop();  // 440 → 660 → 880 triangle arpeggio
  void gameOver() => _noop(); // sweep 440 → 110, 600ms, sawtooth
  void start() => _noop();    // 440 → 660 → 880 triangle arpeggio
}

/// Singleton instance the widget reaches for — mirrors `import { sfx }` in
/// the JS source. Keeping it as a const instance rather than top-level
/// functions matches the JS namespacing so porting is 1:1.
const BlockBlastSfx sfx = BlockBlastSfx();
