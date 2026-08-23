/// Shared identity, key derivation, and crypto primitives for Luci apps.
///
/// Pure Dart — no Flutter, no storage. Identity is a pure function:
/// `(seed, domain) → keypair, uid, backup key, signing key, recovery phrase`.
/// Durable seed *persistence* is deliberately not this package's concern:
/// apps compose a storage layer (e.g. a clobber-guarded secure-enclave slot)
/// with [identityFromSeed] themselves.
///
/// Re-exports the libsodium types ([Sodium], [SecureKey], [KeyPair],
/// [PrecalculatedBox]) used across the public API so consumers need only
/// depend on this package.
library;

export 'package:sodium/sodium.dart';

export 'src/crypto.dart';
export 'src/identity.dart';
export 'src/identity_config.dart';
