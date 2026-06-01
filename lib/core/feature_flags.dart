// Port of src/core/featureFlags.js — runtime feature flags.
//
// Module-level mutable state (matches JS). Persistence is out of scope here;
// UI code can call the setters on unlock if it reads from stored prefs.

/// Lowest wire-handshake protocol version we'll *complete*. v2 hellos are
/// unsigned — they carry no identity key, so accepting one silently skips the
/// signature check and the TOFU pin, leaving the session on a bare
/// DH-of-ephemerals secret with no binding to the peer's identity. A MITM on
/// the (untrusted) public relay can therefore force `v: 2` to bypass
/// verification entirely. The floor defaults to 3 so that downgrade is refused
/// outright; an operator can lower it to 2 only to interop with a legacy
/// unsigned peer, accepting the loss of authentication.
const int defaultMinProtocolVersion = 3;

class _Flags {
  bool x3dhEnabled = true;
  int minProtocolVersion = defaultMinProtocolVersion;
}

final _Flags _flags = _Flags();

/// Master switch for the X3DH fast path. When false, every handshake stays on
/// v3 (plain DH-of-ephemerals) even if a bundle is cached.
bool isX3dhEnabled() => _flags.x3dhEnabled;

void setX3dhEnabled(bool value) {
  _flags.x3dhEnabled = value;
}

/// The configured minimum acceptable handshake protocol version. See
/// [defaultMinProtocolVersion] for why the floor matters.
int minProtocolVersion() => _flags.minProtocolVersion;

/// Override the protocol floor. Values < 2 are clamped to 2 (v2 is the lowest
/// version the wire protocol defines). Lowering to 2 re-enables unsigned,
/// unauthenticated legacy hellos — only do this for an explicit migration.
void setMinProtocolVersion(int value) {
  _flags.minProtocolVersion = value < 2 ? 2 : value;
}

/// Whether unsigned legacy v2 hellos are permitted at all.
bool isLegacyV2Allowed() => _flags.minProtocolVersion <= 2;

/// Test-only reset. Do not call from production code.
void resetFlagsForTests() {
  _flags.x3dhEnabled = true;
  _flags.minProtocolVersion = defaultMinProtocolVersion;
}
