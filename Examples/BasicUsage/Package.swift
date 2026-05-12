// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BasicUsage",
    platforms: [.macOS(.v10_15)],
    dependencies: [
        // When using from the cloned repo:
        //   (run ./scripts/build-local.sh at the repo root first)
        .package(path: "../..")

        // When using as a dependency in your own project:
        // .package(url: "https://github.com/h1431532403240/sudachi-swift", from: "0.6.11")
    ],
    targets: [
        .executableTarget(
            name: "BasicUsage",
            dependencies: [.product(name: "SudachiSwift", package: "sudachi-swift")],
            path: "Sources"
        )
    ]
)
