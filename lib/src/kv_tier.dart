import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'block_store_client.dart';

/// One storage tier in a [SecureKvStore] read/write chain.
///
/// An interface rather than an enum so consumers can supply tiers this
/// package has no business depending on (e.g. a plaintext
/// `SharedPreferences` legacy-migration tier) without this package taking
/// the dependency. Ships with [SecureStorageTier] and [BlockStoreTier].
abstract class KvTier {
  /// Stable identifier used in diagnostics, [TierPolicy.retryTiers] /
  /// [TierPolicy.writeTiers] selection, and failure reporting
  /// (`Unavailable.cause` context, `KvDeleteIncomplete.tiers`).
  String get name;

  /// False for legacy/migration-only tiers: they are read (and their copy
  /// deleted after a successful promote to the primary tier) but never
  /// written.
  bool get writable;

  /// False when the platform arm is off (e.g. Block Store on iOS). An
  /// unavailable tier is skipped entirely — it is never read, written, or
  /// deleted, and being skipped never counts as a read failure.
  bool get available;

  /// False when the tier cannot enumerate its keys (e.g. Block Store, which
  /// has no listing API). Non-enumerable tiers are skipped by
  /// `SecureKvStore.readAll` — documented, and not counted as a failure.
  bool get enumerable;

  Future<String?> read(String key);
  Future<bool> containsKey(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<Map<String, String>> readAll();
}

/// A [KvTier] over a [FlutterSecureStorage] instance (Keychain /
/// EncryptedSharedPreferences, with whatever options the caller configured —
/// local, iCloud-synchronizable, or a legacy accessibility class).
///
/// Distinct tiers are distinct *Dart* objects here, which is what makes
/// per-tier fault injection possible on the test host: a test can hand two
/// different fakes to two tiers, where platform-level option selection made
/// them indistinguishable.
class SecureStorageTier implements KvTier {
  SecureStorageTier(
    this.name,
    this.storage, {
    this.available = true,
    this.writable = true,
  });

  @override
  final String name;

  final FlutterSecureStorage storage;

  @override
  final bool available;

  @override
  final bool writable;

  @override
  bool get enumerable => true;

  @override
  Future<String?> read(String key) => storage.read(key: key);

  @override
  Future<bool> containsKey(String key) => storage.containsKey(key: key);

  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => storage.readAll();
}

/// A [KvTier] over a [BlockStoreClient] (Android Block Store — the
/// cross-device durable copy). [available] defaults to the real platform
/// check; tests and [IdentityStore] inject their own flag.
///
/// [BlockStoreClient.get] reports failure by returning null rather than
/// throwing (it is opportunistic by contract) — but this tier must NOT: the
/// tri-state [StorageRead] treats a throw as "unavailable" and a null as
/// "confirmed absent", and only the former stops a fresh mint from
/// overwriting a real seed this tier holds. Reads therefore use
/// [BlockStoreClient.getStrict]; a false `put`/`delete` return is likewise
/// converted to a throw — the generic layer must be able to count a failed
/// delete, or a silently surviving copy resurrects deleted data via
/// promote-on-read.
class BlockStoreTier implements KvTier {
  BlockStoreTier(
    this.client, {
    this.name = 'blockStore',
    bool? available,
  }) : available = available ?? Platform.isAndroid;

  @override
  final String name;

  final BlockStoreClient client;

  @override
  final bool available;

  @override
  bool get writable => true;

  @override
  bool get enumerable => false;

  @override
  Future<String?> read(String key) => client.getStrict(key);

  @override
  Future<bool> containsKey(String key) async =>
      await client.getStrict(key) != null;

  @override
  Future<void> write(String key, String value) async {
    if (!await client.put(key, value)) {
      throw StateError('Block Store put($key) failed');
    }
  }

  @override
  Future<void> delete(String key) async {
    if (!await client.delete(key)) {
      throw StateError('Block Store delete($key) failed');
    }
  }

  @override
  Future<Map<String, String>> readAll() =>
      throw UnsupportedError('Block Store cannot enumerate keys');
}
