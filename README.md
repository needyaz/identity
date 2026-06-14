# identity

Shared identity, key derivation, secure-storage tiering, and crypto primitives
for Luci apps. Extracted from Mylo (`mylo_app/lib/src/crypto/` +
`services/identity_store.dart`); the crypto is byte-identical to that source.

This is an L0 foundation package: it has **zero domain coupling** (no location,
no groups, no app models) and is the substrate the rest of a Luci app builds on.

## What's in here

- **`crypto.dart`** — generic libsodium primitives: DH shared secret, symmetric
  `secretbox` blobs, DH-`box` blobs, anonymous sealed boxes, Ed25519 signing,
  and canonical-JSON encoding for byte-exact signatures.
- **`identity.dart`** — `Identity` (seed → X25519 keypair → uid), BIP39 recovery
  phrase round-trip, and the de-linked store-binding token.
- **`identity_store.dart`** — tiered durable storage of the 32-byte seed:
  local Keychain/EncryptedSharedPreferences + iCloud Keychain (iOS) + Block
  Store (Android). Includes the hard-won presence-unknown guard (a failed read
  must never be treated as "no identity").
- **`block_store_client.dart`** — Android Block Store MethodChannel wrapper.

## Per-app namespace: `IdentityConfig`

Every app instantiates its own `IdentityConfig`. The crypto is identical across
apps — only these domain strings differ, which keeps each app's identities,
derived keys, and secure-storage entries disjoint and non-cross-joinable.

```dart
const vaultIdentity = IdentityConfig(
  seedStorageKey: 'vault.seed',
  backupKeyDomain: 'vault-backup-v1',
  signingKeyDomain: 'vault-group-signing',
  storeBindingDomain: 'vault-store-binding-v1',
  blockStoreChannel: 'blue.luci.vault/blockstore',
);
```

`IdentityConfig.mylo` holds Mylo's original values, preserved so a future Mylo
migration onto this package stays byte-for-byte compatible. **New apps must not
reuse them** — pick your own domain family.

> ⚠️ Once an app ships, never change `backupKeyDomain`, `signingKeyDomain`, or
> `storeBindingDomain`: they feed domain-separated derivations that any server
> verifier must reproduce byte-for-byte, and changing one rotates every user's
> derived keys out from under their stored data.

## Usage

```dart
final sodium = await SodiumInit.init();
final store = IdentityStore(vaultIdentity);

var identity = await store.load(sodium);
identity ??= generateIdentity(sodium);
await store.save(identity);            // refuses to clobber an existing seed

final backupKey = deriveBackupKey(
  sodium, identity.seed, domain: vaultIdentity.backupKeyDomain,
);
final phrase = seedToMnemonic(identity.seed);   // 24-word recovery phrase
```

## Native requirement (Android only)

`IdentityStore`'s Block Store tier needs a native MethodChannel handler on the
host app's `blockStoreChannel`, implementing `get`/`put`/`delete`. See Mylo's
Kotlin `BlockStore` handler for a reference implementation. iCloud Keychain on
iOS works through `flutter_secure_storage` options with no native code.

## Tests

`flutter test` — covers crypto round-trips, identity/BIP39 determinism, and a
known-answer vector for the store-binding token that is shared with Mylo and the
Deno server (proves the extracted crypto is byte-identical).
