/// BlockStoreClient behavior against a mocked MethodChannel: non-Android
/// no-ops, happy paths, error swallowing, and the delete retry-on-timeout.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:identity/identity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/blockstore');

  void mockHandler(Future<Object?>? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  tearDown(() => mockHandler((_) => null));

  group('non-Android no-ops (no platform call is made)', () {
    test('get → null, put → false, delete → true', () async {
      var called = false;
      mockHandler((call) async {
        called = true;
        return null;
      });
      final client = BlockStoreClient('test/blockstore', isAndroid: false);
      expect(await client.get('k'), isNull);
      expect(await client.put('k', 'v'), isFalse);
      expect(await client.delete('k'), isTrue);
      expect(called, isFalse);
    });
  });

  group('channel round-trips (isAndroid: true)', () {
    test('get returns the stored value and passes the key', () async {
      mockHandler((call) async {
        expect(call.method, 'get');
        expect(call.arguments, {'key': 'acme.seed'});
        return 'seed-b64';
      });
      final client = BlockStoreClient('test/blockstore', isAndroid: true);
      expect(await client.get('acme.seed'), 'seed-b64');
    });

    test('put passes key+value and returns the handler result', () async {
      mockHandler((call) async {
        expect(call.method, 'put');
        expect(call.arguments, {'key': 'k', 'value': 'v'});
        return true;
      });
      final client = BlockStoreClient('test/blockstore', isAndroid: true);
      expect(await client.put('k', 'v'), isTrue);
    });

    test('errors are swallowed: get → null, put → false, delete → false',
        () async {
      mockHandler((call) async => throw PlatformException(code: 'UNAVAILABLE'));
      final client = BlockStoreClient('test/blockstore', isAndroid: true);
      expect(await client.get('k'), isNull);
      expect(await client.put('k', 'v'), isFalse);
      expect(await client.delete('k'), isFalse);
    });

    test('missing native handler (null response) is handled', () async {
      // No mock handler registered at all → MissingPluginException path.
      final client = BlockStoreClient('absent/channel', isAndroid: true);
      expect(await client.get('k'), isNull);
      expect(await client.put('k', 'v'), isFalse);
    });
  });

  group('the tier reads strictly — failure is UNAVAILABLE, never absent', () {
    BlockStoreTier tier() => BlockStoreTier(
          BlockStoreClient('test/blockstore',
              isAndroid: true, timeout: const Duration(milliseconds: 50)),
          available: true,
        );

    test('a platform error propagates out of read/containsKey', () async {
      // Collapsing this to null read as "confirmed absent" — which lets a
      // fresh mint's write fan-out overwrite the REAL seed this tier holds
      // (the exact clobber class the tri-state exists to prevent).
      mockHandler((call) async => throw PlatformException(code: 'UNAVAILABLE'));
      await expectLater(tier().read('k'), throwsA(isA<PlatformException>()));
      await expectLater(
          tier().containsKey('k'), throwsA(isA<PlatformException>()));
    });

    test('a hung task times out to a THROW', () async {
      mockHandler((call) => Completer<Object?>().future);
      await expectLater(tier().read('k'), throwsA(isA<TimeoutException>()));
    });

    test('a clean null success is still a clean miss', () async {
      mockHandler((call) async => null);
      expect(await tier().read('k'), isNull);
      expect(await tier().containsKey('k'), isFalse);
    });

    test('the lenient get() keeps its legacy swallow (Mylo compat)', () async {
      mockHandler((call) async => throw PlatformException(code: 'UNAVAILABLE'));
      final client = BlockStoreClient('test/blockstore', isAndroid: true);
      expect(await client.get('k'), isNull);
    });
  });

  group('delete retry-on-timeout', () {
    test('retries once when the platform call hangs, then returns false',
        () async {
      var attempts = 0;
      mockHandler((call) {
        attempts++;
        return Completer<Object?>().future; // never completes → timeout fires
      });
      final client = BlockStoreClient(
        'test/blockstore',
        isAndroid: true,
        timeout: const Duration(milliseconds: 50),
      );
      expect(await client.delete('k'), isFalse);
      expect(attempts, 2);
    });

    test('first attempt times out, second succeeds', () async {
      var attempts = 0;
      mockHandler((call) {
        attempts++;
        if (attempts == 1) return Completer<Object?>().future;
        return Future<Object?>.value(true);
      });
      final client = BlockStoreClient(
        'test/blockstore',
        isAndroid: true,
        timeout: const Duration(milliseconds: 50),
      );
      expect(await client.delete('k'), isTrue);
      expect(attempts, 2);
    });
  });
}
