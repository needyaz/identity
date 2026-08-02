/// App-specific namespace + domain-separation strings for the identity layer.
///
/// Every Luci app instantiates its OWN config so identities, derived keys, and
/// secure-storage entries never collide across apps and can't be cross-joined.
/// The crypto operations themselves are byte-identical across apps — only these
/// domain strings differ.
///
/// Three of these values feed **domain-separated key derivations** that a server
/// verifier must reproduce byte-for-byte ([backupKeyDomain], [signingKeyDomain],
/// [storeBindingDomain]). Once an app has shipped, NEVER change them — doing so
/// rotates every user's derived keys out from under their stored data.
class IdentityConfig {
  /// Secure-storage key under which the 32-byte seed is persisted
  /// (Keychain / iCloud Keychain / EncryptedSharedPreferences / Block Store).
  final String seedStorageKey;

  /// BLAKE2b domain for `deriveBackupKey`. UTF-8 length must be <= 16 bytes
  /// (short domains are right-padded to libsodium's 16-byte key minimum).
  final String backupKeyDomain;

  /// BLAKE2b domain for `deriveSigningKeyPair` (Ed25519). UTF-8 length must be
  /// within libsodium's generic-hash key range (16..64 bytes).
  final String signingKeyDomain;

  /// SHA-256 domain prefix for `deriveStoreBindingToken`. Must be pure ASCII.
  final String storeBindingDomain;

  /// MethodChannel name the host app's native Block Store handler listens on
  /// (Android only). Must match the app's native registration.
  final String blockStoreChannel;

  const IdentityConfig({
    required this.seedStorageKey,
    required this.backupKeyDomain,
    required this.signingKeyDomain,
    required this.storeBindingDomain,
    required this.blockStoreChannel,
  });
}
