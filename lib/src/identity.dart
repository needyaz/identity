import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:crypto/crypto.dart' as std_crypto;
import 'package:sodium/sodium.dart';

/// An identity: a seed, the derived keypair, and the uid.
///
/// The [seed] (32 bytes) is the canonical secret — it encodes as the recovery
/// phrase and is stored in the platform secure enclave.
/// [keyPair.secretKey] and [keyPair.publicKey] are derived from the seed and
/// are never stored independently.
/// [uid] is derived deterministically from the public key.
class Identity {
  final Uint8List seed;
  final KeyPair keyPair;
  final String uid;

  const Identity({
    required this.seed,
    required this.keyPair,
    required this.uid,
  });
}

/// Generate a fresh random identity.
Identity generateIdentity(Sodium sodium) {
  final seed = sodium.randombytes.buf(sodium.crypto.box.seedBytes);
  return identityFromSeed(sodium, seed);
}

/// Reconstruct an identity from a previously saved seed (e.g. loaded from Keychain).
Identity identityFromSeed(Sodium sodium, Uint8List seed) =>
    _identityFromSeed(sodium, seed);

/// Recover an identity from a BIP39 mnemonic.
/// Throws if the mnemonic is invalid.
Identity identityFromMnemonic(Sodium sodium, String mnemonic) {
  if (!bip39.validateMnemonic(mnemonic)) {
    throw ArgumentError('Invalid mnemonic');
  }
  final entropyHex = bip39.mnemonicToEntropy(mnemonic);
  final seed = Uint8List.fromList(_hexToBytes(entropyHex));
  return _identityFromSeed(sodium, seed);
}

/// Encode the seed as a BIP39 mnemonic (24 words for a 32-byte seed).
/// Never persisted by the app — derived on demand for the "Show Recovery Phrase" UI.
String seedToMnemonic(Uint8List seed) {
  final entropyHex = _bytesToHex(seed);
  return bip39.entropyToMnemonic(entropyHex);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

Identity _identityFromSeed(Sodium sodium, Uint8List seed) {
  final secureKey = SecureKey.fromList(sodium, seed);
  final kp = sodium.crypto.box.seedKeyPair(secureKey);
  final uid = _deriveUid(kp.publicKey);
  return Identity(seed: seed, keyPair: kp, uid: uid);
}

/// SHA-256(publicKey)[0..15], lowercase hex.
String _deriveUid(Uint8List publicKey) {
  final hash = std_crypto.sha256.convert(publicKey).bytes;
  return _bytesToHex(Uint8List.fromList(hash.sublist(0, 16)));
}

/// The uid bound to an X25519 box public key — SHA-256(publicKey)[0..15],
/// lowercase hex. A uid is *defined* as this hash, so any trust boundary that
/// accepts a `(uid, publicKey)` pair from an untrusted source — e.g. owner-side
/// invite finalization — can verify the pair is self-consistent before admitting
/// the key into a roster.
String uidForBoxPublicKey(Uint8List publicKey) => _deriveUid(publicKey);

/// The store buyer-binding token for [boxPublicKey], formatted as a UUID for
/// StoreKit2 (`UUID(uuidString:)`, which silently drops a non-UUID token).
///
/// `SHA-256(domain || boxPublicKey)[0..15]`, hex, grouped 8-4-4-4-12. A SIBLING
/// of the uid (`SHA-256(boxPublicKey)[0..15]`) under a distinct [domain] prefix,
/// so the value disclosed to Apple/Google as the StoreKit2 `appAccountToken` /
/// Google `obfuscatedAccountId` is NOT the uid — it can't be used as a join key
/// to correlate store records with backend records. Re-derivable from the pubkey
/// alone, so it stays stateless and blank-DB-DR-safe. Any server verifier must
/// use the same [domain] and derive this byte-for-byte. [domain] must be ASCII.
String deriveStoreBindingToken(
  Uint8List boxPublicKey, {
  required String domain,
}) {
  // Domain is pure ASCII, so codeUnits == UTF-8 bytes.
  final input = Uint8List.fromList([
    ...domain.codeUnits,
    ...boxPublicKey,
  ]);
  final hash = std_crypto.sha256.convert(input).bytes;
  final hex = _bytesToHex(Uint8List.fromList(hash.sublist(0, 16)));
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String _bytesToHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<int> _hexToBytes(String hex) {
  final result = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    result.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return result;
}
