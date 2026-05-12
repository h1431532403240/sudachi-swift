// swift-tools-version: 5.9
// CI fixture: minimal external SPM consumer used by .github/workflows/build.yml
// to verify the root Package.swift exports a usable API surface.
import PackageDescription

let package = Package(
    name: "Verify",
    platforms: [.macOS(.v10_15)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "Verify",
            dependencies: [.product(name: "SudachiSwift", package: "sudachi-swift")],
            path: "Sources/Verify"
        )
    ]
)
