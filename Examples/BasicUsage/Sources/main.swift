import Foundation
import SudachiSwift

print("=== SudachiSwift Basic Usage ===\n")
print("Library version: \(getVersion())")

print("\nAvailable SudachiDict distributions (V1 format):")
for dist in SudachiDictDistribution.allCases {
    print("  - \(dist) (~\(dist.sizeMB) MB zip)")
    print("    URL: \(dist.downloadURL())")
}

let dictionaryPath = ProcessInfo.processInfo.environment["SUDACHI_DICT_PATH"] ?? "path/to/system.dic"

guard FileManager.default.fileExists(atPath: dictionaryPath) else {
    print("\n[!] Dictionary not found at: \(dictionaryPath)")
    print("    Download a V1 dictionary from: \(SudachiDictDistribution.small.downloadURL())")
    print("    then set SUDACHI_DICT_PATH to the extracted \(SudachiDictDistribution.small.dicFilename)")
    exit(1)
}

guard dictionaryFormat(path: dictionaryPath) != .legacyV0 else {
    print("\n[!] \(dictionaryPath) is a legacy V0 dictionary, which SudachiSwift \(getVersion()) can't load.")
    print("    Download a V1 dictionary from: \(SudachiDictDistribution.small.downloadURL())")
    exit(1)
}

do {
    let tokenizer = try Tokenizer.create(dictionaryPath: dictionaryPath)

    let text = "東京都に住んでいます"
    print("\nTokenizing: \"\(text)\"\n")

    for mode: TokenizeMode in [.a, .b, .c] {
        let morphemes = try tokenizer.tokenize(text: text, mode: mode)
        print("Mode \(mode): \(morphemes.map { $0.surface }.joined(separator: " | "))")
    }

    print("\nDetailed output (Mode A):")
    print("─────────────────────────")
    for m in try tokenizer.tokenize(text: text, mode: .a) {
        print("[\(m.surface)]")
        print("  Reading: \(m.readingForm)")
        print("  Dictionary form: \(m.dictionaryForm)")
        print("  Part of speech: \(m.partOfSpeech.joined(separator: "/"))")
    }

    print("\n=== Done ===")
} catch {
    print("Error: \(error)")
    exit(1)
}
