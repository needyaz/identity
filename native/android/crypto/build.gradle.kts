plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "blue.luci.identity"
    compileSdk = 35

    defaultConfig {
        minSdk = 23
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    // Instrumented crypto-parity test (CryptoVectorsAndroidTest) runs on the
    // emulator because NativeCrypto is JNI. It reads the SHARED vectors from
    // the test APK's assets; copy the single source (../../test/crypto_vectors.json,
    // the Dart identity package's canonical copy) into a generated assets dir
    // at build time so there is no committed duplicate.
    sourceSets.getByName("androidTest").assets.srcDir(
        layout.buildDirectory.dir("generated/androidTestAssets"))

    // NOTE for consuming apps: dlopen-by-soname (see identity_crypto_jni.c)
    // requires the .so to be extracted to disk at install time, not left
    // compressed inside the APK zip. A CONSUMING APPLICATION module (not this
    // library) must set:
    //   packagingOptions { jniLibs { useLegacyPackaging = true } }
}

dependencies {
    // 5.2.0 ships libsodium.so with 16 KB ELF alignment, required on Android 15.
    // We load libsodium ourselves via System.loadLibrary and call it through our
    // own JNI bridge (identity_crypto) to avoid libjnidispatch.so (JNA), which
    // remains 8 KB-aligned and crashes on Android 15. The @aar type suffix
    // prevents Gradle from pulling in JNA as a transitive dependency.
    implementation("com.goterl:lazysodium-android:5.2.0@aar")

    androidTestImplementation("androidx.test:runner:1.2.0")
}

// Stage the shared crypto vectors into the androidTest assets before the asset
// merge so the instrumented test can read the same file the Dart/Swift suites do.
val copyCryptoVectors by tasks.registering(Copy::class) {
    from(rootProject.file("../../test/crypto_vectors.json"))
    into(layout.buildDirectory.dir("generated/androidTestAssets"))
}
tasks.matching { it.name.contains("AndroidTest") && it.name.contains("Assets") }
    .configureEach { dependsOn(copyCryptoVectors) }
