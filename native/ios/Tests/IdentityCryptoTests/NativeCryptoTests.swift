import XCTest
@testable import IdentityCrypto

// NativeCrypto — encrypt / decrypt round-trips
// Ported verbatim from Mylo's ios/RunnerTests/RunnerTests.swift NativeCryptoTests.

final class NativeCryptoTests: XCTestCase {

    // MARK: – deriveSharedKey

    func testDeriveSharedKeyWrongLengthReturnsNil() {
        XCTAssertNil(NativeCrypto.deriveSharedKey(sk: [1, 2, 3], pk: [4, 5, 6]))
    }

    func testDeriveSharedKeySucceedsWithValidKeypair() {
        let (pk, sk) = NativeCrypto.generateBoxKeypair()
        XCTAssertNotNil(NativeCrypto.deriveSharedKey(sk: sk, pk: pk))
    }

    func testDeriveSharedKeyIsSymmetric() {
        // X25519(sk_a, pk_b) == X25519(sk_b, pk_a) — the Diffie-Hellman property
        let (pkA, skA) = NativeCrypto.generateBoxKeypair()
        let (pkB, skB) = NativeCrypto.generateBoxKeypair()
        let sharedAB = NativeCrypto.deriveSharedKey(sk: skA, pk: pkB)!
        let sharedBA = NativeCrypto.deriveSharedKey(sk: skB, pk: pkA)!
        XCTAssertEqual(sharedAB, sharedBA, "shared keys must be equal for both sides")
    }

    // MARK: – encryptBox / decryptBox round-trip

    func testBoxEncryptDecryptRoundTrip() {
        let (pkA, skA) = NativeCrypto.generateBoxKeypair()
        let (pkB, skB) = NativeCrypto.generateBoxKeypair()
        let sharedEnc = NativeCrypto.deriveSharedKey(sk: skA, pk: pkB)!
        let sharedDec = NativeCrypto.deriveSharedKey(sk: skB, pk: pkA)!

        let payload: [String: Any] = ["title": "Alice", "body": "Arrived at Home", "group_id": "g1"]
        let encrypted = NativeCrypto.encryptBox(payload: payload, sharedKey: sharedEnc)!
        let plainData = NativeCrypto.decryptBox(base64Ciphertext: encrypted, sharedKey: sharedDec)!

        let json = try! JSONSerialization.jsonObject(with: plainData) as! [String: Any]
        XCTAssertEqual("Alice",           json["title"]    as? String)
        XCTAssertEqual("Arrived at Home", json["body"]     as? String)
        XCTAssertEqual("g1",              json["group_id"] as? String)
    }

    func testBoxEncryptDecryptSameKeyRoundTrip() {
        // When encrypting to self (same keypair), sharedKey is the same on both sides
        let (pk, sk) = NativeCrypto.generateBoxKeypair()
        let shared = NativeCrypto.deriveSharedKey(sk: sk, pk: pk)!

        let payload: [String: Any] = ["x": 42]
        let encrypted = NativeCrypto.encryptBox(payload: payload, sharedKey: shared)!
        let plainData = NativeCrypto.decryptBox(base64Ciphertext: encrypted, sharedKey: shared)!

        let json = try! JSONSerialization.jsonObject(with: plainData) as! [String: Any]
        XCTAssertEqual(42, (json["x"] as! NSNumber).intValue)
    }

    func testEncryptBoxWireFormatIsBase64NonceCiphertext() {
        // Wire format: base64(24-byte nonce || 16-byte mac || plaintext)
        let (pk, sk) = NativeCrypto.generateBoxKeypair()
        let shared = NativeCrypto.deriveSharedKey(sk: sk, pk: pk)!
        let encrypted = NativeCrypto.encryptBox(payload: ["k": "v"], sharedKey: shared)!
        let data = Data(base64Encoded: encrypted)!
        // minimum size: nonce(24) + mac(16) + at least 1 byte plaintext
        XCTAssertGreaterThan(data.count, 24 + 16, "must be nonce(24) + mac(16) + plaintext")
    }

    func testDecryptBoxInvalidCiphertextReturnsNil() {
        let (pk, sk) = NativeCrypto.generateBoxKeypair()
        let shared = NativeCrypto.deriveSharedKey(sk: sk, pk: pk)!
        let garbage = Data(repeating: 0xFF, count: 100).base64EncodedString()
        XCTAssertNil(NativeCrypto.decryptBox(base64Ciphertext: garbage, sharedKey: shared))
    }

    func testDecryptBoxTooShortReturnsNil() {
        let (pk, sk) = NativeCrypto.generateBoxKeypair()
        let shared = NativeCrypto.deriveSharedKey(sk: sk, pk: pk)!
        let tooShort = Data(repeating: 0, count: 4).base64EncodedString()
        XCTAssertNil(NativeCrypto.decryptBox(base64Ciphertext: tooShort, sharedKey: shared))
    }

    func testDecryptBoxWrongKeyReturnsNil() {
        let (pkA, skA) = NativeCrypto.generateBoxKeypair()
        let (pkB, _)   = NativeCrypto.generateBoxKeypair()
        let (_, skC)   = NativeCrypto.generateBoxKeypair()
        let sharedEnc = NativeCrypto.deriveSharedKey(sk: skA, pk: pkB)!
        let sharedWrong = NativeCrypto.deriveSharedKey(sk: skC, pk: pkB)!

        let encrypted = NativeCrypto.encryptBox(payload: ["x": 1], sharedKey: sharedEnc)!
        XCTAssertNil(NativeCrypto.decryptBox(base64Ciphertext: encrypted, sharedKey: sharedWrong))
    }

    // MARK: – encryptSecretBox / decryptSecretBox round-trip

    func testSecretBoxEncryptDecryptRoundTrip() {
        let key = NativeCrypto.randomSecretBoxKey()
        let payload: [String: Any] = ["lat": 37.7749, "lng": -122.4194, "accuracy": 5.0, "timestamp": 1_700_000_000]
        let encrypted = NativeCrypto.encryptSecretBox(payload: payload, key: key)!
        let plainData = NativeCrypto.decryptSecretBox(base64Ciphertext: encrypted, key: key)!

        let json = try! JSONSerialization.jsonObject(with: plainData) as! [String: Any]
        XCTAssertEqual(37.7749,    (json["lat"]      as! NSNumber).doubleValue, accuracy: 0.0001)
        XCTAssertEqual(-122.4194,  (json["lng"]      as! NSNumber).doubleValue, accuracy: 0.0001)
        XCTAssertEqual(5.0,        (json["accuracy"] as! NSNumber).doubleValue, accuracy: 0.0001)
        XCTAssertEqual(1_700_000_000, (json["timestamp"] as! NSNumber).intValue)
    }

    func testEncryptSecretBoxWrongKeyLengthReturnsNil() {
        XCTAssertNil(NativeCrypto.encryptSecretBox(payload: ["x": 1], key: [1, 2, 3]))
    }

    func testDecryptSecretBoxWrongKeyReturnsNil() {
        let keyA = NativeCrypto.randomSecretBoxKey()
        let keyB = NativeCrypto.randomSecretBoxKey()
        let encrypted = NativeCrypto.encryptSecretBox(payload: ["x": 1], key: keyA)!
        XCTAssertNil(NativeCrypto.decryptSecretBox(base64Ciphertext: encrypted, key: keyB))
    }

    func testDecryptSecretBoxInvalidCiphertextReturnsNil() {
        let key = NativeCrypto.randomSecretBoxKey()
        let garbage = Data(repeating: 0xFF, count: 100).base64EncodedString()
        XCTAssertNil(NativeCrypto.decryptSecretBox(base64Ciphertext: garbage, key: key))
    }

    func testDecryptSecretBoxTooShortReturnsNil() {
        let key = NativeCrypto.randomSecretBoxKey()
        let tooShort = Data(repeating: 0, count: 4).base64EncodedString()
        XCTAssertNil(NativeCrypto.decryptSecretBox(base64Ciphertext: tooShort, key: key))
    }

    func testSecretBoxWireFormatIsBase64NonceCiphertext() {
        // Wire format: base64(24-byte nonce || 16-byte mac || plaintext)
        let key = NativeCrypto.randomSecretBoxKey()
        let encrypted = NativeCrypto.encryptSecretBox(payload: ["k": "v"], key: key)!
        let data = Data(base64Encoded: encrypted)!
        XCTAssertGreaterThan(data.count, 24 + 16, "must be nonce(24) + mac(16) + plaintext")
    }

    // MARK: – cross-party decrypt path (mirrors NotificationService)

    func testCrossPartyDecryptPathRoundTrip() {
        // Party B (sender) encrypts with X25519(skB, pkA)
        // Party A's decrypts with X25519(skA, pkB) → same shared key
        let (pkA, skA) = NativeCrypto.generateBoxKeypair()
        let (pkB, skB) = NativeCrypto.generateBoxKeypair()

        let sharedEnc = NativeCrypto.deriveSharedKey(sk: skB, pk: pkA)!
        let sharedDec = NativeCrypto.deriveSharedKey(sk: skA, pk: pkB)!

        let payload: [String: Any] = ["title": "Alice", "body": "Arrived at Home", "group_id": "g1"]
        let encrypted = NativeCrypto.encryptBox(payload: payload, sharedKey: sharedEnc)!
        let plainData = NativeCrypto.decryptBox(base64Ciphertext: encrypted, sharedKey: sharedDec)!

        let json = try! JSONSerialization.jsonObject(with: plainData) as! [String: Any]
        XCTAssertEqual("Alice",           json["title"]    as? String)
        XCTAssertEqual("Arrived at Home", json["body"]     as? String)
        XCTAssertEqual("g1",              json["group_id"] as? String)
    }
}
