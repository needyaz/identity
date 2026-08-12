## 0.6.0

- **Breaking: removed `SecureKvStore.readModifyWrite` and the per-key version
  counters backing it** (issue #2). Its last consumer moved to per-record
  storage, and the optimistic version counter had a reproduced residual race:
  a reader starting after another writer's synchronous version bump but
  before that write *landed* passed its own version check and could lose the
  concurrent write (3/6 concurrent saves lost on a real Keychain in the
  consuming app's testing). The correct fix for list/set-shaped values is
  per-record keys, not better concurrency control over one blob — so the API
  is deleted rather than repaired, and no replacement is planned.
  `readTyped`/`writeTyped` are unaffected.

## 0.5.0

- **New: generic tiered secure storage — `SecureKvStore`** (issue #1). The
  tiering machinery that lived inside `IdentityStore` is now a reusable,
  exported layer: `StorageRead<T>` (sealed tri-state `Present` / `Absent` /
  `Unavailable` — an exhaustive `switch` makes "failed read treated as
  absent" a compile-time impossibility), the pluggable `KvTier` interface
  (with `SecureStorageTier` and `BlockStoreTier` shipped; consumers can
  supply e.g. a legacy `SharedPreferences` tier without this package taking
  the dependency), `TierPolicy` (ordered read chain, promote-on-read,
  migration-only read-then-delete tiers, platform-armed tiers, cloud
  sync-lag retry, primary-required / mirror-best-effort write fan-out,
  per-tier promote opt-out via `noPromoteTiers` for values whose conflict
  rule resolves above this layer),
  `TypedKey<T>` + `readTyped`/`writeTyped` (decode failure maps to
  `Unavailable`, never `Absent`), and `readModifyWrite` (optimistic version
  counter — no lock, no shared queue, so a stuck caller can never wedge
  another).
- **New: `package:identity/testing.dart`** exports `FakeKvTier`, a
  fault-injectable in-memory tier (per-key + wholesale read/write/delete
  faults defaulting to a realistic locked-Keychain `PlatformException`
  `-25308`, per-key read queues for sync-lag retries, a read gate for
  concurrency tests) so consumer suites can exercise "one tier fails while
  another succeeds" on the host without rewriting the fake.
- **`IdentityStore` now sits on `SecureKvStore`.** Its public API, tier
  order, retry behavior, tri-state `hasIdentity()` /
  `IdentitySeedPresenceUnknown`, `save({force})` clobber guard,
  `onSeedAcquired` timing, and `IdentityClearIncomplete` tier names are all
  unchanged (`identity_store_test.dart` passes unmodified). One edge case
  changed deliberately: a cloud-tier restore whose promote-write to local
  storage fails no longer throws out of `load()` — promote failures are
  non-fatal, `load()` returns the restored identity (the seed still lives in
  the cloud tier; local caching is retried on the next launch), and
  `onSeedAcquired` fires since the device is now using the seed.

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
