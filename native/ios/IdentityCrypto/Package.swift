// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IdentityCrypto",
    platforms: [
        .iOS(.v13),
        .macOS(.v11),
    ],
    products: [
        .library(name: "IdentityCrypto", targets: ["IdentityCrypto"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "IdentityCrypto",
            dependencies: [
                .product(name: "Clibsodium", package: "swift-sodium"),
            ]
        ),
        .testTarget(
            name: "IdentityCryptoTests",
            dependencies: ["IdentityCrypto"]
        ),
    ]
)
