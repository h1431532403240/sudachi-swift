# SudachiSwift

Swift bindings for [sudachi.rs](https://github.com/WorksApplications/sudachi.rs), a high-performance Japanese morphological analyzer written in Rust.

## Features

- Full Japanese morphological analysis
- Three tokenization modes (A: short, B: middle, C: long)
- Part-of-speech tagging
- Reading form (katakana)
- Dictionary form and normalized form
- Support for user dictionaries
- Bundled resources (char.def, unk.def, sudachi.json)

## Requirements

- **Stable:** iOS 13.0+ / macOS 10.15+
- **Nightly:** iOS 13.0+ / macOS 10.15+ / tvOS 13.0+ / visionOS 1.0+
- Swift 5.9+
- Sudachi dictionary file (see [Dictionary Setup](#dictionary-setup))

## Installation

### Swift Package Manager

**Stable (iOS + macOS):**
```swift
dependencies: [
    .package(url: "https://github.com/h1431532403240/sudachi-swift", from: "0.1.0")
]
```

**Nightly (All Apple Platforms):**
```swift
dependencies: [
    .package(url: "https://github.com/h1431532403240/sudachi-swift", exact: "0.1.0-nightly")
]
```
> ⚠️ Nightly builds use Rust nightly compiler and may be unstable.

Or in Xcode: File > Add Package Dependencies > Enter the repository URL.

## Dictionary Setup

SudachiSwift requires a Sudachi dictionary file. The dictionary is **not included** due to its size (~50MB-1GB).

### Download Dictionary

```swift
import SudachiSwift

// Get download URL for a dictionary
let url = getDictionaryDownloadUrl(dictType: .small, version: nil)
print(url)  // https://d2ej7fkh96fzlu.cloudfront.net/sudachi/...

// List all available dictionaries
for info in getAllDictionaryInfo(version: nil) {
    print("\(info.name): \(info.sizeMb)MB")
}
```

Dictionary types:
- `.small` (~50MB) - Minimum vocabulary
- `.core` (~70MB) - Basic vocabulary (recommended)
- `.full` (~1GB) - Complete vocabulary

Download from the URL, extract the `.dic` file, and include it in your app.

## Usage

### Basic Tokenization

```swift
import SudachiSwift

// Create tokenizer with dictionary path
// Resources (char.def, unk.def, sudachi.json) are bundled automatically
let tokenizer = try Tokenizer.create(dictionaryPath: "/path/to/system.dic")

// Tokenize Japanese text
let morphemes = try tokenizer.tokenize(text: "東京都に住んでいます", mode: .c)

for m in morphemes {
    print("\(m.surface) - \(m.partOfSpeech.joined(separator: ","))")
}
```

### Tokenization Modes

```swift
let text = "国家公務員"

// Mode A: Maximum segmentation (short units)
let modeA = try tokenizer.tokenize(text: text, mode: .a)
// -> ["国家", "公務", "員"]

// Mode B: Middle segmentation
let modeB = try tokenizer.tokenize(text: text, mode: .b)
// -> ["国家", "公務員"]

// Mode C: Minimum segmentation (long units)
let modeC = try tokenizer.tokenize(text: text, mode: .c)
// -> ["国家公務員"]
```

### Morpheme Information

```swift
let morphemes = try tokenizer.tokenize(text: "食べる", mode: .c)

for m in morphemes {
    print("Surface: \(m.surface)")           // 食べる
    print("Reading: \(m.readingForm)")       // タベル
    print("Dictionary: \(m.dictionaryForm)") // 食べる
    print("Normalized: \(m.normalizedForm)") // 食べる
    print("POS: \(m.partOfSpeech)")          // ["動詞", "一般", "*", "*", ...]
    print("Is OOV: \(m.isOov)")              // false
}
```

### Advanced Configuration

```swift
let config = TokenizerConfig(
    dictionaryPath: "/path/to/system.dic",
    configPath: "/path/to/custom/sudachi.json",  // Optional: custom config
    resourcePath: "/path/to/resources",           // Optional: custom resources
    userDictionaryPath: "/path/to/user.dic"       // Optional: user dictionary
)

let tokenizer = try Tokenizer(config: config)
```

## API Reference

### Functions

| Function | Description |
|----------|-------------|
| `getVersion()` | Get library version |
| `getDictionaryDownloadUrl(dictType:version:)` | Get download URL for dictionary |
| `getAllDictionaryInfo(version:)` | Get info for all dictionary types |

### TokenizeMode

| Mode | Description | Example |
|------|-------------|---------|
| `.a` | Short unit (maximum segmentation) | 国家 + 公務 + 員 |
| `.b` | Middle unit | 国家 + 公務員 |
| `.c` | Long unit (named entities) | 国家公務員 |

### MorphemeInfo

| Property | Type | Description |
|----------|------|-------------|
| `surface` | `String` | Original text |
| `partOfSpeech` | `[String]` | POS tags (up to 6 levels) |
| `dictionaryForm` | `String` | Lemma |
| `normalizedForm` | `String` | Normalized form |
| `readingForm` | `String` | Reading in katakana |
| `isOov` | `Bool` | Out-of-vocabulary flag |
| `begin` | `UInt32` | Start byte offset |
| `end` | `UInt32` | End byte offset |

### DictionaryType

| Type | Size | Description |
|------|------|-------------|
| `.small` | ~50MB | Minimum vocabulary |
| `.core` | ~70MB | Basic vocabulary (recommended) |
| `.full` | ~1GB | Complete vocabulary |

## Examples

See the [Examples](Examples/) directory for complete working examples:

- **BasicUsage** - macOS command-line tokenization example
- **iOSApp** - iOS SwiftUI app example

To run the examples:

```bash
cd Examples/BasicUsage
swift run
```

## Development

This project uses a fork of sudachi.rs with iOS platform support:
- Fork: https://github.com/h1431532403240/sudachi.rs
- PR: https://github.com/WorksApplications/sudachi.rs/pull/308

### Building from Source

```bash
# Clone with submodule
git clone --recursive https://github.com/h1431532403240/sudachi-swift

# Build XCFramework
cd rust
cargo swift package --platforms macos ios --name SudachiSwift --release
```

### Version Synchronization

Currently using independent versioning (starting at 0.1.0) while waiting for upstream to merge iOS platform support ([PR #308](https://github.com/WorksApplications/sudachi.rs/pull/308)). Once merged, versions will sync with [sudachi.rs releases](https://github.com/WorksApplications/sudachi.rs/releases).

## License

Apache-2.0. See [LICENSE](LICENSE) for details.

This project wraps [sudachi.rs](https://github.com/WorksApplications/sudachi.rs), also licensed under Apache-2.0.
