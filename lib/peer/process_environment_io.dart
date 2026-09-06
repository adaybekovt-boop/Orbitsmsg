import 'dart:io';

/// Process environment for desktop/mobile. Flutter Linux GTK clients inherit
/// `ORBITS_PEERJS_*` from the launching shell (LOCAL TESTNET).
Map<String, String> orbitsProcessEnvironment() => Platform.environment;
