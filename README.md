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

## Native crypto mirrors: `native/ios/` and `native/android/`

Some hosts need to encrypt/decrypt outside the Dart/Flutter runtime — a
killed-state background evaluator, a notification service extension, or
similar native-only code path that can't reach Flutter's memory. `native/ios/` and
`native/android/` are standalone packages (not Dart, not consumed via `pubspec.yaml`)
providing exactly that: a byte-identical native reimplementation of this
package's generic crypto primitives (DH shared secret, `secretbox`/`box`
blobs, sealed boxes) — nothing else. Extracted from Mylo's
`NativeCrypto.swift` / `NativeCrypto.kt` + JNI shim; the crypto is
byte-identical to that source, pinned by the same `test/crypto_vectors.json`
golden vectors this package's Dart tests use.

- **`native/ios/`** — Swift Package (`IdentityCrypto` target), depends on
  [`jedisct1/swift-sodium`](https://github.com/jedisct1/swift-sodium)'s
  `Clibsodium` product for the libsodium C bindings (not the higher-level
  `Sodium` wrapper — this keeps the direct C-call style of the original file).
  `cd native/ios && swift test` — runs headless on plain macOS, no simulator needed.
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
  needs the `.so` extracted to disk at install time. The *application* module
  that packages this library must set
  `packagingOptions { jniLibs { useLegacyPackaging = true } }` — this can't be
  enforced from a library module.
- Not yet wired into any app (Mylo still runs its own in-tree copy; that flip
  is a separate, later step). These two packages exist to be a fully working,
  independently testable baseline first.

## Verifying this works

Three independent implementations of the same crypto (Dart, Swift, Kotlin/JNI),
three independent test suites, all three pinned against the same
`test/crypto_vectors.json` golden vectors. Anyone with a clean checkout can
reproduce all of this — no Mylo checkout, no backend, no account needed.

### Dart

Prereqs: Flutter SDK.

```
flutter pub get
flutter test
```

Expect `All tests passed!` — 20 tests across `crypto_test.dart`,
`identity_test.dart`, and `crypto_vectors_test.dart` (the golden-vector suite).

```
flutter analyze
```

Expect `No issues found!`.

### iOS / Swift (`native/ios/`)

Prereqs: macOS with Xcode / the Swift toolchain. First run needs network
access once, to resolve the `swift-sodium` dependency from GitHub.

```
cd native/ios
swift test
```

Expect `Executed 18 tests, with 0 failures` — `NativeCryptoTests` (16 unit
tests) + `CryptoVectorsTests` (2, the golden-vector suite, reading
`test/crypto_vectors.json` directly off disk). This runs **headless on plain
macOS — no simulator boot required**.

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

Run the crypto-parity test — this one **must** run on a real emulator/device
(not a plain JVM unit test): the JNI `dlopen`-by-soname trick that loads
libsodium only resolves inside a live Android linker namespace.

```
# in one terminal, boot any AVD and wait for it:
$ANDROID_HOME/emulator/emulator -avd <your-avd-name> -no-window &
$ANDROID_HOME/platform-tools/adb wait-for-device

# then:
./gradlew :crypto:connectedDebugAndroidTest
```

Expect `BUILD SUCCESSFUL`, and
`crypto/build/outputs/androidTest-results/connected/debug/TEST-*.xml` shows
`tests="3" failures="0"` — `nativeCryptoReady` (proves the JNI shim loaded and
resolved libsodium via `dlsym`), `boxDecryptVectors`, `sealOpenVectors` (the
golden-vector suite).

### What "all green" proves

If all three suites above pass, the same `box_decrypt` and `seal_open`
vectors in `test/crypto_vectors.json` decrypted correctly through three
independently-implemented code paths (Dart/libsodium-dart,
Swift/swift-sodium's `Clibsodium`, Kotlin via a hand-written JNI bridge to
`libsodium.so`). That's the actual claim this repo makes: not "the code looks
right," but "three unrelated implementations agree on the same ciphertexts."
A failure in any one of them is a crypto-mirror drift bug, not a test flake.
