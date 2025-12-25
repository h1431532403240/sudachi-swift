// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// IMPORTANT: These values are automatically updated by the release workflow.
// Do not modify manually unless you know what you're doing.
let version = "0.1.0"
let checksum = "PLACEHOLDER_CHECKSUM"

let package = Package(
    name: "SudachiSwift",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "SudachiSwift",
            targets: ["SudachiSwift"]
        ),
    ],
    targets: [
        .target(
            name: "SudachiSwift",
            dependencies: ["SudachiSwiftFFI"],
            path: "Sources/SudachiSwift",
            resources: [
                .copy("Resources/char.def"),
                .copy("Resources/unk.def"),
                .copy("Resources/rewrite.def"),
                .copy("Resources/sudachi.json")
            ]
        ),
        .binaryTarget(
            name: "SudachiSwiftFFI",
            url: "https://github.com/h1431532403240/sudachi-swift/releases/download/v\(version)/SudachiSwift.xcframework.zip",
            checksum: checksum
        ),
    ]
)
