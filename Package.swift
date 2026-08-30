// swift-tools-version: 6.0
import Foundation
import PackageDescription

let infoPlistPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Info.plist")
    .path

let package = Package(
    name: "eventkitcontrol",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "eventkitcontrol", targets: ["EventKitControl"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2")
    ],
    targets: [
        .target(
            name: "EventKitControlCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/EventKitControlCore"
        ),
        .executableTarget(
            name: "EventKitControl",
            dependencies: [
                "EventKitControlCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/EventKitControl",
            linkerSettings: [
                .unsafeFlags(
                    [
                        "-Xlinker", "-sectcreate",
                        "-Xlinker", "__TEXT",
                        "-Xlinker", "__info_plist",
                        "-Xlinker", infoPlistPath,
                    ],
                    .when(platforms: [.macOS])
                )
            ]
        ),
        .testTarget(
            name: "EventKitControlTests",
            dependencies: [
                "EventKitControlCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Tests/EventKitControlTests"
        )
    ]
)
