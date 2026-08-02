package blue.luci.identity

import android.util.Base64
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.AndroidJUnit4
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Golden-vector crypto parity — INSTRUMENTED, runs on the emulator because
 * NativeCrypto is JNI (libsodium) and can't load in the pure-JVM unit suite.
 *
 * Loads the SAME identity/test/crypto_vectors.json that the Dart
 * (crypto_vectors_test.dart) and Swift (IdentityCryptoTests CryptoVectorsTests)
 * suites load — staged into the test APK assets by the copyCryptoVectors
 * gradle task — and decrypts via the REAL NativeCrypto. A divergence fails
 * this suite. Wire format: base64(nonce || ciphertext).
 *
 * Run:  cd identity/android && ./gradlew :crypto:connectedDebugAndroidTest
 *       (needs a booted emulator / device).
 */
@RunWith(AndroidJUnit4::class)
class CryptoVectorsAndroidTest {

    private fun vectors(): JSONObject {
        // androidTest assets live in the instrumentation (test) APK context.
        val ctx = InstrumentationRegistry.getInstrumentation().context
        ctx.assets.open("crypto_vectors.json").use { stream ->
            return JSONObject(String(stream.readBytes(), Charsets.UTF_8))
        }
    }

    private fun b64(s: String): ByteArray = Base64.decode(s, Base64.NO_WRAP)

    @Test
    fun nativeCryptoReady() {
        // Fail loudly (not silently skip) if the JNI libs didn't load — every
        // decrypt below would otherwise return null for the wrong reason.
        assertTrue("NativeCrypto JNI (libsodium/identity_crypto) must load on-device",
            NativeCrypto.ready)
    }

    @Test
    fun boxDecryptVectors() {
        val cases = vectors().getJSONArray("box_decrypt")
        for (i in 0 until cases.length()) {
            val v = cases.getJSONObject(i)
            val id = v.getString("id")
            val shared = NativeCrypto.deriveSharedKey(
                b64(v.getString("recipientSkB64")), b64(v.getString("senderPkB64")))
            assertNotNull("$id: deriveSharedKey", shared)
            val map = NativeCrypto.decryptBox(v.getString("b64"), shared!!)
            assertNotNull("$id: decryptBox", map)
            val expected = v.getJSONObject("expected")
            for (k in expected.keys()) {
                assertEquals("$id: field $k", expected.getString(k), map!![k] as String)
            }
        }
    }

    @Test
    fun secretBoxDecryptVectors() {
        val cases = vectors().getJSONArray("secretbox_decrypt")
        for (i in 0 until cases.length()) {
            val v = cases.getJSONObject(i)
            val id = v.getString("id")
            val map = NativeCrypto.decryptSecretBox(v.getString("b64"), b64(v.getString("keyB64")))
            if (v.optBoolean("expectFail", false)) {
                assertNull("$id: ${v.optString("desc")}", map)
            } else {
                assertNotNull("$id: decryptSecretBox", map)
                val expected = v.getJSONObject("expected")
                for (k in expected.keys()) {
                    assertEquals("$id: field $k", expected.getString(k), map!![k] as String)
                }
            }
        }
    }

    @Test
    fun sealOpenVectors() {
        val cases = vectors().getJSONArray("seal_open")
        for (i in 0 until cases.length()) {
            val v = cases.getJSONObject(i)
            val id = v.getString("id")
            val result = NativeCrypto.sealOpen(
                v.getString("sealedB64"),
                b64(v.getString("recipientPkB64")),
                b64(v.getString("recipientSkB64")))
            if (v.optBoolean("expectNull", false)) {
                assertNull("$id: ${v.optString("desc")}", result)
            } else {
                assertEquals("$id: ${v.optString("desc")}", v.getString("expectedPlaintext"), result)
            }
        }
    }
}
