// CallKit / Telecom must not be given a Peer ID or display name.
// The OS sheet shows a generic Orbits call; the app maps the handle
// back after decrypt.

import 'dart:convert';

import 'package:crypto/crypto.dart';

const String kSystemCallDisplayName = 'Orbits';

String opaqueCallHandle(String callId) {
  final digest = sha256.convert(utf8.encode('orbits-call-handle-v1\n$callId'));
  return digest.toString().substring(0, 16);
}
