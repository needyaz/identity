#include <jni.h>
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <android/log.h>

#define TAG "IdentityCrypto"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// NaCl/libsodium constants (stable across all versions)
#define BOX_NONCEBYTES       24
#define BOX_MACBYTES         16
#define BOX_BEFORENMBYTES    32
#define BOX_PUBLICKEYBYTES   32
#define BOX_SECRETKEYBYTES   32
#define BOX_SEALBYTES        48   // crypto_box_PUBLICKEYBYTES + crypto_box_MACBYTES
#define SECRETBOX_NONCEBYTES 24
#define SECRETBOX_MACBYTES   16

// ---------------------------------------------------------------------------
// Lazily resolved libsodium function pointers
// ---------------------------------------------------------------------------

typedef void  (*randombytes_buf_fn)(void *, size_t);
typedef int   (*crypto_box_beforenm_fn)(unsigned char *, const unsigned char *, const unsigned char *);
typedef int   (*crypto_box_easy_afternm_fn)(unsigned char *, const unsigned char *, unsigned long long, const unsigned char *, const unsigned char *);
typedef int   (*crypto_box_open_easy_afternm_fn)(unsigned char *, const unsigned char *, unsigned long long, const unsigned char *, const unsigned char *);
typedef int   (*crypto_secretbox_easy_fn)(unsigned char *, const unsigned char *, unsigned long long, const unsigned char *, const unsigned char *);
typedef int   (*crypto_box_seal_open_fn)(unsigned char *, const unsigned char *, unsigned long long, const unsigned char *, const unsigned char *);

static randombytes_buf_fn             fn_randombytes_buf             = NULL;
static crypto_box_beforenm_fn         fn_crypto_box_beforenm         = NULL;
static crypto_box_easy_afternm_fn     fn_crypto_box_easy_afternm     = NULL;
static crypto_box_open_easy_afternm_fn fn_crypto_box_open_easy_afternm = NULL;
static crypto_secretbox_easy_fn       fn_crypto_secretbox_easy       = NULL;
static crypto_box_seal_open_fn        fn_crypto_box_seal_open        = NULL;

// Handle from dlopen — kept open so symbols remain valid for the process lifetime.
static void *sodium_handle = NULL;

// Returns 0 on success, -1 if any symbol was not found.
static int resolve_symbols(void) {
    if (fn_randombytes_buf) return 0; // already resolved
    if (!sodium_handle) { LOGE("resolve_symbols: sodium_handle is NULL"); return -1; }

    // Android 7+ linker namespaces isolate libraries loaded by System.loadLibrary
    // from RTLD_DEFAULT in native code.  We dlopen with the full path instead and
    // resolve symbols against that explicit handle.
    fn_randombytes_buf              = (randombytes_buf_fn)              dlsym(sodium_handle, "randombytes_buf");
    fn_crypto_box_beforenm          = (crypto_box_beforenm_fn)          dlsym(sodium_handle, "crypto_box_beforenm");
    fn_crypto_box_easy_afternm      = (crypto_box_easy_afternm_fn)      dlsym(sodium_handle, "crypto_box_easy_afternm");
    fn_crypto_box_open_easy_afternm = (crypto_box_open_easy_afternm_fn) dlsym(sodium_handle, "crypto_box_open_easy_afternm");
    fn_crypto_secretbox_easy        = (crypto_secretbox_easy_fn)        dlsym(sodium_handle, "crypto_secretbox_easy");
    fn_crypto_box_seal_open         = (crypto_box_seal_open_fn)         dlsym(sodium_handle, "crypto_box_seal_open");

    if (!fn_randombytes_buf || !fn_crypto_box_beforenm ||
        !fn_crypto_box_easy_afternm || !fn_crypto_box_open_easy_afternm ||
        !fn_crypto_secretbox_easy || !fn_crypto_box_seal_open) {
        LOGE("Failed to resolve libsodium symbols via dlsym");
        fn_randombytes_buf = NULL;
        return -1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// JNI helpers
// ---------------------------------------------------------------------------

static jbyteArray bytes_to_jba(JNIEnv *env, const unsigned char *buf, jsize len) {
    jbyteArray arr = (*env)->NewByteArray(env, len);
    if (arr) (*env)->SetByteArrayRegion(env, arr, 0, len, (const jbyte *)buf);
    return arr;
}

// ---------------------------------------------------------------------------
// Exported JNI functions
// ---------------------------------------------------------------------------

// Initialize: find libsodium by name and resolve symbols.
// Must be called after System.loadLibrary("sodium") so the library is already
// in the app's linker namespace and discoverable by name.  We cannot use a
// filesystem path because Flutter sets extractNativeLibs=false and the .so is
// not on disk; we cannot use RTLD_DEFAULT because Android 7+ namespace
// isolation hides classloader-namespace libs from it.  dlopen by soname from
// within the same classloader namespace finds the already-loaded handle.
// Returns true on success.
JNIEXPORT jboolean JNICALL
Java_blue_luci_identity_NativeCrypto_nativeInit(JNIEnv *env, jclass clazz) {
    (void)env; (void)clazz;
    if (fn_randombytes_buf) return JNI_TRUE; // already initialized

    sodium_handle = dlopen("libsodium.so", RTLD_NOW | RTLD_LOCAL);
    if (!sodium_handle) {
        LOGE("dlopen libsodium.so failed: %s", dlerror());
        return JNI_FALSE;
    }
    return resolve_symbols() == 0 ? JNI_TRUE : JNI_FALSE;
}

// Generate n random bytes.
JNIEXPORT jbyteArray JNICALL
Java_blue_luci_identity_NativeCrypto_nativeRandomBytes(JNIEnv *env, jclass clazz, jint n) {
    (void)clazz;
    if (resolve_symbols() != 0) return NULL;
    unsigned char *buf = (unsigned char *)malloc((size_t)n);
    if (!buf) return NULL;
    fn_randombytes_buf(buf, (size_t)n);
    jbyteArray result = bytes_to_jba(env, buf, n);
    free(buf);
    return result;
}

// crypto_box_beforenm: compute shared key from sk + pk.
// Returns BOX_BEFORENMBYTES bytes or null on failure.
JNIEXPORT jbyteArray JNICALL
Java_blue_luci_identity_NativeCrypto_nativeBoxBeforeNm(
        JNIEnv *env, jclass clazz,
        jbyteArray sk, jbyteArray pk) {
    (void)clazz;
    if (resolve_symbols() != 0) return NULL;

    jsize sk_len = (*env)->GetArrayLength(env, sk);
    jsize pk_len = (*env)->GetArrayLength(env, pk);
    if (sk_len != 32 || pk_len != 32) return NULL;

    unsigned char *c_sk = (unsigned char *)(*env)->GetByteArrayElements(env, sk, NULL);
    unsigned char *c_pk = (unsigned char *)(*env)->GetByteArrayElements(env, pk, NULL);
    unsigned char shared[BOX_BEFORENMBYTES];

    int rc = fn_crypto_box_beforenm(shared, c_pk, c_sk);

    (*env)->ReleaseByteArrayElements(env, sk, (jbyte *)c_sk, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, pk, (jbyte *)c_pk, JNI_ABORT);

    if (rc != 0) return NULL;
    return bytes_to_jba(env, shared, BOX_BEFORENMBYTES);
}

// crypto_box_easy_afternm: encrypt plaintext with precomputed shared key + nonce.
// Returns ciphertext (MAC || cipher) or null on failure.
JNIEXPORT jbyteArray JNICALL
Java_blue_luci_identity_NativeCrypto_nativeBoxEasyAfterNm(
        JNIEnv *env, jclass clazz,
        jbyteArray plaintext, jbyteArray nonce, jbyteArray sharedKey) {
    (void)clazz;
    if (resolve_symbols() != 0) return NULL;

    jsize pt_len    = (*env)->GetArrayLength(env, plaintext);
    jsize n_len     = (*env)->GetArrayLength(env, nonce);
    jsize sk_len    = (*env)->GetArrayLength(env, sharedKey);
    if (n_len != BOX_NONCEBYTES || sk_len != BOX_BEFORENMBYTES) return NULL;

    unsigned char *c_pt = (unsigned char *)(*env)->GetByteArrayElements(env, plaintext, NULL);
    unsigned char *c_n  = (unsigned char *)(*env)->GetByteArrayElements(env, nonce, NULL);
    unsigned char *c_sk = (unsigned char *)(*env)->GetByteArrayElements(env, sharedKey, NULL);

    jsize ct_len = BOX_MACBYTES + pt_len;
    unsigned char *cipher = (unsigned char *)malloc((size_t)ct_len);
    jbyteArray result = NULL;

    if (cipher) {
        int rc = fn_crypto_box_easy_afternm(cipher, c_pt, (unsigned long long)pt_len, c_n, c_sk);
        if (rc == 0) result = bytes_to_jba(env, cipher, ct_len);
        free(cipher);
    }

    (*env)->ReleaseByteArrayElements(env, plaintext, (jbyte *)c_pt, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, nonce,     (jbyte *)c_n,  JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, sharedKey, (jbyte *)c_sk, JNI_ABORT);

    return result;
}

// crypto_secretbox_easy: encrypt plaintext with symmetric key + nonce.
// Returns ciphertext (MAC || cipher) or null on failure.
JNIEXPORT jbyteArray JNICALL
Java_blue_luci_identity_NativeCrypto_nativeSecretBoxEasy(
        JNIEnv *env, jclass clazz,
        jbyteArray plaintext, jbyteArray nonce, jbyteArray key) {
    (void)clazz;
    if (resolve_symbols() != 0) return NULL;

    jsize pt_len  = (*env)->GetArrayLength(env, plaintext);
    jsize n_len   = (*env)->GetArrayLength(env, nonce);
    jsize k_len   = (*env)->GetArrayLength(env, key);
    if (n_len != SECRETBOX_NONCEBYTES || k_len != 32) return NULL;

    unsigned char *c_pt = (unsigned char *)(*env)->GetByteArrayElements(env, plaintext, NULL);
    unsigned char *c_n  = (unsigned char *)(*env)->GetByteArrayElements(env, nonce, NULL);
    unsigned char *c_k  = (unsigned char *)(*env)->GetByteArrayElements(env, key, NULL);

    jsize ct_len = SECRETBOX_MACBYTES + pt_len;
    unsigned char *cipher = (unsigned char *)malloc((size_t)ct_len);
    jbyteArray result = NULL;

    if (cipher) {
        int rc = fn_crypto_secretbox_easy(cipher, c_pt, (unsigned long long)pt_len, c_n, c_k);
        if (rc == 0) result = bytes_to_jba(env, cipher, ct_len);
        free(cipher);
    }

    (*env)->ReleaseByteArrayElements(env, plaintext, (jbyte *)c_pt, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, nonce,     (jbyte *)c_n,  JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, key,       (jbyte *)c_k,  JNI_ABORT);

    return result;
}

// crypto_box_seal_open: anonymous box decrypt. Ciphertext is
// ephemeral_pk(32) || box(message, derived_nonce, recipient_pk, ephemeral_sk).
// Returns plaintext or null on failure.
JNIEXPORT jbyteArray JNICALL
Java_blue_luci_identity_NativeCrypto_nativeBoxSealOpen(
        JNIEnv *env, jclass clazz,
        jbyteArray ciphertext, jbyteArray recipientPk, jbyteArray recipientSk) {
    (void)clazz;
    if (resolve_symbols() != 0) return NULL;

    jsize ct_len = (*env)->GetArrayLength(env, ciphertext);
    jsize pk_len = (*env)->GetArrayLength(env, recipientPk);
    jsize sk_len = (*env)->GetArrayLength(env, recipientSk);
    if (ct_len < BOX_SEALBYTES || pk_len != BOX_PUBLICKEYBYTES || sk_len != BOX_SECRETKEYBYTES) return NULL;

    unsigned char *c_ct = (unsigned char *)(*env)->GetByteArrayElements(env, ciphertext, NULL);
    unsigned char *c_pk = (unsigned char *)(*env)->GetByteArrayElements(env, recipientPk, NULL);
    unsigned char *c_sk = (unsigned char *)(*env)->GetByteArrayElements(env, recipientSk, NULL);

    jsize pt_len = ct_len - BOX_SEALBYTES;
    unsigned char *plain = (unsigned char *)malloc((size_t)pt_len);
    jbyteArray result = NULL;

    if (plain) {
        int rc = fn_crypto_box_seal_open(plain, c_ct, (unsigned long long)ct_len, c_pk, c_sk);
        if (rc == 0) result = bytes_to_jba(env, plain, pt_len);
        free(plain);
    }

    (*env)->ReleaseByteArrayElements(env, ciphertext,  (jbyte *)c_ct, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, recipientPk, (jbyte *)c_pk, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, recipientSk, (jbyte *)c_sk, JNI_ABORT);

    return result;
}

// crypto_box_open_easy_afternm: decrypt ciphertext (MAC || cipher) with precomputed shared key + nonce.
// Returns plaintext or null on failure (includes authentication failure — wrong key or tampered data).
JNIEXPORT jbyteArray JNICALL
Java_blue_luci_identity_NativeCrypto_nativeBoxOpenEasyAfterNm(
        JNIEnv *env, jclass clazz,
        jbyteArray ciphertext, jbyteArray nonce, jbyteArray sharedKey) {
    (void)clazz;
    if (resolve_symbols() != 0) return NULL;

    jsize ct_len = (*env)->GetArrayLength(env, ciphertext);
    jsize n_len  = (*env)->GetArrayLength(env, nonce);
    jsize sk_len = (*env)->GetArrayLength(env, sharedKey);
    if (ct_len < BOX_MACBYTES || n_len != BOX_NONCEBYTES || sk_len != BOX_BEFORENMBYTES) return NULL;

    unsigned char *c_ct = (unsigned char *)(*env)->GetByteArrayElements(env, ciphertext, NULL);
    unsigned char *c_n  = (unsigned char *)(*env)->GetByteArrayElements(env, nonce, NULL);
    unsigned char *c_sk = (unsigned char *)(*env)->GetByteArrayElements(env, sharedKey, NULL);

    jsize pt_len = ct_len - BOX_MACBYTES;
    unsigned char *plain = (unsigned char *)malloc((size_t)pt_len);
    jbyteArray result = NULL;

    if (plain) {
        int rc = fn_crypto_box_open_easy_afternm(plain, c_ct, (unsigned long long)ct_len, c_n, c_sk);
        if (rc == 0) result = bytes_to_jba(env, plain, pt_len);
        free(plain);
    }

    (*env)->ReleaseByteArrayElements(env, ciphertext, (jbyte *)c_ct, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, nonce,      (jbyte *)c_n,  JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, sharedKey,  (jbyte *)c_sk, JNI_ABORT);

    return result;
}
