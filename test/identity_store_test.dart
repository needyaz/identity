/// IdentityStore tier/tri-state decision logic, exercised on the host via the
/// constructor test seam (fake storage tiers, injected platform flag, zero
/// retry delay). The invariants under test are the load-bearing ones:
/// "couldn't read" must never collapse into "no identity", and save() must
/// never overwrite a seed it can't prove absent.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:identity/identity.dart';

/// In-memory FlutterSecureStorage double. Only the four members IdentityStore
/// uses are implemented; anything else hits noSuchMethod and fails loudly.
class FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> store = {};

  /// When set, containsKey/read throw this (write/delete are unaffected).
  Object? throwOnRead;

  /// When set, write throws this.
  Object? throwOnWrite;

  /// When set, delete throws this.
  Object? throwOnDelete;

  /// When non-null, read() answers from this queue (front first) instead of
  /// [store] — lets a test model "empty on first read, present on retry".
  List<String?>? readQueue;

  int readCount = 0;

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (throwOnRead != null) throw throwOnRead!;
    return store.containsKey(key);
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    readCount++;
    if (throwOnRead != null) throw throwOnRead!;
    final queue = readQueue;
    if (queue != null) return queue.isEmpty ? null : queue.removeAt(0);
    return store[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (throwOnWrite != null) throw throwOnWrite!;
    store[key] = value!;
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (throwOnDelete != null) throw throwOnDelete!;
    store.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// In-memory BlockStoreClient double (never touches a MethodChannel).
class FakeBlockStore extends BlockStoreClient {
  FakeBlockStore() : super('test/blockstore', isAndroid: false);

  final Map<String, String> store = {};
  Object? throwOnGet;
  List<String?>? getQueue;
  int getCount = 0;

  /// When false, delete() reports failure the way the real client does —
  /// by returning false, not throwing.
  bool deleteResult = true;

  @override
  Future<String?> get(String key) async {
    getCount++;
    if (throwOnGet != null) throw throwOnGet!;
    final queue = getQueue;
    if (queue != null) return queue.isEmpty ? null : queue.removeAt(0);
    return store[key];
  }

  @override
  Future<bool> put(String key, String value) async {
    store[key] = value;
    return true;
  }

  @override
  Future<bool> delete(String key) async {
    if (!deleteResult) return false;
    store.remove(key);
    return true;
  }
}

const _config = IdentityConfig(
  seedStorageKey: 'acme.seed',
  backupKeyDomain: 'acme-backup-v1',
  signingKeyDomain: 'acme-group-signing',
  storeBindingDomain: 'acme-store-binding-v1',
  blockStoreChannel: 'blue.luci.acme/blockstore',
);

void main() {
  late Sodium sodium;
  late FakeSecureStorage local;
  late FakeSecureStorage cloud;
  late FakeBlockStore block;

  final seed = Uint8List.fromList(List<int>.generate(32, (i) => i));
  final seedB64 = base64.encode(seed);

  setUpAll(() async {
    sodium = await SodiumInit.init();
  });

  setUp(() {
    local = FakeSecureStorage();
    cloud = FakeSecureStorage();
    block = FakeBlockStore();
  });

  IdentityStore storeOn({required bool android}) => IdentityStore(
        _config,
        local: local,
        cloud: cloud,
        blockStore: block,
        isAndroid: android,
        syncRetryDelay: Duration.zero,
      );

  group('hasIdentity tri-state', () {
    test('true when local confirms', () async {
      local.store['acme.seed'] = seedB64;
      expect(await storeOn(android: false).hasIdentity(), isTrue);
    });

    test('true when local read fails but cloud confirms', () async {
      local.throwOnRead = Exception('keystore bad state');
      cloud.store['acme.seed'] = seedB64;
      expect(await storeOn(android: false).hasIdentity(), isTrue);
    });

    test('true when local+cloud fail but Block Store confirms (Android)',
        () async {
      local.throwOnRead = Exception('a');
      cloud.throwOnRead = Exception('b');
      block.store['acme.seed'] = seedB64;
      expect(await storeOn(android: true).hasIdentity(), isTrue);
    });

    test('false only when every tier was readable and absent', () async {
      expect(await storeOn(android: false).hasIdentity(), isFalse);
      expect(await storeOn(android: true).hasIdentity(), isFalse);
    });

    test('throws IdentitySeedPresenceUnknown when a read fails and no tier '
        'confirms — never collapses to false', () async {
      final rootCause = Exception('keychain unavailable');
      local.throwOnRead = rootCause;
      expect(
        () => storeOn(android: false).hasIdentity(),
        throwsA(isA<IdentitySeedPresenceUnknown>()
            .having((e) => e.cause, 'cause', same(rootCause))),
      );
    });

    test('carries the FIRST failure when several tiers fail', () async {
      final first = Exception('local boom');
      local.throwOnRead = first;
      cloud.throwOnRead = Exception('cloud boom');
      block.throwOnGet = Exception('block boom');
      expect(
        () => storeOn(android: true).hasIdentity(),
        throwsA(isA<IdentitySeedPresenceUnknown>()
            .having((e) => e.cause, 'cause', same(first))),
      );
    });

    test('Block Store failure alone is enough to make presence unknown '
        '(Android), and is ignored on non-Android', () async {
      block.throwOnGet = Exception('play services');
      expect(() => storeOn(android: true).hasIdentity(),
          throwsA(isA<IdentitySeedPresenceUnknown>()));
      expect(await storeOn(android: false).hasIdentity(), isFalse);
    });
  });

  group('save guard', () {
    test('refuses to overwrite an existing seed', () async {
      local.store['acme.seed'] = seedB64;
      final id = identityFromSeed(sodium, seed);
      expect(() => storeOn(android: false).save(id),
          throwsA(isA<IdentityAlreadyExistsException>()));
    });

    test('refuses when presence cannot be confirmed (fail safe)', () async {
      local.throwOnRead = Exception('unreadable');
      final id = identityFromSeed(sodium, seed);
      expect(() => storeOn(android: false).save(id),
          throwsA(isA<IdentityAlreadyExistsException>()));
      expect(local.store, isEmpty, reason: 'must not write on doubt');
    });

    test('force: true overwrites', () async {
      local.store['acme.seed'] = 'old';
      final id = identityFromSeed(sodium, seed);
      await storeOn(android: false).save(id, force: true);
      expect(local.store['acme.seed'], seedB64);
    });

    test('writes local + cloud + Block Store', () async {
      // save() delegates Block Store writes unconditionally; the non-Android
      // no-op is BlockStoreClient's contract (block_store_client_test.dart).
      final id = identityFromSeed(sodium, seed);
      await storeOn(android: true).save(id);
      expect(local.store['acme.seed'], seedB64);
      expect(cloud.store['acme.seed'], seedB64);
      expect(block.store['acme.seed'], seedB64);
    });

    test('cloud write failure is best-effort — save still succeeds', () async {
      cloud.throwOnWrite = Exception('icloud off');
      final id = identityFromSeed(sodium, seed);
      await storeOn(android: false).save(id);
      expect(local.store['acme.seed'], seedB64);
    });
  });

  group('load tier orchestration', () {
    test('local hit returns immediately and backfills cloud tiers', () async {
      local.store['acme.seed'] = seedB64;
      final id = await storeOn(android: true).load(sodium);
      expect(id, isNotNull);
      expect(id!.seed.extractBytes(), equals(seed));
      await pumpEventQueue(); // let the fire-and-forget backfill run
      expect(cloud.store['acme.seed'], seedB64);
      expect(block.store['acme.seed'], seedB64);
    });

    test('local miss + iCloud hit promotes the seed to local', () async {
      cloud.store['acme.seed'] = seedB64;
      final id = await storeOn(android: false).load(sodium);
      expect(id!.seed.extractBytes(), equals(seed));
      expect(local.store['acme.seed'], seedB64);
    });

    test('iCloud empty on first read, found on retry (sync lag)', () async {
      cloud.readQueue = [null, seedB64];
      final id = await storeOn(android: false).load(sodium);
      expect(id!.seed.extractBytes(), equals(seed));
      expect(cloud.readCount, 2);
      expect(local.store['acme.seed'], seedB64);
    });

    test('Block Store empty on first read, found on retry (Android)', () async {
      block.getQueue = [null, seedB64];
      final id = await storeOn(android: true).load(sodium);
      expect(id!.seed.extractBytes(), equals(seed));
      expect(local.store['acme.seed'], seedB64);
    });

    test('local read failure falls through to cloud tiers', () async {
      local.throwOnRead = Exception('keystore bad state');
      block.store['acme.seed'] = seedB64;
      final id = await storeOn(android: true).load(sodium);
      expect(id!.seed.extractBytes(), equals(seed));
    });

    test('returns null when no tier has a seed', () async {
      expect(await storeOn(android: true).load(sodium), isNull);
      expect(await storeOn(android: false).load(sodium), isNull);
    });
  });

  group('onSeedAcquired hook', () {
    // The load-bearing contract: fires exactly when the device NEWLY comes to
    // hold the seed (fresh save, cloud-tier restore), never on an ordinary
    // same-device read — so a host can reset wipe-latch bookkeeping without
    // every app launch counting as an acquisition.
    IdentityStore hookedStore({required bool android, required void Function() hook}) =>
        IdentityStore(
          _config,
          local: local,
          cloud: cloud,
          blockStore: block,
          isAndroid: android,
          syncRetryDelay: Duration.zero,
          onSeedAcquired: hook,
        );

    test('save: fires once, after the local write, before the cloud mirrors',
        () async {
      var fired = 0;
      String? localAtFire, cloudAtFire, blockAtFire;
      final store = hookedStore(
        android: true,
        hook: () {
          fired++;
          localAtFire = local.store['acme.seed'];
          cloudAtFire = cloud.store['acme.seed'];
          blockAtFire = block.store['acme.seed'];
        },
      );
      await store.save(identityFromSeed(sodium, seed));
      expect(fired, 1);
      expect(localAtFire, seedB64, reason: 'local write precedes the hook');
      expect(cloudAtFire, isNull, reason: 'cloud mirrors follow the hook');
      expect(blockAtFire, isNull, reason: 'Block Store follows the hook');
    });

    test('save: does NOT fire when the local write fails', () async {
      local.throwOnWrite = Exception('keystore bad state');
      var fired = 0;
      final store = hookedStore(android: false, hook: () => fired++);
      await expectLater(
          store.save(identityFromSeed(sodium, seed)), throwsA(anything));
      expect(fired, 0);
    });

    test('load: does NOT fire on the local-hit fast path', () async {
      local.store['acme.seed'] = seedB64;
      var fired = 0;
      final store = hookedStore(android: true, hook: () => fired++);
      expect(await store.load(sodium), isNotNull);
      await pumpEventQueue(); // the fire-and-forget cloud backfill must not fire it
      expect(fired, 0);
    });

    test('load: fires once after an iCloud restore is promoted to local',
        () async {
      cloud.store['acme.seed'] = seedB64;
      var fired = 0;
      String? localAtFire;
      final store = hookedStore(
        android: false,
        hook: () {
          fired++;
          localAtFire = local.store['acme.seed'];
        },
      );
      expect(await store.load(sodium), isNotNull);
      expect(fired, 1);
      expect(localAtFire, seedB64, reason: 'promotion precedes the hook');
    });

    test('load: fires once after a Block Store restore is promoted to local '
        '(Android)', () async {
      block.store['acme.seed'] = seedB64;
      var fired = 0;
      final store = hookedStore(android: true, hook: () => fired++);
      expect(await store.load(sodium), isNotNull);
      expect(fired, 1);
    });

    test('load: does NOT fire when no tier has a seed', () async {
      var fired = 0;
      final store = hookedStore(android: true, hook: () => fired++);
      expect(await store.load(sodium), isNull);
      expect(fired, 0);
    });
  });

  group('clear / isCloudBackedUp', () {
    test('clear wipes every tier', () async {
      local.store['acme.seed'] = seedB64;
      cloud.store['acme.seed'] = seedB64;
      block.store['acme.seed'] = seedB64;
      await storeOn(android: true).clear();
      expect(local.store, isEmpty);
      expect(cloud.store, isEmpty);
      expect(block.store, isEmpty);
    });

    test('cloud delete failure still wipes the other tiers and throws '
        'IdentityClearIncomplete — a locked iCloud tier must not silently '
        'keep the seed alive', () async {
      local.store['acme.seed'] = seedB64;
      cloud.store['acme.seed'] = seedB64;
      block.store['acme.seed'] = seedB64;
      cloud.throwOnDelete = Exception('keychain locked');
      await expectLater(
        storeOn(android: true).clear(),
        throwsA(isA<IdentityClearIncomplete>()
            .having((e) => e.tiers, 'tiers', ['cloud'])),
      );
      expect(local.store, isEmpty);
      expect(block.store, isEmpty);
    });

    test('local delete failure does not short-circuit the cloud tiers',
        () async {
      local.store['acme.seed'] = seedB64;
      cloud.store['acme.seed'] = seedB64;
      block.store['acme.seed'] = seedB64;
      local.throwOnDelete = Exception('keystore bad state');
      await expectLater(
        storeOn(android: true).clear(),
        throwsA(isA<IdentityClearIncomplete>()
            .having((e) => e.tiers, 'tiers', ['local'])),
      );
      expect(cloud.store, isEmpty);
      expect(block.store, isEmpty);
    });

    test('Block Store false return counts as a failed tier', () async {
      block.store['acme.seed'] = seedB64;
      block.deleteResult = false;
      await expectLater(
        storeOn(android: true).clear(),
        throwsA(isA<IdentityClearIncomplete>()
            .having((e) => e.tiers, 'tiers', ['blockStore'])),
      );
    });

    test('collects every failed tier, and a retry after the failures resolve '
        'succeeds (deletes are idempotent)', () async {
      local.store['acme.seed'] = seedB64;
      cloud.store['acme.seed'] = seedB64;
      block.store['acme.seed'] = seedB64;
      local.throwOnDelete = Exception('a');
      cloud.throwOnDelete = Exception('b');
      block.deleteResult = false;
      final store = storeOn(android: true);
      await expectLater(
        store.clear(),
        throwsA(isA<IdentityClearIncomplete>()
            .having((e) => e.tiers, 'tiers', ['local', 'cloud', 'blockStore'])),
      );
      local.throwOnDelete = null;
      cloud.throwOnDelete = null;
      block.deleteResult = true;
      await store.clear();
      expect(local.store, isEmpty);
      expect(cloud.store, isEmpty);
      expect(block.store, isEmpty);
    });

    test('isCloudBackedUp consults Block Store on Android, iCloud otherwise',
        () async {
      block.store['acme.seed'] = seedB64;
      expect(await storeOn(android: true).isCloudBackedUp(), isTrue);
      expect(await storeOn(android: false).isCloudBackedUp(), isFalse);
      cloud.store['acme.seed'] = seedB64;
      expect(await storeOn(android: false).isCloudBackedUp(), isTrue);
    });

    test('isCloudBackedUp reports false (not throw) when iCloud read fails',
        () async {
      cloud.throwOnRead = Exception('icloud unavailable');
      expect(await storeOn(android: false).isCloudBackedUp(), isFalse);
    });
  });
}
