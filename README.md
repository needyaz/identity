# identity

Shared identity, key derivation, secure-storage tiering, and crypto primitives
for Luci apps. Extracted from a shipped production app; the crypto is
byte-identical to that source.

This is an L0 foundation package: it has **zero domain coupling** (no location,
no groups, no app models) and is the substrate the rest of a Luci app builds on.

## Why this exists

The short version of "why did you build your own thing":

**We didn't build crypto — we composed libsodium.** There is no novel
primitive or protocol in this repo. Every operation is a stock libsodium
construction — X25519 `crypto_box`, XSalsa20-Poly1305 `secretbox`, sealed
boxes, Ed25519 detached signatures, keyed BLAKE2b for key derivation — plus
standard BIP39 for the recovery phrase. The crypto surface is thin glue with
one fixed, boring wire format: `base64(nonce ‖ ciphertext)`. Read
`lib/src/crypto.dart`; it's ~250 lines and mostly doc comments.

**The glue is the thing that doesn't exist off the shelf.** What this package
actually adds is architecture, not cryptography, and each piece earns its
place:

- *One seed → domain-separated derived keys → one 24-word recovery phrase.*
  A user has exactly one secret to back up; every app and every purpose
  (backup encryption, signing, store binding) gets its own key, derived under
  a distinct domain, so keys never collide or cross-join. Server-account SDKs
  (OAuth providers, Firebase, passkeys) solve a different problem — they
  authenticate you *to a server*; none of them hand an app stable local keys
  for end-to-end encryption.
- *Tiered seed durability with honest failure semantics.* The seed is
  mirrored local + cloud (Keychain / iCloud Keychain, EncryptedSharedPreferences /
  Block Store), and `hasIdentity()` is deliberately tri-state: "couldn't
  read" is not "absent". That distinction — and `save()` refusing to
  overwrite an existing seed — exists because collapsing it to a bool caused
  a real re-onboard/seed-clobber bug class in the production app this was
  extracted from.
- *A de-linked store-binding token.* The account token disclosed to
  Apple/Google for purchases is a sibling hash of the uid, not the uid — so
  store records can't be joined against backend records. A privacy property
  no generic library provides.
- *Native mirrors, because the Dart runtime isn't always there.* Notification
  service extensions and killed-state evaluators can't reach Flutter memory.
  The Android mirror hand-rolls a thin JNI bridge specifically because JNA's
  `libjnidispatch.so` crashes on Android 15's 16 KB page-size devices — a
  documented workaround, not not-invented-here.

**You don't have to take our word for it.** Three independent implementations
(Dart, Swift, Kotlin/JNI) are pinned against one shared golden-vector file,
and every derivation is pinned by known-answer vectors computed with an
*independent* implementation (Python `hashlib` / `cryptography`) rather than
by the code testing itself. See "Verifying this works" below and `SPEC.md`
for the full contract.

The fair criticism that remains: key *management* — not primitives — is where
real-world failures live, and this package does hand-roll that. The
presence-unknown tri-state, the overwrite guard, and the parity vectors are
the direct response; treat `SPEC.md` as the auditable statement of exactly
what this code promises.

## What's in here

- **`crypto.dart`** — generic libsodium primitives: DH shared secret, symmetric
  `secretbox` blobs, DH-`box` blobs, anonymous sealed boxes, Ed25519 signing,
  and canonical-JSON encoding for byte-exact signatures.
- **`identity.dart`** — `Identity` (seed → X25519 keypair → uid), BIP39 recovery
  phrase round-trip, and the de-linked store-binding token.
- **`secure_kv_store.dart`** (+ `storage_read.dart`, `kv_tier.dart`,
  `tier_policy.dart`) — generic tiered secure storage: a sealed tri-state
  `StorageRead` result (`Present` / `Absent` / `Unavailable` — an exhaustive
  `switch` makes "failed read treated as absent" uncompilable), a pluggable
  `KvTier` interface (ships `SecureStorageTier` and `BlockStoreTier`;
  consumers can add e.g. a legacy `SharedPreferences` tier without this
  package taking the dependency), a `TierPolicy` describing read order,
  promote-on-read, migration-only tiers, platform arming, cloud sync-lag
  retry and write fan-out, plus `TypedKey` views.
- **`identity_store.dart`** — tiered durable storage of the 32-byte seed:
  local Keychain/EncryptedSharedPreferences + iCloud Keychain (iOS) + Block
  Store (Android), built on `SecureKvStore`. Includes the hard-won
  presence-unknown guard (a failed read must never be treated as "no
  identity").
- **`block_store_client.dart`** — Android Block Store MethodChannel wrapper.
- **`package:identity/testing.dart`** — `FakeKvTier`, a fault-injectable
  in-memory tier for consumer test suites ("one tier fails while another
  succeeds" on the host, no platform channels).

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

> ⚠️ Once an app ships, never change `backupKeyDomain`, `signingKeyDomain`, or
> `storeBindingDomain`: they feed domain-separated derivations that any server
> verifier must reproduce byte-for-byte, and changing one rotates every user's
> derived keys out from under their stored data. An app migrating onto this
> package must define an `IdentityConfig` with exactly the values it already
> shipped.

## Usage

```dart
final sodium = await SodiumInit.init();
final store = IdentityStore(acmeIdentity);

var identity = await store.load(sodium);
identity ??= generateIdentity(sodium);
await store.save(identity);            // refuses to clobber an existing seed

final backupKey = deriveBackupKey(
  sodium, identity.seed, domain: acmeIdentity.backupKeyDomain,
);
// identity.seed is a SecureKey — extract only where raw bytes are needed:
final phrase = seedToMnemonic(identity.seed.extractBytes());  // 24-word phrase
```

### Tiered storage for your own keys: `SecureKvStore`

The tiering `IdentityStore` uses for the seed is available generically — a
domain store reduces to a key, a codec, and a `TierPolicy`:

```dart
final kv = SecureKvStore(TierPolicy(
  tiers: [
    SecureStorageTier('local', localStorage),
    SecureStorageTier('cloud', icloudStorage),
    SecureStorageTier('legacy', legacyStorage, writable: false), // migrate-and-retire
  ],
  retryDelay: const Duration(seconds: 2),
  retryTiers: const {'cloud'},
));

const profileKey = TypedKey<Profile>('acme.profile',
    encode: encodeProfile, decode: decodeProfile);

switch (await kv.readTyped(profileKey)) {
  case Present(:final value): useProfile(value);
  case Absent(): startOnboarding();            // confirmed: no data anywhere
  case Unavailable(:final cause): report(cause); // couldn't read — NOT "no data"
}
```

The `sealed` result is the point: a failed or corrupt read can't be mistaken
for absence without the compiler objecting. For tests,
`package:identity/testing.dart` exports `FakeKvTier` with per-key and
wholesale fault injection.

## Native requirement (Android only)

`IdentityStore`'s Block Store tier needs a native MethodChannel handler on the
host app's `blockStoreChannel`, implementing `get`/`put`/`delete` against the
Play Services Block Store API (the host app supplies the
`com.google.android.gms:play-services-auth-blockstore` dependency). Absent a
handler, the tier no-ops safely. iCloud Keychain on iOS works through
`flutter_secure_storage` options with no native code.

## Native crypto mirrors: `native/ios/` and `native/android/`

Some hosts need to encrypt/decrypt outside the Dart/Flutter runtime — a
killed-state background evaluator, a notification service extension, or
similar native-only code path that can't reach Flutter's memory. `native/ios/` and
`native/android/` are standalone packages (not Dart, not consumed via `pubspec.yaml`)
providing exactly that: a byte-identical native reimplementation of this
package's generic crypto primitives (DH shared secret, `secretbox`/`box`
blobs, sealed boxes) — nothing else. All three implementations are pinned by
the same `test/crypto_vectors.json` golden vectors.

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
- Not yet wired into any app. These two packages exist to be a fully working,
  independently testable baseline first.

## Verifying this works

Three independent implementations of the same crypto (Dart, Swift, Kotlin/JNI),
three independent test suites, all three pinned against the same
`test/crypto_vectors.json` golden vectors. Anyone with a clean checkout can
reproduce all of this — no backend, no account needed.

### Dart

Prereqs: Flutter SDK.

```
flutter pub get
flutter test
```

Expect `All tests passed!` — 107 tests across `crypto_test.dart` (round-trips,
failure modes, and the backup/signing known-answer vectors),
`identity_test.dart` (identity determinism + the store-binding parity vector),
`crypto_vectors_test.dart` (the golden-vector suite), and
`secure_kv_store_test.dart` / `identity_store_test.dart` /
`block_store_client_test.dart` (the storage tier/tri-state decision logic, run
against injected fakes).

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

Expect `Executed 19 tests, with 0 failures` — `NativeCryptoTests` (16 unit
tests) + `CryptoVectorsTests` (3, the golden-vector suite, reading
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

### What "all green" proves

If all three suites above pass, the same `box_decrypt`, `secretbox_decrypt`,
and `seal_open` vectors in `test/crypto_vectors.json` decrypted correctly
through three independently-implemented code paths (Dart/libsodium-dart,
Swift/swift-sodium's `Clibsodium`, Kotlin via a hand-written JNI bridge to
`libsodium.so`). That's the actual claim this repo makes: not "the code looks
right," but "three unrelated implementations agree on the same ciphertexts."
A failure in any one of them is a crypto-mirror drift bug, not a test flake.

## License

MIT — see [LICENSE](LICENSE). No third-party code is vendored into this repo;
everything below is consumed as an unmodified dependency.

Third-party licenses (relevant when redistributing built apps, since their
binaries embed these — preserve the upstream notices):

| Dependency | Used by | License |
|---|---|---|
| [libsodium](https://github.com/jedisct1/libsodium) | all three implementations | ISC |
| [`sodium`](https://pub.dev/packages/sodium) (Dart bindings) | Dart | BSD-3-Clause |
| [`bip39`](https://pub.dev/packages/bip39), [`crypto`](https://pub.dev/packages/crypto), [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage) | Dart | BSD-3-Clause |
| [swift-sodium](https://github.com/jedisct1/swift-sodium) (`Clibsodium`) | `native/ios/` | ISC |
| [lazysodium-android](https://github.com/terl/lazysodium-android) | `native/android/` | MPL-2.0 |
| Gradle wrapper | `native/android/` build | Apache-2.0 |

Note on `lazysodium-android`: it is used **only** as the delivery vehicle for
its bundled, 16 KB-aligned `libsodium.so` (ISC) — its MPL-2.0 Java classes are
loaded never and modified never, so MPL's file-level copyleft imposes nothing
here; apps wanting a pure-permissive dependency tree can exclude those classes
in packaging. Android's Block Store itself comes from Google Play Services
(proprietary), which the consuming app supplies.
