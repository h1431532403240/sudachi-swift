import Foundation
import SudachiSwift

// ===========================================
// SudachiSwift Basic Usage Example
// ===========================================
//
// Before running this example, you need to download a dictionary:
//   1. Get the download URL: print(getDictionaryDownloadUrl(dictType: .small, version: nil))
//   2. Download and extract the zip file
//   3. Update the dictionaryPath below to point to the .dic file
//

print("=== SudachiSwift Basic Usage ===\n")

// 1. Check library version
print("Library version: \(getVersion())")

// 2. List available dictionaries
print("\nAvailable dictionaries:")
for info in getAllDictionaryInfo(version: nil) {
    print("  - \(info.name): \(info.sizeMb)MB")
    print("    URL: \(info.downloadUrl)")
}

// 3. Tokenization example
//    Set SUDACHI_DICT_PATH environment variable or update dictionaryPath below
let dictionaryPath = ProcessInfo.processInfo.environment["SUDACHI_DICT_PATH"] ?? "path/to/system.dic"

guard FileManager.default.fileExists(atPath: dictionaryPath) else {
    print("\n[!] Dictionary not found at: \(dictionaryPath)")
    print("    Please download a dictionary first.")
    print("    Download URL: \(getDictionaryDownloadUrl(dictType: .small, version: nil))")
    exit(1)
}

do {
    // Create tokenizer with convenience API (uses bundled resources)
    let tokenizer = try Tokenizer.create(dictionaryPath: dictionaryPath)

    let text = "東京都に住んでいます"
    print("\nTokenizing: \"\(text)\"\n")

    // Tokenize with different modes
    for mode: TokenizeMode in [.a, .b, .c] {
        let morphemes = try tokenizer.tokenize(text: text, mode: mode)
        let surfaces = morphemes.map { $0.surface }
        print("Mode \(mode): \(surfaces.joined(separator: " | "))")
    }

    // Detailed output for Mode A
    print("\nDetailed output (Mode A):")
    print("─────────────────────────")
    let morphemes = try tokenizer.tokenize(text: text, mode: .a)
    for m in morphemes {
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
