## 0.4.0

- Added an optional `onSeedAcquired` callback to `IdentityStore`'s constructor
  (default null — no behavior change). Fires when the device NEWLY comes to
  hold the seed: after `save()`'s local write succeeds (before the best-effort
  cloud mirrors) and after a cloud-tier restore in `load()` is promoted to
  local — never on the local-hit fast path or the fire-and-forget cloud
  backfill. Lets a host reset "the seed was wiped" bookkeeping (e.g. a native
  wipe latch) exactly when key material legitimately (re)appears, without
  forking the class. Synchronous; must not throw.

## 0.3.0

- **`IdentityStore.clear()` no longer swallows per-tier delete failures.**
  Previously a locked/offline cloud tier during account deletion silently kept
  the seed alive there; the next `load()` would find it, promote it back to
  local, and resurrect the "deleted" identity. `clear()` now attempts every
  tier unconditionally (a Block Store `false` return counts as a failure) and
  throws the new `IdentityClearIncomplete(tiers)` naming the tiers that could
  not confirm deletion. **Breaking** for callers that assumed `clear()` never
  throws; deletes are idempotent, so retry on catch.

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
