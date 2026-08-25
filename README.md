# identity

[![CI](https://github.com/needyaz/identity/actions/workflows/ci.yml/badge.svg)](https://github.com/needyaz/identity/actions/workflows/ci.yml)

Identity, key derivation, and crypto primitives for Luci apps. Pure Dart —
no Flutter, no storage. This package is the crypto that shipped in a
production app, extracted in place.

L0 foundation package: no app models, no domain types, no coupling to what
an app built on it actually does.

## Design

Identity is a pure function of `(seed, domain)`: seed in, keypair, uid,
backup key, signing key, and a 24-word recovery phrase out. Computation is
entirely on-device, using stock libsodium primitives — X25519 `crypto_box`,
XSalsa20-Poly1305 `secretbox`, sealed boxes, Ed25519 detached signatures,
keyed BLAKE2b for key derivation — plus BIP39 for the recovery phrase. No
novel cryptography.

A single seed derives separate keys per purpose (backup encryption,
signing, store binding) under distinct domains, so keys never collide or
cross-join across apps or purposes. Domain strings are frozen once shipped:
changing one after release re-derives every user's keys, with no migration
path, since no server ever held a mapping between old and new.

The server side holds no account secret and no key registry: it stores
opaque ciphertext and checks signatures. The only outputs that leave the
device are the uid (`SHA-256(pubkey)`), the store-binding token (a hash of
two public inputs), and Ed25519 verification against the signing key's
public half. The backup key never leaves the device.

Persistence is not this package's problem: durable seed storage (secure
enclave, cloud tiering, tri-state reads, clobber-guarded writes) is composed
by the app, outside this package, and handed in via `identityFromSeed`.

Native mirrors exist because the Dart runtime isn't always reachable —
notification service extensions and killed-state evaluators run outside
Flutter's memory. See "Native crypto mirrors" below.

Each derivation is pinned by known-answer vectors computed with an
independent implementation (Python `hashlib` / `cryptography`), and three
implementations (Dart, Swift, Kotlin/JNI) are checked against one shared
golden-vector file. See "Verifying this works" and `SPEC.md`.

## What's in here

- **`crypto.dart`** — generic libsodium primitives: DH shared secret, symmetric
  `secretbox` blobs, DH-`box` blobs, anonymous sealed boxes, Ed25519 signing,
  and canonical-JSON encoding for byte-exact signatures.
- **`identity.dart`** — `Identity` (seed → X25519 keypair → uid), BIP39 recovery
  phrase round-trip, and the de-linked store-binding token.

That's the whole Dart surface — three files. Durable seed storage used to
live here; since 1.0.0 it's composed by the consuming app and handed in via
`identityFromSeed`.

## Per-app namespace: `IdentityConfig`

Every app instantiates its own `IdentityConfig`. The crypto is identical across
apps — only these domain strings differ, which keeps each app's identities,
derived keys, and secure-storage entries disjoint and non-cross-joinable.

```dart
// "acme" is a placeholder — substitute your app's own namespace.
const acmeIdentity = IdentityConfig(
  seedStorageKey: 'acme.seed',
  backupKeyDomain: 'acme-backup-v1',
  signingKeyDomain: 'acme-group-signing',
  storeBindingDomain: 'acme-store-binding-v1',
  blockStoreChannel: 'blue.luci.acme/blockstore',
);
```

## Usage

```dart
final sodium = await SodiumInit.init();

// Persistence is composed by the app: read the seed from wherever the app
// durably keeps it (a clobber-guarded secure-enclave slot), or mint one.
final storedSeed = await readSeedFromAppStorage();     // app-side
final identity = storedSeed != null
    ? identityFromSeed(sodium, storedSeed)
    : generateIdentity(sodium);

final backupKey = deriveBackupKey(
  sodium, identity.seed, domain: acmeIdentity.backupKeyDomain,
);
// identity.seed is a SecureKey — extract only where raw bytes are needed:
final phrase = seedToMnemonic(identity.seed.extractBytes());  // 24-word phrase
```

The app-side seed store must honor two rules: a failed read is never
treated as "no identity" (never route an established user to onboarding on
a read error), and a fresh seed must never overwrite an
existing one without explicit recovery intent.

## Native crypto mirrors: `native/ios/` and `native/android/`

Some hosts need to encrypt/decrypt outside the Dart/Flutter runtime — a
killed-state background evaluator, a notification service extension, or
similar native-only code path that can't reach Flutter's memory. `native/ios/`
and `native/android/` are standalone packages, outside the pub dependency
graph, that reimplement this package's generic crypto primitives (DH shared
secret, `secretbox`/`box` blobs, sealed boxes) byte-for-byte. All three
implementations are pinned by the same `test/crypto_vectors.json` golden
vectors.

- **`native/ios/IdentityCrypto/`** — Swift Package (`IdentityCrypto` target),
  depends on [`jedisct1/swift-sodium`](https://github.com/jedisct1/swift-sodium)'s
  `Clibsodium` product for the libsodium C bindings (not the higher-level
  `Sodium` wrapper — this keeps the direct C-call style of the original file).
  `cd native/ios/IdentityCrypto && swift test` — runs headless on plain macOS,
  no simulator needed.
- **`native/android/`** — standalone Gradle project, one library module (`:crypto`,
  namespace `blue.luci.identity`). Loads libsodium.so from the
  `lazysodium-android` AAR at runtime and resolves symbols via `dlsym` through
  its own thin JNI bridge (`identity_crypto`), bypassing lazysodium's JNA
  bridge (`libjnidispatch.so`, which crashes on Android 15's 16 KB page-size
  requirement). `cd native/android && ./gradlew :crypto:connectedDebugAndroidTest` —
  the crypto-parity test is instrumented (needs a booted emulator/device),
  since the JNI `dlopen`-by-soname trick only works inside a live Android
  linker namespace.
- **Consuming-app requirement (Android)**: the JNI shim's `dlopen`-by-soname
  needs the `.so` extracted to disk at install time. The application module
  that packages this library must set
  `packagingOptions { jniLibs { useLegacyPackaging = true } }` — this can't be
  enforced from a library module.
- **Consumed by Mylo by path** (2026-08-25): the app's Runner and notification
  service extension link `IdentityCrypto.podspec` (a CocoaPods view of the
  same SwiftPM sources — `pod 'IdentityCrypto', :path => …`), its host test
  package depends on `native/ios/IdentityCrypto` directly, and its Gradle
  build includes `native/android/crypto` as a project. One copy, built by the
  app and pinned here. The Swift package lives one directory down
  (`native/ios/IdentityCrypto/`) because SwiftPM identifies local packages by
  directory basename and a consuming app's own host package also lives in a
  dir called `ios`.

## Verifying this works

Three independent implementations of the same crypto (Dart, Swift, Kotlin/JNI),
three independent test suites, all three pinned against the same
`test/crypto_vectors.json` golden vectors. CI runs the Dart, Swift, and
Android-emulator suites on every push (badge above).

### Derivation vectors: independent computation

The known-answer vectors in `SPEC.md` were computed with an implementation
that shares no code with this package — Python's stdlib `hashlib` plus the
`cryptography` package's Ed25519. The computation is checked into this
repo, in `tools/verify_vectors.py`. Run

```
python3 tools/verify_vectors.py
```

and it re-derives all five expected values from the spec'd algorithms and
compares them (exit non-zero on any mismatch). The script covers the
domain-separated derivations only; the box/sealed-box/secretbox golden
vectors are libsodium constructions with no mainstream independent Python
implementation, and their guarantee is the three-way binding parity below
instead.

### Dart

Prereqs: the Dart SDK (no Flutter needed).

```
dart pub get
dart test
```

Expect `All tests passed!` — `crypto_test.dart` (round-trips, failure modes,
and the backup/signing known-answer vectors), `identity_test.dart` (identity
determinism + the store-binding parity vector), and `crypto_vectors_test.dart`
(the golden-vector suite).

```
dart analyze
```

Expect `No issues found!`.

### iOS / Swift (`native/ios/IdentityCrypto/`)

Prereqs: macOS with Xcode / the Swift toolchain. First run needs network
access once, to resolve the `swift-sodium` dependency from GitHub.

```
cd native/ios/IdentityCrypto
swift test
```

Expect `Executed 19 tests, with 0 failures` — `NativeCryptoTests` (16 unit
tests) + `CryptoVectorsTests` (3, the golden-vector suite, reading
`test/crypto_vectors.json` directly off disk). This runs headless on plain
macOS — no simulator boot required.

### Android / Kotlin (`native/android/`)

Prereqs: Android SDK with NDK 27+ installed, JDK 17+, and a booted
emulator/device for the instrumented test. The Gradle wrapper (`gradlew` +
`gradle/wrapper/`) is committed, so no local Gradle install is needed —
`./gradlew` bootstraps its own.

Create `native/android/local.properties` (machine-specific, gitignored, not
committed) pointing at your SDK:

```
sdk.dir=/path/to/Android/sdk
```

Build — compiles the JNI shim (`identity_crypto_jni.c`) for all 4 ABIs via
CMake, no emulator needed:

```
cd native/android
./gradlew :crypto:assembleDebug
```

Expect `BUILD SUCCESSFUL`.

Run the crypto-parity test — this one must run on a real emulator/device
(not a plain JVM unit test): the JNI `dlopen`-by-soname trick that loads
libsodium only resolves inside a live Android linker namespace.

```
# in one terminal, boot any AVD and wait for it:
$ANDROID_HOME/emulator/emulator -avd <your-avd-name> -no-window &
$ANDROID_HOME/platform-tools/adb wait-for-device

# then:
./gradlew :crypto:connectedDebugAndroidTest
```

> ⚠️ Use an AVD **without a screen-lock PIN/pattern**. A locked AVD booted
> headless stays in the `RUNNING_LOCKED` (credential-encrypted) state, Android
> refuses to start the test process (`SecurityException: package … is not
> encryption aware`), and the connected test hangs forever with no error.
> Verify with `adb shell dumpsys user | grep State:` — it must say
> `RUNNING_UNLOCKED`.

Expect `BUILD SUCCESSFUL`, and
`crypto/build/outputs/androidTest-results/connected/debug/TEST-*.xml` shows
`tests="4" failures="0"` — `nativeCryptoReady` (proves the JNI shim loaded and
resolved libsodium via `dlsym`), `boxDecryptVectors`, `secretBoxDecryptVectors`,
`sealOpenVectors` (the golden-vector suite).

### Test coverage across implementations

When all three suites pass, the same `box_decrypt`, `secretbox_decrypt`,
and `seal_open` vectors in `test/crypto_vectors.json` decrypted correctly
through three independently-implemented code paths: Dart/libsodium-dart,
Swift/swift-sodium's `Clibsodium`, and Kotlin via a hand-written JNI bridge
to `libsodium.so`. A failure in any one of them indicates crypto-mirror
drift.

## License

MIT — see [LICENSE](LICENSE). No third-party code is vendored into this repo;
everything below is consumed as an unmodified dependency.

Third-party licenses (relevant when redistributing built apps, since their
binaries embed these — preserve the upstream notices):

| Dependency | Used by | License |
|---|---|---|
| [libsodium](https://github.com/jedisct1/libsodium) | all three implementations | ISC |
| [`sodium`](https://pub.dev/packages/sodium) (Dart bindings) | Dart | BSD-3-Clause |
| [`bip39`](https://pub.dev/packages/bip39), [`crypto`](https://pub.dev/packages/crypto) | Dart | BSD-3-Clause |
| [swift-sodium](https://github.com/jedisct1/swift-sodium) (`Clibsodium`) | `native/ios/` | ISC |
| [lazysodium-android](https://github.com/terl/lazysodium-android) | `native/android/` | MPL-2.0 |
| Gradle wrapper | `native/android/` build | Apache-2.0 |

`lazysodium-android` is used only as the delivery vehicle for its bundled,
16 KB-aligned `libsodium.so` (ISC) — its MPL-2.0 Java classes are not loaded
or modified, so MPL's file-level copyleft imposes nothing here; apps wanting
a pure-permissive dependency tree can exclude those classes in packaging.
