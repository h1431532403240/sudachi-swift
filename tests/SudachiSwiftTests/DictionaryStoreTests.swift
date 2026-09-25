import Foundation
import XCTest
@testable import SudachiSwift

/// `SudachiDictionaryStore`: dictionary discovery and install paths, with
/// synthetic header files in temporary directories. The search rules are
/// tested through the internal `findDictionary(searching:)`, which leaves out
/// `defaultDirectory` and the main bundle, so the results don't depend on the
/// files of the machine running the tests; the directory order through the
/// internal `searchPaths(additional:)`.
final class DictionaryStoreTests: XCTestCase {
    /// Recognised names in their documented order.
    private let recognisedNames = ["system.dic", "system_small.dic", "system_core.dic", "system_full.dic"]

    // MARK: - Search rules

    func testV1InLaterDirectoryBeatsLegacyV0InEarlierDirectory() throws {
        let first = try makeTemporaryDirectory()
        let second = try makeTemporaryDirectory()
        try writeFile(SyntheticDictionary.legacyV0System, named: "system.dic", in: first)
        let v1 = try writeFile(SyntheticDictionary.v1, named: "system_full.dic", in: second)

        XCTAssertEqual(SudachiDictionaryStore.findDictionary(searching: [first, second]), v1)
    }

    func testLegacyV0BeatsUnknownFormat() throws {
        let first = try makeTemporaryDirectory()
        let second = try makeTemporaryDirectory()
        try writeFile(SyntheticDictionary.unknown, named: "system.dic", in: first)
        let v0 = try writeFile(SyntheticDictionary.legacyV0System, named: "system.dic", in: second)

        XCTAssertEqual(SudachiDictionaryStore.findDictionary(searching: [first, second]), v0)
    }

    func testFirstFallbackInSearchOrderWinsWhenThereIsNoV1() throws {
        let first = try makeTemporaryDirectory()
        let second = try makeTemporaryDirectory()
        let earlierV0 = try writeFile(SyntheticDictionary.legacyV0System, named: "system_full.dic", in: first)
        try writeFile(SyntheticDictionary.legacyV0System, named: "system.dic", in: second)
        XCTAssertEqual(SudachiDictionaryStore.findDictionary(searching: [first, second]), earlierV0)

        let third = try makeTemporaryDirectory()
        let fourth = try makeTemporaryDirectory()
        let earlierUnknown = try writeFile(SyntheticDictionary.unknown, named: "system_core.dic", in: third)
        try writeFile(SyntheticDictionary.unknown, named: "system.dic", in: fourth)
        XCTAssertEqual(SudachiDictionaryStore.findDictionary(searching: [third, fourth]), earlierUnknown)
    }

    func testFilenameOrderWithinOneDirectory() throws {
        let directory = try makeTemporaryDirectory()
        for name in recognisedNames {
            try writeFile(SyntheticDictionary.v1, named: name, in: directory)
        }
        // Remove each winner in turn: the next name in the documented order wins.
        for name in recognisedNames {
            let expected = directory.appendingPathComponent(name)
            XCTAssertEqual(SudachiDictionaryStore.findDictionary(searching: [directory]), expected)
            try FileManager.default.removeItem(at: expected)
        }
        XCTAssertNil(SudachiDictionaryStore.findDictionary(searching: [directory]))
    }

    func testLaterDirectoryIsSearchedOnlyAfterEveryNameInEarlierOne() throws {
        let first = try makeTemporaryDirectory()
        let second = try makeTemporaryDirectory()
        let v1 = try writeFile(SyntheticDictionary.v1, named: "system_full.dic", in: first)
        try writeFile(SyntheticDictionary.v1, named: "system.dic", in: second)

        XCTAssertEqual(SudachiDictionaryStore.findDictionary(searching: [first, second]), v1)
    }

    func testNilWhenNothingMatches() throws {
        let empty = try makeTemporaryDirectory()
        let unrecognised = try makeTemporaryDirectory()
        for name in ["system.dic.test", "system.dic.bak", "user.dic", "system_tiny.dic"] {
            try writeFile(SyntheticDictionary.v1, named: name, in: unrecognised)
        }
        let missing = empty.appendingPathComponent("does-not-exist", isDirectory: true)

        XCTAssertNil(SudachiDictionaryStore.findDictionary(searching: []))
        XCTAssertNil(SudachiDictionaryStore.findDictionary(searching: [empty, unrecognised, missing]))
    }

    func testSearchPathsAreCallerPathsThenDefaultDirectoryThenMainBundle() {
        // The documented order of findDictionary(in:).
        let first = URL(fileURLWithPath: "/first", isDirectory: true)
        let second = URL(fileURLWithPath: "/second", isDirectory: true)
        var expected = [first, second, SudachiDictionaryStore.defaultDirectory]
        if let bundleURL = Bundle.main.resourceURL {
            expected.append(bundleURL)
        }

        XCTAssertEqual(SudachiDictionaryStore.searchPaths(additional: [first, second]), expected)
        XCTAssertEqual(SudachiDictionaryStore.searchPaths(additional: []), Array(expected.dropFirst(2)))
    }

    func testPublicFindDictionarySearchesCallerPaths() throws {
        // Smoke test of the public entry point. A V1 file in a caller-supplied
        // path wins over anything in defaultDirectory or the main bundle, so
        // this holds on any machine.
        let directory = try makeTemporaryDirectory()
        let v1 = try writeFile(SyntheticDictionary.v1, named: "system_core.dic", in: directory)

        XCTAssertEqual(SudachiDictionaryStore.findDictionary(in: [directory]), v1)
    }

    // MARK: - Install paths

    func testDictionaryPathUsesEachDistributionsFilename() throws {
        let directory = try makeTemporaryDirectory()
        for distribution in SudachiDictDistribution.allCases {
            let path = SudachiDictionaryStore.dictionaryPath(for: distribution, in: directory)
            XCTAssertEqual(path.lastPathComponent, distribution.dicFilename, "\(distribution)")
            XCTAssertEqual(path.deletingLastPathComponent().path, directory.path, "\(distribution)")

            let defaultPath = SudachiDictionaryStore.dictionaryPath(for: distribution)
            XCTAssertEqual(
                defaultPath.deletingLastPathComponent().path,
                SudachiDictionaryStore.defaultDirectory.path,
                "\(distribution)"
            )
        }
    }

    func testIsInstalledOnlyForV1() throws {
        let directory = try makeTemporaryDirectory()
        let cases: [(SudachiDictDistribution, Data?, Bool)] = [
            (.small, SyntheticDictionary.v1, true),
            (.core, SyntheticDictionary.legacyV0System, false),
            (.full, nil, false),
        ]
        for (distribution, contents, expected) in cases {
            if let contents = contents {
                try writeFile(contents, named: distribution.dicFilename, in: directory)
            }
            XCTAssertEqual(
                SudachiDictionaryStore.isInstalled(distribution, in: directory),
                expected,
                "\(distribution)"
            )
        }

        try writeFile(SyntheticDictionary.unknown, named: SudachiDictDistribution.full.dicFilename, in: directory)
        XCTAssertFalse(SudachiDictionaryStore.isInstalled(.full, in: directory))
    }

    // MARK: - createTokenizer(in:)

    /// Skips when `defaultDirectory` or the main bundle already holds a file
    /// `findDictionary(in:)` would pick up, since `createTokenizer(in:)`
    /// always searches them too.
    private func skipIfMachineHasDictionary() throws {
        let machinePaths = SudachiDictionaryStore.searchPaths(additional: [])
        if let found = SudachiDictionaryStore.findDictionary(searching: machinePaths) {
            throw XCTSkip("\(found.path) exists; createTokenizer(in:) would find it.")
        }
    }

    func testCreateTokenizerWithoutDictionaryNamesSearchedDirectories() throws {
        try skipIfMachineHasDictionary()
        let directory = try makeTemporaryDirectory()

        let error = try XCTUnwrap(sudachiError { try SudachiDictionaryStore.createTokenizer(in: [directory]) })
        guard case .DictionaryLoadError(let message) = error else {
            return XCTFail("expected DictionaryLoadError, got \(error)")
        }
        XCTAssertTrue(message.contains(directory.path), message)
        XCTAssertTrue(message.contains(SudachiDictionaryStore.defaultDirectory.path), message)
    }

    func testCreateTokenizerLoadsLegacyFallbackToReportIt() throws {
        // With no V1 file, the V0 fallback is loaded so the error says why it
        // can't be used.
        try skipIfMachineHasDictionary()
        let directory = try makeTemporaryDirectory()
        let v0 = try writeFile(SyntheticDictionary.legacyV0System, named: "system.dic", in: directory)

        let error = try XCTUnwrap(sudachiError { try SudachiDictionaryStore.createTokenizer(in: [directory]) })
        guard case .DictionaryLoadError(let message) = error else {
            return XCTFail("expected DictionaryLoadError, got \(error)")
        }
        XCTAssertTrue(message.contains("legacy V0"), message)
        XCTAssertTrue(message.contains(v0.path), message)
    }
}
