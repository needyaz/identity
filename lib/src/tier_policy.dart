import 'kv_tier.dart';

/// Per-key tier behavior for a [SecureKvStore], declared as data.
///
/// Expresses the tier shapes seen at real call sites: an ordered read chain
/// with promote-on-read, migration-only (read-never-write) legacy tiers,
/// platform-armed tiers that are skipped when unavailable, a one-shot
/// cloud-sync-lag retry, and primary-required / mirror-best-effort write
/// fan-out.
class TierPolicy {
  const TierPolicy({
    required this.tiers,
    this.promoteOnRead = true,
    this.noPromoteTiers = const {},
    this.writeTiers,
    this.retryDelay,
    this.retryTiers = const {},
  });

  /// Ordered read chain; the first tier to produce a value wins.
  final List<KvTier> tiers;

  /// When true (default), a hit on any tier other than the primary write
  /// tier is written back to the primary so subsequent reads are fast.
  /// Promote failures are non-fatal — the read still returns `Present`.
  /// After a *successful* promote from a non-[KvTier.writable] (migration)
  /// tier, the legacy copy is deleted, best-effort.
  final bool promoteOnRead;

  /// Per-tier opt-out from [promoteOnRead]: a hit on a tier named here is
  /// served but never written back to the primary (and, for migration
  /// tiers, never triggers the legacy delete). For values whose conflict
  /// rule resolves *above* this layer — e.g. a cloud copy that must not be
  /// treated as authoritative until the app has arbitrated against a server
  /// backup.
  final Set<String> noPromoteTiers;

  /// Tier names to write, in order: the first entry is the primary (its
  /// write must succeed or the whole write fails, rethrowing the tier's
  /// original exception); the rest are best-effort mirrors. When null
  /// (default), every [KvTier.writable] tier in [tiers] order is written,
  /// first-as-primary.
  final List<String>? writeTiers;

  /// When set, a tier named in [retryTiers] that produces no value (a miss
  /// *or* a failure) is re-read once after this delay before the chain moves
  /// on — cloud tiers (iCloud Keychain, Block Store) can lag for a few
  /// seconds right after install. Injected so tests run instantly
  /// (`Duration.zero`). Applies to reads only, never to `containsKey`.
  final Duration? retryDelay;

  /// Names of the tiers [retryDelay] applies to.
  final Set<String> retryTiers;
}
