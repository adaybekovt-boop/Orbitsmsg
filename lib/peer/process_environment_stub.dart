/// Web has no OS environment. 1:1 signaling stays on compile-time dart-defines
/// or public PeerJS — never an inferred localhost fallback.
Map<String, String> orbitsProcessEnvironment() => const {};
