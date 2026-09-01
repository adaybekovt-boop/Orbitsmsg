// Pure-Dart P-256 ECDH for VM tests.
//
// `package:cryptography` 2.9's DartEcdh throws UnimplementedError for
// newKeyPair / sharedSecretKey. Production web uses BrowserEcdh; Linux CI
// `flutter test` does not. PointyCastle (already a dependency) fills the gap
// so Double Ratchet tests can run without cryptography_flutter.

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:pointycastle/export.dart' as pc;

/// Installs [PointyCastleCryptography] as [Cryptography.instance].
///
/// Call this at the start of `main()` **before** any code first-touches
/// `Ecdh.p256()` (top-level `final _ecdh = Ecdh.p256(...)` in double_ratchet
/// captures the instance lazily).
void installPointyCastleEcdh() {
  Cryptography.instance = PointyCastleCryptography();
}

/// [DartCryptography] with working P-256 ECDH via PointyCastle.
class PointyCastleCryptography extends DartCryptography {
  @override
  Ecdh ecdhP256({required int length}) => const PointyCastleP256Ecdh();
}

class PointyCastleP256Ecdh extends Ecdh {
  const PointyCastleP256Ecdh() : super.constructor();

  @override
  KeyPairType get keyPairType => KeyPairType.p256;

  @override
  Future<EcKeyPair> newKeyPairFromSeed(List<int> seed) {
    throw UnimplementedError('P-256 ECDH from seed is unused in tests');
  }

  @override
  Future<EcKeyPair> newKeyPair() async {
    final generator = pc.ECKeyGenerator()
      ..init(
        pc.ParametersWithRandom(
          pc.ECKeyGeneratorParameters(_p256),
          _seededRandom(),
        ),
      );
    final pair = generator.generateKeyPair();
    final priv = pair.privateKey as pc.ECPrivateKey;
    final pub = pair.publicKey as pc.ECPublicKey;
    final q = pub.Q!;
    return EcKeyPairData(
      d: _bigIntToBytes(priv.d!, 32),
      x: _bigIntToBytes(q.x!.toBigInteger()!, 32),
      y: _bigIntToBytes(q.y!.toBigInteger()!, 32),
      type: KeyPairType.p256,
    );
  }

  @override
  Future<SecretKey> sharedSecretKey({
    required KeyPair keyPair,
    required PublicKey remotePublicKey,
  }) async {
    if (keyPair is! EcKeyPair) {
      throw ArgumentError.value(keyPair, 'keyPair', 'expected EcKeyPair');
    }
    if (remotePublicKey is! EcPublicKey) {
      throw ArgumentError.value(
        remotePublicKey,
        'remotePublicKey',
        'expected EcPublicKey',
      );
    }
    final data = await keyPair.extract();
    final priv = pc.ECPrivateKey(_bytesToBigInt(data.d), _p256);
    final q = _p256.curve.createPoint(
      _bytesToBigInt(remotePublicKey.x),
      _bytesToBigInt(remotePublicKey.y),
    );
    final pub = pc.ECPublicKey(q, _p256);
    final z = (pc.ECDHBasicAgreement()..init(priv)).calculateAgreement(pub);
    return SecretKey(_bigIntToBytes(z, 32));
  }
}

final pc.ECDomainParameters _p256 = pc.ECDomainParameters('prime256v1');

pc.FortunaRandom _seededRandom() {
  final rnd = pc.FortunaRandom();
  final seed = Uint8List(32);
  final dart = Random.secure();
  for (var i = 0; i < seed.length; i++) {
    seed[i] = dart.nextInt(256);
  }
  rnd.seed(pc.KeyParameter(seed));
  return rnd;
}

BigInt _bytesToBigInt(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}

/// IEEE P1363 R||S signature. Matches [signBytes] on the identity key.
Uint8List signP256Ecdsa(EcKeyPairData pair, List<int> data) {
  final priv = pc.ECPrivateKey(_bytesToBigInt(pair.d), _p256);
  final signer = pc.ECDSASigner(pc.SHA256Digest())
    ..init(true, pc.ParametersWithRandom(pc.PrivateKeyParameter(priv), _seededRandom()));
  final sig = signer.generateSignature(Uint8List.fromList(data)) as pc.ECSignature;
  final out = Uint8List(64);
  out.setAll(0, _bigIntToBytes(sig.r, 32));
  out.setAll(32, _bigIntToBytes(sig.s, 32));
  return out;
}

Future<EcKeyPairData> generateP256EcdsaKey() async {
  final pair = await const PointyCastleP256Ecdh().newKeyPair();
  return pair as EcKeyPairData;
}

Uint8List _bigIntToBytes(BigInt value, int length) {
  final out = Uint8List(length);
  var n = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (n & BigInt.from(0xff)).toInt();
    n = n >> 8;
  }
  return out;
}
