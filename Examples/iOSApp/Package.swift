// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SudachiDemo",
    platforms: [.iOS(.v16)],  // LabeledContent needs iOS 16
    dependencies: [
        // When using from the cloned repo:
        //   (run ./scripts/build-local.sh at the repo root first)
        .package(path: "../..")

        // When using as a dependency in your own project:
        // .package(url: "https://github.com/h1431532403240/sudachi-swift", exact: "0.7.0")
    ],
    targets: [
        .executableTarget(
            name: "SudachiDemo",
            dependencies: [.product(name: "SudachiSwift", package: "sudachi-swift")],
            path: "Sources"
        )
    ]
)
