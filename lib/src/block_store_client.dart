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
      return await _channel
          .invokeMethod<String>('get', {'key': key}).timeout(_kTimeout);
    } catch (e) {
      debugPrint('[BlockStore] get($key) failed: $e');
      return null;
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
  /// AVDs/cold boots); logs a warning via [print] (not debugPrint) so that
  /// a persistent timeout surfaces in crash logs even in release builds.
  Future<bool> delete(String key) async {
    if (!_isAndroid) return true;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final ok = await _channel
            .invokeMethod<bool>('delete', {'key': key}).timeout(_kTimeout);
        return ok ?? false;
      } on TimeoutException {
        // ignore: avoid_print
        print('[BlockStore] delete($key) timed out (attempt ${attempt + 1})');
        // Fall through to retry on attempt 0; return false on attempt 1.
      } catch (e) {
        debugPrint('[BlockStore] delete($key) failed: $e');
        return false;
      }
    }
    return false;
  }
}
