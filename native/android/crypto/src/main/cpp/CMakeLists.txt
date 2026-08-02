cmake_minimum_required(VERSION 3.22.1)
project(identity_crypto)

# Require 16 KB page-aligned segments so the .so loads on Android 15 devices
# that mandate 16 KB ELF alignment (Google policy, enabled by default in NDK r28).
add_link_options(-Wl,-z,max-page-size=16384)

add_library(identity_crypto SHARED identity_crypto_jni.c)

# libsodium is loaded from lazysodium-android's AAR at runtime.
# We resolve sodium symbols at run-time via dlsym so we don't link against it
# here — the only system libs we need are log and dl.
find_library(log-lib log)
find_library(dl-lib dl)
target_link_libraries(identity_crypto ${log-lib} ${dl-lib})
