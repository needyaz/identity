/// Crypto primitive round-trips, determinism, and failure modes.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:identity/identity.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late Sodium sodium;

  setUpAll(() async {
    sodium = await SodiumInit.init();
  });

  group('symmetric blob (secretbox)', () {
    test('round-trips a map', () {
      final key = SecureKey.random(sodium, sodium.crypto.secretBox.keyBytes);
      final enc = encryptBlob(sodium, {'hello': 'world', 'n': 42}, key);
      final dec = decryptBlob(sodium, enc, key) as Map<String, dynamic>;
      expect(dec['hello'], 'world');
      expect(dec['n'], 42);
      key.dispose();
    });

    test('wrong key fails authentication', () {
      final k1 = SecureKey.random(sodium, sodium.crypto.secretBox.keyBytes);
      final k2 = SecureKey.random(sodium, sodium.crypto.secretBox.keyBytes);
      final enc = encryptBlob(sodium, {'x': 1}, k1);
      expect(
          () => decryptBlob(sodium, enc, k2), throwsA(isA<SodiumException>()));
      k1.dispose();
      k2.dispose();
    });
  });

  group('DH box blob', () {
    test('round-trips between two identities (both directions agree)', () {
      final a = generateIdentity(sodium);
      final b = generateIdentity(sodium);
      final aToB =
          deriveSharedSecret(sodium, b.keyPair.publicKey, a.keyPair.secretKey);
      final bToA =
          deriveSharedSecret(sodium, a.keyPair.publicKey, b.keyPair.secretKey);
      final enc = encryptBlobWithBox(sodium, {'msg': 'hi'}, aToB);
      final dec = decryptBlobWithBox(sodium, enc, bToA) as Map<String, dynamic>;
      expect(dec['msg'], 'hi');
      aToB.dispose();
      bToA.dispose();
    });
  });

  group('sealed box', () {
    test('seal/open round-trips a string', () {
      final r = generateIdentity(sodium);
      final sealed = sealString(sodium, 'Alice', r.keyPair.publicKey);
      expect(openSealedString(sodium, sealed, r.keyPair), 'Alice');
    });

    test('open with the wrong key returns null', () {
      final r = generateIdentity(sodium);
      final other = generateIdentity(sodium);
      final sealed = sealString(sodium, 'secret', r.keyPair.publicKey);
      expect(openSealedString(sodium, sealed, other.keyPair), isNull);
    });

    test('openSealedBytes round-trips raw token bytes (PoP shape)', () {
      final r = generateIdentity(sodium);
      final token = Uint8List.fromList(List<int>.generate(24, (i) => i));
      final sealed = base64.encode(
          sodium.crypto.box.seal(message: token, publicKey: r.keyPair.publicKey));
      expect(openSealedBytes(sodium, sealed, r.keyPair), equals(token));
    });
  });

  group('deriveBackupKey', () {
    test('deterministic for the same seed + domain', () {
      final id = generateIdentity(sodium);
      final k1 = deriveBackupKey(sodium, id.seed, domain: 'acme-backup-v1');
      final k2 = deriveBackupKey(sodium, id.seed, domain: 'acme-backup-v1');
      expect(k1.extractBytes(), equals(k2.extractBytes()));
      k1.dispose();
      k2.dispose();
    });

    test('different domains yield different keys', () {
      final id = generateIdentity(sodium);
      final k1 = deriveBackupKey(sodium, id.seed, domain: 'acme-backup-v1');
      final k2 = deriveBackupKey(sodium, id.seed, domain: 'identity-pad-v1');
      expect(k1.extractBytes(), isNot(equals(k2.extractBytes())));
      k1.dispose();
      k2.dispose();
    });

    test('matches the known-answer vectors (both padding branches)', () {
      // Seed 0x00..0x1f. Expected values were computed independently with
      // Python hashlib.blake2b (keyed BLAKE2b == libsodium crypto_generichash),
      // so this pins the derivation against a second implementation, not
      // against itself. Any server verifier must reproduce these exactly.
      final seed = SecureKey.fromList(
          sodium, Uint8List.fromList(List<int>.generate(32, (i) => i)));
      // 15-byte domain — exercises the right-pad-to-16 branch. Also doubles as
      // the secretbox_decrypt vector key in crypto_vectors.json.
      final padded = deriveBackupKey(sodium, seed, domain: 'identity-pad-v1');
      expect(_hex(padded.extractBytes()),
          'a509286e124be20c5dc50f097e7dbbcae1773919d88d3d0bc3a9af2fddce45e8');
      padded.dispose();
      // 23-byte domain — exercises the no-padding (>= 16 bytes) branch.
      final long =
          deriveBackupKey(sodium, seed, domain: 'identity-spec-backup-v1');
      expect(_hex(long.extractBytes()),
          '1580c0cdbd94fca160c0b78e4758755bda45e39dc5786db92541b2f60b535e98');
      long.dispose();
    });
  });

  group('Ed25519 signing', () {
    test('sign/verify round-trips; tampered payload fails', () {
      final id = generateIdentity(sodium);
      final kp =
          deriveSigningKeyPair(sodium, id.seed, domain: 'acme-group-signing');
      final payload = canonicalJsonBytes({'b': 2, 'a': 1});
      final sig = signDetached(sodium, payload, kp.secretKey);
      expect(verifyDetached(sodium, payload, sig, kp.publicKey), isTrue);
      final tampered = canonicalJsonBytes({'b': 2, 'a': 99});
      expect(verifyDetached(sodium, tampered, sig, kp.publicKey), isFalse);
    });

    test('deriveSigningKeyPair is deterministic', () {
      final id = generateIdentity(sodium);
      final kp1 =
          deriveSigningKeyPair(sodium, id.seed, domain: 'acme-group-signing');
      final kp2 =
          deriveSigningKeyPair(sodium, id.seed, domain: 'acme-group-signing');
      expect(kp1.publicKey, equals(kp2.publicKey));
    });

    test('matches the known-answer vector', () {
      // Seed 0x00..0x1f, domain 'identity-spec-signing-v1'. Expected public
      // key was computed independently (Python hashlib.blake2b for the
      // keyed-BLAKE2b ed-seed stage, cryptography's Ed25519 for seed -> public
      // key), so this pins the derivation against a second implementation.
      // Any server verifier must reproduce this exactly.
      final seed = SecureKey.fromList(
          sodium, Uint8List.fromList(List<int>.generate(32, (i) => i)));
      final kp =
          deriveSigningKeyPair(sodium, seed, domain: 'identity-spec-signing-v1');
      expect(_hex(kp.publicKey),
          'e986c2797e79ee0aa8ed38dc90c9292fc4ff0d101eee5b85d7c38bf277d01d20');
    });
  });

  test('canonicalJsonBytes sorts keys recursively', () {
    final a = canonicalJsonBytes({
      'b': 1,
      'a': {'d': 4, 'c': 3},
    });
    final b = canonicalJsonBytes({
      'a': {'c': 3, 'd': 4},
      'b': 1,
    });
    expect(a, equals(b));
    expect(utf8.decode(a), '{"a":{"c":3,"d":4},"b":1}');
  });
}
