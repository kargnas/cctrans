// swift-tools-version: 6.2

import Foundation
import PackageDescription

// CCTRANS_MAS_BUILD=1 produces the Mac App Store variant: Sparkle must not be
// linked or embedded there (the store owns updates), and MAS_BUILD gates the
// sandbox-incompatible code paths. SwiftPM caches manifest evaluation, so MAS
// builds must use a separate scratch path (scripts/build-mas.zsh passes
// --scratch-path .build-mas) instead of flipping the env var on a shared
// .build directory.
let isMASBuild = ProcessInfo.processInfo.environment["CCTRANS_MAS_BUILD"] == "1"

let package = Package(
    name: "CCTrans",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "CCTransCore", targets: ["CCTransCore"]),
        .executable(name: "CCTrans", targets: ["CCTrans"]),
    ],
    dependencies: isMASBuild ? [] : [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.0"),
    ],
    targets: [
        .target(name: "CCTransCore"),
        .executableTarget(
            name: "CCTrans",
            dependencies: isMASBuild
                ? ["CCTransCore"]
                : ["CCTransCore", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: isMASBuild ? [.define("MAS_BUILD")] : [],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("StoreKit"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "CCTransTests",
            dependencies: ["CCTransCore"]
        ),
    ]
)
