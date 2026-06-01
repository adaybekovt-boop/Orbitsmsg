// Stub matching the API of src/games/blackjack21/sound.js. Real WebAudio
// synthesis isn't trivial to reproduce in Dart without an extra package, so
// every method is a no-op for now and `setSoundEnabled` just toggles a flag.
// When the team is ready to wire real audio, drop a `just_audio` /
// `audioplayers` implementation here without touching the page code.

bool _enabled = true;

void setBjSoundEnabled(bool v) {
  _enabled = v;
}

bool isBjSoundEnabled() => _enabled;

class BjSfx {
  const BjSfx();
  void deal() {}
  void hit() {}
  void flip() {}
  void bust() {}
  void blackjack() {}
  void win() {}
  void lose() {}
  void push() {}
}

const BjSfx bjSfx = BjSfx();
