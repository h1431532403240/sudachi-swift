import Foundation
import XCTest
@testable import SudachiSwift

// Shared fixtures. These tests cover this package's own layer (the Swift
// API in SudachiSwift.swift, how values and errors cross the FFI boundary,
// resource bundling, dictionary discovery); sudachi.rs tests its analysis.

/// Files whose first 24 bytes, the only part `dictionaryFormat(path:)`
/// reads, make it report a given format (see `detect_dictionary_format` in
/// rust/src/lib.rs). None of them is a loadable dictionary.
enum SyntheticDictionary {
    /// Format V1: the magic `SudachiBinaryDic` + little-endian UInt64 1.
    static let v1: Data = Data("SudachiBinaryDic".utf8) + littleEndian(1)
    /// Legacy V0 system dictionary (sudachi.rs `SYSTEM_DICT_VERSION_2`).
    static let legacyV0System: Data = littleEndian(0xce9f_011a_9239_4434) + Data(count: 16)
    /// Legacy V0 user dictionary (sudachi.rs `USER_DICT_VERSION_3`).
    static let legacyV0User: Data = littleEndian(0xca98_1175_6ff6_4fb0) + Data(count: 16)
    /// Long enough to be read, but neither header.
    static let unknown: Data = Data("definitely not a sudachi dictionary".utf8)

    private static func littleEndian(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

/// An error that fails a test (XCTest records thrown errors as failures).
struct TestSetupError: LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
}

extension XCTestCase {
    /// A new empty directory, removed when the test ends.
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SudachiSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Writes `contents` to `directory/name` and returns its URL.
    @discardableResult
    func writeFile(_ contents: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    /// Runs `body`, which must throw a `SudachiError`, and returns that
    /// error. Records a failure and returns nil otherwise.
    func sudachiError<T>(
        from body: () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> SudachiError? {
        do {
            _ = try body()
            XCTFail("expected a SudachiError, but nothing was thrown", file: file, line: line)
        } catch let error as SudachiError {
            return error
        } catch {
            XCTFail("expected a SudachiError, got \(type(of: error)): \(error)", file: file, line: line)
        }
        return nil
    }
}

/// The real V1 system dictionary for the end-to-end tests.
enum EndToEndDictionary {
    static let environmentVariable = "SUDACHI_DICT_PATH"

    /// Absolute path from `SUDACHI_DICT_PATH`. Skips the test when the
    /// variable is unset; fails it when the file isn't a V1 dictionary, so a
    /// misconfigured CI run can't pass by skipping.
    static func path() throws -> String {
        guard let value = ProcessInfo.processInfo.environment[environmentVariable],
              !value.isEmpty else {
            throw XCTSkip("Set \(environmentVariable) to a V1 system .dic to run the end-to-end tests.")
        }
        let path = URL(fileURLWithPath: value).standardizedFileURL.path
        let format = dictionaryFormat(path: path)
        guard format == .v1 else {
            throw TestSetupError(description: "\(environmentVariable)=\(value): expected a V1 dictionary, dictionaryFormat(path:) says \(format)")
        }
        return path
    }
}
