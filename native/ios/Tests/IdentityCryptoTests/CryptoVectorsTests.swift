import XCTest
@testable import IdentityCrypto

// Golden-vector parity for the native crypto mirror (docs/NATIVE_PARITY.md
// mirror #1 in Mylo). Loads the SAME crypto_vectors.json used by the Dart
// (identity package's crypto_test.dart) and Kotlin (identity/android
// CryptoVectorsAndroidTest) suites, and decrypts via the REAL NativeCrypto.
// Pins the X25519 DH (deriveSharedKey) + crypto_box open and the sealed-box
// open (incl. tamper / wrong-recipient → nil) byte-for-byte against the other
// mirrors. Wire format: base64(nonce || ciphertext).
final class CryptoVectorsTests: XCTestCase {

    private func bytes(_ v: Any?) -> [UInt8] { Array(Data(base64Encoded: v as! String)!) }
    private func str(_ v: Any?) -> String { v as! String }

    // Walks up from this file's on-disk location to find the canonical
    // identity/test/crypto_vectors.json — same approach as Mylo's
    // RunnerTests.swift, so there's exactly one committed copy (Dart's),
    // not a duplicate bundled into this package.
    private func cases(_ section: String) -> [[String: Any]] {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let f = dir.appendingPathComponent("test/crypto_vectors.json")
            if FileManager.default.fileExists(atPath: f.path),
               let data = try? Data(contentsOf: f),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let arr = obj[section] as? [[String: Any]] {
                return arr
            }
            dir = dir.deletingLastPathComponent()
        }
        XCTFail("crypto_vectors.json not found from \(#filePath)")
        return []
    }

    func testBoxDecryptVectors() {
        for v in cases("box_decrypt") {
            guard let shared = NativeCrypto.deriveSharedKey(
                    sk: bytes(v["recipientSkB64"]), pk: bytes(v["senderPkB64"])) else {
                XCTFail("\(str(v["id"])): deriveSharedKey failed"); continue
            }
            guard let data = NativeCrypto.decryptBox(
                    base64Ciphertext: str(v["b64"]), sharedKey: shared),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                XCTFail("\(str(v["id"])): decryptBox failed"); continue
            }
            let expected = v["expected"] as! [String: Any]
            for (k, want) in expected {
                XCTAssertEqual(json[k] as? String, want as? String, "\(str(v["id"])): field \(k)")
            }
        }
    }

    func testSealOpenVectors() {
        for v in cases("seal_open") {
            let result = NativeCrypto.sealOpen(
                base64Ciphertext: str(v["sealedB64"]),
                recipientPk: bytes(v["recipientPkB64"]),
                recipientSk: bytes(v["recipientSkB64"]))
            if (v["expectNull"] as? Bool) == true {
                XCTAssertNil(result, "\(str(v["id"])): \(str(v["desc"]))")
            } else {
                XCTAssertEqual(result, str(v["expectedPlaintext"]), "\(str(v["id"])): \(str(v["desc"]))")
            }
        }
    }
}
