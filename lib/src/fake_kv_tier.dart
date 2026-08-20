import 'package:flutter/services.dart';

import 'kv_tier.dart';

/// In-memory, fault-injectable [KvTier] for host tests — exported via
/// `package:identity/testing.dart` so consumers don't each rewrite it.
///
/// Faults default to a realistic locked-Keychain `PlatformException`
/// (`errSecInteractionNotAllowed`, OSStatus -25308) — the real-world shape
/// of "one tier fails while another succeeds".
class FakeKvTier implements KvTier {
  FakeKvTier(
    this.name, {
    this.available = true,
    this.writable = true,
    this.enumerable = true,
  });

  @override
  final String name;

  @override
  bool available;

  @override
  bool writable;

  @override
  bool enumerable;

  /// Backing map — seed it directly to model pre-existing data.
  final Map<String, String> store = {};

  /// Per-key faults: `read`/`containsKey` (resp. `write`, `delete`) of that
  /// key throws the given error.
  final Map<String, Object> readFaults = {};
  final Map<String, Object> writeFaults = {};
  final Map<String, Object> deleteFaults = {};

  /// Wholesale switches — every read (resp. write, delete, including
  /// `readAll`) throws [defaultFault].
  bool failAllReads = false;
  bool failAllWrites = false;
  bool failAllDeletes = false;

  /// What the wholesale switches throw.
  Object defaultFault = PlatformException(
    code: '-25308',
    message: 'errSecInteractionNotAllowed (Keychain locked)',
  );

  /// When a queue exists for a key, `read` answers from it (front first,
  /// `null` = miss) instead of [store] — models "empty on first read,
  /// present on retry" (cloud sync lag).
  final Map<String, List<String?>> readQueues = {};

  /// When set, `read`/`containsKey` first await this future — lets a test
  /// hold a read open while it interleaves a concurrent write, or model a
  /// call that never settles.
  Future<void>? readGate;

  /// When set, `write` first awaits this future — lets a test prove mirror
  /// writes run concurrently (a held-open mirror must not gate its siblings).
  Future<void>? writeGate;

  final Map<String, int> readCounts = {};

  /// How many times [read] was called for [key].
  int readCount(String key) => readCounts[key] ?? 0;

  @override
  Future<String?> read(String key) async {
    readCounts[key] = readCount(key) + 1;
    final gate = readGate;
    if (gate != null) await gate;
    if (failAllReads) throw defaultFault;
    final fault = readFaults[key];
    if (fault != null) throw fault;
    final queue = readQueues[key];
    if (queue != null) return queue.isEmpty ? null : queue.removeAt(0);
    return store[key];
  }

  @override
  Future<bool> containsKey(String key) async {
    final gate = readGate;
    if (gate != null) await gate;
    if (failAllReads) throw defaultFault;
    final fault = readFaults[key];
    if (fault != null) throw fault;
    return store.containsKey(key);
  }

  @override
  Future<void> write(String key, String value) async {
    final gate = writeGate;
    if (gate != null) await gate;
    if (failAllWrites) throw defaultFault;
    final fault = writeFaults[key];
    if (fault != null) throw fault;
    store[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failAllDeletes) throw defaultFault;
    final fault = deleteFaults[key];
    if (fault != null) throw fault;
    store.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async {
    if (!enumerable) {
      throw UnsupportedError('tier "$name" cannot enumerate');
    }
    if (failAllReads) throw defaultFault;
    return Map.of(store);
  }
}
