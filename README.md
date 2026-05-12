# SudachiSwift

[![Release](https://img.shields.io/github/v/release/h1431532403240/sudachi-swift?label=release&color=blue)](https://github.com/h1431532403240/sudachi-swift/releases/latest)
[![sudachi.rs](https://img.shields.io/badge/sudachi.rs-v0.6.11-orange)](https://github.com/WorksApplications/sudachi.rs/releases/tag/v0.6.11)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20visionOS-lightgrey)](#requirements)
[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen)](#installation)
[![License](https://img.shields.io/github/license/h1431532403240/sudachi-swift)](LICENSE)
[![Build](https://github.com/h1431532403240/sudachi-swift/actions/workflows/build.yml/badge.svg)](https://github.com/h1431532403240/sudachi-swift/actions/workflows/build.yml)

Swift bindings for [sudachi.rs](https://github.com/WorksApplications/sudachi.rs), a high-performance Japanese morphological analyzer written in Rust.

## Features

- Japanese morphological analysis with three tokenization modes (A: short, B: middle, C: long)
- Per-morpheme fields: surface, reading, dictionary form, normalized form, POS (6 levels), POS id, word id, dictionary id, synonym group ids, byte / codepoint offsets, total cost
- Sub-unit splitting (decompose a Mode C morpheme into Mode A units)
- Dictionary surface lookup
- POS id ↔ POS components resolver
- Sentence splitting (rule-based and lexicon-aware)
- User dictionary support (multiple, in order)
- Bundled `char.def` / `unk.def` / `sudachi.json`

## Requirements

- **Stable:** iOS 13.0+ / macOS 10.15+
- **Nightly:** iOS 13.0+ / macOS 10.15+ / tvOS 13.0+ / visionOS 1.0+ *(uses Rust nightly `-Z build-std` — treat as experimental)*
- Swift 5.9+
- A Sudachi dictionary `.dic` file (see [Dictionary Setup](#dictionary-setup))

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/h1431532403240/sudachi-swift", from: "0.6.11")
]
```

For all Apple platforms (tvOS / visionOS via the Tier 3 nightly build):

```swift
dependencies: [
    .package(url: "https://github.com/h1431532403240/sudachi-swift", exact: "0.6.11-nightly")
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste the repository URL.

## Dictionary Setup

`SudachiSwift` ships the analyzer, not the dictionary (`.dic` files are 50 MB – 1 GB). Download a SudachiDict release, extract the `.dic`, and point `Tokenizer.create` at it.

```swift
import SudachiSwift

// Discover what to download
for dist in SudachiDictDistribution.allCases {
    print("\(dist) (~\(dist.sizeMB) MB) → \(dist.downloadURL())")
}

// After downloading + extracting, place the .dic somewhere your app can read
let tokenizer = try Tokenizer.create(dictionaryPath: "/path/to/system.dic")
```

`SudachiDictDistribution` cases — `.small` (~50 MB), `.core` (~70 MB, recommended), `.full` (~1 GB). The library does not download or unzip on your behalf; use `URLSession` and any zip library (e.g. ZIPFoundation) for that, then let `SudachiDictionaryStore.findDictionary()` locate the result.

## Usage

### Tokenization

```swift
let tokenizer = try Tokenizer.create(dictionaryPath: "/path/to/system.dic")
let morphemes = try tokenizer.tokenize(text: "東京都に住んでいます", mode: .c)

for m in morphemes {
    print("\(m.surface)\t\(m.readingForm)\t\(m.partOfSpeech.joined(separator: "/"))")
}
```

### Tokenization modes

```swift
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
    print("\(entry.morpheme.surface) → \(subs)")
}
```

When `addSingle` is `false`, morphemes that can't split further get an empty `subunits` array instead of a single-element fallback.

### Sentence splitting

```swift
// Rule-based, no dictionary required
for range in splitSentences(text: "テスト。テスト2。最後の文") {
    print(range.text)
}

// Lexicon-aware (avoids breaking inside known multi-character expressions)
for range in tokenizer.splitSentences(text: "東京都に住んでいます。今日は良い天気です。") {
    print(range.text)
}
```

### Dictionary lookup

```swift
// Exact-surface lookup (every entry whose surface matches the query)
let entries = try tokenizer.lookup(query: "東京")
for e in entries {
    print("\(e.surface) [\(e.partOfSpeech.joined(separator: "/"))]")
}

// Resolve a part-of-speech id (e.g. one stored elsewhere) back to its components
if let pos = tokenizer.posOf(posId: entries[0].partOfSpeechId) {
    print(pos)  // ["名詞", "固有名詞", "地名", "一般", "*", "*"]
}
```

### Morpheme information

```swift
let m = try tokenizer.tokenize(text: "食べる", mode: .c)[0]

m.surface          // "食べる"
m.readingForm      // "タベル"
m.dictionaryForm   // "食べる"
m.normalizedForm   // "食べる"
m.partOfSpeech     // ["動詞", "一般", "*", "*", "五段-バ行", "終止形-一般"]
m.partOfSpeechId   // numeric POS id, resolvable via tokenizer.posOf(posId:)
m.wordId           // encoded WordId (dict + entry)
m.dictionaryId     // 0 = system, ≥1 = user, -1 = OOV
m.synonymGroupIds  // [UInt32]
m.begin / m.end             // UTF-8 byte offsets in the input
m.beginChar / m.endChar     // Unicode codepoint offsets (matches sudachipy's begin/end)
m.totalCost        // path cost
m.isOov            // out-of-vocabulary flag
```

> Note: Swift's `String` is grapheme-indexed. Use `.utf8` view + `m.begin..<m.end` for byte slicing, or `.unicodeScalars` + `m.beginChar..<m.endChar` for codepoint slicing.

### Multiple user dictionaries

```swift
let tokenizer = try Tokenizer.create(
    dictionaryPath: "/path/to/system.dic",
    userDictionaryPaths: ["/path/to/user_a.dic", "/path/to/user_b.dic"]
)
```

Mirrors the `userDict` array in `sudachi.json`. Lower-indexed dictionaries take precedence.

### Advanced configuration

For full control over config / resource paths:

```swift
let tokenizer = try Tokenizer(config: TokenizerConfig(
    dictionaryPath: "/path/to/system.dic",
    configPath: "/path/to/custom/sudachi.json",  // nil → use bundled defaults
    resourcePath: "/path/to/resources",           // nil → derive from configPath / dictionaryPath
    userDictionaryPaths: []
))
```

## API Reference

### Free functions

| Function | Description |
|----------|-------------|
| `getVersion() -> String` | Wrapper version (matches the pinned upstream sudachi.rs release) |
| `splitSentences(text:) -> [SentenceRange]` | Rule-based sentence splitting (no dictionary) |

### `Tokenizer`

| Member | Description |
|----------|-------------|
| `Tokenizer.create(dictionaryPath:userDictionaryPaths:)` | Bundle-aware convenience constructor |
| `init(config: TokenizerConfig)` | Explicit configuration |
| `tokenize(text:mode:)` | Returns `[MorphemeInfo]` |
| `tokenizeWithSubunits(text:mode:subMode:addSingle:)` | Bulk tokenize + per-morpheme split |
| `lookup(query:)` | Exact-surface dictionary lookup |
| `posOf(posId:)` | Resolve POS id to `[String]?` components |
| `splitSentences(text:)` | Lexicon-aware sentence splitting |

### `SudachiDictDistribution`

| Case | Size | Use |
|------|------|-----|
| `.small` | ~50 MB | Minimum vocabulary |
| `.core` | ~70 MB | Basic vocabulary (recommended) |
| `.full` | ~1 GB | Complete vocabulary |

Each exposes `sizeMB`, `dicFilename`, and `downloadURL(version:)`.

### `SudachiDictionaryStore`

Pure Swift helpers for locating user-installed `.dic` files. `defaultDirectory` points at `Application Support/SudachiSwift/`. `findDictionary(in:)` searches caller-supplied paths, the default directory, and the host app's main bundle.

## Examples

The [Examples/](Examples/) directory ships two runnable demos:

- **`BasicUsage`** — macOS command-line tokenization
- **`iOSApp`** — iOS SwiftUI app

```bash
cd Examples/BasicUsage
SUDACHI_DICT_PATH=/path/to/system.dic swift run BasicUsage
```

## Development

The project pins the official [sudachi.rs](https://github.com/WorksApplications/sudachi.rs) repository as a git submodule. Apple platforms support landed upstream in [v0.6.11](https://github.com/WorksApplications/sudachi.rs/releases/tag/v0.6.11) via [PR #308](https://github.com/WorksApplications/sudachi.rs/pull/308).

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
tests/spm-consumer/            # CI fixture that builds the package as an external consumer
```

### Building from source

```bash
git clone --recursive https://github.com/h1431532403240/sudachi-swift
cd sudachi-swift

./scripts/build-local.sh           # produces SudachiSwift.xcframework + sudachi_swift.swift
swift build
cd Examples/BasicUsage && swift run BasicUsage
```

The root `Package.swift` auto-detects the local `SudachiSwift.xcframework` and falls back to the published release zip when it's absent, so the same manifest serves both contributors and external SPM users.

### Version sync with upstream

`.github/workflows/check-upstream.yml` runs daily; when WorksApplications/sudachi.rs publishes a new tag it opens a PR that bumps the submodule and `rust/Cargo.toml` version. Merging the PR + dispatching `release.yml` ships the corresponding SudachiSwift release.

## License

Apache-2.0. See [LICENSE](LICENSE).

This project wraps [sudachi.rs](https://github.com/WorksApplications/sudachi.rs), also licensed under Apache-2.0.
