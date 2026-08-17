#!/usr/bin/env python3
"""Independently re-derive the known-answer vectors pinned in SPEC.md.

The repo's credibility claim is that the derivation vectors asserted in
`test/identity_test.dart` / `test/crypto_test.dart` were computed with an
implementation that shares no code with this package — Python's stdlib
`hashlib` for the SHA-256 and keyed-BLAKE2b stages, and the `cryptography`
package's Ed25519 for seed → public key. This script IS that computation:
run it and compare its output against SPEC.md's "Known-answer vectors"
section (it does the comparison for you and exits non-zero on mismatch).

    python3 tools/verify_vectors.py

Requires only the Python standard library; the one Ed25519 check
additionally needs `pip install cryptography` and is skipped (with a
warning) if it is missing.

Scope, stated honestly: this covers the three domain-separated derivations
(uid, store-binding token, backup key, signing public key) — the parts a
second implementation can reproduce from a written spec. It does NOT cover
`test/crypto_vectors.json` (the box/sealed-box/secretbox golden vectors):
those pin libsodium constructions (XSalsa20-Poly1305, HSalsa20 key
derivation) that no mainstream independent Python library implements, so
any "independent" check would just be libsodium again via PyNaCl. Their
guarantee is different — three separately written bindings (Dart, Swift,
Kotlin/JNI) agreeing on the same fixture — and is exercised by the three
test suites, not by this script.
"""

import hashlib
import sys

# --- Inputs (SPEC.md "Known-answer vectors") ------------------------------

PUBKEY = bytes(range(32))  # box public key 0x00 0x01 .. 0x1f
SEED = bytes(range(32))    # seed 0x00 0x01 .. 0x1f

# --- Expected values (SPEC.md; asserted by the Dart test suite) -----------

EXPECTED_UID = "630dcd2966c4336691125448bbb25b4f"
EXPECTED_BINDING = "520b61d7-b56f-74f5-726c-3dfab07859a0"
EXPECTED_BACKUP_PADDED = (
    "a509286e124be20c5dc50f097e7dbbcae1773919d88d3d0bc3a9af2fddce45e8"
)
EXPECTED_BACKUP_UNPADDED = (
    "1580c0cdbd94fca160c0b78e4758755bda45e39dc5786db92541b2f60b535e98"
)
EXPECTED_SIGNING_PUB = (
    "e986c2797e79ee0aa8ed38dc90c9292fc4ff0d101eee5b85d7c38bf277d01d20"
)


def uid(pubkey: bytes) -> str:
    """uid = SHA-256(boxPublicKey)[0..15] as 32-char lowercase hex."""
    return hashlib.sha256(pubkey).hexdigest()[:32]


def store_binding_token(pubkey: bytes, domain: str) -> str:
    """SHA-256(domain_ascii ‖ pubkey)[0..15], hex, grouped 8-4-4-4-12."""
    h = hashlib.sha256(domain.encode("ascii") + pubkey).hexdigest()[:32]
    return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


def backup_key(seed: bytes, domain: str) -> str:
    """BLAKE2b(message=seed, key=domain, outLen=32).

    libsodium's crypto_generichash is keyed BLAKE2b; the domain is
    right-padded with 0x00 to libsodium's 16-byte key minimum when shorter.
    """
    key = domain.encode("utf-8")
    if len(key) < 16:
        key = key.ljust(16, b"\x00")
    return hashlib.blake2b(seed, key=key, digest_size=32).hexdigest()


def signing_pubkey(seed: bytes, domain: str) -> str:
    """edSeed = BLAKE2b(seed, key=domain, outLen=32); Ed25519 seed → pubkey."""
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey,
    )

    ed_seed = hashlib.blake2b(
        seed, key=domain.encode("utf-8"), digest_size=32
    ).digest()
    pub = Ed25519PrivateKey.from_private_bytes(ed_seed).public_key()
    return pub.public_bytes_raw().hex()


def main() -> int:
    checks = [
        ("uid", uid(PUBKEY), EXPECTED_UID),
        (
            "store-binding token (identity-spec-binding-v1)",
            store_binding_token(PUBKEY, "identity-spec-binding-v1"),
            EXPECTED_BINDING,
        ),
        (
            "backup key (identity-pad-v1, 15-byte domain → padded)",
            backup_key(SEED, "identity-pad-v1"),
            EXPECTED_BACKUP_PADDED,
        ),
        (
            "backup key (identity-spec-backup-v1, 23-byte domain)",
            backup_key(SEED, "identity-spec-backup-v1"),
            EXPECTED_BACKUP_UNPADDED,
        ),
    ]

    try:
        checks.append(
            (
                "signing public key (identity-spec-signing-v1)",
                signing_pubkey(SEED, "identity-spec-signing-v1"),
                EXPECTED_SIGNING_PUB,
            )
        )
    except ImportError:
        print(
            "WARNING: `cryptography` not installed — skipping the Ed25519 "
            "signing-key check (pip install cryptography)",
            file=sys.stderr,
        )

    failed = 0
    for name, got, expected in checks:
        ok = got == expected
        failed += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'}  {name}")
        if not ok:
            print(f"      expected {expected}")
            print(f"      got      {got}")

    print(
        f"\n{len(checks) - failed}/{len(checks)} vectors independently "
        f"reproduced{' — SPEC.md and this script agree' if not failed else ''}"
    )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
