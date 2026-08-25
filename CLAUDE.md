# CLAUDE.md — identity

Guidance for Claude Code when working in this package.

## What this is

`identity` is the **L0 foundation** for the Luci family of apps:
generic libsodium crypto primitives, seed→keypair→uid→BIP39 identity, the
de-linked store-binding token, and Ed25519 signing. **Pure Dart** — no
Flutter, no storage. Since 1.0.0, durable seed persistence (and the tiered
secure-storage layer it was built on) lives in the separate private
`storage` package; consuming apps compose the two. This package must
**never** grow a dependency on `storage` (or any private repo): identity is
public, and a public package must carry no private dependency.

It was **extracted from a shipped production app** — this package is that
app's crypto, moved in place. Only the app-specific namespace strings were
lifted out into `IdentityConfig`.

It is a standalone package consumed as a path dependency. It has **zero domain
coupling** — no app models, no domain types. `groups` depends on this; apps
depend on this (directly and via `groups`).

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

- Keep this package **pure Dart** — no `flutter` imports, no storage, no
  platform channels. That purity is the point of the 1.0.0 split (it is the
  `identity_core` end-state the pre-1.0 docs anticipated); anything needing
  a platform belongs in `storage` or the apps.
- `crypto.dart` holds generic primitives only — no payload/domain types ever.
- `IdentityConfig.seedStorageKey` / `.blockStoreChannel` are passive per-app
  namespace data the app forwards to its storage layer — this package never
  reads them, but they stay in the config so each app's namespace lives in
  one place. Same frozen-once-shipped rule as the domains.
- The seed-store invariants ("a failed read is never no-identity"; "never
  overwrite a seed without explicit recovery intent") are documented in
  SPEC.md "Secure storage" and enforced by the storage layer the apps
  compose — keep the SPEC section intact so the contract survives the
  package boundary.

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

`dart test` — crypto round-trips + failure modes, identity/BIP39 determinism,
the store-binding parity vector, and the golden-vector suite. `dart analyze`
must be clean (`lints/recommended`). No Flutter SDK needed.
`native/ios/`: `swift test`. `native/android/`: `./gradlew :crypto:connectedDebugAndroidTest`
(emulator required).

## Docs & commits

- `SPEC.md` — the full cryptographic contract (derivations, wire formats,
  known-answer vectors). `README.md` — usage.
- Feature branches + PRs are the normal workflow. Commit only when explicitly asked.
