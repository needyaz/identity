# The same checks CI runs (.github/workflows/ci.yml), as make targets.
.PHONY: analyze test test-native test-swift test-android

## dart analyze
analyze:
	dart pub get
	dart analyze

## dart test, then re-derive the SPEC.md vectors independently (needs libsodium and python3 cryptography, as in CI)
test:
	dart pub get
	dart test
	python3 -c "import cryptography" 2>/dev/null || python3 -m pip install --user --quiet cryptography
	python3 tools/verify_vectors.py

## The native mirrors: LANES picks which (default both)
LANES ?= test-swift test-android
test-native:
	@for l in $(LANES); do $(MAKE) --no-print-directory $$l || exit 1; done

## Swift mirror (macOS)
test-swift:
	cd native/ios/IdentityCrypto && swift test

## Android mirror on an emulator
test-android:
	@serial="$$(bash tool/android_device.sh)" && cd native/android && ANDROID_SERIAL="$$serial" ./gradlew :crypto:connectedDebugAndroidTest
