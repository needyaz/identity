import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin Dart wrapper around Android's Google Play Services Block Store, used as
/// the cross-device durable copy for small high-value secrets (the identity
/// seed) — the Android equivalent of iCloud Keychain on iOS.
///
/// The host app must register a native MethodChannel handler under the channel
/// name passed to the constructor (`IdentityConfig.blockStoreChannel`) that
/// implements `get` / `put` / `delete` against the Play Services Block Store
/// API (`com.google.android.gms:play-services-auth-blockstore`).
///
/// All operations are best-effort. They return null/false on:
///   - non-Android platforms (the calling code should already gate on this)
///   - Play Services unavailable or out of date
///   - no screen lock set (Block Store requires it for E2E encryption)
///   - the user's Google account isn't backing up to cloud
///   - any other transient or permanent failure
///
/// Calling code is expected to treat BlockStoreClient as an opportunistic
/// extra tier on top of a local store, never the source of truth.
class BlockStoreClient {
  final MethodChannel _channel;

  /// [channelName] must match the native handler registered by the host app
  /// (e.g. `'blue.luci.<app>/blockstore'`).
  ///
  /// [isAndroid] and [timeout] are a test seam — production callers take the
  /// defaults (real platform detection, 5 s timeout).
  BlockStoreClient(
    String channelName, {
    bool? isAndroid,
    Duration timeout = const Duration(seconds: 5),
  })  : _channel = MethodChannel(channelName),
        _isAndroid = isAndroid ?? Platform.isAndroid,
        _kTimeout = timeout;

  final bool _isAndroid;

  // Play Services Block Store tasks sometimes never call their success/failure
  // listener on AVDs without Play Store (the Task neither succeeds nor fails,
  // so the MethodChannel result is never delivered and the Dart await hangs
  // forever). A 5-second timeout converts that into a null/false return, which
  // the callers already treat as "tier unavailable".
  final Duration _kTimeout;

  /// Reads the UTF-8 string stored under [key]. Returns null if unavailable
  /// for any reason. iOS / non-Android always returns null without making
  /// any platform call.
  Future<String?> get(String key) async {
    if (!_isAndroid) return null;
    try {
      return await getStrict(key);
    } catch (e) {
      debugPrint('[BlockStore] get($key) failed: $e');
      return null;
    }
  }

  /// Like [get], but a FAILED read (platform error, timeout, hung task)
  /// THROWS instead of reading as "absent". The tiered store's tri-state
  /// depends on that difference: a confirmed absence may be trusted — and a
  /// freshly minted seed's write fan-out may then overwrite this tier — while
  /// "couldn't read" must never be. Collapsing a Play Services outage to null
  /// made a restored seed's ONLY cloud copy on Android clobberable during a
  /// re-onboard.
  ///
  /// Two client-side cases are NOT failures:
  ///  - non-Android → null (the tier is off, same as [get]);
  ///  - no native handler registered ([MissingPluginException]) → null: an
  ///    unprovisioned tier definitionally holds nothing — the same category
  ///    as `available == false`, a confirmed non-participant. Treating it as
  ///    a failure would brick a fresh install of an app that never wired the
  ///    bridge (absence could never be confirmed, so no seed could be
  ///    persisted without force).
  ///
  /// A [TimeoutException] DOES propagate — a hung Play Services task is
  /// genuinely "couldn't read", and treating it as absence is the clobber
  /// vector above. (On AVDs without Play Services, where tasks are known to
  /// hang, reads now surface as presence-unknown rather than absent.)
  ///
  /// Bridge contract for host apps: answer "Block Store not supported here"
  /// (no lock screen, outdated Play Services) as a null SUCCESS, and reserve
  /// `result.error(...)` for genuine read failures. With reads strict, that
  /// distinction is what keeps an opportunistic tier from becoming
  /// load-bearing for the launch gate. A legacy bridge that still maps
  /// failures to a null success simply never throws here — behavior is
  /// unchanged until it opts in.
  Future<String?> getStrict(String key) async {
    if (!_isAndroid) return null;
    try {
      return await _channel
          .invokeMethod<String>('get', {'key': key}).timeout(_kTimeout);
    } on MissingPluginException {
      return null; // unprovisioned tier — a confirmed non-participant
    }
  }

  /// Writes the UTF-8 string [value] under [key]. Returns true on success.
  /// On iOS / non-Android, no-ops and returns false.
  Future<bool> put(String key, String value) async {
    if (!_isAndroid) return false;
    try {
      final ok = await _channel
          .invokeMethod<bool>('put', {'key': key, 'value': value})
          .timeout(_kTimeout);
      return ok ?? false;
    } catch (e) {
      debugPrint('[BlockStore] put($key) failed: $e');
      return false;
    }
  }

  /// Deletes the entry under [key]. Returns true if the call succeeded
  /// (including the case where the key didn't exist).
  /// Retries once on timeout (Play Services tasks can hang transiently on
  /// AVDs/cold boots), logging through [debugPrint] like every other call site
  /// here. This used to be a deliberate `print()` bypass so a persistent
  /// timeout would surface in release logs — a permanent hole in a host app's
  /// "no console output in release builds" guarantee, for no benefit: [key] is
  /// never more than a constant label.
  Future<bool> delete(String key) async {
    if (!_isAndroid) return true;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final ok = await _channel
            .invokeMethod<bool>('delete', {'key': key}).timeout(_kTimeout);
        return ok ?? false;
      } on TimeoutException {
        debugPrint('[BlockStore] delete($key) timed out (attempt ${attempt + 1})');
        // Fall through to retry on attempt 0; return false on attempt 1.
      } catch (e) {
        debugPrint('[BlockStore] delete($key) failed: $e');
        return false;
      }
    }
    return false;
  }
}
