// swift-tools-version: 6.0

import PackageDescription

// SQLCipher, OpenSSL (libcrypto) and zstd are linked statically from Homebrew so the app bundle
// does not depend on /opt/homebrew at runtime.
let brew = "/opt/homebrew/opt"

let package = Package(
    name: "ChatMaster",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "ChatMaster", targets: ["ChatMaster"]),
        .executable(name: "chatmasterctl", targets: ["LensCtl"]),
    ],
    dependencies: [
        .package(path: "../MudsUI"),
    ],
    targets: [
        .target(
            name: "CLensNative",
            path: "Sources/CLensNative",
            linkerSettings: [
                .unsafeFlags([
                    "\(brew)/sqlcipher/lib/libsqlcipher.a",
                    "\(brew)/openssl@4/lib/libcrypto.a",
                    "\(brew)/zstd/lib/libzstd.a",
                ]),
                .linkedLibrary("z"),
            ]),
        .target(
            name: "LensCore",
            dependencies: ["CLensNative"],
            path: "Sources/LensCore"),
        .executableTarget(
            name: "ChatMaster",
            dependencies: ["LensCore", "MudsUI"],
            path: "Sources/ChatMaster"),
        .executableTarget(
            name: "LensCtl",
            dependencies: ["LensCore"],
            path: "Sources/LensCtl"),
        .testTarget(
            name: "LensCoreTests",
            dependencies: ["LensCore"],
            path: "Tests/LensCoreTests"),
    ],
    swiftLanguageModes: [.v5])
