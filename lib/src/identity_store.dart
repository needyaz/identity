import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sodium/sodium.dart';

import 'block_store_client.dart';
import 'identity.dart';
import 'identity_config.dart';

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

  /// Returns true if the identity seed is present in the cloud backup tier:
  /// Block Store on Android, iCloud Keychain on iOS.
  Future<bool> isCloudBackedUp() async {
    if (_isAndroid) return await _blockStore.get(_seedKey) != null;
    try {
      return await _cloud.containsKey(key: _seedKey);
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
    Object? firstFailure;
    try {
      if (await _local.containsKey(key: _seedKey)) return true;
    } catch (e) {
      firstFailure = e;
    }
    try {
      if (await _cloud.containsKey(key: _seedKey)) return true;
    } catch (e) {
      firstFailure ??= e;
    }
    if (_isAndroid) {
      try {
        if (await _blockStore.get(_seedKey) != null) return true;
      } catch (e) {
        firstFailure ??= e;
      }
    }
    if (firstFailure != null) throw IdentitySeedPresenceUnknown(firstFailure);
    return false;
  }

  /// Load and reconstruct identity from the stored seed.
  /// Returns null if no identity has been saved yet.
  Future<Identity?> load(Sodium sodium) async {
    // Fast path: local store (same device, always available).
    // Wrapped in try/catch because EncryptedSharedPreferences can throw on
    // Android if the Keystore key is in a bad state (invalidated after a
    // security-policy change, corrupted during an OS update, etc.). Without
    // this guard the exception would propagate and skip the Block Store tier.
    String? localB64;
    try {
      localB64 = await _local.read(key: _seedKey);
    } catch (e) {
      debugPrint('[IdentityStore] local read failed: $e');
    }
    if (localB64 != null) {
      debugPrint('[IdentityStore] load: found in local storage');
      // Fire-and-forget: write cloud copies for users who predate the cloud tiers.
      unawaited(_ensureCloudCopies(localB64));
      return identityFromSeed(sodium, Uint8List.fromList(base64.decode(localB64)));
    }
    debugPrint('[IdentityStore] load: local empty, trying cloud tiers');

    // iOS restore path: iCloud Keychain (new device, same Apple ID). iCloud
    // Keychain sync can lag for a few seconds right after install, so a single
    // read can miss a seed that is about to land. Try once, then retry after a
    // short wait — mirrors the Block Store retry below. Only true-new installs
    // (no seed anywhere) pay the extra wait; an established device with a local
    // seed never reaches this path.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final cloudB64 = await _cloud.read(key: _seedKey);
        if (cloudB64 != null) {
          debugPrint('[IdentityStore] load: restored from iCloud Keychain'
              ' (attempt ${attempt + 1})');
          await _local.write(key: _seedKey, value: cloudB64);
          _onSeedAcquired?.call();
          return identityFromSeed(
              sodium, Uint8List.fromList(base64.decode(cloudB64)));
        }
      } catch (e) {
        debugPrint('[IdentityStore] iCloud read failed (attempt'
            ' ${attempt + 1}): $e');
      }
      if (attempt == 0) {
        debugPrint('[IdentityStore] load: iCloud empty, waiting 2 s for sync…');
        await Future<void>.delayed(_syncRetryDelay);
      }
    }

    // Android restore path: Block Store (same device reinstall or new device
    // on the same Google account). Block Store cloud sync has a documented
    // delay — data may not be available immediately after reinstall. We try
    // once, then retry after a short wait to give the cloud sync time to land.
    if (_isAndroid) {
      debugPrint('[IdentityStore] load: trying Block Store (attempt 1)');
      String? blockB64 = await _blockStore.get(_seedKey);
      if (blockB64 == null) {
        debugPrint('[IdentityStore] load: Block Store empty, waiting 2 s for cloud sync…');
        await Future<void>.delayed(_syncRetryDelay);
        blockB64 = await _blockStore.get(_seedKey);
        debugPrint('[IdentityStore] load: Block Store retry: ${blockB64 != null ? 'found' : 'still empty'}');
      } else {
        debugPrint('[IdentityStore] load: restored from Block Store');
      }
      if (blockB64 != null) {
        await _local.write(key: _seedKey, value: blockB64);
        _onSeedAcquired?.call();
        return identityFromSeed(sodium, Uint8List.fromList(base64.decode(blockB64)));
      }
    }

    debugPrint('[IdentityStore] load: no identity found on any tier');
    return null;
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
      bool exists;
      try {
        exists = await hasIdentity();
      } catch (_) {
        exists = true; // fail safe: cannot confirm absence → do not overwrite.
      }
      if (exists) throw const IdentityAlreadyExistsException();
    }
    // extractBytes() is a deliberate one-off materialization to persist the
    // seed, not a session-long copy — see [Identity.seed].
    final encoded = base64.encode(identity.seed.extractBytes());
    // Local copy — always written first.
    await _local.write(key: _seedKey, value: encoded);
    debugPrint('[IdentityStore] save: local write ok');
    // The device now holds the seed — fires before the best-effort cloud
    // mirrors, which may fail without un-acquiring anything.
    _onSeedAcquired?.call();
    // iCloud copy — iOS only in practice (no-op on Android); best effort.
    try {
      await _cloud.write(key: _seedKey, value: encoded);
      debugPrint('[IdentityStore] save: cloud write ok');
    } catch (e) {
      debugPrint('[IdentityStore] save: cloud write failed: $e');
    }
    // Block Store copy — Android only; best effort. BlockStoreClient.put
    // already no-ops on non-Android.
    final blockOk = await _blockStore.put(_seedKey, encoded);
    if (_isAndroid) {
      debugPrint('[IdentityStore] save: Block Store put: $blockOk');
    }
  }

  // Silently write cloud copies (iCloud + Block Store) if not already present.
  // Called from the load() fast-path so existing users get their seed mirrored
  // on first launch after the feature ships.
  Future<void> _ensureCloudCopies(String encoded) async {
    try {
      if (!await _cloud.containsKey(key: _seedKey)) {
        await _cloud.write(key: _seedKey, value: encoded);
      }
    } catch (e) {
      debugPrint('[IdentityStore] iCloud sync failed: $e');
    }
    if (_isAndroid && await _blockStore.get(_seedKey) == null) {
      await _blockStore.put(_seedKey, encoded);
    }
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
    final failedTiers = <String>[];
    try {
      await _local.delete(key: _seedKey);
    } catch (_) {
      failedTiers.add('local');
    }
    try {
      await _cloud.delete(key: _seedKey);
    } catch (_) {
      failedTiers.add('cloud');
    }
    try {
      // BlockStoreClient.delete reports failure as `false`, not a throw
      // (and returns true on non-Android, where the tier doesn't exist).
      final ok = await _blockStore.delete(_seedKey);
      if (!ok) failedTiers.add('blockStore');
    } catch (_) {
      failedTiers.add('blockStore');
    }
    if (failedTiers.isNotEmpty) throw IdentityClearIncomplete(failedTiers);
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
