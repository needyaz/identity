## 0.1.0

- Initial extraction from a shipped production app.
- Generic crypto primitives, seed→keypair→UID→BIP39 identity, store-binding token,
  Ed25519 signing, and tiered secure storage (Keychain / iCloud / Block Store).
- App-specific namespace strings lifted into `IdentityConfig` so each app picks its
  own domain.
