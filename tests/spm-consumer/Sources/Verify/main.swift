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

// Optional runtime check (build.yml's V0 step): given a legacy V0 system
// dictionary, the library itself must refuse it with its actionable message,
// not fail later with an unrelated resource/parse error. Exits non-zero
// otherwise.
if let v0Path = ProcessInfo.processInfo.environment["SUDACHI_V0_DICT_PATH"] {
    let expected = "uses the legacy V0 format"
    do {
        _ = try Tokenizer.create(dictionaryPath: v0Path)
        print("FAIL: Tokenizer.create accepted \(v0Path); expected an error containing \"\(expected)\"")
        exit(1)
    } catch {
        let text = String(describing: error)
        guard text.contains(expected) else {
            print("FAIL: Tokenizer.create(\(v0Path)) threw, but not the V0 error (expected \"\(expected)\"): \(text)")
            exit(1)
        }
        print("V0 dictionary rejected by Tokenizer.create: \(text)")
    }
}

print("ok")
