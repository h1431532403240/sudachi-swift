import Foundation
import SudachiSwift

// Compile-time checks: this file stops building if the root Package.swift no
// longer exports any of these symbols.
_ = getVersion()
_ = SudachiResources.bundle
_ = splitSentences(text: "テスト。")
_ = SudachiDictDistribution.core.downloadURL()
_ = SudachiDictionaryStore.defaultDirectory
_ = SudachiDictionaryStore.isInstalled(.core)
_ = dictionaryFormat(path: "/nonexistent")
_ = DictionaryFormat.v1
let _: KeyPath<MorphemeInfo, [Int32]> = \.synonymGroupIds
let _: ([URL]) throws -> Tokenizer = SudachiDictionaryStore.createTokenizer(in:)
let _: KeyPath<SudachiError, String> = \.message

// Runtime checks that need no dictionary. Every failure is printed, then the
// process exits non-zero.
var failures = 0
func check(_ condition: Bool, _ description: String) {
    if !condition {
        print("FAIL: \(description)")
        failures += 1
    }
}

// sudachi.rs 0.7.0 alone stops splitting after the first ASCII '"'; the
// wrapper works around it and slices each range from the original text.
let quoted = "彼は\"はい\"と言った。次の文です。"
let quotedRanges = splitSentences(text: quoted)
check(
    quotedRanges.map(\.text) == ["彼は\"はい\"と言った。", "次の文です。"],
    "splitSentences(text: \(quoted.debugDescription)) = \(quotedRanges.map(\.text))"
)

// A leading U+FEFF must survive the trip back from Rust (build-local.sh
// patches the generated string decoding).
let bomText = "\u{FEFF}あ。"
let bomRanges = splitSentences(text: bomText)
check(
    bomRanges.first?.text.hasPrefix("\u{FEFF}") == true,
    "splitSentences(text: \(bomText.debugDescription)) lost the BOM: \(bomRanges.map { $0.text.debugDescription })"
)

check(
    SudachiError.InvalidArgument(message: "m").message == "m",
    "SudachiError.message must return the associated message"
)

do {
    _ = try Tokenizer.create(dictionaryPath: "")
    check(false, "Tokenizer.create(dictionaryPath: \"\") must throw")
} catch let error as SudachiError {
    if case .InvalidArgument = error {} else {
        check(false, "Tokenizer.create(dictionaryPath: \"\") threw \(error), expected InvalidArgument")
    }
} catch {
    check(false, "Tokenizer.create(dictionaryPath: \"\") threw a non-SudachiError: \(error)")
}

let missingConfig = "/nonexistent/sudachi.json"
do {
    _ = try Tokenizer(config: TokenizerConfig(
        dictionaryPath: "/nonexistent/system.dic",
        configPath: missingConfig,
        resourcePath: nil,
        userDictionaryPaths: []
    ))
    check(false, "a missing config file must throw")
} catch let error as SudachiError {
    if case .ConfigError(let message) = error {
        check(message.hasPrefix("\(missingConfig): "), "ConfigError doesn't start with the config path: \(message)")
    } else {
        check(false, "a missing config file threw \(error), expected ConfigError")
    }
} catch {
    check(false, "a missing config file threw a non-SudachiError: \(error)")
}

// Optional runtime check (build.yml's V0 step): given a legacy V0 system
// dictionary, the library itself must refuse it with its actionable message,
// not fail later with an unrelated resource/parse error.
if let v0Path = ProcessInfo.processInfo.environment["SUDACHI_V0_DICT_PATH"] {
    let expected = "uses the legacy V0 format"
    do {
        _ = try Tokenizer.create(dictionaryPath: v0Path)
        check(false, "Tokenizer.create accepted \(v0Path); expected an error containing \"\(expected)\"")
    } catch {
        let text = String(describing: error)
        if text.contains(expected) {
            print("V0 dictionary rejected by Tokenizer.create: \(text)")
        } else {
            check(false, "Tokenizer.create(\(v0Path)) threw, but not the V0 error (expected \"\(expected)\"): \(text)")
        }
    }
}

if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("ok")
