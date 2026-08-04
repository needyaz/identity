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
