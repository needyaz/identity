# CLAUDE.md — identity

Guidance for Claude Code when working in this package.

## What this is

`identity` is the **L0 foundation** for the Luci family of apps (Mylo, Vault, …):
generic libsodium crypto primitives, seed→keypair→uid→BIP39 identity, the
de-linked store-binding token, Ed25519 signing, and tiered durable storage of
the seed (Keychain / iCloud Keychain / Android Block Store).

It was **extracted from Mylo** (`mylo_app/lib/src/crypto/` +
`services/identity_store.dart`). The crypto is byte-identical to that source —
only the app-specific namespace strings were lifted into `IdentityConfig`.

It is a standalone package consumed as a path dependency (same pattern as
`sammy`). It has **zero domain coupling** — no location, no groups, no app
models. `groups` depends on this; apps depend on this (directly and via `groups`).

## The cardinal rule: byte-parity

Three derivations are **domain-separated** and must be reproduced byte-for-byte
by any server verifier (the Deno edge functions) and by Mylo:

- `deriveBackupKey` — BLAKE2b(seed, key=domain)
- `deriveSigningKeyPair` — Ed25519 from BLAKE2b(seed, key=domain)
- `deriveStoreBindingToken` — SHA-256(domain ‖ pubkey)[:16] as a UUID

**Never** change the crypto here without updating the corresponding server
verifier in lockstep, and **never** change a shipped app's domain strings —
doing so rotates every user's derived keys out from under their stored data.
`identity_test.dart` pins the store-binding **known-answer vector** shared with
Mylo + the Deno server; if it goes red, parity is broken. Keep it green.

## IdentityConfig — the per-app seam

Every app passes its own `IdentityConfig` (seed storage key + the three domains +
Block Store channel). Apps must each pick a **distinct** namespace so identities
and derived keys never collide or cross-join. `IdentityConfig.mylo` preserves
Mylo's original values for a future Mylo migration; new apps must not reuse them.

## Conventions

- Keep this package **Flutter-widget-free**. The only Flutter coupling is
  secure storage (`flutter_secure_storage` + the Block Store MethodChannel). If
  a pure-Dart consumer is ever needed, split a `identity_core` (crypto +
  identity, pure Dart) out and leave storage here.
- `crypto.dart` holds generic primitives only — no payload/domain types ever.
- The `hasIdentity()` / `IdentitySeedPresenceUnknown` tri-state is load-bearing:
  a failed secure-storage read must **never** collapse to "no identity" (that is
  the root of Mylo's recurring re-onboard/seed-clobber bug class). Don't
  "simplify" it to a bool.

## Native requirement

The Android Block Store tier needs a host-app Kotlin MethodChannel handler on
`IdentityConfig.blockStoreChannel`. Absent that handler it no-ops safely. iOS
iCloud Keychain works through `flutter_secure_storage` options with no native code.

## Native crypto mirrors — `native/ios/` and `native/android/`

These are **not Dart** — standalone packages (Swift Package, Gradle project)
alongside `lib/`, for hosts that need to encrypt/decrypt outside the
Dart/Flutter runtime (killed-state evaluators, notification extensions).
Extracted verbatim from Mylo's `NativeCrypto.swift` / `NativeCrypto.kt` + JNI
shim — same byte-parity discipline as the Dart crypto: any change here must
keep `test/crypto_vectors.json` green on all three platforms (Dart, Swift,
Kotlin). Scope is deliberately narrow: **only** the generic primitives mirror
(DH shared secret, `secretbox`/`box`, sealed box) — Mylo's alert-evaluator and
native-store mirrors are app business logic and stay in Mylo, not here.

- `native/ios/` — SPM package `IdentityCrypto`, depends on `swift-sodium`'s
  `Clibsodium` product (raw C bindings, not the high-level `Sodium` wrapper).
  `cd native/ios && swift test` — headless, no simulator.
- `native/android/` — standalone Gradle project, module `:crypto`, namespace
  `blue.luci.identity` (renamed from Mylo's `blue.luci.mylo` — nothing
  app-specific belongs here). JNI shim renamed `mylo_crypto` →
  `identity_crypto` throughout (lib name, CMake target, exported symbols).
  Needs the Android SDK + NDK (r27+) to build and a booted emulator/device to
  test — `cd native/android && ./gradlew :crypto:connectedDebugAndroidTest`.
  Gradle wrapper jar isn't committed yet (copy one from an existing Gradle
  9.5.1 project, e.g. Mylo's, or run `gradle wrapper` once a system Gradle is
  available).
- Both are currently **unwired** — no app depends on them yet. Mylo still runs
  its own in-tree copy of `NativeCrypto.swift`/`.kt`. Get these fully working
  and tested standalone first; wiring Mylo (or any app) onto them is a
  separate, later step — don't conflate the two.
- If you touch the crypto logic in `native/ios/` or `native/android/`, the change must be
  mirrored in `lib/src/crypto.dart` (and vice versa) and `test/crypto_vectors.json`
  must still pass on all three. This is the same drift risk Mylo's
  `docs/NATIVE_PARITY.md` warns about — a divergence here is a security bug,
  not a cosmetic one.

## Testing

`flutter test` — crypto round-trips + failure modes, identity/BIP39 determinism,
and the store-binding parity vector. `flutter analyze` must be clean
(`flutter_lints`). `IdentityStore` itself is platform-channel-bound and isn't
unit-tested here; it's exercised by the consuming app on a real device/sim.
`native/ios/`: `swift test`. `native/android/`: `./gradlew :crypto:connectedDebugAndroidTest`
(emulator required).

## Docs & commits

- `SPEC.md` — the full cryptographic contract (derivations, wire formats,
  known-answer vectors). `README.md` — usage.
- **Never mention Claude, AI, or any assistant in commit messages, PR/issue
  text, or anywhere in git history** — no `Co-Authored-By`, no "generated with"
  trailers. Write commits as a plain human author.
- Work on `main` (no feature branches). Commit only when explicitly asked.
