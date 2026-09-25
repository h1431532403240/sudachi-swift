import Foundation
import XCTest
@testable import SudachiSwift

/// How failures cross the FFI boundary: which `SudachiError` case Swift
/// receives from `Tokenizer.create` / `Tokenizer.withDictionary`, and that its
/// payload is the bare message. Dictionary-format detection itself is tested
/// in Rust (rust/src/lib.rs). `TokenizeError` needs a loaded dictionary, so
/// it is checked in EndToEndTests.
final class ErrorMappingTests: XCTestCase {
    func testMessageReturnsPayloadForEveryCase() {
        let cases: [SudachiError] = [
            .DictionaryLoadError(message: "dictionary"),
            .ConfigError(message: "config"),
            .TokenizeError(message: "tokenize"),
            .InvalidArgument(message: "argument"),
        ]
        XCTAssertEqual(cases.map(\.message), ["dictionary", "config", "tokenize", "argument"])
    }

    func testEmptyDictionaryPathIsInvalidArgument() throws {
        let error = try XCTUnwrap(sudachiError { try Tokenizer.withDictionary(dictionaryPath: "") })
        guard case .InvalidArgument(let message) = error else {
            return XCTFail("expected InvalidArgument, got \(error)")
        }
        XCTAssertTrue(message.contains("dictionaryPath"), message)
    }

    func testMissingDictionaryIsDictionaryLoadErrorNamingThePath() throws {
        let path = try makeTemporaryDirectory().appendingPathComponent("missing.dic").path
        let constructors: [(String, () throws -> Tokenizer)] = [
            ("create", { try Tokenizer.create(dictionaryPath: path) }),
            ("withDictionary", { try Tokenizer.withDictionary(dictionaryPath: path) }),
        ]
        for (name, construct) in constructors {
            let error = try XCTUnwrap(sudachiError(from: construct), name)
            guard case .DictionaryLoadError(let message) = error else {
                XCTFail("\(name): expected DictionaryLoadError, got \(error)")
                continue
            }
            XCTAssertTrue(message.contains(path), "\(name): \(message)")
        }
    }

    func testLegacyV0SystemDictionaryIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        let v0 = try writeFile(SyntheticDictionary.legacyV0System, named: "system.dic", in: directory)

        let error = try XCTUnwrap(sudachiError { try Tokenizer.create(dictionaryPath: v0.path) })
        guard case .DictionaryLoadError(let message) = error else {
            return XCTFail("expected DictionaryLoadError, got \(error)")
        }
        // The payload is the bare message, without Rust's Display prefix
        // ("Failed to load dictionary: ").
        XCTAssertTrue(message.hasPrefix("System dictionary \(v0.path) "), message)
        XCTAssertTrue(message.contains("legacy V0"), message)
        XCTAssertEqual(error.message, message)
    }

    func testLegacyV0UserDictionaryIsRejectedByPath() throws {
        // The format check reads only headers and runs before any dictionary
        // is loaded, so a V1 header is enough for the system dictionary.
        let directory = try makeTemporaryDirectory()
        let system = try writeFile(SyntheticDictionary.v1, named: "system.dic", in: directory)
        let v0User = try writeFile(SyntheticDictionary.legacyV0User, named: "user.dic", in: directory)

        let error = try XCTUnwrap(sudachiError {
            try Tokenizer.create(dictionaryPath: system.path, userDictionaryPaths: [v0User.path])
        })
        guard case .DictionaryLoadError(let message) = error else {
            return XCTFail("expected DictionaryLoadError, got \(error)")
        }
        XCTAssertTrue(message.hasPrefix("User dictionary \(v0User.path) "), message)
        XCTAssertTrue(message.contains("legacy V0"), message)
    }
}
