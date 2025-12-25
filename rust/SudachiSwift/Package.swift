// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
// Swift Package: SudachiSwift

import PackageDescription

let package = Package(
    name: "SudachiSwift",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "SudachiSwift",
            targets: ["SudachiSwift"]
        )
    ],
    dependencies: [],
    targets: [
        .binaryTarget(name: "RustFramework", path: "./RustFramework.xcframework"),
        .target(
            name: "SudachiSwift",
            dependencies: [
                .target(name: "RustFramework")
            ],
            resources: [
                .copy("Resources/char.def"),
                .copy("Resources/unk.def"),
                .copy("Resources/rewrite.def"),
                .copy("Resources/sudachi.json")
            ]
        ),
    ]
)