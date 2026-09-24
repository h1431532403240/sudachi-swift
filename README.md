# SudachiSwift

[![Release](https://img.shields.io/github/v/release/h1431532403240/sudachi-swift?label=release&color=blue)](https://github.com/h1431532403240/sudachi-swift/releases/latest)
[![sudachi.rs](https://img.shields.io/badge/sudachi.rs-v0.7.0-orange)](https://github.com/WorksApplications/sudachi.rs/releases/tag/v0.7.0)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20macOS%20%7C%20Mac%20Catalyst%20%7C%20tvOS%20%7C%20visionOS-lightgrey)](#requirements)
[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen)](#installation)
[![License](https://img.shields.io/github/license/h1431532403240/sudachi-swift)](LICENSE)
[![Build](https://github.com/h1431532403240/sudachi-swift/actions/workflows/build.yml/badge.svg)](https://github.com/h1431532403240/sudachi-swift/actions/workflows/build.yml)

Swift bindings for [sudachi.rs](https://github.com/WorksApplications/sudachi.rs), a high-performance Japanese morphological analyzer written in Rust.

## Features

- Japanese morphological analysis with three tokenization modes (A: short, B: middle, C: long)
- Per-morpheme fields: surface, reading, dictionary form, normalized form, POS (6 levels), POS id, word id, dictionary id, synonym group ids, byte / codepoint offsets, total cost
- Sub-unit splitting (decompose a Mode C morpheme into Mode A units)
- Dictionary surface lookup (query normalized the same way as analyzer input)
- POS id ↔ POS components resolver
- Sentence splitting (rule-based and lexicon-aware)
- User dictionary support (multiple, in order)
- Dictionary format check (`dictionaryFormat(path:)`), so an app can detect a pre-0.7 dictionary before loading it
- Bundled `char.def` / `unk.def` / `rewrite.def` / `sudachi.json`, with sudachi.rs's built-in defaults as the fallback

## Requirements

- **Stable:** iOS 13.0+ / macOS 10.15+ / Mac Catalyst 13.0+
- **Nightly:** iOS 13.0+ / macOS 10.15+ / Mac Catalyst 13.0+ / tvOS 13.0+ / visionOS 1.0+ *(uses Rust nightly `-Z build-std` — treat as experimental)*
- Swift 5.9+
- A **V1-format** Sudachi dictionary `.dic` file, SudachiDict 20260723 or later (see [Dictionary Setup](#dictionary-setup)). The V0 dictionaries used with SudachiSwift 0.6.x don't load.

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/h1431532403240/sudachi-swift", exact: "0.7.0")
]
```

Or in Xcode: **File → Add Package Dependencies…**, paste the repository URL, and set **Dependency Rule** to **Exact Version** with the version shown above.

Pin the exact version. SudachiSwift versions follow sudachi.rs, and upstream calls 0.7.x an intermediate series before 1.0 in which "breaking behavioral changes may be introduced even in patch releases". SPM's `from:` and Xcode's default **Up to Next Major Version** rule both allow every version below the next major, which for a 0.x package means every later 0.x minor. For example, `from: "0.6.11"` already resolves to 0.7.0, and so does Up to Next Major Version from 0.6.11. If you're fine with patch-level behavior changes, use `.upToNextMinor(from: "0.7.0")` (Xcode: **Up to Next Minor Version**) instead.

**Upgrading from 0.6.x?** 0.7.0 needs new dictionaries. See [Upgrading from 0.6.x](#upgrading-from-06x).

For tvOS / visionOS as well (Tier 3 targets via the Rust nightly build):

```swift
dependencies: [
    .package(url: "https://github.com/h1431532403240/sudachi-swift", exact: "0.7.0-nightly")
]
```

The `-nightly` tag is a separate prerelease, published only when that release's nightly build succeeds. Check [Releases](https://github.com/h1431532403240/sudachi-swift/releases) for it.

The nightly visionOS Simulator slice is arm64 only, because Rust has no x86_64 visionOS target. A build for the generic visionOS Simulator destination also builds x86_64 and fails to link. Set `EXCLUDED_ARCHS[sdk=xrsimulator*] = x86_64` in your project's build settings or an `.xcconfig`. On the `xcodebuild` command line, pass `ARCHS=arm64` (or `EXCLUDED_ARCHS=x86_64`) instead, because the conditional `[sdk=…]` form doesn't work there.

SudachiSwift is distributed through Swift Package Manager only.

## Dictionary Setup

`SudachiSwift` ships the analyzer but not the dictionary. It loads **V1-format** dictionaries, which SudachiDict publishes starting with release 20260723:

| Distribution | Zip | Extracted `.dic` | Download (`latest`) |
|--------------|-----|------------------|---------------------|
| `.small` | ~42 MB | ~115 MB | https://d2ej7fkh96fzlu.cloudfront.net/sudachidict/v1/sudachi-dictionary-latest-small.zip |
| `.core` (recommended) | ~77 MB | ~202 MB | https://d2ej7fkh96fzlu.cloudfront.net/sudachidict/v1/sudachi-dictionary-latest-core.zip |
| `.full` | ~137 MB | ~331 MB | https://d2ej7fkh96fzlu.cloudfront.net/sudachidict/v1/sudachi-dictionary-latest-full.zip |

Each zip contains `sudachi-dictionary-<version>/system_<distribution>.dic` (plus `LEGAL` and `LICENSE-2.0.txt`). `latest` redirects to the newest V1 release. Replace `latest` with a version such as `20260723` to pin one. Prebuilt V1 dictionaries start at 20260723. Older prebuilt releases are V0 only and don't load, and their `/v1/` URLs return HTTP 404. The zips under the old `/sudachidict/` path (without `/v1/`) and the ones attached to SudachiDict's GitHub releases are V0 as well. Upstream publishes [V1 lexicon sources](https://d2ej7fkh96fzlu.cloudfront.net/sudachidict-raw/v1/) for 20260428 (and 20260723) if you need to build one yourself.

SudachiDict is licensed under Apache-2.0 and contains UniDic data under BSD-3-Clause, plus other attributions listed in the zip's `LEGAL` file ([also on GitHub](https://github.com/WorksApplications/SudachiDict/blob/develop/LEGAL)). If your app ships the `.dic`, for example in its bundle, include `LEGAL` and `LICENSE-2.0.txt` in its acknowledgements.

```swift
import Foundation
import SudachiSwift

// Discover what to download
for dist in SudachiDictDistribution.allCases {
    print("\(dist) (~\(dist.sizeMB) MB) → \(dist.downloadURL())")
}

let dist: SudachiDictDistribution = .core
let dicURL = SudachiDictionaryStore.dictionaryPath(for: dist)  // .../Application Support/SudachiSwift/system_core.dic
if !SudachiDictionaryStore.isInstalled(dist) {  // false when the file is missing or a V0 leftover
    // Download dist.downloadURL() (or dist.downloadURL(version: "20260723"))
    // and extract system_core.dic from the zip. Then move it into place:
    let extracted = URL(fileURLWithPath: "/path/to/extracted/system_core.dic")
    let fm = FileManager.default
    try fm.createDirectory(at: dicURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fm.fileExists(atPath: dicURL.path) {
        try fm.removeItem(at: dicURL)  // e.g. a V0 file left over from SudachiSwift 0.6.x
    }
    try fm.moveItem(at: extracted, to: dicURL)
    // Large and re-downloadable: keep it out of iCloud / device backups
    var installed = dicURL
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try installed.setResourceValues(values)
}
let tokenizer = try Tokenizer.create(dictionaryPath: dicURL.path)
```

Nothing replaces an old file for you: the folder doesn't exist before the first install, and `moveItem` fails when a file is already at `dicURL`. Create the folder, then delete the old file before moving the new one in, as above. `FileManager.replaceItemAt` can do the delete and move in one step. Don't unzip or write over the existing `.dic` in place instead (see [Trusted input](#trusted-input)).

The last lines of the snippet exclude the dictionary from backups. On iOS, Application Support is included in iCloud and device backups, and Apple's [iCloud backup guidance](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup) says to exclude large files that the user can download again. The flag belongs to the file, not the path, so set it after every install.

On macOS, a non-sandboxed app or command-line tool gets `~/Library/Application Support/SudachiSwift/` as `SudachiDictionaryStore.defaultDirectory`, and every such program on the Mac shares it. (A sandboxed app gets its own container.) The snippet above replaces a V0 file it finds there, and an app on the same Mac that still uses SudachiSwift 0.6.x needs that file. If that matters, install into your own directory: pass it to `dictionaryPath(for:in:)` and `isInstalled(_:in:)`, and to `createTokenizer(in: [directory])` if you use it.

The library does not download or unzip on your behalf. Use `URLSession` and any zip library (e.g. ZIPFoundation), and check the HTTP status before unzipping. SudachiDict publishes no checksums. When you pin a version, record the zip's SHA-256 yourself and compare downloads against it, or at least check for HTTP 200 and the expected size (the 20260723 small zip is 42,480,336 bytes). Load dictionaries only from sources you trust (see [Trusted input](#trusted-input)). If a `.dic` came from somewhere else, check it with `dictionaryFormat(path:)` first (`.v1` is the only format this version loads). On a development machine, upstream's script in the `sudachi.rs` submodule does the download and extraction. It needs a recursive clone of this repo (or `git submodule update --init` in an existing clone): `sh sudachi.rs/fetch_dictionary.sh 20260723 core v1` writes `./system.dic`. An optional fourth argument checks the zip against a SHA-256 you recorded.

## Usage

### Tokenization

```swift
let tokenizer = try Tokenizer.create(dictionaryPath: "/path/to/system.dic")
let morphemes = try tokenizer.tokenize(text: "東京都に住んでいます", mode: .c)

for m in morphemes {
    print("\(m.surface)\t\(m.readingForm)\t\(m.partOfSpeech.joined(separator: "/"))")
}
```

One `tokenize`, `tokenizeWithSubunits` or `lookup` call takes at most 49,149 UTF-8 bytes (about 16,000 Japanese characters). The limit is 65,535 bytes after input normalization, which can make text longer (`㍿` becomes `株式会社`). Longer input throws `SudachiError.TokenizeError` ("Input is too long …"). Split long text with `splitSentences(text:)` first and tokenize one sentence at a time. A range can still be longer than the limit: when no sentence ends within 4,096 characters (for example text separated only by line breaks), the rest of the text comes back as one range, so check `range.text.utf8.count` and cut such a range further (for example at line breaks) before tokenizing.

### Tokenization modes

```swift
// Results with the core dictionary
let text = "国家公務員"
try tokenizer.tokenize(text: text, mode: .a)  // ["国家", "公務", "員"]
try tokenizer.tokenize(text: text, mode: .b)  // ["国家", "公務員"]
try tokenizer.tokenize(text: text, mode: .c)  // ["国家公務員"]
```

### Sub-unit splitting

Tokenize at Mode C and split each result into Mode A sub-units in one call (mirrors `Morpheme.split(mode, add_single)` in sudachipy):

```swift
let nested = try tokenizer.tokenizeWithSubunits(
    text: "国家公務員はラーメンを食べた",
    mode: .c,
    subMode: .a,
    addSingle: true
)
for entry in nested {
    let subs = entry.subunits.map(\.surface).joined(separator: "+")
    print("\(entry.morpheme.surface) → \(subs)")  // core dictionary: "国家公務員 → 国家+公務+員", "は → は", ...
}
```

When `addSingle` is `false`, morphemes that can't split further get an empty `subunits` array instead of a single-element fallback.

### Sentence splitting

```swift
// Rule-based, no dictionary required
for range in splitSentences(text: "テスト。テスト2。最後の文") {
    print(range.text)  // "テスト。", "テスト2。", "最後の文"
}

// Lexicon-aware (tries not to break inside known multi-character expressions)
for range in tokenizer.splitSentences(text: "東京都に住んでいます。今日は良い天気です。") {
    print(range.text)
}
```

> **Known upstream issues:**
>
> - **Lexicon-aware splitting (sudachi.rs 0.6.11 and 0.7.0):** the lexicon check treats a boundary as "inside a word" whenever the closing punctuation (e.g. `。`, itself a dictionary entry) is followed by more text. In practice `tokenizer.splitSentences(text:)` returns the example above as a single range. Use the rule-based `splitSentences(text:)` until this is fixed upstream.
> - **ASCII double quotes (sudachi.rs 0.7.0):** upstream now treats `"` as both an opening and a closing bracket, so after the first `"` in the text nothing splits (`彼は"はい"と言った。次の文です。` comes back as one sentence). The rule-based `splitSentences(text:)` works around this: it runs the splitter with every `"` replaced by `'` and returns ranges and `text` from your original string, so it gives the same results as 0.6.11 and Java Sudachi (two sentences here). `tokenizer.splitSentences(text:)` still has the upstream behavior.

### Dictionary lookup

```swift
// Every dictionary entry whose surface matches the query
let entries = try tokenizer.lookup(query: "東京")
for e in entries {
    print("\(e.surface) [\(e.partOfSpeech.joined(separator: "/"))]")
}

// Resolve a part-of-speech id back to its components
if let pos = tokenizer.posOf(posId: entries[0].partOfSpeechId) {
    print(pos)  // ["名詞", "固有名詞", "地名", "一般", "*", "*"]
}

// The query is normalized like analyzer input first, so "ＡＢＣ" and "ABC" both
// find the "abc" entries. `surface` and offsets refer to the normalized text.
try tokenizer.lookup(query: "ＡＢＣ").map(\.surface)  // ["abc", "abc"]
```

### Morpheme information

```swift
let m = try tokenizer.tokenize(text: "食べる", mode: .c)[0]

m.surface          // "食べる"
m.readingForm      // "タベル"
m.dictionaryForm   // "食べる"
m.normalizedForm   // "食べる"
m.partOfSpeech     // ["動詞", "一般", "*", "*", "下一段-バ行", "終止形-一般"]
m.partOfSpeechId   // numeric POS id, resolvable via tokenizer.posOf(posId:)
m.wordId           // encoded WordId (dict + entry)
m.dictionaryId     // 0 = system, ≥1 = user (in the order given), -1 = OOV
m.synonymGroupIds  // [Int32]
(m.begin, m.end)          // UTF-8 byte offsets in the input
(m.beginChar, m.endChar)  // Unicode codepoint offsets (matches sudachipy's begin/end)
m.totalCost        // path cost
m.isOov            // out-of-vocabulary flag
```

`partOfSpeechId` and `wordId` only mean something for the dictionary file that produced them. Store `partOfSpeech` / surface forms if you persist results across dictionary updates.

When input normalization expands one character into several morphemes, the extra ones have an empty `surface` and `begin == end` (`…` gives three morphemes). The fields don't identify a morpheme uniquely, so identify it by its position in the result, e.g. `ForEach(Array(morphemes.enumerated()), id: \.offset)` in SwiftUI.

> Note: Swift's `String` is grapheme-indexed. Use `.utf8` view + `m.begin..<m.end` for byte slicing, or `.unicodeScalars` + `m.beginChar..<m.endChar` for codepoint slicing.

### Multiple user dictionaries

```swift
let tokenizer = try Tokenizer.create(
    dictionaryPath: "/path/to/system_core.dic",
    userDictionaryPaths: ["/path/to/user_a.dic", "/path/to/user_b.dic"]
)
```

Mirrors the `userDict` array in `sudachi.json`. Entries get `dictionaryId` 1, 2, … in the order given (after any `userDict` entries from a custom config file). Pass absolute paths: a relative path is resolved like the resource files (see [Advanced configuration](#advanced-configuration)), not against the system `.dic`'s folder. Each user dictionary must be a V1 dictionary built against this exact system `.dic` file: the check compares the system dictionary's signature, so the same release and distribution from another source (e.g. the PyPI `sudachidict_*` packages, a separate build) does not count. `sudachi dump <file> description <out>` shows a dictionary's Signature / Reference. Otherwise loading throws `SudachiError.DictionaryLoadError` ("… not compatible with the system dictionary"). Build one with the sudachi.rs 0.7 CLI (`cargo install --locked --path sudachi.rs/sudachi-cli` from a recursive clone of this repo):

```bash
sudachi ubuild -s system_core.dic -o user.dic user.csv
```

For converting old user dictionaries, see Sudachi's [user dictionary migration guide](https://github.com/WorksApplications/Sudachi/blob/develop/docs/migrate_user_dictionary.md). The CSV format is in the [V1 user dictionary format reference](https://github.com/WorksApplications/Sudachi/blob/develop/docs/user_dict_v1.md). Both are in Japanese.

### Advanced configuration

For full control over config / resource paths:

```swift
let tokenizer = try Tokenizer(config: TokenizerConfig(
    dictionaryPath: "/path/to/system.dic",
    configPath: "/path/to/custom/sudachi.json",  // nil → sudachi.rs's built-in default config
    resourcePath: "/path/to/resources",           // nil → see resolution order below
    userDictionaryPaths: []
))
```

`char.def` / `unk.def` / `rewrite.def` are resolved in sudachi.rs order: `resourcePath`, then the config's `path` field, then the directory containing `configPath`, then defaults built into sudachi.rs. The `.dic`'s own directory is not searched, so a custom `char.def` needs one of the first three. A `resourcePath` that doesn't exist, or lacks one of the files, is not an error: that file silently comes from the next location, in the end from the built-in defaults. `Tokenizer.create` passes the bundled `SudachiResources.configPath` / `SudachiResources.resourceDirectory`. `Tokenizer.withDictionary(dictionaryPath:)` passes `nil` for both and runs on the built-in defaults, so a bare `.dic` is enough.

Relative dictionary paths (`dictionaryPath` and `userDictionaryPaths`) are looked up the same way: in `resourcePath`, the config's `path` field and the directory containing `configPath`, then in the current working directory. They are not resolved against the system `.dic`'s folder, so use absolute paths. An empty `dictionaryPath` throws `SudachiError.InvalidArgument`.

#### Trusted input

Dictionaries and config files are trusted input. sudachi.rs doesn't guard against malicious ones:

- A crafted or tampered `.dic` can crash the process (e.g. a segmentation fault on the first `tokenize`) instead of throwing. Load dictionaries only from sources you trust, such as the SudachiDict CDN over HTTPS or your own builds.
- A plugin `class` in a config file that isn't one of sudachi.rs's built-in `com.worksap.nlp.sudachi.*` plugins is loaded as a native library, and its code runs inside your process. Pass only a `configPath` you control.
- A loaded `.dic` is memory-mapped. Replace it by rename: delete the old file and move the new one in, or use `FileManager.replaceItemAt`. Never unzip or write over the file in place while a `Tokenizer` uses it, because truncating or overwriting it crashes the process on the next call. An existing `Tokenizer` keeps using the old file until you create a new one.

### Error handling

```swift
do {
    let tokenizer = try Tokenizer.create(dictionaryPath: "/path/to/system.dic")
    let morphemes = try tokenizer.tokenize(text: "東京都に住んでいます", mode: .c)
    print(morphemes.map(\.surface))
} catch let error as SudachiError {
    print(error.message)  // the bare message, suitable for UI
} catch {
    print(error)          // an internal failure, e.g. a Rust panic
}
```

Show `error.message` rather than `localizedDescription`, which is UniFFI's debug dump (`SudachiSwift.SudachiError.DictionaryLoadError(message: "…")`). Keep the generic `catch`: an internal failure such as a Rust panic surfaces as an `Error` that isn't a `SudachiError`, and the process keeps running.

## Upgrading from 0.6.x

SudachiSwift 0.7.0 moves to [sudachi.rs 0.7.0](https://github.com/WorksApplications/sudachi.rs/releases/tag/v0.7.0). Upstream's [migration guide](https://github.com/WorksApplications/sudachi.rs/blob/v0.7.0/docs/migration_guide.md) (Japanese) has the details. What changes for Swift users:

**Package resolution**

- `.package(url: …, from:)` with any 0.x version (the 0.6.x README suggested `from: "0.1.0"`), or Xcode's default **Up to Next Major Version** rule, moves to 0.7.0 on your next package update. To stay on 0.6, pin `exact: "0.6.11"` (Xcode: **Exact Version** 0.6.11). To move, pin the exact version shown under [Installation](#installation) and replace your dictionaries at the same time.
- If the first build after updating fails with `file '…/sudachi_swiftFFI.h' has been modified since the module file '…' was built`, clean once: in Xcode, **Product → Clean Build Folder** (or delete DerivedData); with SwiftPM, `swift package clean`. The cached precompiled module isn't rebuilt when the package's C header changes, so building again without cleaning fails the same way.

**Dictionaries**

- **V1 dictionaries only.** A V0 `.dic` (everything SudachiSwift 0.6.x loaded) now throws `SudachiError.DictionaryLoadError` saying it is a legacy V0 dictionary. `dictionaryFormat(path:)` returns `.v1`, `.legacyV0` or `.unknown` without loading the file.
- **New download location.** `SudachiDictDistribution.downloadURL(version:)` now points at the `/sudachidict/v1/` CDN path. Update any hard-coded URL: the old path serves V0 files, and SudachiDict's GitHub releases no longer carry the dictionary zips. `sizeMB` now reports the V1 zip sizes (42 / 77 / 137).
- **Delete old files before installing new ones.** `SudachiDictionaryStore.isInstalled(_:in:)` returns `true` only for a V1 file, so a V0 file left from 0.6.x counts as not installed and a "download if not installed" flow runs again. Nothing replaces the old file: create the folder if needed, then delete any file already at `dicURL` before moving the new `.dic` in (or use `FileManager.replaceItemAt`), as in [Dictionary Setup](#dictionary-setup). V0 files under other names stay on disk until you delete them. `findDictionary(in:)`, and so `createTokenizer(in:)`, prefers V1 files and returns another match only when no V1 file exists, in which case `createTokenizer(in:)` throws the V0 error.
- **Rebuild user dictionaries.** They must be V1 and built against the exact system `.dic` you load them with. Do this again every time you update the system dictionary (see [Multiple user dictionaries](#multiple-user-dictionaries)).
- **Custom `char.def`.** The `NOOOVBOW2` category was removed. Replace it with `NOOOVBOW NOOOVEOW`. A `char.def` that still uses it fails to load with `SudachiError.DictionaryLoadError` ("Invalid character category definition: Invalid type NOOOVBOW2 at line …"). The bundled `char.def` is already updated.

**API**

- `MorphemeInfo.synonymGroupIds` is `[Int32]` (was `[UInt32]`).
- `MorphemeInfo` no longer conforms to `Identifiable`. Its `id` (`"\(begin)-\(end)-\(surface)"`) wasn't unique: when normalization expands one character into several morphemes, the extra ones share an empty surface at the same offset (`…` gives ids `0-3-…`, `3-3-`, `3-3-`), and `lookup(query:)` returns homographs with the same surface and offsets. SwiftUI's `ForEach(morphemes)` then logged "the ID … occurs multiple times" and could render wrong rows. Identify morphemes by position instead: `ForEach(Array(morphemes.enumerated()), id: \.offset) { Text($0.element.surface) }`.
- `lookup(query:)` normalizes the query with the dictionary's input-text plugins before searching, the same way as analyzer input: width and case folding (`"ＡＢＣ"` finds `abc`), collapsing repeated `ー` (`ラーーメン` finds `ラーメン`), removing readings in parentheses (`今日（きょう）` finds `今日`), and the `rewrite.def` mappings. Returned `surface` / offsets refer to the normalized query, not your input string. Java Sudachi returns the entry's headword instead (`ＫＤＤＩ` gives `kddi` here and `KDDI` in Java).
- Resources resolve in sudachi.rs order: `resourcePath`, then the config `path` field, then the config file's directory, then built-in defaults. The `.dic`'s directory is no longer searched, and `Tokenizer.withDictionary(dictionaryPath:)` now works with a bare `.dic` (see [Advanced configuration](#advanced-configuration)).
- A `resourcePath` that doesn't exist, or lacks one of the files, no longer throws. The missing files silently fall back to the next location and, in the end, to the built-in defaults.
- Relative `userDictionaryPaths` are resolved like resources (`resourcePath`, the config `path` field, the config file's directory, then the working directory), no longer against the system `.dic`'s folder. Use absolute paths.
- An empty `dictionaryPath` throws `SudachiError.InvalidArgument`. Before, it resolved to the resources folder and failed with "Invalid argument (os error 22)". A config file that can't be loaded gives an error message that starts with the config file's path.
- New: `dictionaryFormat(path:)` and `DictionaryFormat`; `SudachiDictionaryStore.createTokenizer(in:)`, which searches your own directories as `findDictionary(in:)` does; `SudachiError.message`, the message without the case name (see [Error handling](#error-handling)).

**Analysis results**

- POS ids and word ids are renumbered in V1 dictionaries. Don't persist `partOfSpeechId` / `wordId` across dictionary builds.
- Upstream algorithm fixes change segmentation for some inputs: `NOOOVBOW` / `NOOOVEOW` handling ([#325](https://github.com/WorksApplications/sudachi.rs/pull/325)) and character-category run length ([#326](https://github.com/WorksApplications/sudachi.rs/pull/326)). In 0.6.x, a dictionary word could not start at `ー`, `々`, a small kana or an emoji skin-tone modifier. Examples:
  - A hiragana word followed by `ー` or `〜`: `ありがとー` was `あり|が|と|ー` and is now `ありがと|ー` (感動詞, normalized form 有り難う). `よろしくー` was `よろし|く|ー` and is now `よろしく|ー`. 10 of the 63 casual expressions with `ー` / `〜` we tried changed.
  - Repeated `々`: `代々々` was `代|々々` and is now `代々|々`.
  - An emoji with a skin-tone modifier is now one token: `👍🏻` was `👍|🏻`.

  Part of speech and normalized / reading / dictionary forms change with the segmentation, and a few spans change POS or forms without a segmentation change (in `すっごーい`, `ご` is now a prefix, normalized 御, instead of an OOV noun). `totalCost` changes on these spans too. On a mixed 1,292-line test corpus, about 0.4% of lines changed segmentation, and 0.7.0's results matched Java Sudachi 0.8.2 on every line. Re-check golden outputs and search indexes built from 0.6.x results.
- Numbers joined by `JoinNumericPlugin` now carry an OOV-style `wordId` instead of `UInt32.max`. Numbers written with grouping commas keep the comma in `readingForm`: `1,280` reads `イチ,ニハチレイ` (was `イチニハチレイ`), and `１，０００` reads `イチ,レイレイレイ`. The reading changes for every comma-grouped number and for no other number, and Java Sudachi reads them the same way. Remove the commas if you show readings as furigana or pass them to text-to-speech.
- `JoinKatakanaOovPlugin` now reuses an existing lattice node that covers the joined span, picking the one with the lowest node cost ([#323](https://github.com/WorksApplications/sudachi.rs/pull/323)), and otherwise marks the joined word as OOV. Joined katakana OOVs that 0.6.x reported with `isOov == false` and `dictionaryId == 0` (with the small dictionary, e.g. `ワンピース` and `オンライン`) now report `isOov == true` and `dictionaryId == -1`, with a different `wordId` and `totalCost`. When a dictionary word is reused, the result gets that word's part of speech and reading / normalized forms.
- Strings that start with U+FEFF (a byte order mark), such as the `surface` of a morpheme or the `text` of a sentence at the start of the input, now keep it. 0.6.x dropped it from the string while `begin` / `end` still counted it.
- The rule-based `splitSentences(text:)` gives the same results as 0.6.11, including around ASCII `"`, because SudachiSwift works around an upstream 0.7.0 change (see [Sentence splitting](#sentence-splitting)).

## API Reference

### Free functions

| Function | Description |
|----------|-------------|
| `getVersion() -> String` | Wrapper version (matches the pinned upstream sudachi.rs release) |
| `splitSentences(text:) -> [SentenceRange]` | Rule-based sentence splitting (no dictionary), with a workaround for upstream 0.7.0's ASCII `"` handling (see [Sentence splitting](#sentence-splitting)) |
| `dictionaryFormat(path:) -> DictionaryFormat` | Reads only the `.dic` header and reports its format |

### `Tokenizer`

| Member | Description |
|----------|-------------|
| `Tokenizer.create(dictionaryPath:userDictionaryPaths:)` | Convenience constructor using the bundled `sudachi.json` and resources |
| `Tokenizer.withDictionary(dictionaryPath:)` | System dictionary only, with sudachi.rs's built-in config and resources |
| `init(config: TokenizerConfig)` | Explicit configuration |
| `tokenize(text:mode:)` | Returns `[MorphemeInfo]`. Input limit: 49,149 UTF-8 bytes (see [Tokenization](#tokenization)) |
| `tokenizeWithSubunits(text:mode:subMode:addSingle:)` | Bulk tokenize + per-morpheme split |
| `lookup(query:)` | Entries whose surface equals the normalized query |
| `posOf(posId:)` | Resolve POS id to `[String]?` components |
| `splitSentences(text:)` | Lexicon-aware sentence splitting (see the [known issue](#sentence-splitting)) |

Throwing members throw `SudachiError` (`.DictionaryLoadError`, `.ConfigError`, `.TokenizeError`, `.InvalidArgument`). Its `message` property returns the message without the case name. Internal failures can surface as another `Error` type (see [Error handling](#error-handling)).

### `DictionaryFormat`

| Case | Meaning |
|------|---------|
| `.v1` | Binary format V1, the only format this version loads |
| `.legacyV0` | Pre-0.7 format. Download a V1 build and rebuild user dictionaries against it |
| `.unknown` | Missing, unreadable, or not a Sudachi dictionary |

### `SudachiDictDistribution`

| Case | Zip | `.dic` | Use |
|------|-----|--------|-----|
| `.small` | ~42 MB | ~115 MB | Minimum vocabulary |
| `.core` | ~77 MB | ~202 MB | Basic vocabulary (recommended) |
| `.full` | ~137 MB | ~331 MB | Complete vocabulary |

Each exposes `sizeMB` (approximate zip size), `dicFilename` (`system_<distribution>.dic`), and `downloadURL(version:)` (V1 zip on the CDN; `nil` means `latest`).

### `SudachiDictionaryStore`

Pure Swift helpers for locating user-installed `.dic` files. `defaultDirectory` points at `Application Support/SudachiSwift/`, and `dictionaryPath(for:in:)` gives the conventional file path inside it. Neither is created for you. `isInstalled(_:in:)` is `true` only if a V1 dictionary exists at that path. `findDictionary(in:)` looks for `system.dic` / `system_<distribution>.dic` in caller-supplied paths, then the default directory, then the host app's main bundle, and returns the first V1 file. Only when no V1 file exists does it return the first other match. `createTokenizer(in:)` loads the file `findDictionary(in:)` returns for the same paths, and throws `SudachiError.DictionaryLoadError` if none is found or the file is V0. If you install into your own directory, pass it to `createTokenizer(in:)` as well; `createTokenizer()` only searches the default directory and the main bundle. On macOS, non-sandboxed apps share the default directory (see [Dictionary Setup](#dictionary-setup)). On iOS, exclude the installed file from backup.

## Examples

The [Examples/](Examples/) directory ships two runnable demos:

- **`BasicUsage`**: macOS command-line tokenization
- **`iOSApp`**: iOS SwiftUI app

```bash
cd Examples/BasicUsage
SUDACHI_DICT_PATH=/path/to/system.dic swift run BasicUsage
```

## Development

The project pins the official [sudachi.rs](https://github.com/WorksApplications/sudachi.rs) repository as a git submodule, pinned to an upstream release tag (shown in the badge at the top). Apple platforms support landed upstream in [v0.6.11](https://github.com/WorksApplications/sudachi.rs/releases/tag/v0.6.11) via [PR #308](https://github.com/WorksApplications/sudachi.rs/pull/308).

### Repository layout

```
rust/                          # Rust UniFFI wrapper crate
├── Cargo.toml
└── src/lib.rs

sudachi.rs/                    # git submodule, pinned to an upstream tag
Sources/SudachiSwift/          # Swift package source
├── SudachiSwift.swift         # Hand-written extensions
├── sudachi_swift.swift        # UniFFI-generated bindings (committed by release.yml)
└── Resources/                 # Sudachi runtime data (char.def, sudachi.json, ...)

Package.swift                  # Single SPM manifest, used by both external
                               # consumers and local contributors
scripts/build-local.sh         # Builds XCFramework + stages bindings locally
scripts/generate-third-party-notices.py
                               # Regenerates THIRD_PARTY_NOTICES.md from rust/Cargo.lock
tests/spm-consumer/            # CI fixture that builds the package as an external consumer
```

### Building from source

```bash
git clone --recursive https://github.com/h1431532403240/sudachi-swift
cd sudachi-swift

rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin
cargo install cargo-swift --version 0.11.1 --locked

cargo test --manifest-path rust/Cargo.toml   # Rust wrapper tests (uses the submodule's test dictionaries)
./scripts/build-local.sh                     # produces SudachiSwift.xcframework + sudachi_swift.swift
swift build
cd Examples/BasicUsage && SUDACHI_DICT_PATH=/path/to/system.dic swift run BasicUsage
```

`build-local.sh` requires cargo-swift **0.11.1** exactly. cargo-swift generates the Swift bindings with its own bundled `uniffi_bindgen`, and that has to match the uniffi version the crate is compiled with (`=0.31.1` in `rust/Cargo.toml`). The script then patches the generated `sudachi_swift.swift` to decode strings with `String(decoding:as: UTF8.self)` instead of `String(bytes:encoding:)`, which drops a leading U+FEFF.

Regenerate `THIRD_PARTY_NOTICES.md` with `python3 scripts/generate-third-party-notices.py` whenever `rust/Cargo.lock` changes. With `--check`, it exits non-zero if the file is out of date.

The root `Package.swift` auto-detects the local `SudachiSwift.xcframework` and falls back to the published release zip when it's absent, so the same manifest serves both contributors and external SPM users.

### Version sync with upstream

`.github/workflows/check-upstream.yml` runs daily. It can also be started by hand, with a `dry_run` option. It looks up the highest stable release of WorksApplications/sudachi.rs (by version number, not GitHub's "Latest" label). When that release is newer than the pinned submodule tag, the workflow:

- runs `cargo check` of `rust/` against it in a read-only job,
- opens a tracking issue assigned to the maintainer with the `cargo check` result, and
- opens a PR from `automation/sudachi-rs-<tag>` that bumps the submodule, syncs the `rust/Cargo.toml` version, refreshes the bundled resources and `rust/Cargo.lock`, and updates the `exact:` install pins (this README and the example manifests) plus the sudachi.rs badge. The PR is a draft when the bump is breaking (a new major, or a new minor while on 0.x) or when `rust/` doesn't compile.

Each release is handled once. Once its tracking issue exists, open or closed, the workflow doesn't open another issue or PR for that release, and it never pushes to an existing bump branch, so migration commits you push there are safe. Close the issue to skip the release. When a newer release arrives while older tracking issues are still open, the new issue lists them and they get a "superseded" comment.

Opening the PR needs one of these:

- **Settings → Actions → General → Workflow permissions → Allow GitHub Actions to create and approve pull requests**, or
- an `UPSTREAM_BOT_TOKEN` secret: a fine-grained personal access token for this repository with **Contents** and **Pull requests** read/write.

Without the secret, the PR is opened with `GITHUB_TOKEN`, and its `pull_request` CI would wait for approval. The workflow therefore dispatches `build.yml` on the bump branch instead. With neither, the branch is still pushed and the tracking issue gets a comment with a compare link to open the PR by hand.

The workflow also opens an issue when the check itself fails. GitHub disables scheduled workflows after 60 days without repository activity, so once the last commit on the default branch is 45 or more days old, the workflow re-enables itself daily through the REST API (a best-effort keepalive: GitHub doesn't document whether that resets the timer) and opens a warning issue.

Merging the PR publishes nothing. To ship, run the **Release** workflow (`release.yml`) from `main` with the new version. It stops unless the version equals `version` in `rust/Cargo.toml`, which the bump PR sets. The stable release is published right after its tag is pushed. When the Rust nightly build succeeds, a separate `<version>-nightly` prerelease follows; its tag is not on `main`.

## License

Apache-2.0. See [LICENSE](LICENSE).

This project wraps [sudachi.rs](https://github.com/WorksApplications/sudachi.rs), also licensed under Apache-2.0.

The prebuilt XCFramework statically links sudachi.rs and other third-party Rust crates. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists them with their licenses and the notices that must go with the binary, including MIT, ISC and Unlicense notices and where to get the source of the MPL-2.0 `uniffi` crates. Include it in your app's acknowledgements.

Dictionaries are licensed separately. See [Dictionary Setup](#dictionary-setup) for SudachiDict's license and attributions.
