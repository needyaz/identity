## 0.8.0

- **Promote-on-read honors never-overwrite-on-doubt.** A cloud-tier hit was
  promoted over the primary even when the primary's read had FAILED that same
  pass — unknown ground, not a miss: the primary may hold a different value
  the failure hid (two devices on one cloud account, one force-restored), and
  the promote silently replaced this device's identity. Promotion now skips a
  primary that failed this read and retries on a later, healthy one.
- **`isCloudBackedUp` value-compares instead of presence-checking.** After
  another device force-restored a different identity, the shared cloud item
  held *someone's* seed and the readout still said "backed up". It now
  reports true only when the cloud copy equals this device's local seed.
- **Android no longer arms the duplicate 'cloud' secure-storage tier.** The
  `synchronizable` flag is a no-op there, so that tier resolves to the same
  EncryptedSharedPreferences as local: arming it made a true-new install pay
  a full retry budget re-reading a store local had already confirmed empty,
  and save/clear double-wrote/deleted the same physical store. Block Store
  remains the Android cloud tier.
- **Mirror writes run concurrently.** Serial awaits put one hung tier's full
  timeout (a stalled Play Services task) on the save path ahead of every
  other mirror; the primary-first ordering and per-tier best-effort semantics
  are unchanged.

## 0.7.0

- **Block Store reads join the tri-state: a failed read is UNAVAILABLE, never
  absent.** `BlockStoreClient.get` collapsed every failure (platform error,
  timeout, hung Play Services task) to null, and `BlockStoreTier` passed that
  through as a clean miss — so `SecureKvStore`'s tri-state read the one
  Android cloud tier's *failure* as "confirmed absent", the single answer
  that authorizes a fresh mint's write fan-out to overwrite a seed the tier
  actually holds. New `BlockStoreClient.getStrict` (throws on failure; null
  only on a confirmed miss) is what the tier reads through; the lenient
  `get()` keeps its exact legacy swallow for direct callers.
- **Behavior change:** a hung/timed-out Block Store task now surfaces as
  presence-unknown (`IdentitySeedPresenceUnknown` at the store level) rather
  than absent — deliberate: "couldn't read" was the clobber vector. On AVDs
  without Play Services, where tasks are known to hang, expect
  presence-unknown instead of a silent miss.
- **Not a behavior change:** no registered native handler
  (`MissingPluginException`) stays a confirmed non-participant (null), so an
  app that never wired the bridge boots exactly as before. A legacy bridge
  that maps failures to null successes also behaves exactly as before —
  surfacing failures requires the host bridge to report them as channel
  errors (`result.error(...)`), with "Block Store not supported here" kept a
  null success.

## 0.6.0

- **Breaking: removed `SecureKvStore.readModifyWrite` and the per-key version
  counters backing it.** Its last consumer moved to per-record
  storage, and the optimistic version counter had a reproduced residual race:
  a reader starting after another writer's synchronous version bump but
  before that write *landed* passed its own version check and could lose the
  concurrent write (3/6 concurrent saves lost on a real Keychain in the
  consuming app's testing). The correct fix for list/set-shaped values is
  per-record keys, not better concurrency control over one blob — so the API
  is deleted rather than repaired, and no replacement is planned.
  `readTyped`/`writeTyped` are unaffected.

## 0.5.0

- **New: generic tiered secure storage — `SecureKvStore`.** The
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
