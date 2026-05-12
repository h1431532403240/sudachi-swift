// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

// IMPORTANT: These values are automatically updated by the release workflow.
// Do not modify manually unless you know what you're doing.
let version = "0.6.11"
let checksum = "8db8a6b49f355b91e8dbf46555e33ebf40ad50c86722b268e6fcdeb462b3cbaf"

// Local development uses an XCFramework staged at the repo root by
// scripts/build-local.sh; published releases download the prebuilt zip
// from GitHub. We pick whichever is available so the same Package.swift
// works for both contributors and external SPM consumers.
let manifestDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let localXCFramework = manifestDir + "/SudachiSwift.xcframework"

let ffiTarget: Target = FileManager.default.fileExists(atPath: localXCFramework)
    ? .binaryTarget(
        name: "SudachiSwiftFFI",
        path: "SudachiSwift.xcframework"
    )
    : .binaryTarget(
        name: "SudachiSwiftFFI",
        url: "https://github.com/h1431532403240/sudachi-swift/releases/download/v\(version)/SudachiSwift.xcframework.zip",
        checksum: checksum
    )

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
        ffiTarget,
    ]
)
