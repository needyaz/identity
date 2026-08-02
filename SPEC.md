# identity — specification

The cryptographic contract for the `identity` package. Anything that has to
interoperate with it (a server verifier, another app, a future reimplementation)
must match this byte-for-byte.

## Identity

- **Seed** — 32 random bytes. The canonical secret; everything else derives from
  it. Stored in the platform secure enclave; never transmitted.
- **Keypair** — X25519 (`crypto_box`) seed-keypair derived from the seed.
- **uid** — `SHA-256(boxPublicKey)[0..15]` as 32-char lowercase hex.
- **Recovery phrase** — BIP39, 24 words encoding the 32-byte seed (standard
  BIP39 entropy↔mnemonic). Never persisted.

## Domain-separated derivations (the byte-parity surface)

Each takes a per-app `domain` string. **Never change a shipped app's domains** —
it rotates every user's keys. A server verifier must use the identical domain.

| function | algorithm |
|---|---|
| `deriveBackupKey(seed, domain)` | `BLAKE2b(message=seed, key=domain, outLen=32)`. The key is right-padded with `0x00` to libsodium's 16-byte minimum if `len(domain) < 16`. |
| `deriveSigningKeyPair(seed, domain)` | `edSeed = BLAKE2b(message=seed, key=domain, outLen=sign.seedBytes)`, then Ed25519 `sign.seedKeyPair(edSeed)`. `domain` UTF-8 length must be 16..64. |
| `deriveStoreBindingToken(pubkey, domain)` | `SHA-256(domain_ascii ‖ pubkey)[0..15]`, hex, grouped `8-4-4-4-12` (a UUID). `domain` must be ASCII. |

## Generic primitives

Wire format for all blobs: **`base64(nonce ‖ ciphertext)`**, standard base64
alphabet (`+`/`/`), not URL-safe.

- `deriveSharedSecret(theirPub, mySecret)` — X25519 DH precalculated box.
- `encryptBlob` / `decryptBlob` — `crypto_secretbox` (XSalsa20-Poly1305) with a
  32-byte symmetric key; payload is `jsonEncode(data)`.
- `encryptBlobWithBox` / `decryptBlobWithBox` — same, but authenticated with a DH
  `PrecalculatedBox`.
- `sealString` / `openSealedString` / `openSealedBytes` — anonymous `crypto_box_seal`.
- `signDetached` / `verifyDetached` — Ed25519 64-byte detached signatures.
- `canonicalJsonBytes(map)` — recursively key-sorted, whitespace-free JSON, for
  byte-exact signing. Schema must be ASCII strings + integers, no nulls (so Dart
  `jsonEncode` and JS `JSON.stringify` agree byte-for-byte).

## IdentityConfig

Per-app namespace, 5 fields: `seedStorageKey`, `backupKeyDomain`,
`signingKeyDomain`, `storeBindingDomain`, `blockStoreChannel`. Each app picks a
**distinct** set so identities/keys never collide, defines it in its own
codebase, and must never change it after shipping.

## Known-answer vectors (parity locks)

For box public key `0x00 0x01 … 0x1f` (32 bytes):
- `uid` = `630dcd2966c4336691125448bbb25b4f`
- `deriveStoreBindingToken(pub, domain="identity-spec-binding-v1")` =
  `520b61d7-b56f-74f5-726c-3dfab07859a0`

For seed `0x00 0x01 … 0x1f` (32 bytes):
- `deriveBackupKey(seed, domain="identity-pad-v1")` (15-byte domain — exercises
  the pad-to-16 branch) =
  `a509286e124be20c5dc50f097e7dbbcae1773919d88d3d0bc3a9af2fddce45e8`
- `deriveBackupKey(seed, domain="identity-spec-backup-v1")` (23-byte domain —
  no padding) =
  `1580c0cdbd94fca160c0b78e4758755bda45e39dc5786db92541b2f60b535e98`
- `deriveSigningKeyPair(seed, domain="identity-spec-signing-v1").publicKey` =
  `e986c2797e79ee0aa8ed38dc90c9292fc4ff0d101eee5b85d7c38bf277d01d20`

All vectors use neutral spec domains and were computed with an independent
implementation (Python `hashlib` for the SHA-256 and keyed-BLAKE2b stages,
`cryptography`'s Ed25519 for seed → public key), so they pin the derivations
against a second implementation rather than against this code itself. They are
asserted in `test/identity_test.dart` and `test/crypto_test.dart`. If any
drifts, parity is broken. Consuming apps and their server verifiers should
additionally pin vectors under their own production domains in their own
repos.

## Native crypto mirrors (`native/ios/`, `native/android/`)

The generic primitives above — `deriveSharedSecret`, `encryptBlob`/`decryptBlob`,
`encryptBlobWithBox`/`decryptBlobWithBox`, `sealString`/`openSealedString`/
`openSealedBytes` — have byte-identical native reimplementations for hosts that
can't reach the Dart runtime (a killed-state background evaluator, a
notification service extension). This is a **three-way mirror**: Dart
(`lib/src/crypto.dart`), Swift (`native/ios/Sources/IdentityCrypto/NativeCrypto.swift`),
Kotlin (`native/android/crypto/.../NativeCrypto.kt` + JNI). All three must produce
identical ciphertext/plaintext for the same inputs.

`test/crypto_vectors.json` is the canonical golden-vector fixture (Dart is the
source of truth; Swift reads the same file directly off disk by walking up
from its own path; Android gets a build-time copy staged into its test
assets, since instrumented tests can't reach the host filesystem). Sections:

- `box_decrypt` — pins X25519 DH (`deriveSharedSecret`/`deriveSharedKey`) +
  `crypto_box` open, including a unicode payload.
- `seal_open` — pins `crypto_box_seal_open`, including a tampered ciphertext
  and a wrong-recipient keypair, both of which must return null/nil, never
  throw.
- `secretbox_decrypt` — pins `crypto_secretbox` open (the symmetric backup/blob
  format), including a unicode payload, a tampered ciphertext, and a wrong key.
  The vector key is itself the `deriveBackupKey(seed 0x00..0x1f,
  "identity-pad-v1")` known answer, so the section pins the full
  derive → encrypt → decrypt backup pipeline. `expectFail` cases fail as
  null/nil on the native mirrors and as `SodiumException` in Dart.

A divergence in any of the three implementations against this fixture is a
crypto-mirror drift bug — the security-relevant kind, not a cosmetic one. The
native mirrors are scoped **narrowly** to these primitives only — no identity
derivation, no BIP39, no secure storage, no app business logic.

## Secure storage

The seed is mirrored across tiers, read local-first:
- **iOS** — local Keychain (`first_unlock`, not synced) + iCloud Keychain
  (`synchronizable`, best-effort).
- **Android** — EncryptedSharedPreferences (local) + Block Store (cloud,
  best-effort, via the `blockStoreChannel` native handler).

**Invariant:** `hasIdentity()` returns false only when *every* tier was readable
and confirmed absent. A failed read throws `IdentitySeedPresenceUnknown` —
"couldn't read" must never collapse into "no identity" (the root of the recurring
re-onboard/seed-clobber class). `save()` refuses to overwrite an existing seed
unless `force: true`.
