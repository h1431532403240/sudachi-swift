import Foundation
import XCTest
@testable import SudachiSwift

/// Loads a real V1 SudachiDict (`SUDACHI_DICT_PATH`; skipped when unset) and
/// checks that the pipe works and that each morpheme's fields describe the
/// same text. It asserts nothing about how the text is segmented: that is
/// sudachi.rs's job.
final class EndToEndTests: XCTestCase {
    /// Mixes one-byte ASCII with three-byte kana and kanji, so UTF-8 byte
    /// offsets and code point offsets differ.
    private let text = "東京都でSwiftを使っています。"

    /// For the subunit tests: compound nouns that SudachiDict tends to split,
    /// and to split differently in modes A and B (CI's full dictionary does).
    /// The tests hold whatever splits, including nothing.
    private let compoundText = "東京都選挙管理委員会の国家公務員がSwiftを使っています。"

    func testCreateTokenizesInEveryMode() throws {
        let tokenizer = try Tokenizer.create(dictionaryPath: EndToEndDictionary.path())
        for mode in [TokenizeMode.a, .b, .c] {
            let morphemes = try tokenizer.tokenize(text: text, mode: mode)
            assertFieldsDescribeText(morphemes, "mode \(mode)")
            for morpheme in morphemes {
                XCTAssertEqual(
                    tokenizer.posOf(posId: morpheme.partOfSpeechId),
                    morpheme.partOfSpeech,
                    "partOfSpeechId of \(morpheme.surface.debugDescription), mode \(mode)"
                )
            }
        }
    }

    func testWithDictionaryTokenizes() throws {
        let tokenizer = try Tokenizer.withDictionary(dictionaryPath: EndToEndDictionary.path())
        let morphemes = try tokenizer.tokenize(text: text, mode: .c)
        assertFieldsDescribeText(morphemes, "withDictionary")
    }

    func testDictionaryStoreLoadsSystemDic() throws {
        // A symlink named system.dic, so this works whatever the file is called.
        let path = try EndToEndDictionary.path()
        let directory = try makeTemporaryDirectory()
        let link = directory.appendingPathComponent("system.dic")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: path)

        XCTAssertEqual(SudachiDictionaryStore.findDictionary(in: [directory]), link)
        let tokenizer = try SudachiDictionaryStore.createTokenizer(in: [directory])
        let morphemes = try tokenizer.tokenize(text: text, mode: .c)
        assertFieldsDescribeText(morphemes, "createTokenizer(in:)")
    }

    func testTokenizeWithSubunitsAddSingle() throws {
        // The wrapper's own logic: addSingle only changes the entries that
        // didn't split, from [] to [morpheme]. Which morphemes split is the
        // dictionary's business; the checks hold whatever splits.
        let tokenizer = try Tokenizer.create(dictionaryPath: EndToEndDictionary.path())
        let morphemes = try tokenizer.tokenize(text: compoundText, mode: .c)
        let withSingle = try tokenizer.tokenizeWithSubunits(text: compoundText, mode: .c, subMode: .a, addSingle: true)
        let withoutSingle = try tokenizer.tokenizeWithSubunits(text: compoundText, mode: .c, subMode: .a, addSingle: false)

        XCTAssertEqual(withSingle.map(\.morpheme), morphemes)
        XCTAssertEqual(withoutSingle.map(\.morpheme), morphemes)
        guard withSingle.count == morphemes.count, withoutSingle.count == morphemes.count else { return }

        // Keeps a wrapper that never reports subunits from passing just
        // because nothing split. sudachi.rs derives mode A by splitting the
        // mode C morphemes, so if mode A has more morphemes, some entry must
        // have split. With a dictionary that splits nothing here, both counts
        // match and this checks nothing.
        let modeA = try tokenizer.tokenize(text: compoundText, mode: .a)
        if modeA.count > morphemes.count {
            XCTAssertTrue(
                withoutSingle.contains { !$0.subunits.isEmpty },
                "mode A has \(modeA.count) morphemes and mode C \(morphemes.count), but no mode C morpheme reported subunits"
            )
        }

        for (index, morpheme) in morphemes.enumerated() {
            let context = "morpheme \(index) \(morpheme.surface.debugDescription)"
            let subunits = withoutSingle[index].subunits
            if subunits.isEmpty {
                XCTAssertEqual(withSingle[index].subunits, [morpheme], context)
                continue
            }
            XCTAssertEqual(withSingle[index].subunits, subunits, context)
            XCTAssertEqual(subunits.map(\.surface).joined(), morpheme.surface, context)
            for subunit in subunits {
                XCTAssertTrue(
                    morpheme.begin <= subunit.begin && subunit.end <= morpheme.end,
                    "\(context): subunit \(subunit.surface.debugDescription) at \(subunit.begin)..<\(subunit.end)"
                )
            }
        }
    }

    func testTokenizeWithSubunitsFollowsSubMode() throws {
        // The wrapper's own logic: it passes subMode on to split_into. In
        // sudachi.rs, modes A and B are the mode C path with each morpheme
        // split by the same dictionary data (split_path in
        // stateless_tokenizer.rs; both go through ResultNode::split). So for
        // subMode X, a mode C morpheme's subunits are exactly the mode X
        // morphemes inside its span, field for field: split pieces are built
        // the same way (totalCost Int32.max included), and a morpheme that
        // doesn't split is the same node in both lists. This holds whatever
        // the dictionary splits; a wrapper that ignored subMode, swapped A
        // and B, or always used one mode fails it wherever modes A and B
        // differ.
        let tokenizer = try Tokenizer.create(dictionaryPath: EndToEndDictionary.path())
        let modeC = try tokenizer.tokenize(text: compoundText, mode: .c)
        var subunitsBySubMode: [TokenizeMode: [[MorphemeInfo]]] = [:]
        for subMode in [TokenizeMode.a, .b] {
            let expected = try tokenizer.tokenize(text: compoundText, mode: subMode)
            let entries = try tokenizer.tokenizeWithSubunits(text: compoundText, mode: .c, subMode: subMode, addSingle: false)
            XCTAssertEqual(entries.map(\.morpheme), modeC, "subMode \(subMode)")
            guard entries.count == modeC.count else { continue }
            subunitsBySubMode[subMode] = entries.map(\.subunits)

            for (index, entry) in entries.enumerated() {
                let morpheme = entry.morpheme
                let context = "subMode \(subMode), morpheme \(index) \(morpheme.surface.debugDescription)"
                let inside = expected.filter { morpheme.begin <= $0.begin && $0.end <= morpheme.end }
                switch entry.subunits.count {
                case 0:
                    // Didn't split: mode X keeps the morpheme as it is.
                    XCTAssertEqual(inside, [morpheme], context)
                case 1:
                    // A one-word split list: split_into reports that word over
                    // the whole span, but split_path splits only into two or
                    // more, so mode X keeps the morpheme.
                    XCTAssertEqual(inside, [morpheme], context)
                    XCTAssertEqual(entry.subunits[0].begin, morpheme.begin, context)
                    XCTAssertEqual(entry.subunits[0].end, morpheme.end, context)
                default:
                    XCTAssertEqual(entry.subunits, inside, context)
                }
            }
        }

        // Only where modes A and B differ can a check tell them apart; if
        // they differ in this text, the subunits must differ too.
        let modeA = try tokenizer.tokenize(text: compoundText, mode: .a)
        let modeB = try tokenizer.tokenize(text: compoundText, mode: .b)
        if modeA != modeB {
            XCTAssertNotEqual(
                subunitsBySubMode[.a],
                subunitsBySubMode[.b],
                "modes A and B differ, but subMode .a and .b gave the same subunits"
            )
        }
    }

    func testInputOverTheLimitIsTokenizeError() throws {
        // Over the 49,149-byte input limit documented on tokenize (60,000
        // UTF-8 bytes). Only the case is ours; the message is sudachi.rs's.
        let tokenizer = try Tokenizer.create(dictionaryPath: EndToEndDictionary.path())
        let long = String(repeating: "あ", count: 20_000)
        let calls: [(String, () throws -> Any)] = [
            ("tokenize", { try tokenizer.tokenize(text: long, mode: .c) }),
            ("tokenizeWithSubunits", { try tokenizer.tokenizeWithSubunits(text: long, mode: .c, subMode: .a, addSingle: true) }),
            ("lookup", { try tokenizer.lookup(query: long) }),
        ]
        for (name, call) in calls {
            let error = try XCTUnwrap(sudachiError(from: call), name)
            guard case .TokenizeError = error else {
                XCTFail("\(name): expected TokenizeError, got \(error)")
                continue
            }
        }
    }

    /// The surfaces rebuild `text`, and each morpheme's byte offsets
    /// (`begin`/`end`) and code point offsets (`beginChar`/`endChar`) select
    /// its surface and follow on from the previous morpheme. With no user
    /// dictionary, `dictionaryId` is 0, or -1 for OOV.
    private func assertFieldsDescribeText(
        _ morphemes: [MorphemeInfo],
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(morphemes.isEmpty, label, file: file, line: line)
        XCTAssertEqual(morphemes.map(\.surface).joined(), text, label, file: file, line: line)

        let bytes = Array(text.utf8)
        // Code points, not Characters: `beginChar` counts what Python's
        // `Morpheme.begin()` counts.
        let scalars = Array(text.unicodeScalars)
        var byteOffset = 0
        var scalarOffset = 0
        for (index, morpheme) in morphemes.enumerated() {
            let context = "\(label), morpheme \(index) \(morpheme.surface.debugDescription)"
            let begin = Int(morpheme.begin), end = Int(morpheme.end)
            let beginChar = Int(morpheme.beginChar), endChar = Int(morpheme.endChar)
            XCTAssertEqual(begin, byteOffset, "begin: \(context)", file: file, line: line)
            XCTAssertEqual(beginChar, scalarOffset, "beginChar: \(context)", file: file, line: line)
            guard begin <= end, end <= bytes.count, beginChar <= endChar, endChar <= scalars.count else {
                XCTFail("offsets out of range: \(context) \(begin)..<\(end), \(beginChar)..<\(endChar)", file: file, line: line)
                return
            }
            XCTAssertEqual(
                String(decoding: bytes[begin..<end], as: UTF8.self),
                morpheme.surface,
                "UTF-8 slice: \(context)",
                file: file,
                line: line
            )
            var slice = String.UnicodeScalarView()
            slice.append(contentsOf: scalars[beginChar..<endChar])
            XCTAssertEqual(String(slice), morpheme.surface, "code point slice: \(context)", file: file, line: line)
            XCTAssertEqual(morpheme.dictionaryId, morpheme.isOov ? -1 : 0, "dictionaryId: \(context)", file: file, line: line)
            byteOffset = end
            scalarOffset = endChar
        }
        XCTAssertEqual(byteOffset, bytes.count, "last end: \(label)", file: file, line: line)
        XCTAssertEqual(scalarOffset, scalars.count, "last endChar: \(label)", file: file, line: line)
    }
}
