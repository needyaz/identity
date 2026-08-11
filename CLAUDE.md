# CLAUDE.md — identity

Guidance for Claude Code when working in this package.

## What this is

`identity` is the **L0 foundation** for the Luci family of apps:
generic libsodium crypto primitives, seed→keypair→uid→BIP39 identity, the
de-linked store-binding token, Ed25519 signing, generic tiered secure storage
(`SecureKvStore` + tri-state `StorageRead`), and tiered durable storage of
the seed (Keychain / iCloud Keychain / Android Block Store) built on it.

It was **extracted from a shipped production app**. The crypto is byte-identical
to that source — only the app-specific namespace strings were lifted into
`IdentityConfig`.

It is a standalone package consumed as a path dependency (same pattern as
`sammy`). It has **zero domain coupling** — no location, no groups, no app
models. `groups` depends on this; apps depend on this (directly and via `groups`).

## The cardinal rule: byte-parity

Three derivations are **domain-separated** and must be reproduced byte-for-byte
by any server verifier and by every consuming app:

- `deriveBackupKey` — BLAKE2b(seed, key=domain)
- `deriveSigningKeyPair` — Ed25519 from BLAKE2b(seed, key=domain)
- `deriveStoreBindingToken` — SHA-256(domain ‖ pubkey)[:16] as a UUID

**Never** change the crypto here without updating the corresponding server
verifier in lockstep, and **never** change a shipped app's domain strings —
doing so rotates every user's derived keys out from under their stored data.
All three derivations are pinned by **known-answer vectors** under neutral spec
domains (`identity_test.dart`, `crypto_test.dart`), computed against an
independent implementation. If any goes red, parity is broken. Keep them green.
Consuming apps pin their own production-domain vectors in their own repos.

## IdentityConfig — the per-app seam

Every app passes its own `IdentityConfig` (seed storage key + the three domains +
Block Store channel), defined in the app's own codebase — app configs never live
in this package. Apps must each pick a **distinct** namespace so identities
and derived keys never collide or cross-join; an app migrating onto this package
must use exactly the values it already shipped.

## Conventions

- Keep this package **Flutter-widget-free**. The only Flutter coupling is
  secure storage (`flutter_secure_storage` + the Block Store MethodChannel). If
  a pure-Dart consumer is ever needed, split a `identity_core` (crypto +
  identity, pure Dart) out and leave storage here.
- `crypto.dart` holds generic primitives only — no payload/domain types ever.
- The `hasIdentity()` / `IdentitySeedPresenceUnknown` tri-state is load-bearing:
  a failed secure-storage read must **never** collapse to "no identity" (that is
  the root of a recurring re-onboard/seed-clobber bug class seen in production).
  Don't "simplify" it to a bool.
- The generic storage layer (`storage_read.dart`, `kv_tier.dart`,
  `tier_policy.dart`, `secure_kv_store.dart`) makes that same rule structural:
  `StorageRead` is `sealed` with `Absent` ≠ `Unavailable` — never add a
  `valueOrNull` (that escape hatch is exactly how the bug comes back), and a
  decode failure in `readTyped` must map to `Unavailable`, never `Absent`.
  `IdentityStore` sits on this layer; its public API, tier names
  (`local`/`cloud`/`blockStore`), and `identity_store_test.dart` must not
  change when the layer evolves. `readModifyWrite` is an optimistic version
  counter on purpose — never "simplify" it into a lock or a `Future`-chained
  queue (a stuck caller must never wedge other callers).
- `package:identity/testing.dart` exports `FakeKvTier` for consumer suites —
  it is public API; keep it dependency-light (no `flutter_test`).

## Native requirement

The Android Block Store tier needs a host-app Kotlin MethodChannel handler on
`IdentityConfig.blockStoreChannel`. Absent that handler it no-ops safely. iOS
iCloud Keychain works through `flutter_secure_storage` options with no native code.

## Native crypto mirrors — `native/ios/` and `native/android/`

These are **not Dart** — standalone packages (Swift Package, Gradle project)
alongside `lib/`, for hosts that need to encrypt/decrypt outside the
Dart/Flutter runtime (killed-state evaluators, notification extensions).
Same byte-parity discipline as the Dart crypto: any change here must
keep `test/crypto_vectors.json` green on all three platforms (Dart, Swift,
Kotlin). Scope is deliberately narrow: **only** the generic primitives mirror
(DH shared secret, `secretbox`/`box`, sealed box) — app business logic stays
in the apps, not here.

- `native/ios/` — SPM package `IdentityCrypto`, depends on `swift-sodium`'s
  `Clibsodium` product (raw C bindings, not the high-level `Sodium` wrapper).
  `cd native/ios && swift test` — headless, no simulator.
- `native/android/` — standalone Gradle project, module `:crypto`, namespace
  `blue.luci.identity` (nothing app-specific belongs here; the JNI shim is
  `identity_crypto` throughout — lib name, CMake target, exported symbols).
  Needs the Android SDK + NDK (r27+) to build and a booted emulator/device to
  test — `cd native/android && ./gradlew :crypto:connectedDebugAndroidTest`.
  The Gradle wrapper (jar + scripts) is committed, so no system Gradle is
  needed.
- Both are currently **unwired** — no app depends on them yet. Get these fully
  working and tested standalone first; wiring an app onto them is a separate,
  later step — don't conflate the two.
- If you touch the crypto logic in `native/ios/` or `native/android/`, the change must be
  mirrored in `lib/src/crypto.dart` (and vice versa) and `test/crypto_vectors.json`
  must still pass on all three. A divergence here is a security bug, not a
  cosmetic one.

## Testing

`flutter test` — crypto round-trips + failure modes, identity/BIP39 determinism,
the store-binding parity vector, the `SecureKvStore` tier-orchestration suite
(run against `FakeKvTier`), and the `IdentityStore`/`BlockStoreClient`
tier/tri-state logic (via the constructor test seams — fakes injected for
storage, platform flag, and retry delay; the seams' defaults must always
preserve shipped behavior exactly). `flutter analyze` must be clean
(`flutter_lints`). The real platform-channel storage behavior is still only
exercised by a consuming app on a device/sim.
`native/ios/`: `swift test`. `native/android/`: `./gradlew :crypto:connectedDebugAndroidTest`
(emulator required).

## Docs & commits

- `SPEC.md` — the full cryptographic contract (derivations, wire formats,
  known-answer vectors). `README.md` — usage.
- Work on `main` (no feature branches). Commit only when explicitly asked.
