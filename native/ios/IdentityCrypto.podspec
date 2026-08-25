# CocoaPods view of the SAME sources IdentityCrypto/Package.swift tests.
# Consuming apps:
#   pod 'IdentityCrypto', :path => '../../../identity/native/ios'
# in every target that needs the native crypto — the Runner AND any
# notification service extension — alongside `pod 'libsodium'`, whose
# framework module supplies the C API here (`import libsodium`).
Pod::Spec.new do |s|
  s.name             = 'IdentityCrypto'
  s.version          = '1.0.0'
  s.summary          = 'Byte-identical native (Swift) mirror of the identity package\'s generic crypto primitives.'
  s.description      = 'DH shared secret, secretbox/box blobs and sealed boxes over libsodium, for native-only code paths (killed-state evaluators, notification service extensions). Pinned by the same crypto_vectors.json as the Dart and Kotlin halves.'
  s.homepage         = 'https://github.com/needyaz/identity'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Luci' => 'nate@eide.us' }
  s.source           = { :git => 'https://github.com/needyaz/identity.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.9'
  s.source_files     = 'IdentityCrypto/Sources/IdentityCrypto/**/*.swift'
  s.dependency 'libsodium', '~> 1.0'
end
