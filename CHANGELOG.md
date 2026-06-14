## 0.1.0

- Initial extraction from Mylo (`mylo_app/lib/src/crypto/` + `identity_store.dart`).
- Generic crypto primitives, seed→keypair→UID→BIP39 identity, store-binding token,
  Ed25519 signing, and tiered secure storage (Keychain / iCloud / Block Store).
- App-specific namespace strings lifted into `IdentityConfig` so each app picks its
  own domain. `IdentityConfig.mylo` preserves the original values for byte-parity.
