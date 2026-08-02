import Foundation
import Clibsodium

/// Cryptographic helpers for use outside the Dart/Flutter runtime (killed-state
/// evaluation, notification service extensions, and similar native-only paths).
/// Wire format: base64(nonce || ciphertext) — identical to the Dart crypto.dart helpers.
struct NativeCrypto {

  // MARK: – Box (asymmetric, watchee SK + watcher PK)

  /// Derive the X25519 shared key from our secret key and the watcher's public key.
  /// Returns nil if key lengths are wrong.
  static func deriveSharedKey(sk: [UInt8], pk: [UInt8]) -> [UInt8]? {
    guard sk.count == Int(crypto_box_secretkeybytes()),
          pk.count == Int(crypto_box_publickeybytes()) else { return nil }
    var shared = [UInt8](repeating: 0, count: Int(crypto_box_beforenmbytes()))
    let rc = sk.withUnsafeBufferPointer { skBuf in
      pk.withUnsafeBufferPointer { pkBuf in
        crypto_box_beforenm(&shared, pkBuf.baseAddress!, skBuf.baseAddress!)
      }
    }
    return rc == 0 ? shared : nil
  }

  /// Encrypt JSON-serialisable [payload] as base64(nonce || box-ciphertext).
  /// Returns nil on any failure.
  static func encryptBox(payload: [String: Any], sharedKey: [UInt8]) -> String? {
    guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
    let nonceLen = Int(crypto_box_noncebytes())
    let macLen   = Int(crypto_box_macbytes())
    var nonce    = [UInt8](repeating: 0, count: nonceLen)
    randombytes_buf(&nonce, nonceLen)

    let plaintext = Array(json)
    var ciphertext = [UInt8](repeating: 0, count: plaintext.count + macLen)

    let rc = nonce.withUnsafeBufferPointer { nPtr in
      plaintext.withUnsafeBufferPointer { pPtr in
        sharedKey.withUnsafeBufferPointer { kPtr in
          crypto_box_easy_afternm(
            &ciphertext,
            pPtr.baseAddress!, UInt64(plaintext.count),
            nPtr.baseAddress!,
            kPtr.baseAddress!
          )
        }
      }
    }
    guard rc == 0 else { return nil }

    let combined = Data(nonce) + Data(ciphertext)
    return combined.base64EncodedString()
  }

  // MARK: – SecretBox (symmetric, group key)

  /// Encrypt a location payload as base64(nonce || secretbox-ciphertext).
  static func encryptSecretBox(payload: [String: Any], key: [UInt8]) -> String? {
    guard key.count == Int(crypto_secretbox_keybytes()),
          let json = try? JSONSerialization.data(withJSONObject: payload)
    else { return nil }

    let nonceLen = Int(crypto_secretbox_noncebytes())
    let macLen   = Int(crypto_secretbox_macbytes())
    var nonce    = [UInt8](repeating: 0, count: nonceLen)
    randombytes_buf(&nonce, nonceLen)

    let plaintext  = Array(json)
    var ciphertext = [UInt8](repeating: 0, count: plaintext.count + macLen)

    let rc = nonce.withUnsafeBufferPointer { nPtr in
      plaintext.withUnsafeBufferPointer { pPtr in
        key.withUnsafeBufferPointer { kPtr in
          crypto_secretbox_easy(
            &ciphertext,
            pPtr.baseAddress!, UInt64(plaintext.count),
            nPtr.baseAddress!,
            kPtr.baseAddress!
          )
        }
      }
    }
    guard rc == 0 else { return nil }

    let combined = Data(nonce) + Data(ciphertext)
    return combined.base64EncodedString()
  }

  // MARK: – Box decryption

  static func decryptBox(base64Ciphertext: String, sharedKey: [UInt8]) -> Data? {
    guard let combined = Data(base64Encoded: base64Ciphertext) else { return nil }
    let nonceLen = Int(crypto_box_noncebytes())
    let macLen   = Int(crypto_box_macbytes())
    guard combined.count > nonceLen + macLen else { return nil }
    let nonce      = Array(combined.prefix(nonceLen))
    let ciphertext = Array(combined.dropFirst(nonceLen))
    let plainLen   = ciphertext.count - macLen
    var plaintext  = [UInt8](repeating: 0, count: plainLen)
    let rc = nonce.withUnsafeBufferPointer { nPtr in
      ciphertext.withUnsafeBufferPointer { cPtr in
        sharedKey.withUnsafeBufferPointer { kPtr in
          crypto_box_open_easy_afternm(
            &plaintext,
            cPtr.baseAddress!, UInt64(ciphertext.count),
            nPtr.baseAddress!,
            kPtr.baseAddress!
          )
        }
      }
    }
    return rc == 0 ? Data(plaintext) : nil
  }

  // MARK: – SecretBox decryption

  static func decryptSecretBox(base64Ciphertext: String, key: [UInt8]) -> Data? {
    guard key.count == Int(crypto_secretbox_keybytes()),
          let combined = Data(base64Encoded: base64Ciphertext) else { return nil }
    let nonceLen = Int(crypto_secretbox_noncebytes())
    let macLen   = Int(crypto_secretbox_macbytes())
    guard combined.count > nonceLen + macLen else { return nil }
    let nonce      = Array(combined.prefix(nonceLen))
    let ciphertext = Array(combined.dropFirst(nonceLen))
    let plainLen   = ciphertext.count - macLen
    var plaintext  = [UInt8](repeating: 0, count: plainLen)
    let rc = nonce.withUnsafeBufferPointer { nPtr in
      ciphertext.withUnsafeBufferPointer { cPtr in
        key.withUnsafeBufferPointer { kPtr in
          crypto_secretbox_open_easy(
            &plaintext,
            cPtr.baseAddress!, UInt64(ciphertext.count),
            nPtr.baseAddress!,
            kPtr.baseAddress!
          )
        }
      }
    }
    return rc == 0 ? Data(plaintext) : nil
  }

  // MARK: – Sealed box (anonymous box — joiner's display name)

  /// Decrypt a `crypto_box_seal` ciphertext using the recipient's keypair.
  /// Returns the UTF-8 plaintext string, or nil on any failure.
  static func sealOpen(base64Ciphertext: String,
                       recipientPk: [UInt8],
                       recipientSk: [UInt8]) -> String? {
    guard recipientPk.count == Int(crypto_box_publickeybytes()),
          recipientSk.count == Int(crypto_box_secretkeybytes()),
          let ct = Data(base64Encoded: base64Ciphertext)
    else { return nil }
    let sealLen = Int(crypto_box_sealbytes())
    guard ct.count > sealLen else { return nil }

    let plainLen = ct.count - sealLen
    var plain    = [UInt8](repeating: 0, count: plainLen)
    let ctBytes  = Array(ct)

    let rc = ctBytes.withUnsafeBufferPointer { cPtr in
      recipientPk.withUnsafeBufferPointer { pkPtr in
        recipientSk.withUnsafeBufferPointer { skPtr in
          crypto_box_seal_open(
            &plain,
            cPtr.baseAddress!, UInt64(ctBytes.count),
            pkPtr.baseAddress!,
            skPtr.baseAddress!
          )
        }
      }
    }
    guard rc == 0 else { return nil }
    return String(data: Data(plain), encoding: .utf8)
  }

  // MARK: – Key generation

  static func generateBoxKeypair() -> (pk: [UInt8], sk: [UInt8]) {
    var pk = [UInt8](repeating: 0, count: Int(crypto_box_publickeybytes()))
    var sk = [UInt8](repeating: 0, count: Int(crypto_box_secretkeybytes()))
    crypto_box_keypair(&pk, &sk)
    return (pk, sk)
  }

  static func randomSecretBoxKey() -> [UInt8] {
    var key = [UInt8](repeating: 0, count: Int(crypto_secretbox_keybytes()))
    // Use libsodium's RNG (same as the nonce paths) rather than
    // SecRandomCopyBytes: the previous call ignored its OSStatus, so an RNG
    // failure would have silently returned an all-zero key. randombytes_buf
    // cannot partially fail — it fills the buffer or aborts.
    randombytes_buf(&key, key.count)
    return key
  }
}
