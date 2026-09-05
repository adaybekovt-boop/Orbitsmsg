import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/core/pointycastle_cryptography.dart';

void main() {
  test('PointyCastle backend can mint and sign P-256 identity keys', () async {
    installPointyCastleEcdh();
    final ecdsa = Ecdsa.p256(Sha256());
    final pair = await ecdsa.newKeyPair();
    final sig = await ecdsa.sign([1, 2, 3], keyPair: pair);
    expect(await ecdsa.verify([1, 2, 3], signature: sig), isTrue);

    final ecdh = Ecdh.p256(length: 32);
    final a = await ecdh.newKeyPair();
    final b = await ecdh.newKeyPair();
    final sa = await ecdh.sharedSecretKey(
      keyPair: a,
      remotePublicKey: await b.extractPublicKey(),
    );
    final sb = await ecdh.sharedSecretKey(
      keyPair: b,
      remotePublicKey: await a.extractPublicKey(),
    );
    expect(await sa.extractBytes(), await sb.extractBytes());
  });
}
