/// Test doubles for `package:identity`'s storage layer.
///
/// Import this (not `package:identity/identity.dart`) from test code that
/// needs to fault-inject storage tiers:
///
/// ```dart
/// import 'package:identity/testing.dart';
///
/// final local = FakeKvTier('local')..failAllReads = true;
/// final cloud = FakeKvTier('cloud')..store['k'] = 'v';
/// ```
library;

export 'src/fake_kv_tier.dart';
