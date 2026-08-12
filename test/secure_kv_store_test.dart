/// SecureKvStore tier orchestration + tri-state semantics, exercised with the
/// package's own exported fault-injecting fake (`package:identity/testing.dart`).
/// The invariants under test are the load-bearing ones: `Absent` only when
/// every available tier read cleanly, `Unavailable` never collapses into
/// `Absent` (including decode failures), promote/migrate/mirror behavior,
/// and per-tier delete failure surfacing.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:identity/identity.dart';
import 'package:identity/testing.dart';

void main() {
  SecureKvStore storeWith(
    List<KvTier> tiers, {
    bool promoteOnRead = true,
    Set<String> noPromoteTiers = const {},
    List<String>? writeTiers,
    Duration? retryDelay,
    Set<String> retryTiers = const {},
  }) =>
      SecureKvStore(TierPolicy(
        tiers: tiers,
        promoteOnRead: promoteOnRead,
        noPromoteTiers: noPromoteTiers,
        writeTiers: writeTiers,
        retryDelay: retryDelay,
        retryTiers: retryTiers,
      ));

  group('read tri-state', () {
    test('Absent only when every available tier read cleanly and none held '
        'the key', () async {
      final a = FakeKvTier('a');
      final b = FakeKvTier('b');
      expect(await storeWith([a, b]).read('k'), isA<Absent<String>>());
    });

    test('Unavailable when a tier throws and no tier produced a value — '
        'carries the FIRST failure', () async {
      final first = Exception('a boom');
      final a = FakeKvTier('a')..readFaults['k'] = first;
      final b = FakeKvTier('b')..readFaults['k'] = Exception('b boom');
      final result = await storeWith([a, b]).read('k');
      expect(
        result,
        isA<Unavailable<String>>()
            .having((r) => r.cause, 'cause', same(first)),
      );
    });

    test('Present when a later tier hits despite an earlier tier throwing',
        () async {
      final a = FakeKvTier('a')..readFaults['k'] = Exception('locked');
      final b = FakeKvTier('b')..store['k'] = 'v';
      final result = await storeWith([a, b], promoteOnRead: false).read('k');
      expect(
        result,
        isA<Present<String>>()
            .having((r) => r.value, 'value', 'v')
            .having((r) => r.tier, 'tier', 'b'),
      );
    });

    test('Present from an earlier tier never consults later (failing) tiers',
        () async {
      final a = FakeKvTier('a')..store['k'] = 'v';
      final b = FakeKvTier('b')..failAllReads = true;
      final result = await storeWith([a, b]).read('k');
      expect(result, isA<Present<String>>());
      expect(b.readCount('k'), 0);
    });

    test('unavailable (platform-armed-off) tier is skipped entirely — '
        'never read, never counted as a failure', () async {
      final off = FakeKvTier('off', available: false)..failAllReads = true;
      final on = FakeKvTier('on');
      expect(await storeWith([off, on]).read('k'), isA<Absent<String>>());
      expect(off.readCount('k'), 0);
    });

    test('default fault is a realistic locked-Keychain PlatformException',
        () async {
      final a = FakeKvTier('a')..failAllReads = true;
      final result = await storeWith([a]).read('k');
      expect(
        result,
        isA<Unavailable<String>>().having(
            (r) => r.cause.toString(), 'cause', contains('-25308')),
      );
    });

    test('valueOr forces a named fallback', () async {
      expect(const Present<String>('v').valueOr('f'), 'v');
      expect(const Absent<String>().valueOr('f'), 'f');
      expect(Unavailable<String>(Exception('x')).valueOr('f'), 'f');
    });
  });

  group('promote-on-read', () {
    test('a non-primary hit is written back to the primary; a writable '
        'source keeps its copy', () async {
      final primary = FakeKvTier('primary');
      final cloud = FakeKvTier('cloud')..store['k'] = 'v';
      final result = await storeWith([primary, cloud]).read('k');
      expect(result, isA<Present<String>>().having((r) => r.tier, 'tier', 'cloud'));
      expect(primary.store['k'], 'v');
      expect(cloud.store['k'], 'v', reason: 'cloud is writable, not migration');
    });

    test('promote-write failure is non-fatal — the read still returns Present',
        () async {
      final primary = FakeKvTier('primary')..failAllWrites = true;
      final cloud = FakeKvTier('cloud')..store['k'] = 'v';
      final result = await storeWith([primary, cloud]).read('k');
      expect(result, isA<Present<String>>().having((r) => r.value, 'value', 'v'));
      expect(primary.store, isEmpty);
    });

    test('promoteOnRead: false leaves the primary untouched', () async {
      final primary = FakeKvTier('primary');
      final cloud = FakeKvTier('cloud')..store['k'] = 'v';
      await storeWith([primary, cloud], promoteOnRead: false).read('k');
      expect(primary.store, isEmpty);
    });

    test('noPromoteTiers opts a single tier out: its hit is served but never '
        'written back as authoritative', () async {
      final primary = FakeKvTier('primary');
      final cloud = FakeKvTier('cloud')..store['k'] = 'cloud-v';
      final legacy = FakeKvTier('legacy', writable: false)..store['k2'] = 'v2';
      final store = storeWith([primary, cloud, legacy],
          noPromoteTiers: {'cloud'});

      final hit = await store.read('k');
      expect(hit, isA<Present<String>>().having((r) => r.value, 'value', 'cloud-v'));
      expect(primary.store, isEmpty, reason: 'cloud hit must not be promoted');

      // Other tiers still promote (and migrate) normally.
      await store.read('k2');
      expect(primary.store['k2'], 'v2');
      expect(legacy.store, isEmpty);
    });

    test('a noPromoteTiers migration tier keeps its copy (no promote → no '
        'legacy delete)', () async {
      final primary = FakeKvTier('primary');
      final legacy = FakeKvTier('legacy', writable: false)..store['k'] = 'v';
      await storeWith([primary, legacy], noPromoteTiers: {'legacy'}).read('k');
      expect(primary.store, isEmpty);
      expect(legacy.store['k'], 'v');
    });
  });

  group('migration-only tiers', () {
    test('read → promote to primary → delete from legacy', () async {
      final primary = FakeKvTier('primary');
      final legacy = FakeKvTier('legacy', writable: false)..store['k'] = 'v';
      final result = await storeWith([primary, legacy]).read('k');
      expect(result, isA<Present<String>>().having((r) => r.value, 'value', 'v'));
      expect(primary.store['k'], 'v');
      expect(legacy.store, isEmpty, reason: 'legacy copy retired after promote');
    });

    test('legacy copy survives when the promote-write failed', () async {
      final primary = FakeKvTier('primary')..failAllWrites = true;
      final legacy = FakeKvTier('legacy', writable: false)..store['k'] = 'v';
      await storeWith([primary, legacy]).read('k');
      expect(legacy.store['k'], 'v',
          reason: 'never delete the only remaining copy');
    });

    test('legacy delete failure is non-fatal', () async {
      final primary = FakeKvTier('primary');
      final legacy = FakeKvTier('legacy', writable: false)
        ..store['k'] = 'v'
        ..failAllDeletes = true;
      final result = await storeWith([primary, legacy]).read('k');
      expect(result, isA<Present<String>>());
      expect(primary.store['k'], 'v');
    });

    test('write() never writes a migration tier', () async {
      final primary = FakeKvTier('primary');
      final legacy = FakeKvTier('legacy', writable: false);
      await storeWith([primary, legacy]).write('k', 'v');
      expect(primary.store['k'], 'v');
      expect(legacy.store, isEmpty);
    });
  });

  group('cloud sync-lag retry', () {
    test('a retryTiers tier empty on first read is re-read once after '
        'retryDelay', () async {
      final local = FakeKvTier('local');
      final cloud = FakeKvTier('cloud')..readQueues['k'] = [null, 'v'];
      final store = storeWith([local, cloud],
          retryDelay: Duration.zero, retryTiers: {'cloud'});
      final result = await store.read('k');
      expect(result, isA<Present<String>>().having((r) => r.value, 'value', 'v'));
      expect(cloud.readCount('k'), 2);
      expect(local.store['k'], 'v', reason: 'retry hit still promotes');
    });

    test('retry fires only for tiers named in retryTiers', () async {
      final local = FakeKvTier('local')..readQueues['k'] = [null, 'v'];
      final cloud = FakeKvTier('cloud')..readQueues['k'] = [null, 'v'];
      final store = storeWith([local, cloud],
          retryDelay: Duration.zero, retryTiers: {'cloud'});
      await store.read('k');
      expect(local.readCount('k'), 1, reason: 'local is not retried');
      expect(cloud.readCount('k'), 2);
    });

    test('retry fires once, not more', () async {
      final cloud = FakeKvTier('cloud')..readQueues['k'] = [null, null, 'v'];
      final store =
          storeWith([cloud], retryDelay: Duration.zero, retryTiers: {'cloud'});
      expect(await store.read('k'), isA<Absent<String>>());
      expect(cloud.readCount('k'), 2);
    });

    test('retry also fires after a failed first read (not just a miss)',
        () async {
      final cloud = FakeKvTier('cloud')..readFaults['k'] = Exception('lag');
      final store =
          storeWith([cloud], retryDelay: Duration.zero, retryTiers: {'cloud'});
      expect(await store.read('k'), isA<Unavailable<String>>());
      expect(cloud.readCount('k'), 2);
    });

    test('no retryDelay configured → single read even for retryTiers',
        () async {
      final cloud = FakeKvTier('cloud')..readQueues['k'] = [null, 'v'];
      final store = storeWith([cloud], retryTiers: {'cloud'});
      expect(await store.read('k'), isA<Absent<String>>());
      expect(cloud.readCount('k'), 1);
    });
  });

  group('containsKey', () {
    test('Present(true) via a later tier despite an earlier failure',
        () async {
      final a = FakeKvTier('a')..failAllReads = true;
      final b = FakeKvTier('b')..store['k'] = 'v';
      final result = await storeWith([a, b]).containsKey('k');
      expect(result, isA<Present<bool>>().having((r) => r.value, 'value', true));
    });

    test('Present(false) when every available tier was readable and absent',
        () async {
      final a = FakeKvTier('a');
      final b = FakeKvTier('b', available: false)..failAllReads = true;
      final result = await storeWith([a, b]).containsKey('k');
      expect(
          result, isA<Present<bool>>().having((r) => r.value, 'value', false));
    });

    test('Unavailable when a tier throws and none confirms — never collapses '
        'to false', () async {
      final first = Exception('boom');
      final a = FakeKvTier('a')..readFaults['k'] = first;
      final b = FakeKvTier('b');
      final result = await storeWith([a, b]).containsKey('k');
      expect(
        result,
        isA<Unavailable<bool>>().having((r) => r.cause, 'cause', same(first)),
      );
    });
  });

  group('write fan-out', () {
    test('writes the primary plus every writable available mirror', () async {
      final a = FakeKvTier('a');
      final b = FakeKvTier('b');
      final c = FakeKvTier('c');
      await storeWith([a, b, c]).write('k', 'v');
      expect(a.store['k'], 'v');
      expect(b.store['k'], 'v');
      expect(c.store['k'], 'v');
    });

    test('primary failure rethrows the original exception and skips mirrors',
        () async {
      final boom = Exception('keystore bad state');
      final a = FakeKvTier('a')..writeFaults['k'] = boom;
      final b = FakeKvTier('b');
      await expectLater(
          storeWith([a, b]).write('k', 'v'), throwsA(same(boom)));
      expect(b.store, isEmpty);
    });

    test('mirror failure is best-effort — the write still succeeds', () async {
      final a = FakeKvTier('a');
      final b = FakeKvTier('b')..failAllWrites = true;
      final c = FakeKvTier('c');
      await storeWith([a, b, c]).write('k', 'v');
      expect(a.store['k'], 'v');
      expect(c.store['k'], 'v');
    });

    test('onPrimaryWrite fires after the primary commit, before the mirrors',
        () async {
      final a = FakeKvTier('a');
      final b = FakeKvTier('b');
      String? aAtFire, bAtFire;
      await storeWith([a, b]).write('k', 'v', onPrimaryWrite: () {
        aAtFire = a.store['k'];
        bAtFire = b.store['k'];
      });
      expect(aAtFire, 'v');
      expect(bAtFire, isNull);
    });

    test('onPrimaryWrite does not fire when the primary write fails',
        () async {
      final a = FakeKvTier('a')..failAllWrites = true;
      var fired = 0;
      await expectLater(
          storeWith([a]).write('k', 'v', onPrimaryWrite: () => fired++),
          throwsA(anything));
      expect(fired, 0);
    });

    test('unavailable mirror tier is skipped', () async {
      final a = FakeKvTier('a');
      final b = FakeKvTier('b', available: false);
      await storeWith([a, b]).write('k', 'v');
      expect(b.store, isEmpty);
    });

    test('explicit writeTiers restricts and orders the write chain',
        () async {
      final a = FakeKvTier('a');
      final b = FakeKvTier('b');
      final c = FakeKvTier('c');
      await storeWith([a, b, c], writeTiers: ['c', 'a']).write('k', 'v');
      expect(a.store['k'], 'v');
      expect(b.store, isEmpty);
      expect(c.store['k'], 'v');
    });
  });

  group('mirror (backfill)', () {
    test('check-then-writes every non-primary writable tier', () async {
      final a = FakeKvTier('a')..store['k'] = 'v';
      final b = FakeKvTier('b');
      final c = FakeKvTier('c')..store['k'] = 'already-there';
      await storeWith([a, b, c]).mirror('k', 'v');
      expect(b.store['k'], 'v');
      expect(c.store['k'], 'already-there',
          reason: 'an existing copy is never overwritten');
    });

    test('per-tier failures are non-fatal and do not stop later tiers',
        () async {
      final a = FakeKvTier('a')..store['k'] = 'v';
      final b = FakeKvTier('b')..failAllWrites = true;
      final c = FakeKvTier('c');
      await storeWith([a, b, c]).mirror('k', 'v');
      expect(c.store['k'], 'v');
    });
  });

  group('delete', () {
    test('attempts every tier, collects failures in tier order, wipes the '
        'rest', () async {
      final a = FakeKvTier('a')..store['k'] = 'v';
      final bBoom = Exception('locked');
      final b = FakeKvTier('b')
        ..store['k'] = 'v'
        ..deleteFaults['k'] = bBoom;
      final c = FakeKvTier('c')
        ..store['k'] = 'v'
        ..failAllDeletes = true;
      await expectLater(
        storeWith([a, b, c]).delete('k'),
        throwsA(isA<KvDeleteIncomplete>()
            .having((e) => e.tiers, 'tiers', ['b', 'c'])
            .having((e) => e.causes['b'], 'causes[b]', same(bBoom))),
      );
      expect(a.store, isEmpty);
      expect(b.store['k'], 'v');
    });

    test('unavailable tier is skipped, not counted as a failure', () async {
      final a = FakeKvTier('a')..store['k'] = 'v';
      final b = FakeKvTier('b', available: false)..failAllDeletes = true;
      await storeWith([a, b]).delete('k');
      expect(a.store, isEmpty);
    });

    test('read-only migration tiers are deleted too', () async {
      final a = FakeKvTier('a')..store['k'] = 'v';
      final legacy = FakeKvTier('legacy', writable: false)..store['k'] = 'v';
      await storeWith([a, legacy]).delete('k');
      expect(legacy.store, isEmpty);
    });
  });

  group('readAll', () {
    test('merges enumerable tiers, earlier tiers winning per key', () async {
      final a = FakeKvTier('a')..store.addAll({'k1': 'a1', 'k2': 'a2'});
      final b = FakeKvTier('b')..store.addAll({'k2': 'b2', 'k3': 'b3'});
      final result = await storeWith([a, b]).readAll();
      expect(
        result,
        isA<Present<Map<String, String>>>().having((r) => r.value, 'value',
            {'k1': 'a1', 'k2': 'a2', 'k3': 'b3'}),
      );
    });

    test('ANY tier failure yields Unavailable even when other tiers read '
        'fine — a partial map is per-key absence-as-fact', () async {
      final a = FakeKvTier('a')..store['k1'] = 'v1';
      final b = FakeKvTier('b')..failAllReads = true;
      expect(await storeWith([a, b]).readAll(),
          isA<Unavailable<Map<String, String>>>());
    });

    test('non-enumerable tiers are skipped without counting as a failure',
        () async {
      final a = FakeKvTier('a')..store['k1'] = 'v1';
      final blocky = FakeKvTier('blocky', enumerable: false)
        ..store['hidden'] = 'x';
      final result = await storeWith([a, blocky]).readAll();
      expect(
        result,
        isA<Present<Map<String, String>>>()
            .having((r) => r.value, 'value', {'k1': 'v1'}),
      );
    });

    test('Absent when the merged map is empty', () async {
      expect(await storeWith([FakeKvTier('a')]).readAll(),
          isA<Absent<Map<String, String>>>());
    });
  });

  group('typed views', () {
    final listKey = TypedKey<List<String>>(
      'list',
      encode: jsonEncode,
      decode: (s) => (jsonDecode(s) as List<dynamic>).cast<String>(),
    );

    test('writeTyped / readTyped round-trip', () async {
      final a = FakeKvTier('a');
      final store = storeWith([a]);
      await store.writeTyped(listKey, ['x', 'y']);
      final result = await store.readTyped(listKey);
      expect(result,
          isA<Present<List<String>>>().having((r) => r.value, 'value', ['x', 'y']));
    });

    test('decode failure maps to Unavailable, NEVER Absent — a corrupt blob '
        'is "couldn\'t read", not "no data"', () async {
      final a = FakeKvTier('a')..store['list'] = 'not json {{{';
      final result = await storeWith([a]).readTyped(listKey);
      expect(result, isA<Unavailable<List<String>>>());
      expect(result, isNot(isA<Absent<List<String>>>()));
    });

    test('Absent and Unavailable pass through readTyped unchanged', () async {
      final clean = FakeKvTier('a');
      expect(await storeWith([clean]).readTyped(listKey),
          isA<Absent<List<String>>>());

      final broken = FakeKvTier('a')..readFaults['list'] = Exception('boom');
      expect(await storeWith([broken]).readTyped(listKey),
          isA<Unavailable<List<String>>>());
    });
  });

  group('policy validation', () {
    test('writeTiers naming an unknown tier throws ArgumentError', () async {
      final store = storeWith([FakeKvTier('a')], writeTiers: ['nope']);
      await expectLater(store.write('k', 'v'), throwsArgumentError);
    });

    test('write with no writable tier throws StateError', () async {
      final store = storeWith([FakeKvTier('a', writable: false)]);
      await expectLater(store.write('k', 'v'), throwsStateError);
    });

    test('write with an unavailable primary throws StateError', () async {
      final store = storeWith([FakeKvTier('a', available: false)]);
      await expectLater(store.write('k', 'v'), throwsStateError);
    });
  });
}
