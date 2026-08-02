package blue.luci.identity

import android.util.Base64
import org.json.JSONObject

// Crypto helpers for use outside the Dart/Flutter runtime — wire format
// matches iOS NativeCrypto and the identity package's Dart crypto.dart:
// base64(nonce || ciphertext).
//
// We bypass lazysodium's JNA bridge entirely to avoid libjnidispatch.so, which
// ships with 8 KB ELF alignment and crashes on Android 15 devices that require
// 16 KB alignment.  Instead we load libsodium.so (from lazysodium-android's
// AAR, which ships a 16 KB-aligned build as of 5.2.0) and resolve the sodium
// symbols we need at runtime via dlsym inside our own thin JNI wrapper
// (identity_crypto), which is compiled with -Wl,-z,max-page-size=16384.
object NativeCrypto {

    // NaCl constants — stable across libsodium versions.
    private const val BOX_NONCEBYTES       = 24
    private const val BOX_MACBYTES         = 16
    private const val BOX_BEFORENMBYTES    = 32
    private const val SECRETBOX_NONCEBYTES = 24
    private const val SECRETBOX_MACBYTES   = 16
    private const val SECRETBOX_KEYBYTES   = 32

    val ready: Boolean by lazy {
        // Load sodium first so it's in the classloader namespace before
        // nativeInit calls dlopen("libsodium.so") by name to get a handle.
        // Consuming apps commonly ship with extractNativeLibs=false (Flutter's
        // default) so the .so isn't on disk — filesystem-path dlopen would
        // fail; by-name dlopen works because both libraries live in the same
        // Android linker namespace.
        try {
            System.loadLibrary("sodium")
        } catch (e: UnsatisfiedLinkError) {
            android.util.Log.e("NativeCrypto", "failed to load libsodium: $e")
        }
        try {
            System.loadLibrary("identity_crypto")
        } catch (e: UnsatisfiedLinkError) {
            android.util.Log.e("NativeCrypto", "failed to load identity_crypto: $e")
            return@lazy false
        }
        val ok = nativeInit()
        if (!ok) android.util.Log.e("NativeCrypto", "nativeInit failed — dlsym could not resolve libsodium symbols")
        ok
    }

    // JNI entry points — implemented in identity_crypto_jni.c
    @JvmStatic private external fun nativeInit(): Boolean
    @JvmStatic private external fun nativeRandomBytes(n: Int): ByteArray?
    @JvmStatic private external fun nativeBoxBeforeNm(sk: ByteArray, pk: ByteArray): ByteArray?
    @JvmStatic private external fun nativeBoxEasyAfterNm(plaintext: ByteArray, nonce: ByteArray, sharedKey: ByteArray): ByteArray?
    @JvmStatic private external fun nativeBoxOpenEasyAfterNm(ciphertext: ByteArray, nonce: ByteArray, sharedKey: ByteArray): ByteArray?
    @JvmStatic private external fun nativeSecretBoxEasy(plaintext: ByteArray, nonce: ByteArray, key: ByteArray): ByteArray?
    @JvmStatic private external fun nativeSecretBoxOpenEasy(ciphertext: ByteArray, nonce: ByteArray, key: ByteArray): ByteArray?
    @JvmStatic private external fun nativeBoxSealOpen(ciphertext: ByteArray, recipientPk: ByteArray, recipientSk: ByteArray): ByteArray?

    fun deriveSharedKey(sk: ByteArray, pk: ByteArray): ByteArray? {
        if (!ready) return null
        if (sk.size != 32 || pk.size != 32) return null
        return nativeBoxBeforeNm(sk, pk)
    }

    fun encryptBox(payload: Map<String, Any>, sharedKey: ByteArray): String? {
        if (!ready) return null
        if (sharedKey.size != BOX_BEFORENMBYTES) return null
        val json = try { JSONObject(payload).toString().toByteArray(Charsets.UTF_8) } catch (_: Exception) { return null }
        val nonce = nativeRandomBytes(BOX_NONCEBYTES) ?: return null
        val cipher = nativeBoxEasyAfterNm(json, nonce, sharedKey) ?: return null
        if (cipher.size != BOX_MACBYTES + json.size) return null
        return Base64.encodeToString(nonce + cipher, Base64.NO_WRAP)
    }

    fun decryptBox(b64Payload: String, sharedKey: ByteArray): Map<String, Any>? {
        if (!ready) return null
        if (sharedKey.size != BOX_BEFORENMBYTES) return null
        val combined = try { Base64.decode(b64Payload, Base64.NO_WRAP) } catch (_: Exception) { return null }
        if (combined.size < BOX_NONCEBYTES + BOX_MACBYTES) return null
        val nonce      = combined.sliceArray(0 until BOX_NONCEBYTES)
        val ciphertext = combined.sliceArray(BOX_NONCEBYTES until combined.size)
        val plaintext  = nativeBoxOpenEasyAfterNm(ciphertext, nonce, sharedKey) ?: return null
        return try {
            val json = org.json.JSONObject(String(plaintext, Charsets.UTF_8))
            buildMap { json.keys().forEach { k -> put(k, json.get(k)) } }
        } catch (_: Exception) { null }
    }

    /// Decrypt a sealed-box ciphertext (anonymous box). The sealed box was
    /// produced with `crypto_box_seal(message, recipientPk)`; only the holder
    /// of [recipientSk] can decrypt it.
    fun sealOpen(b64Ciphertext: String, recipientPk: ByteArray, recipientSk: ByteArray): String? {
        if (!ready) return null
        if (recipientPk.size != 32 || recipientSk.size != 32) return null
        val ct = try { Base64.decode(b64Ciphertext, Base64.NO_WRAP) } catch (_: Exception) { return null }
        val plain = nativeBoxSealOpen(ct, recipientPk, recipientSk) ?: return null
        return try { String(plain, Charsets.UTF_8) } catch (_: Exception) { null }
    }

    fun encryptSecretBox(payload: Map<String, Any>, key: ByteArray): String? {
        if (!ready) return null
        if (key.size != SECRETBOX_KEYBYTES) return null
        val json = try { JSONObject(payload).toString().toByteArray(Charsets.UTF_8) } catch (_: Exception) { return null }
        val nonce = nativeRandomBytes(SECRETBOX_NONCEBYTES) ?: return null
        val cipher = nativeSecretBoxEasy(json, nonce, key) ?: return null
        if (cipher.size != SECRETBOX_MACBYTES + json.size) return null
        return Base64.encodeToString(nonce + cipher, Base64.NO_WRAP)
    }

    fun decryptSecretBox(b64Payload: String, key: ByteArray): Map<String, Any>? {
        if (!ready) return null
        if (key.size != SECRETBOX_KEYBYTES) return null
        val combined = try { Base64.decode(b64Payload, Base64.NO_WRAP) } catch (_: Exception) { return null }
        if (combined.size < SECRETBOX_NONCEBYTES + SECRETBOX_MACBYTES) return null
        val nonce      = combined.sliceArray(0 until SECRETBOX_NONCEBYTES)
        val ciphertext = combined.sliceArray(SECRETBOX_NONCEBYTES until combined.size)
        val plaintext  = nativeSecretBoxOpenEasy(ciphertext, nonce, key) ?: return null
        return try {
            val json = org.json.JSONObject(String(plaintext, Charsets.UTF_8))
            buildMap { json.keys().forEach { k -> put(k, json.get(k)) } }
        } catch (_: Exception) { null }
    }
}
