import Foundation
import XCTest
@testable import SudachiSwift

/// The Swift-side conformances and helpers in SudachiSwift.swift.
final class FormattingTests: XCTestCase {
    func testTokenizeModeDescription() {
        XCTAssertEqual(TokenizeMode.a.description, "Short (A)")
        XCTAssertEqual(TokenizeMode.b.description, "Middle (B)")
        XCTAssertEqual(TokenizeMode.c.description, "Long (C)")
    }

    func testDistributionProperties() {
        let expected: [(SudachiDictDistribution, String, Int, String)] = [
            (.small, "Small", 42, "system_small.dic"),
            (.core, "Core", 77, "system_core.dic"),
            (.full, "Full", 137, "system_full.dic"),
        ]
        XCTAssertEqual(SudachiDictDistribution.allCases, expected.map { $0.0 })
        for (distribution, description, sizeMB, dicFilename) in expected {
            XCTAssertEqual(distribution.description, description)
            XCTAssertEqual(distribution.sizeMB, sizeMB, description)
            XCTAssertEqual(distribution.dicFilename, dicFilename, description)
        }
    }

    func testDownloadURL() {
        let host = "https://d2ej7fkh96fzlu.cloudfront.net/sudachidict/v1"
        for distribution in SudachiDictDistribution.allCases {
            let name = distribution.rawValue
            XCTAssertEqual(
                distribution.downloadURL(version: "20260723").absoluteString,
                "\(host)/sudachi-dictionary-20260723-\(name).zip"
            )
            XCTAssertEqual(
                distribution.downloadURL().absoluteString,
                "\(host)/sudachi-dictionary-latest-\(name).zip"
            )
            XCTAssertEqual(distribution.downloadURL(version: nil), distribution.downloadURL())
        }
    }

    func testMorphemeInfoDescription() {
        // Distinct surface / dictionary / normalized / reading forms, so the
        // output shows which one is used.
        let morpheme = MorphemeInfo(
            surface: "surface",
            partOfSpeech: ["pos1", "pos2", "*"],
            dictionaryForm: "dictionary",
            normalizedForm: "normalized",
            readingForm: "reading",
            isOov: false,
            wordId: 1,
            begin: 0,
            end: 7,
            partOfSpeechId: 2,
            dictionaryId: 0,
            synonymGroupIds: [],
            beginChar: 0,
            endChar: 7,
            totalCost: 100
        )
        XCTAssertEqual(morpheme.description, "surface\tpos1,pos2,*\tnormalized")

        var noPartOfSpeech = morpheme
        noPartOfSpeech.partOfSpeech = []
        XCTAssertEqual(noPartOfSpeech.description, "surface\t\tnormalized")
    }
}
