/// Tri-state result of a tiered secure-storage read.
///
/// The reason this exists (instead of `T?`): a nullable read cannot
/// distinguish "confirmed absent" from "couldn't read", and collapsing the
/// two is the root of a recurring re-onboard/data-clobber bug class — a
/// locked Keychain or corrupt blob gets treated as "new user" and drives a
/// destructive overwrite. Because [StorageRead] is `sealed`, an exhaustive
/// `switch` makes that collapse a compile-time impossibility rather than a
/// discipline callers must remember.
///
/// There is deliberately no `valueOrNull` — that escape hatch reintroduces
/// exactly the bug this type prevents. Use an exhaustive `switch`, or
/// [valueOr] when a named fallback is genuinely correct.
sealed class StorageRead<T> {
  const StorageRead();

  /// The read value, or [fallback] for [Absent] and [Unavailable].
  ///
  /// The only value-extracting convenience on purpose: it forces the caller
  /// to name a fallback, keeping "what happens when the read didn't produce
  /// a value" an explicit decision at the call site.
  T valueOr(T fallback) => switch (this) {
        Present<T>(:final value) => value,
        Absent<T>() => fallback,
        Unavailable<T>() => fallback,
      };
}

/// A tier produced a value.
///
/// A later-tier hit still yields [Present] even if an earlier tier threw —
/// the value is real; the earlier failure only matters when *no* tier
/// produces one (then the result is [Unavailable], never [Absent]).
final class Present<T> extends StorageRead<T> {
  const Present(this.value, {this.tier});

  final T value;

  /// Name of the [KvTier] that produced the value, when the read came from a
  /// single tier; null for merged or derived results (e.g. `readAll`).
  /// Lets callers distinguish a primary-tier hit from a promoted restore.
  final String? tier;
}

/// Confirmed: every available tier was read successfully and none held the
/// key. This is a positive fact — safe to act on (e.g. route to onboarding).
final class Absent<T> extends StorageRead<T> {
  const Absent();
}

/// No tier produced a value AND at least one tier read failed — presence is
/// unknown. NEVER interchangeable with [Absent]: acting on [Unavailable] as
/// if it were absence (onboarding, re-creation, overwrite) is precisely the
/// bug class this type exists to prevent.
final class Unavailable<T> extends StorageRead<T> {
  const Unavailable(this.cause);

  /// The first per-tier failure, surfaced (not swallowed) so callers can
  /// report it rather than silently degrade.
  final Object cause;
}
