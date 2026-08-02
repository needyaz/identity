import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:identity/identity.dart';

// Golden-vector crypto parity (see ios/Tests/IdentityCryptoTests/CryptoVectorsTests.swift
// and android/.../CryptoVectorsAndroidTest.kt — same fixture, same expectations).
// A divergence on any platform is a crypto-mirror drift bug, not a test bug.
// Wire format: base64(nonce || ciphertext), nonce 24B, MAC 16B.

void main() {
  late Sodium sodium;
  late Map<String, dynamic> vectors;

  setUpAll(() async {
    sodium = await SodiumInit.init();
    vectors = jsonDecode(File('test/crypto_vectors.json').readAsStringSync())
        as Map<String, dynamic>;
  });

  test('box_decrypt vectors (real deriveSharedSecret + decryptBlobWithBox)', () {
    for (final c in vectors['box_decrypt'] as List<dynamic>) {
      final v = c as Map<String, dynamic>;
      final recipientSk = SecureKey.fromList(
          sodium, Uint8List.fromList(base64.decode(v['recipientSkB64'] as String)));
      final senderPk = Uint8List.fromList(base64.decode(v['senderPkB64'] as String));
      final box = deriveSharedSecret(sodium, senderPk, recipientSk);
      final result = decryptBlobWithBox(sodium, v['b64'] as String, box) as Map<String, dynamic>;
      box.dispose();
      recipientSk.dispose();
      final expected = v['expected'] as Map<String, dynamic>;
      for (final k in expected.keys) {
        expect(result[k], expected[k], reason: '${v['id']}: field $k');
      }
    }
  });

  test('secretbox_decrypt vectors (real decryptBlob)', () {
    for (final c in vectors['secretbox_decrypt'] as List<dynamic>) {
      final v = c as Map<String, dynamic>;
      final key = SecureKey.fromList(
          sodium, Uint8List.fromList(base64.decode(v['keyB64'] as String)));
      if (v['expectFail'] == true) {
        expect(() => decryptBlob(sodium, v['b64'] as String, key),
            throwsA(isA<SodiumException>()),
            reason: '${v['id']}: ${v['desc']}');
      } else {
        final result =
            decryptBlob(sodium, v['b64'] as String, key) as Map<String, dynamic>;
        final expected = v['expected'] as Map<String, dynamic>;
        for (final k in expected.keys) {
          expect(result[k], expected[k], reason: '${v['id']}: field $k');
        }
      }
      key.dispose();
    }
  });

  test('seal_open vectors (real openSealedString)', () {
    for (final c in vectors['seal_open'] as List<dynamic>) {
      final v = c as Map<String, dynamic>;
      final keyPair = KeyPair(
        publicKey: Uint8List.fromList(base64.decode(v['recipientPkB64'] as String)),
        secretKey: SecureKey.fromList(
            sodium, Uint8List.fromList(base64.decode(v['recipientSkB64'] as String))),
      );
      final result = openSealedString(sodium, v['sealedB64'] as String, keyPair);
      keyPair.secretKey.dispose();
      if (v['expectNull'] == true) {
        expect(result, isNull, reason: '${v['id']}: ${v['desc']}');
      } else {
        expect(result, v['expectedPlaintext'] as String,
            reason: '${v['id']}: ${v['desc']}');
      }
    }
  });
}
