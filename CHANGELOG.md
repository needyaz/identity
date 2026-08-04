## 0.2.0

- **`Identity.seed` is now a `SecureKey`** (locked, zeroed-on-dispose memory)
  rather than a plain `Uint8List` held for the whole session. Every *derived*
  key here was already protected that way; the root seed — from which the
  keypair, backup key and signing key all descend — was the one thing left
  exposed to a memory read for as long as the app ran. `deriveBackupKey` and
  `deriveSigningKeyPair` take a `SecureKey` and unlock it in place
  (`runUnlockedSync`) only for the duration of the hash. **Breaking**; the
  known-answer vectors confirm the derivations are byte-identical.
- Added `encryptBlobWithBoxDisposing` / `decryptBlobWithBoxDisposing`: a bare
  call followed by a separate `box.dispose()` skips the dispose on the throw
  path — which, for decrypt, is exactly the path an attacker controls via a
  tampered payload's MAC failure.
- `BlockStoreClient.delete()` logs through `debugPrint` instead of a raw
  `print()`, closing a permanent hole in a host app's "no console output in
  release builds" guarantee.

## 0.1.0

- Initial extraction from a shipped production app.
- Generic crypto primitives, seed→keypair→UID→BIP39 identity, store-binding token,
  Ed25519 signing, and tiered secure storage (Keychain / iCloud / Block Store).
- App-specific namespace strings lifted into `IdentityConfig` so each app picks its
  own domain.
