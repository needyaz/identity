/// Shared identity, key derivation, secure-storage tiering, and crypto
/// primitives for Luci apps.
///
/// Re-exports the libsodium types ([Sodium], [SecureKey], [KeyPair],
/// [PrecalculatedBox]) used across the public API so consumers need only depend
/// on this package.
library;

export 'package:sodium/sodium.dart';

export 'src/block_store_client.dart';
export 'src/crypto.dart';
export 'src/identity.dart';
export 'src/identity_config.dart';
export 'src/identity_store.dart';
