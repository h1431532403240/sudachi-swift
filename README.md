# SudachiSwift

[![Release](https://img.shields.io/github/v/release/h1431532403240/sudachi-swift?label=release&color=blue)](https://github.com/h1431532403240/sudachi-swift/releases/latest)
[![sudachi.rs](https://img.shields.io/badge/sudachi.rs-v0.7.0-orange)](https://github.com/WorksApplications/sudachi.rs/releases/tag/v0.7.0)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20visionOS-lightgrey)](#requirements)
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

- **Stable:** iOS 13.0+ / macOS 10.15+
- **Nightly:** iOS 13.0+ / macOS 10.15+ / tvOS 13.0+ / visionOS 1.0+ *(uses Rust nightly `-Z build-std` — treat as experimental)*
- Swift 5.9+
- A **V1-format** Sudachi dictionary `.dic` file, SudachiDict 20260723 or later (see [Dictionary Setup](#dictionary-setup)). The V0 dictionaries used with SudachiSwift 0.6.x don't load.

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/h1431532403240/sudachi-swift", exact: "0.7.0")
]
```

Or in Xcode: **File → Add Package Dependencies…**, paste the repository URL, and set **Dependency Rule** to **Exact Version** `0.7.0`.

Pin the exact version. SudachiSwift versions follow sudachi.rs, and upstream calls 0.7.x an intermediate series before 1.0 in which "breaking behavioral changes may be introduced even in patch releases". SPM's `from:` allows every version below the next major, which for a 0.x package means every later 0.x minor. For example, `from: "0.6.11"` already resolves to 0.7.0. If you're fine with patch-level behavior changes, use `.upToNextMinor(from: "0.7.0")` instead.

**Upgrading from 0.6.x?** 0.7.0 needs new dictionaries. See [Upgrading from 0.6.x](#upgrading-from-06x).

For all Apple platforms (tvOS / visionOS via the Tier 3 nightly build):

```swift
dependencies: [
    .package(url: "https://github.com/h1431532403240/sudachi-swift", exact: "0.7.0-nightly")
]
```

A nightly tag is published only when that release's nightly build succeeds. Check [Releases](https://github.com/h1431532403240/sudachi-swift/releases) for it.

SudachiSwift is distributed through Swift Package Manager only.

## Dictionary Setup

`SudachiSwift` ships the analyzer but not the dictionary. It loads **V1-format** dictionaries, which SudachiDict publishes starting with release 20260723:

| Distribution | Zip | Extracted `.dic` | Download (`latest`) |
|--------------|-----|------------------|---------------------|
| `.small` | ~42 MB | ~115 MB | https://d2ej7fkh96fzlu.cloudfront.net/sudachidict/v1/sudachi-dictionary-latest-small.zip |
| `.core` (recommended) | ~77 MB | ~202 MB | https://d2ej7fkh96fzlu.cloudfront.net/sudachidict/v1/sudachi-dictionary-latest-core.zip |
| `.full` | ~137 MB | ~331 MB | https://d2ej7fkh96fzlu.cloudfront.net/sudachidict/v1/sudachi-dictionary-latest-full.zip |

Each zip contains `sudachi-dictionary-<version>/system_<distribution>.dic` (plus `LEGAL` and `LICENSE-2.0.txt`). `latest` redirects to the newest V1 release. Replace `latest` with a version such as `20260723` to pin one. Releases older than 20260723 exist only as V0 and don't load. The same goes for the zips under the old `/sudachidict/` path (without `/v1/`) and the ones attached to SudachiDict's GitHub releases.

```swift
import SudachiSwift

// Discover what to download
for dist in SudachiDictDistribution.allCases {
    print("\(dist) (~\(dist.sizeMB) MB) → \(dist.downloadURL())")
}

let dist: SudachiDictDistribution = .core
let dicURL = SudachiDictionaryStore.dictionaryPath(for: dist)  // .../Application Support/SudachiSwift/system_core.dic
if !SudachiDictionaryStore.isInstalled(dist) {  // false when the file is missing or a V0 leftover
    // Download dist.downloadURL() (or dist.downloadURL(version: "20260723")),
    // extract system_core.dic from the zip, and move it to dicURL.
}
let tokenizer = try Tokenizer.create(dictionaryPath: dicURL.path)
```

The library does not download or unzip on your behalf. Use `URLSession` and any zip library (e.g. ZIPFoundation). If a `.dic` came from somewhere else, check it with `dictionaryFormat(path:)` first (`.v1` is the only format this version loads). On a development machine with a clone of this repo, upstream's script does the download and extraction: `sh sudachi.rs/fetch_dictionary.sh 20260723 core v1` writes `./system.dic`, and an optional fourth argument verifies the zip's SHA-256.

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
    print("\(entry.morpheme.surface) → \(subs)")  // "国家公務員 → 国家+公務+員", "は → は", ...
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

> **Known upstream issue (sudachi.rs 0.6.11 and 0.7.0):** the lexicon check treats a boundary as "inside a word" whenever the closing punctuation (e.g. `。`, itself a dictionary entry) is followed by more text. In practice `tokenizer.splitSentences(text:)` returns the example above as a single range. Use the rule-based `splitSentences(text:)` until this is fixed upstream.

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
m.begin / m.end             // UTF-8 byte offsets in the input
m.beginChar / m.endChar     // Unicode codepoint offsets (matches sudachipy's begin/end)
m.totalCost        // path cost
m.isOov            // out-of-vocabulary flag
```

`partOfSpeechId` and `wordId` only mean something for the dictionary file that produced them. Store `partOfSpeech` / surface forms if you persist results across dictionary updates.

> Note: Swift's `String` is grapheme-indexed. Use `.utf8` view + `m.begin..<m.end` for byte slicing, or `.unicodeScalars` + `m.beginChar..<m.endChar` for codepoint slicing.

### Multiple user dictionaries

```swift
let tokenizer = try Tokenizer.create(
    dictionaryPath: "/path/to/system_core.dic",
    userDictionaryPaths: ["/path/to/user_a.dic", "/path/to/user_b.dic"]
)
```

Mirrors the `userDict` array in `sudachi.json`. Entries get `dictionaryId` 1, 2, … in the order given. Each user dictionary must be a V1 dictionary built against this exact system `.dic` (same release and distribution). Otherwise loading throws `SudachiError.DictionaryLoadError` ("… not compatible with the system dictionary"). Build one with the sudachi.rs 0.7 CLI (`cargo install --locked --path sudachi.rs/sudachi-cli` from a recursive clone of this repo):

```bash
sudachi ubuild -s system_core.dic -o user.dic user.csv
```

For the CSV format and for converting old user dictionaries, see Sudachi's [user dictionary migration guide](https://github.com/WorksApplications/Sudachi/blob/develop/docs/migrate_user_dictionary.md).

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

`char.def` / `unk.def` / `rewrite.def` are resolved in sudachi.rs order: `resourcePath`, then the config's `path` field, then the directory containing `configPath`, then defaults built into sudachi.rs. The `.dic`'s own directory is not searched, so a custom `char.def` needs one of the first three. `Tokenizer.create` passes the bundled `SudachiResources.configPath` / `SudachiResources.resourceDirectory`. `Tokenizer.withDictionary(dictionaryPath:)` passes `nil` for both and runs on the built-in defaults, so a bare `.dic` is enough.

## Upgrading from 0.6.x

SudachiSwift 0.7.0 moves to [sudachi.rs 0.7.0](https://github.com/WorksApplications/sudachi.rs/releases/tag/v0.7.0). Upstream's [migration guide](https://github.com/WorksApplications/sudachi.rs/blob/develop/docs/migration_guide.md) has the details. What changes for Swift users:

**Package resolution**

- `.package(url: …, from: "0.6.x")` moves to 0.7.0 on your next package update. To stay on 0.6, pin `exact: "0.6.11"`. To move, pin `exact: "0.7.0"` and replace your dictionaries at the same time.

**Dictionaries**

- **V1 dictionaries only.** A V0 `.dic` (everything SudachiSwift 0.6.x loaded) now throws `SudachiError.DictionaryLoadError` saying it is a legacy V0 dictionary. `dictionaryFormat(path:)` returns `.v1`, `.legacyV0` or `.unknown` without loading the file.
- **New download location.** `SudachiDictDistribution.downloadURL(version:)` now points at the `/sudachidict/v1/` CDN path. Update any hard-coded URL: the old path serves V0 files, and SudachiDict's GitHub releases no longer carry the dictionary zips. `sizeMB` now reports the V1 zip sizes (42 / 77 / 137).
- **Re-download flows replace old files.** `SudachiDictionaryStore.isInstalled(_:in:)` returns `true` only for a V1 file, so a V0 file left from 0.6.x counts as not installed. `findDictionary(in:)` still returns any file it finds, and `createTokenizer()` then throws the V0 error.
- **Rebuild user dictionaries.** They must be V1 and built against the exact system `.dic` you load them with. Do this again every time you update the system dictionary (see [Multiple user dictionaries](#multiple-user-dictionaries)).
- **Custom `char.def`.** The `NOOOVBOW2` category was removed. Replace it with `NOOOVBOW NOOOVEOW`. The bundled `char.def` is already updated.

**API**

- `MorphemeInfo.synonymGroupIds` is `[Int32]` (was `[UInt32]`).
- `lookup(query:)` normalizes the query before searching (`"ＡＢＣ"` finds `abc`). Returned `surface` / offsets refer to the normalized query, not your input string.
- Resources resolve in sudachi.rs order: `resourcePath`, then the config `path` field, then the config file's directory, then built-in defaults. The `.dic`'s directory is no longer searched, and `Tokenizer.withDictionary(dictionaryPath:)` now works with a bare `.dic` (see [Advanced configuration](#advanced-configuration)).
- New: `dictionaryFormat(path:)` and `DictionaryFormat`.

**Analysis results**

- POS ids and word ids are renumbered in V1 dictionaries. Don't persist `partOfSpeechId` / `wordId` across dictionary builds.
- Upstream algorithm fixes can change segmentation for some inputs: minimum-cost path by total cost ([#323](https://github.com/WorksApplications/sudachi.rs/pull/323)), `NOOOVBOW` / `NOOOVEOW` handling ([#325](https://github.com/WorksApplications/sudachi.rs/pull/325)), and character-category run length ([#326](https://github.com/WorksApplications/sudachi.rs/pull/326)). Comparing 0.6.11 and 0.7.0 on the same dictionary release, surface, POS, and normalized / reading / dictionary forms were unchanged on the text we tried. Still, re-check any golden outputs.
- Numbers joined by `JoinNumericPlugin` now carry an OOV-style `wordId` instead of `UInt32.max`, and numbers written with commas can get different readings.
- Joined katakana out-of-vocabulary words can come back with a different `isOov` / `dictionaryId` / `wordId`.

## API Reference

### Free functions

| Function | Description |
|----------|-------------|
| `getVersion() -> String` | Wrapper version (matches the pinned upstream sudachi.rs release) |
| `splitSentences(text:) -> [SentenceRange]` | Rule-based sentence splitting (no dictionary) |
| `dictionaryFormat(path:) -> DictionaryFormat` | Reads only the `.dic` header and reports its format |

### `Tokenizer`

| Member | Description |
|----------|-------------|
| `Tokenizer.create(dictionaryPath:userDictionaryPaths:)` | Convenience constructor using the bundled `sudachi.json` and resources |
| `Tokenizer.withDictionary(dictionaryPath:)` | System dictionary only, with sudachi.rs's built-in config and resources |
| `init(config: TokenizerConfig)` | Explicit configuration |
| `tokenize(text:mode:)` | Returns `[MorphemeInfo]` |
| `tokenizeWithSubunits(text:mode:subMode:addSingle:)` | Bulk tokenize + per-morpheme split |
| `lookup(query:)` | Entries whose surface equals the normalized query |
| `posOf(posId:)` | Resolve POS id to `[String]?` components |
| `splitSentences(text:)` | Lexicon-aware sentence splitting (see the [known issue](#sentence-splitting)) |

Throwing members throw `SudachiError` (`.DictionaryLoadError`, `.ConfigError`, `.TokenizeError`, `.InvalidArgument`, each with a `message`).

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

Pure Swift helpers for locating user-installed `.dic` files. `defaultDirectory` points at `Application Support/SudachiSwift/`, and `dictionaryPath(for:in:)` gives the conventional file path inside it. `isInstalled(_:in:)` is `true` only if a V1 dictionary exists at that path. `findDictionary(in:)` returns the first `system.dic` / `system_<distribution>.dic` in caller-supplied paths, the default directory, or the host app's main bundle, without checking its format. `createTokenizer()` loads that file, and throws `SudachiError.DictionaryLoadError` if none is found or the file is V0.

## Examples

The [Examples/](Examples/) directory ships two runnable demos:

- **`BasicUsage`**: macOS command-line tokenization
- **`iOSApp`**: iOS SwiftUI app

```bash
cd Examples/BasicUsage
SUDACHI_DICT_PATH=/path/to/system.dic swift run BasicUsage
```

## Development

The project pins the official [sudachi.rs](https://github.com/WorksApplications/sudachi.rs) repository as a git submodule, currently at [v0.7.0](https://github.com/WorksApplications/sudachi.rs/releases/tag/v0.7.0). Apple platforms support landed upstream in [v0.6.11](https://github.com/WorksApplications/sudachi.rs/releases/tag/v0.6.11) via [PR #308](https://github.com/WorksApplications/sudachi.rs/pull/308).

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

rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin
cargo install cargo-swift --version 0.11.1 --locked

cargo test --manifest-path rust/Cargo.toml   # Rust wrapper tests (uses the submodule's test dictionaries)
./scripts/build-local.sh                     # produces SudachiSwift.xcframework + sudachi_swift.swift
swift build
cd Examples/BasicUsage && SUDACHI_DICT_PATH=/path/to/system.dic swift run BasicUsage
```

`build-local.sh` requires cargo-swift **0.11.1** exactly. cargo-swift generates the Swift bindings with its own bundled `uniffi_bindgen`, and that has to match the `uniffi = "=0.31.1"` the crate is compiled with.

The root `Package.swift` auto-detects the local `SudachiSwift.xcframework` and falls back to the published release zip when it's absent, so the same manifest serves both contributors and external SPM users.

### Version sync with upstream

`.github/workflows/check-upstream.yml` runs daily. It can also be started by hand, with a `dry_run` option. When WorksApplications/sudachi.rs publishes a newer release, it:

- opens a tracking issue assigned to the maintainer with the `cargo check` result, and
- opens a PR from `automation/sudachi-rs-<tag>` that bumps the submodule, syncs the `rust/Cargo.toml` version, and refreshes the bundled resources. The PR is a draft when the bump is breaking (a new major, or a new minor while on 0.x) or when it doesn't compile.

Closing the tracking issue skips that release. The workflow also opens an issue when the check itself fails, and a warning issue after ~45 days without repository activity, because GitHub disables scheduled workflows after 60.

Merging the PR doesn't publish anything. To ship, dispatch the **Release** workflow (`release.yml`) with the new version.

## License

Apache-2.0. See [LICENSE](LICENSE).

This project wraps [sudachi.rs](https://github.com/WorksApplications/sudachi.rs), also licensed under Apache-2.0.
