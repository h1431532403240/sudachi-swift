// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BasicUsage",
    platforms: [.macOS(.v10_15)],
    dependencies: [
        // When using from the cloned repo:
        .package(path: "../../rust/SudachiSwift")

        // When using as a dependency in your own project:
        // .package(url: "https://github.com/h1431532403240/sudachi-swift", from: "0.1.0")
    ],
    targets: [
        .executableTarget(
            name: "BasicUsage",
            dependencies: ["SudachiSwift"],
            path: "Sources"
        )
    ]
)
