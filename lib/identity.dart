/// Shared identity, key derivation, and crypto primitives for Luci apps.
///
/// Re-exports the libsodium types ([Sodium], [SecureKey], [KeyPair],
/// [PrecalculatedBox]) used across the public API so consumers need only depend
/// on this package. The tiered secure-storage layer (`SecureKvStore`,
/// `StorageRead`, `KvTier`, `TierPolicy`, `BlockStoreClient`) now lives in
/// `package:storage` and is re-exported here unchanged, so existing imports
/// keep working.
library;

export 'package:sodium/sodium.dart';
export 'package:storage/storage.dart';

export 'src/crypto.dart';
export 'src/identity.dart';
export 'src/identity_config.dart';
export 'src/identity_store.dart';
