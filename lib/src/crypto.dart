import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

// Generic libsodium primitives — no domain models.
//
// Extracted from a shipped production app; the crypto here is byte-identical
// to that source. The three domain-separated derivations ([deriveBackupKey],
// [deriveSigningKeyPair], and `deriveStoreBindingToken` in identity.dart) take
// their domain string as a parameter so every app supplies its own namespace.

// ---------------------------------------------------------------------------
// Shared secret (DH)
// ---------------------------------------------------------------------------

/// Derive the X25519 shared secret for a connection.
/// Call from both sides with swapped keys — the result is identical (DH property).
/// Returns a [PrecalculatedBox] that owns the shared secret in secure memory.
/// Caller must [dispose] it when done.
PrecalculatedBox deriveSharedSecret(
  Sodium sodium,
  Uint8List theirPublicKey,
  SecureKey mySecretKey,
) {
  return sodium.crypto.box.precalculate(
    publicKey: theirPublicKey,
    secretKey: mySecretKey,
  );
}

// ---------------------------------------------------------------------------
// Symmetric blob encryption (backup + shared blobs)
// ---------------------------------------------------------------------------

/// Derive a 32-byte symmetric key from the identity seed under [domain].
/// `BLAKE2b(message=seed, key=domain, outLen=32)`.
///
/// Any server verifier that re-derives this key must use the same [domain].
/// Short domains are right-padded to libsodium's 16-byte key minimum, matching
/// the origin app's shipped derivation byte-for-byte.
///
/// [seed] is a [SecureKey]: `genericHash`'s message parameter only accepts a
/// plain [Uint8List], so the seed's protected memory is briefly unlocked via
/// `runUnlockedSync` for the duration of the hash and re-locked immediately
/// after — a scoped view, not a separate untracked copy.
SecureKey deriveBackupKey(
  Sodium sodium,
  SecureKey seed, {
  required String domain,
}) {
  final domainBytes = utf8.encode(domain);
  // BLAKE2b requires key length >= 16 bytes. Right-pad short domains to 16.
  final keyBytes = domainBytes.length >= 16
      ? Uint8List.fromList(domainBytes)
      : (Uint8List(16)..setAll(0, domainBytes));
  final keyParam = SecureKey.fromList(sodium, keyBytes);
  final hash = seed.runUnlockedSync((seedBytes) => sodium.crypto.genericHash(
        message: seedBytes,
        outLen: 32,
        key: keyParam,
      ));
  keyParam.dispose();
  return SecureKey.fromList(sodium, hash);
}

/// Encrypt an arbitrary JSON-serialisable object.
/// Returns base64(nonce || ciphertext).
String encryptBlob(Sodium sodium, Object data, SecureKey key) {
  final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(data)));
  final nonce = sodium.randombytes.buf(sodium.crypto.secretBox.nonceBytes);
  final ciphertext = sodium.crypto.secretBox.easy(
    message: plaintext,
    nonce: nonce,
    key: key,
  );
  final combined = Uint8List(nonce.length + ciphertext.length)
    ..setAll(0, nonce)
    ..setAll(nonce.length, ciphertext);
  return base64.encode(combined);
}

/// Decrypt a blob produced by [encryptBlob]. Throws [SodiumException] on auth failure.
/// Returns the decoded JSON value — a `Map<String, dynamic>` or `List` depending
/// on what was encrypted; callers cast explicitly.
Object decryptBlob(Sodium sodium, String encoded, SecureKey key) {
  final combined = base64.decode(encoded);
  final nonceLen = sodium.crypto.secretBox.nonceBytes;
  final nonce = combined.sublist(0, nonceLen);
  final ciphertext = combined.sublist(nonceLen);
  final plaintext = sodium.crypto.secretBox.openEasy(
    cipherText: ciphertext,
    nonce: nonce,
    key: key,
  );
  return jsonDecode(utf8.decode(plaintext)) as Object;
}

// ---------------------------------------------------------------------------
// Box blob encryption (uses DH shared secret)
// ---------------------------------------------------------------------------

/// Encrypt an arbitrary JSON-serialisable object using a [PrecalculatedBox]
/// (the DH shared secret between two users). Same wire format as the symmetric
/// blob, but authenticated to the two parties. Returns base64(nonce || ciphertext).
String encryptBlobWithBox(Sodium sodium, Object data, PrecalculatedBox box) {
  final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(data)));
  final nonce = sodium.randombytes.buf(sodium.crypto.box.nonceBytes);
  final ciphertext = box.easy(message: plaintext, nonce: nonce);
  final combined = Uint8List(nonce.length + ciphertext.length)
    ..setAll(0, nonce)
    ..setAll(nonce.length, ciphertext);
  return base64.encode(combined);
}

/// Same as [encryptBlobWithBox], but disposes [box] on every path — success or
/// a throw. A bare `encryptBlobWithBox(...)` followed by a separate
/// `box.dispose()` statement skips the dispose when encrypt throws, leaking the
/// derived shared secret to the GC instead of wiping it deterministically.
/// Prefer this whenever the box exists only for this one call.
String encryptBlobWithBoxDisposing(
    Sodium sodium, Object data, PrecalculatedBox box) {
  try {
    return encryptBlobWithBox(sodium, data, box);
  } finally {
    box.dispose();
  }
}

/// Decrypt a blob produced by [encryptBlobWithBox]. Throws [SodiumException] on auth failure.
/// Returns the decoded JSON value — a `Map<String, dynamic>` or `List` depending
/// on what was encrypted; callers cast explicitly.
Object decryptBlobWithBox(Sodium sodium, String encoded, PrecalculatedBox box) {
  final combined = base64.decode(encoded);
  final nonceLen = sodium.crypto.box.nonceBytes;
  final nonce = combined.sublist(0, nonceLen);
  final ciphertext = combined.sublist(nonceLen);
  final plaintext = box.openEasy(cipherText: ciphertext, nonce: nonce);
  return jsonDecode(utf8.decode(plaintext)) as Object;
}

/// Same as [decryptBlobWithBox], but disposes [box] on every path — success or
/// the [SodiumException] a tampered or replayed payload's MAC failure raises.
/// The throw path is the one a caller is most likely to forget, and it is
/// exactly the path an attacker controls, so prefer this whenever the box
/// exists only for this one call.
Object decryptBlobWithBoxDisposing(
    Sodium sodium, String encoded, PrecalculatedBox box) {
  try {
    return decryptBlobWithBox(sodium, encoded, box);
  } finally {
    box.dispose();
  }
}

// ---------------------------------------------------------------------------
// Sealed-box encryption (anonymous box)
// ---------------------------------------------------------------------------

/// Seal [plaintext] so only the holder of [recipientPublicKey]'s secret key can
/// read it. Returns base64-encoded ciphertext. Uses crypto_box_seal (anonymous
/// box — the sender identity is not authenticated). Useful for delivering a
/// value privately to a recipient you only know by public key (e.g. an invite
/// joiner sealing their display name to the group owner).
String sealString(Sodium sodium, String plaintext, Uint8List recipientPublicKey) {
  final ciphertext = sodium.crypto.box.seal(
    message: Uint8List.fromList(utf8.encode(plaintext)),
    publicKey: recipientPublicKey,
  );
  return base64.encode(ciphertext);
}

/// Decrypt a value produced by [sealString]. Returns the plaintext string, or
/// null if decryption fails (wrong key, corrupt data, etc.).
String? openSealedString(Sodium sodium, String encryptedB64, KeyPair keyPair) {
  try {
    final plaintext = sodium.crypto.box.sealOpen(
      cipherText: base64.decode(encryptedB64),
      publicKey: keyPair.publicKey,
      secretKey: keyPair.secretKey,
    );
    return utf8.decode(plaintext);
  } catch (_) {
    return null;
  }
}

/// Open a sealed-box payload addressed to [keyPair]'s public key and return the
/// raw bytes, or null on failure. Used by registration proof-of-possession: the
/// server seals a random token to the claimed public key, and only the holder of
/// the matching secret key can recover it — proving private-key possession
/// without any signing key or server secret.
Uint8List? openSealedBytes(Sodium sodium, String sealedB64, KeyPair keyPair) {
  try {
    return sodium.crypto.box.sealOpen(
      cipherText: base64.decode(sealedB64),
      publicKey: keyPair.publicKey,
      secretKey: keyPair.secretKey,
    );
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Ed25519 signing
// ---------------------------------------------------------------------------
//
// A second, signing keypair derived from the same seed, domain-separated from
// the X25519 box/identity keypair so the two can never be confused. Re-derivable
// from the recovery phrase — no new backup surface.

/// Derive a per-user Ed25519 signing keypair from the identity seed under [domain].
/// `BLAKE2b(message=seed, key=domain, outLen=sign.seedBytes)` → `sign.seedKeyPair`.
/// Deterministic: the same seed + domain always yields the same keypair, so it
/// reconstructs from the BIP39 phrase like the box key does. [domain] must be
/// within libsodium's generic-hash key range (16..64 bytes UTF-8).
///
/// [seed] is a [SecureKey] — see [deriveBackupKey] for why the unlock is scoped
/// via `runUnlockedSync` rather than taking a plain [Uint8List].
KeyPair deriveSigningKeyPair(
  Sodium sodium,
  SecureKey seed, {
  required String domain,
}) {
  final keyParam =
      SecureKey.fromList(sodium, Uint8List.fromList(utf8.encode(domain)));
  final edSeed = seed.runUnlockedSync((seedBytes) => sodium.crypto.genericHash(
        message: seedBytes,
        outLen: sodium.crypto.sign.seedBytes,
        key: keyParam,
      ));
  keyParam.dispose();
  final secureSeed = SecureKey.fromList(sodium, edSeed);
  final keyPair = sodium.crypto.sign.seedKeyPair(secureSeed);
  secureSeed.dispose();
  return keyPair;
}

/// Canonical byte encoding of a JSON payload, for signing/verification.
///
/// Ed25519 verify is byte-exact, and the same payload must produce identical
/// bytes on the Dart client and any other verifier (e.g. a Deno edge function) —
/// so this sorts every map's keys recursively and emits whitespace-free JSON.
/// **Invariants the payload schema must honour** (so Dart `jsonEncode` and JS
/// `JSON.stringify` agree byte-for-byte): ASCII-only string values (base64/hex),
/// integers only (no floats), and no `null` fields.
Uint8List canonicalJsonBytes(Map<String, Object?> payload) =>
    Uint8List.fromList(utf8.encode(jsonEncode(_canonicalize(payload))));

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final sorted = <String, Object?>{};
    for (final key in value.keys.cast<String>().toList()..sort()) {
      sorted[key] = _canonicalize(value[key]);
    }
    return sorted;
  }
  if (value is List) return value.map(_canonicalize).toList();
  return value;
}

/// Sign canonical payload bytes with an Ed25519 secret key.
/// Returns the 64-byte detached signature.
Uint8List signDetached(
  Sodium sodium,
  Uint8List payloadBytes,
  SecureKey signSecretKey,
) =>
    sodium.crypto.sign.detached(message: payloadBytes, secretKey: signSecretKey);

/// Verify a detached Ed25519 signature against [signPublicKey]. Returns false
/// (never throws) on any malformed input or mismatch.
bool verifyDetached(
  Sodium sodium,
  Uint8List payloadBytes,
  Uint8List signature,
  Uint8List signPublicKey,
) {
  try {
    return sodium.crypto.sign.verifyDetached(
      message: payloadBytes,
      signature: signature,
      publicKey: signPublicKey,
    );
  } catch (_) {
    return false;
  }
}
