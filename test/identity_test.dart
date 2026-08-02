/// Identity derivation, BIP39 round-trip, and the store-binding known-answer
/// vector that locks byte-parity with any server-side verifier.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:identity/identity.dart';

void main() {
  late Sodium sodium;

  setUpAll(() async {
    sodium = await SodiumInit.init();
  });

  test('generate → seed → mnemonic → recover is stable', () {
    final id = generateIdentity(sodium);

    final fromSeed = identityFromSeed(sodium, id.seed);
    expect(fromSeed.uid, id.uid);
    expect(fromSeed.keyPair.publicKey, equals(id.keyPair.publicKey));

    final phrase = seedToMnemonic(id.seed);
    expect(phrase.split(' ').length, 24);

    final recovered = identityFromMnemonic(sodium, phrase);
    expect(recovered.seed, equals(id.seed));
    expect(recovered.uid, id.uid);
    expect(recovered.keyPair.publicKey, equals(id.keyPair.publicKey));
  });

  test('uid is SHA-256(pub)[:16] hex and matches uidForBoxPublicKey', () {
    final id = generateIdentity(sodium);
    expect(id.uid.length, 32);
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(id.uid), isTrue);
    expect(uidForBoxPublicKey(id.keyPair.publicKey), id.uid);
  });

  test('invalid mnemonic throws ArgumentError', () {
    expect(() => identityFromMnemonic(sodium, 'not a valid phrase'),
        throwsA(isA<ArgumentError>()));
  });

  group('deriveStoreBindingToken', () {
    // Known-answer vector: box pubkey 0x00..0x1f under the spec's neutral test
    // domain. The expected token was computed independently (Python hashlib
    // SHA-256), so this pins the derivation against a second implementation.
    // Consuming apps should pin their own production domains in their own
    // test suites the same way.
    final pub = Uint8List.fromList(List<int>.generate(32, (i) => i));
    const specTokenUuid = '520b61d7-b56f-74f5-726c-3dfab07859a0';
    const uidHex = '630dcd2966c4336691125448bbb25b4f';

    test('matches the known-answer vector', () {
      expect(
        deriveStoreBindingToken(pub, domain: 'identity-spec-binding-v1'),
        specTokenUuid,
      );
    });

    test('uid for the same pubkey matches the shared vector', () {
      expect(uidForBoxPublicKey(pub), uidHex);
    });

    test('is a valid UUID and not equal to the uid (de-linked)', () {
      final t = deriveStoreBindingToken(pub, domain: 'acme-store-binding-v1');
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
            .hasMatch(t),
        isTrue,
      );
      expect(t.replaceAll('-', ''), isNot(uidForBoxPublicKey(pub)));
    });

    test('different domains yield different tokens', () {
      expect(
        deriveStoreBindingToken(pub, domain: 'acme-store-binding-v1'),
        isNot(deriveStoreBindingToken(pub, domain: 'identity-spec-binding-v1')),
      );
    });
  });
}
