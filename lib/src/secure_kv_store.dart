import 'package:flutter/foundation.dart';

import 'kv_tier.dart';
import 'storage_read.dart';
import 'tier_policy.dart';

/// Thrown by [SecureKvStore.delete] when one or more tiers could not confirm
/// deletion. The other tiers were still attempted; deletes are idempotent,
/// so retrying is safe. A silently surviving copy on one tier would
/// otherwise be found by a later read, promoted back to the primary, and
/// resurrect the "deleted" value.
class KvDeleteIncomplete implements Exception {
  const KvDeleteIncomplete(this.tiers, this.causes);

  /// Names of the tiers that failed, in [TierPolicy.tiers] order.
  final List<String> tiers;

  /// The per-tier failure, keyed by tier name.
  final Map<String, Object> causes;

  @override
  String toString() => 'KvDeleteIncomplete: ${tiers.join(", ")}';
}

/// Generic tiered secure-storage: an ordered read chain with tri-state
/// results, promote-on-read, migration tiers, platform arming, sync-lag
/// retry, and primary-required write fan-out — the machinery extracted from
/// `IdentityStore`, which now sits on top of this.
///
/// Every behavior is driven by an injected [TierPolicy], so "one tier fails
/// while another succeeds" is testable on the host with plain Dart fakes
/// (`package:identity/testing.dart` ships one).
class SecureKvStore {
  SecureKvStore(this.policy)
      : assert(policy.tiers.isNotEmpty, 'TierPolicy.tiers must not be empty');

  final TierPolicy policy;

  /// The resolved write chain: [TierPolicy.writeTiers] by name, or every
  /// writable tier in [TierPolicy.tiers] order. First entry is the primary.
  List<KvTier> get _writeChain {
    final names = policy.writeTiers;
    if (names == null) {
      return [
        for (final tier in policy.tiers)
          if (tier.writable) tier,
      ];
    }
    return [
      for (final name in names)
        policy.tiers.firstWhere(
          (tier) => tier.name == name,
          orElse: () =>
              throw ArgumentError('writeTiers names unknown tier "$name"'),
        ),
    ];
  }

  /// Reads [key] through the tier chain, first hit wins.
  ///
  /// - [Present] when any available tier produced a value — even if an
  ///   earlier tier threw. A non-primary hit is promoted to the primary
  ///   write tier when [TierPolicy.promoteOnRead] is set; promote failures
  ///   are non-fatal.
  /// - [Absent] ONLY when every available tier was read successfully and
  ///   none held the key.
  /// - [Unavailable] when no tier produced a value and at least one threw;
  ///   carries the first failure.
  Future<StorageRead<String>> read(String key) async {
    Object? firstFailure;
    final failedTiers = <String>{};
    for (final tier in policy.tiers) {
      if (!tier.available) continue;
      final retry = policy.retryDelay != null &&
          policy.retryTiers.contains(tier.name);
      final attempts = retry ? 2 : 1;
      for (var attempt = 0; attempt < attempts; attempt++) {
        String? value;
        try {
          value = await tier.read(key);
        } catch (e) {
          firstFailure ??= e;
          failedTiers.add(tier.name);
          debugPrint('[SecureKvStore] read($key): ${tier.name} failed '
              '(attempt ${attempt + 1}): $e');
        }
        if (value != null) {
          await _promote(key, value,
              source: tier, failedThisRead: failedTiers);
          return Present(value, tier: tier.name);
        }
        if (attempt == 0 && attempts == 2) {
          debugPrint('[SecureKvStore] read($key): ${tier.name} empty, '
              'waiting ${policy.retryDelay} for sync…');
          await Future<void>.delayed(policy.retryDelay!);
        }
      }
    }
    if (firstFailure != null) return Unavailable(firstFailure);
    return const Absent();
  }

  Future<void> _promote(String key, String value,
      {required KvTier source, Set<String> failedThisRead = const {}}) async {
    if (!policy.promoteOnRead) return;
    if (policy.noPromoteTiers.contains(source.name)) return;
    final chain = _writeChain;
    if (chain.isEmpty) return;
    final primary = chain.first;
    if (source.name == primary.name || !primary.available) return;
    // Never overwrite a primary whose read FAILED this pass. A miss is
    // promotable ground; a failure is unknown ground — the primary may hold
    // a DIFFERENT value the failure hid (two devices on one cloud account,
    // one force-restored), and writing over it silently replaces this
    // device's identity. Same never-overwrite-on-doubt discipline as
    // save()'s guard; promotion simply retries on a later, healthy read.
    if (failedThisRead.contains(primary.name)) {
      debugPrint('[SecureKvStore] read($key): promote skipped — '
          '${primary.name} read failed this pass (miss ≠ failure)');
      return;
    }
    try {
      await primary.write(key, value);
      debugPrint(
          '[SecureKvStore] read($key): promoted ${source.name} → ${primary.name}');
    } catch (e) {
      // Non-fatal: the read still returns Present; the source copy remains
      // authoritative and promotion is retried on the next read.
      debugPrint('[SecureKvStore] read($key): promote to ${primary.name} '
          'failed (non-fatal): $e');
      return;
    }
    if (!source.writable) {
      // Migration-only tier: retire the legacy copy now that the primary
      // holds the value. Best-effort — a failed legacy delete never fails
      // the read; the next read simply migrates again.
      try {
        await source.delete(key);
      } catch (e) {
        debugPrint('[SecureKvStore] read($key): legacy delete from '
            '${source.name} failed (non-fatal): $e');
      }
    }
  }

  /// Whether any tier holds [key].
  ///
  /// - `Present(true)` as soon as one available tier confirms.
  /// - `Present(false)` when every available tier was readable and none
  ///   held the key — for a boolean question, "confirmed absent" IS the
  ///   value `false`, so [Absent] is never returned.
  /// - [Unavailable] when no tier confirmed and at least one threw (first
  ///   failure on `cause`).
  ///
  /// No [TierPolicy.retryDelay] applies here — presence checks are gate
  /// decisions and must stay fast.
  Future<StorageRead<bool>> containsKey(String key) async {
    Object? firstFailure;
    for (final tier in policy.tiers) {
      if (!tier.available) continue;
      try {
        if (await tier.containsKey(key)) {
          return Present(true, tier: tier.name);
        }
      } catch (e) {
        firstFailure ??= e;
      }
    }
    if (firstFailure != null) return Unavailable(firstFailure);
    return const Present(false);
  }

  /// Writes [key]=[value] through the write chain: the primary tier must
  /// succeed (its original exception is rethrown unwrapped, and no mirror is
  /// attempted), then each remaining available tier is written best-effort.
  ///
  /// [onPrimaryWrite] fires after the primary commit and before the mirrors
  /// — the durable "this device now holds the value" point (e.g.
  /// `IdentityStore.onSeedAcquired`). Synchronous; a throw propagates.
  Future<void> write(String key, String value,
      {void Function()? onPrimaryWrite}) async {
    final chain = _writeChain;
    if (chain.isEmpty) {
      throw StateError('TierPolicy has no writable tiers');
    }
    final primary = chain.first;
    if (!primary.available) {
      throw StateError('primary write tier "${primary.name}" is unavailable');
    }
    await primary.write(key, value);
    onPrimaryWrite?.call();
    // Mirrors are independent and individually best-effort — run them
    // CONCURRENTLY: serial awaits put one hung tier's full timeout (a
    // stalled Play Services task can ride out several seconds) on the save
    // path ahead of every other mirror.
    await Future.wait([
      for (final tier in chain.skip(1))
        if (tier.available)
          () async {
            try {
              await tier.write(key, value);
            } catch (e) {
              debugPrint('[SecureKvStore] write($key): best-effort mirror to '
                  '${tier.name} failed: $e');
            }
          }(),
    ]);
  }

  /// Ensures every available non-primary write tier holds [key]=[value],
  /// check-before-write, each tier best-effort. The generalization of
  /// `IdentityStore`'s cloud backfill: called (typically fire-and-forget)
  /// after a primary-tier hit so users who predate a mirror tier get their
  /// value mirrored without rewriting every tier on every read.
  Future<void> mirror(String key, String value) async {
    for (final tier in _writeChain.skip(1)) {
      if (!tier.available) continue;
      try {
        if (!await tier.containsKey(key)) {
          await tier.write(key, value);
          debugPrint('[SecureKvStore] mirror($key): backfilled ${tier.name}');
        }
      } catch (e) {
        debugPrint(
            '[SecureKvStore] mirror($key): ${tier.name} failed (non-fatal): $e');
      }
    }
  }

  /// Deletes [key] from every available tier — including read-only
  /// migration tiers (their legacy copies must die too), and without
  /// short-circuiting on failure. If any tier could not confirm deletion,
  /// throws [KvDeleteIncomplete] naming the tiers; retrying is safe.
  Future<void> delete(String key) async {
    final failed = <String>[];
    final causes = <String, Object>{};
    for (final tier in policy.tiers) {
      if (!tier.available) continue;
      try {
        await tier.delete(key);
      } catch (e) {
        failed.add(tier.name);
        causes[tier.name] = e;
        debugPrint('[SecureKvStore] delete($key): ${tier.name} failed: $e');
      }
    }
    if (failed.isNotEmpty) throw KvDeleteIncomplete(failed, causes);
  }

  /// Merges `readAll` across every available, enumerable tier, earlier
  /// tiers taking precedence per key.
  ///
  /// Stricter than [read]: ANY tier failure yields [Unavailable], even if
  /// other tiers enumerated fine — a partially-merged map with silently
  /// missing keys is per-key absence-as-fact, exactly the bug this layer
  /// exists to prevent. Non-enumerable tiers (e.g. Block Store) are
  /// skipped, which is documented behavior, not a failure.
  Future<StorageRead<Map<String, String>>> readAll() async {
    Object? firstFailure;
    final merged = <String, String>{};
    for (final tier in policy.tiers) {
      if (!tier.available || !tier.enumerable) continue;
      try {
        final entries = await tier.readAll();
        for (final entry in entries.entries) {
          merged.putIfAbsent(entry.key, () => entry.value);
        }
      } catch (e) {
        firstFailure ??= e;
        debugPrint('[SecureKvStore] readAll: ${tier.name} failed: $e');
      }
    }
    if (firstFailure != null) return Unavailable(firstFailure);
    if (merged.isEmpty) return const Absent();
    return Present(merged);
  }
}

/// A storage key plus its codec — what a domain store reduces to when the
/// tiering lives in [SecureKvStore].
class TypedKey<T> {
  const TypedKey(this.key, {required this.encode, required this.decode});

  final String key;
  final String Function(T) encode;
  final T Function(String) decode;
}

/// Typed views over [SecureKvStore].
extension SecureKvStoreTyped on SecureKvStore {
  /// [SecureKvStore.read] through [TypedKey.decode].
  ///
  /// A decode failure maps to [Unavailable], never [Absent]: a corrupt blob
  /// is "couldn't read", not "no data" — collapsing it to absence is
  /// precisely what drove a destructive re-onboard in production.
  Future<StorageRead<T>> readTyped<T>(TypedKey<T> k) async {
    switch (await read(k.key)) {
      case Present(:final value, :final tier):
        try {
          return Present(k.decode(value), tier: tier);
        } catch (e) {
          return Unavailable<T>(e);
        }
      case Absent():
        return Absent<T>();
      case Unavailable(:final cause):
        return Unavailable<T>(cause);
    }
  }

  /// [SecureKvStore.write] through [TypedKey.encode].
  ///
  /// There is deliberately no read-modify-write helper for list/set-shaped
  /// values: an earlier optimistic-version-counter version had a reproduced
  /// residual race (a reader starting after another writer's version bump
  /// but before that write landed passed its own check and lost the write —
  /// see CHANGELOG 0.6.0). The correct fix for list-shaped values is
  /// per-record keys, not better concurrency control over one blob.
  Future<void> writeTyped<T>(TypedKey<T> k, T value) =>
      write(k.key, k.encode(value));
}
