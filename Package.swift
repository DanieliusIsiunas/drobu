// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Drobu",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/soffes/HotKey.git", from: "0.2.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Leaf library shared by the app (DrobuCore) and the privileged daemon
        // (DrobuDaemon): XPC protocol, protocol version, constants, deadline
        // math, request validation, state-file codec. No dependencies — keeps
        // GRDB/HotKey/Sparkle/SwiftUI out of the root daemon process.
        .target(
            name: "DrobuShared",
            path: "Sources/DrobuShared"
        ),
        .target(
            name: "DrobuCore",
            dependencies: [
                "DrobuShared",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "HotKey", package: "HotKey"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/DrobuCore",
            exclude: ["Info.plist", "Drobu.entitlements"]
        ),
        .executableTarget(
            name: "Drobu",
            dependencies: ["DrobuCore"],
            path: "Sources/Drobu"
        ),
        // Privileged root daemon. Thin wiring over DrobuShared; SPM does not
        // embed the launchd plist (build.sh copies it into the bundle), so it
        // is excluded from the source list.
        .executableTarget(
            name: "DrobuDaemon",
            dependencies: ["DrobuShared"],
            path: "Sources/DrobuDaemon",
            exclude: ["com.danielius.ClipboardHistory.daemon.plist"]
        ),
        .testTarget(
            name: "DrobuTests",
            dependencies: [
                "DrobuCore",
                "DrobuShared",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests"
        ),
    ]
)
