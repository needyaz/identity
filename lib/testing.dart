/// Test doubles for the storage layer `package:identity` sits on.
///
/// `FakeKvTier` now lives in `package:storage/testing.dart`; this re-export
/// keeps existing consumer imports working:
///
/// ```dart
/// import 'package:identity/testing.dart';
///
/// final local = FakeKvTier('local')..failAllReads = true;
/// final cloud = FakeKvTier('cloud')..store['k'] = 'v';
/// ```
library;

export 'package:storage/testing.dart';
