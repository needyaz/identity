import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sodium/sodium.dart';

import 'block_store_client.dart';
import 'identity.dart';
import 'identity_config.dart';
import 'kv_tier.dart';
import 'secure_kv_store.dart';
import 'storage_read.dart';
import 'tier_policy.dart';

/// Thrown by [IdentityStore.save] when a seed already exists and `force` was not
/// set — the guard that makes new-identity creation non-destructive.
class IdentityAlreadyExistsException implements Exception {
  const IdentityAlreadyExistsException();
  @override
  String toString() =>
      'IdentityAlreadyExistsException: refusing to overwrite an existing seed';
}

/// Thrown by [IdentityStore.hasIdentity] when no tier confirmed a seed but at
/// least one tier read FAILED — presence is unknown, not absent. Collapsing
/// this to `false` is the root of a recurring re-onboard/seed-clobber bug class:
/// both callers must fail safe on this — the launch gate should route to recover
/// (not onboarding), and [IdentityStore.save] refuses to overwrite.
class IdentitySeedPresenceUnknown implements Exception {
  final Object cause;
  const IdentitySeedPresenceUnknown(this.cause);
  @override
  String toString() => 'IdentitySeedPresenceUnknown: $cause';
}

/// Persists the identity seed in the platform secure enclave
/// (iOS Keychain / Android Keystore). Everything else is derived from the seed.
///
/// Tiered storage by platform:
///
///   iOS:
///     - Local Keychain item (synchronizable: false) — fast, always-available.
///     - iCloud-synced Keychain item (synchronizable: true, best-effort) for
///       seamless restore when the user signs into the same Apple ID on a
///       new device.
///
///   Android:
///     - Local EncryptedSharedPreferences entry — fast, always-available.
///     - Block Store entry (shouldBackupToCloud: true, best-effort) for
///       restore on a new device set up under the same Google account via
///       the device-setup wizard. Block Store is the Android counterpart of
///       iCloud Keychain. (Requires a native handler on the
///       [IdentityConfig.blockStoreChannel] MethodChannel.)
///
/// Reads always try the local item first. On a new device where the local
/// item is absent, the cloud tier (iCloud Keychain on iOS, Block Store on
/// Android) is consulted and — if found — promoted to local storage so
/// subsequent reads are fast.
///
/// The tier orchestration itself lives in the generic [SecureKvStore]; this
/// class supplies the seed-specific policy (tier order, cloud-sync retry,
/// tier names) and the identity-specific contracts on top: the
/// [IdentitySeedPresenceUnknown] tri-state, the [save] clobber guard, and
/// the [onSeedAcquired] hook.
class IdentityStore {
  final IdentityConfig config;

  /// The optional storage/platform parameters are a test seam: production
  /// callers use `IdentityStore(config)` and get exactly the shipped behavior
  /// (platform secure storage, real platform detection, 2 s cloud-sync retry
  /// waits). Tests inject fakes to exercise the tier/tri-state decision logic
  /// on the host, including the Android arms.
  ///
  /// [onSeedAcquired] fires when this device NEWLY comes to hold the seed:
  /// after [save]'s local write succeeds (before the best-effort cloud
  /// mirrors), and after a cloud-tier restore in [load] promotes the seed to
  /// local (iCloud Keychain or Block Store) — never on [load]'s local-hit fast
  /// path, so an ordinary same-device read stays observation-free. That
  /// distinction is the point: it lets a host reset "the seed was wiped"
  /// bookkeeping (e.g. a native wipe latch) exactly when key material
  /// legitimately (re)appears. Synchronous and must not throw — a throw
  /// propagates to the [save]/[load] caller.
  IdentityStore(
    this.config, {
    FlutterSecureStorage? local,
    FlutterSecureStorage? cloud,
    BlockStoreClient? blockStore,
    bool? isAndroid,
    Duration syncRetryDelay = const Duration(seconds: 2),
    void Function()? onSeedAcquired,
  })  : _local = local ?? _defaultLocal,
        _cloud = cloud ?? _defaultCloud,
        _blockStore = blockStore ?? BlockStoreClient(config.blockStoreChannel),
        _isAndroid = isAndroid ?? Platform.isAndroid,
        _syncRetryDelay = syncRetryDelay,
        _onSeedAcquired = onSeedAcquired;

  String get _seedKey => config.seedStorageKey;

  // Local-only — always works, used for all normal reads.
  static const _defaultLocal = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
      synchronizable: false,
    ),
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // iOS iCloud Keychain mirror — best-effort. May throw if iCloud Keychain is
  // unavailable (disabled in Settings or no Apple ID signed in). On Android
  // this resolves to the same EncryptedSharedPreferences as _local (the
  // synchronizable flag is a no-op there); the real Android cloud is _blockStore.
  static const _defaultCloud = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
      synchronizable: true,
    ),
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final FlutterSecureStorage _local;
  final FlutterSecureStorage _cloud;

  // Android Block Store mirror — best-effort. No-op on non-Android.
  final BlockStoreClient _blockStore;

  final bool _isAndroid;
  final Duration _syncRetryDelay;
  final void Function()? _onSeedAcquired;

  static const _localTier = 'local';
  static const _cloudTier = 'cloud';
  static const _blockStoreTier = 'blockStore';

  /// The seed's tier policy: local first, then the cloud tiers, with the
  /// cloud-sync-lag retry on both cloud tiers (iCloud Keychain sync and Block
  /// Store cloud sync can lag right after install; only true-new installs —
  /// no seed anywhere — pay the extra waits). Block Store is Android-armed.
  /// The tier names are load-bearing: they surface verbatim in
  /// [IdentityClearIncomplete.tiers].
  late final SecureKvStore _kv = SecureKvStore(TierPolicy(
    tiers: [
      SecureStorageTier(_localTier, _local),
      // iOS-only: on Android the synchronizable flag is a no-op and this
      // resolves to the SAME EncryptedSharedPreferences as local — arming it
      // made a true-new Android install pay a full retry budget re-reading a
      // store local had already confirmed empty (the real Android cloud is
      // Block Store).
      SecureStorageTier(_cloudTier, _cloud, available: !_isAndroid),
      BlockStoreTier(_blockStore, available: _isAndroid),
    ],
    retryDelay: _syncRetryDelay,
    retryTiers: const {_cloudTier, _blockStoreTier},
  ));

  /// Returns true when the cloud backup tier holds THIS device's current
  /// seed: Block Store on Android, iCloud Keychain on iOS. Value-compared
  /// against the local tier — presence alone mis-reported "backed up" after
  /// another device's force-restore replaced the SHARED cloud copy with a
  /// different identity's seed.
  Future<bool> isCloudBackedUp() async {
    String? mine;
    try {
      mine = await _local.read(key: _seedKey);
    } catch (_) {
      return false; // can't read our own seed → no honest claim to make
    }
    if (mine == null) return false;
    if (_isAndroid) return await _blockStore.get(_seedKey) == mine;
    try {
      return await _cloud.read(key: _seedKey) == mine;
    } catch (_) {
      return false;
    }
  }

  /// True when a seed is confirmed present on ANY tier; false only when every
  /// tier was readable and confirmed absent. When no tier confirmed presence
  /// but at least one read FAILED, throws [IdentitySeedPresenceUnknown] —
  /// "couldn't read" must never collapse into "confirmed absent", because both
  /// callers make irreversible choices on a false: the launch gate routes an
  /// established user to onboarding, and save() lets a new seed clobber the
  /// real one.
  Future<bool> hasIdentity() async {
    return switch (await _kv.containsKey(_seedKey)) {
      Present(value: true) => true,
      Present() => false,
      Absent() => false,
      Unavailable(:final cause) => throw IdentitySeedPresenceUnknown(cause),
    };
  }

  /// Load and reconstruct identity from the stored seed.
  /// Returns null if no identity has been saved yet.
  ///
  /// Note: an `Unavailable` read (no tier produced a seed AND at least one
  /// tier failed) also returns null — the shipped contract. The launch gate
  /// must consult [hasIdentity] (which throws [IdentitySeedPresenceUnknown]
  /// in that situation) before treating a null here as "new user".
  Future<Identity?> load(Sodium sodium) async {
    switch (await _kv.read(_seedKey)) {
      case Present(:final value, :final tier):
        if (tier == _localTier) {
          debugPrint('[IdentityStore] load: found in local storage');
          // Fire-and-forget: write cloud copies for users who predate the
          // cloud tiers.
          unawaited(_kv.mirror(_seedKey, value));
        } else {
          // Cloud-tier restore, already promoted to local by the kv layer —
          // this device newly holds the seed.
          debugPrint('[IdentityStore] load: restored from $tier');
          _onSeedAcquired?.call();
        }
        return identityFromSeed(
            sodium, Uint8List.fromList(base64.decode(value)));
      case Absent():
        debugPrint('[IdentityStore] load: no identity found on any tier');
        return null;
      case Unavailable(:final cause):
        debugPrint('[IdentityStore] load: no tier produced a seed and at '
            'least one read failed: $cause');
        return null;
    }
  }

  /// Save the identity seed to secure storage.
  ///
  /// Safe-by-construction: refuses to overwrite an existing seed unless [force]
  /// is set. This is the last line of defence against a transient identity-read
  /// miss (which can surface an onboarding screen to an established user) causing
  /// a "Get Started" tap to irreversibly clobber the real seed across every tier
  /// (local + iCloud + Block Store). Only the explicit recovery/reset flows
  /// (restore-from-phrase) pass `force: true`. If presence can't be confirmed
  /// (a tier read throws) we fail safe and refuse — never overwrite on doubt.
  /// Throws [IdentityAlreadyExistsException] when a seed exists and !force.
  Future<void> save(Identity identity, {bool force = false}) async {
    if (!force) {
      final exists = switch (await _kv.containsKey(_seedKey)) {
        Present(value: false) => false,
        Absent() => false,
        // Present(true), or Unavailable: fail safe — never overwrite on doubt.
        _ => true,
      };
      if (exists) throw const IdentityAlreadyExistsException();
    }
    // extractBytes() is a deliberate one-off materialization to persist the
    // seed, not a session-long copy — see [Identity.seed].
    final encoded = base64.encode(identity.seed.extractBytes());
    // Local write is required (a failure rethrows and nothing else runs);
    // the iCloud / Block Store mirrors are best-effort.
    await _kv.write(_seedKey, encoded, onPrimaryWrite: () {
      debugPrint('[IdentityStore] save: local write ok');
      // The device now holds the seed — fires before the best-effort cloud
      // mirrors, which may fail without un-acquiring anything.
      _onSeedAcquired?.call();
    });
  }

  /// Wipe the stored identity (used for reset / account deletion).
  ///
  /// Every tier is attempted unconditionally; failures are collected rather
  /// than short-circuiting or being swallowed. If any tier could not confirm
  /// deletion, throws [IdentityClearIncomplete] naming the tiers — a silently
  /// surviving copy (e.g. iCloud Keychain locked/offline during "Delete my
  /// account") would otherwise be found by the next [load], promoted back to
  /// local, and resurrect the "deleted" identity. Deletes are idempotent, so
  /// callers can simply retry on catch.
  Future<void> clear() async {
    try {
      await _kv.delete(_seedKey);
    } on KvDeleteIncomplete catch (e) {
      throw IdentityClearIncomplete(e.tiers);
    }
  }
}

/// Thrown by [IdentityStore.clear] when one or more storage tiers could not
/// confirm deletion of the seed. [tiers] names the failed tiers
/// (`'local'`, `'cloud'`, `'blockStore'`). The other tiers were still
/// attempted; retrying [IdentityStore.clear] is safe (deletes are idempotent).
class IdentityClearIncomplete implements Exception {
  final List<String> tiers;
  const IdentityClearIncomplete(this.tiers);
  @override
  String toString() => 'IdentityClearIncomplete: ${tiers.join(", ")}';
}
