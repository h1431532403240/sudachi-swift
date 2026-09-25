import Foundation
import XCTest
@testable import SudachiSwift

/// `SudachiResources`: the files Package.swift bundles, which
/// `Tokenizer.create` passes to Rust as `configPath` / `resourcePath`.
final class BundledResourcesTests: XCTestCase {
    private let bundledFiles = ["char.def", "unk.def", "rewrite.def", "sudachi.json"]

    func testConfigPathPointsAtBundledConfig() throws {
        let configPath = try XCTUnwrap(SudachiResources.configPath)
        XCTAssertEqual((configPath as NSString).lastPathComponent, "sudachi.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath), configPath)
    }

    func testHasRequiredResources() {
        XCTAssertTrue(SudachiResources.hasRequiredResources)
    }

    func testResourceDirectoryContainsBundledFiles() throws {
        let directory = try XCTUnwrap(SudachiResources.resourceDirectory)
        for name in bundledFiles {
            let path = (directory as NSString).appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "\(name) missing from \(directory)")
        }
    }

    func testConfigSitsInResourceDirectory() throws {
        // Upstream also resolves resources against the config file's
        // directory; the bundle keeps both in one place.
        let configPath = try XCTUnwrap(SudachiResources.configPath)
        let directory = try XCTUnwrap(SudachiResources.resourceDirectory)
        XCTAssertEqual(
            URL(fileURLWithPath: configPath).deletingLastPathComponent().standardizedFileURL.path,
            URL(fileURLWithPath: directory).standardizedFileURL.path
        )
    }

    func testEveryDefinitionFileTheConfigNamesIsBundled() throws {
        // A `.def` added to sudachi.json but not to Package.swift's resources
        // would silently fall back to sudachi.rs's embedded default.
        let configPath = try XCTUnwrap(SudachiResources.configPath)
        let directory = try XCTUnwrap(SudachiResources.resourceDirectory)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configPath)))

        var referenced: Set<String> = []
        func collect(_ value: Any) {
            if let string = value as? String, string.hasSuffix(".def") {
                referenced.insert(string)
            } else if let array = value as? [Any] {
                array.forEach(collect)
            } else if let object = value as? [String: Any] {
                object.values.forEach(collect)
            }
        }
        collect(json)

        XCTAssertFalse(referenced.isEmpty, "sudachi.json names no .def file")
        for name in referenced.sorted() {
            let path = (directory as NSString).appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "sudachi.json names \(name), which isn't bundled")
        }
    }
}
