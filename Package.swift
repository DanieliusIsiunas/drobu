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
        .target(
            name: "DrobuCore",
            dependencies: [
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
        .testTarget(
            name: "DrobuTests",
            dependencies: [
                "DrobuCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests"
        ),
    ]
)
