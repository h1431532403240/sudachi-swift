// SudachiSwift - Swift bindings for sudachi.rs Japanese morphological analyzer
//
// Swift-idiomatic adapters on top of the UniFFI-generated bindings in
// `sudachi_swift.swift`. We only add things UniFFI structurally can't
// express (Swift protocol conformances, SPM bundle access) — never new
// analyzer behavior.

import Foundation

// MARK: - Swift idiom adapters for UniFFI types

extension MorphemeInfo: CustomStringConvertible {
    public var description: String {
        "\(surface)\t\(partOfSpeech.joined(separator: ","))\t\(normalizedForm)"
    }
}

extension MorphemeInfo: Identifiable {
    public var id: String { "\(begin)-\(end)-\(surface)" }
}

extension TokenizeMode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .a: return "Short (A)"
        case .b: return "Middle (B)"
        case .c: return "Long (C)"
        }
    }
}

// MARK: - Bundled resources

/// Locates `char.def` / `unk.def` / `sudachi.json` shipped inside the SPM
/// bundle, so `Tokenizer.create` can wire them up without the caller knowing
/// the bundle layout.
public enum SudachiResources {
    public static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle(for: BundleToken.self)
        #endif
    }

    public static var configPath: String? {
        bundle.path(forResource: "sudachi", ofType: "json")
    }

    public static var resourceDirectory: String? {
        bundle.resourcePath
    }

    public static var hasRequiredResources: Bool {
        guard let resourceDir = resourceDirectory else { return false }
        let fm = FileManager.default
        return ["char.def", "unk.def"].allSatisfy { file in
            fm.fileExists(atPath: (resourceDir as NSString).appendingPathComponent(file))
        }
    }
}

#if !SWIFT_PACKAGE
private class BundleToken {}
#endif

// MARK: - Tokenizer convenience

extension Tokenizer {
    /// Create a tokenizer using the bundled char.def / unk.def / sudachi.json
    /// resources, so callers only need to provide their `.dic` file.
    ///
    /// ## Getting a `.dic`
    ///
    /// The dictionary file itself ships separately from this package — it's
    /// 50 MB – 1 GB depending on which distribution you pick. See
    /// ``SudachiDictDistribution`` for download URLs and
    /// ``SudachiDictionaryStore`` for conventional install paths.
    ///
    /// **iOS / app bundle:** download a `sudachi-dictionary-*.zip` from
    /// https://github.com/WorksApplications/SudachiDict on your dev machine,
    /// extract the `.dic`, drag it into your Xcode target's *Copy Bundle
    /// Resources* build phase, and read it via `Bundle.main.url(forResource:)`.
    ///
    /// **Runtime download:** fetch ``SudachiDictDistribution/downloadURL(version:)``
    /// with `URLSession`, extract the zip with a library such as
    /// [ZIPFoundation](https://github.com/weichsel/ZIPFoundation), and place
    /// the resulting `.dic` at ``SudachiDictionaryStore/dictionaryPath(for:in:)``.
    /// This package does not bundle a zip extractor — `FileManager.unzipItem`
    /// doesn't exist on iOS, so leaving the choice to the caller keeps the
    /// dependency surface clean.
    ///
    /// - Parameters:
    ///   - dictionaryPath: Absolute path to a system `.dic` file.
    ///   - userDictionaryPaths: Optional user dictionaries, applied in order
    ///     (mirrors `userDict` in `sudachi.json`).
    public static func create(
        dictionaryPath: String,
        userDictionaryPaths: [String] = []
    ) throws -> Tokenizer {
        try Tokenizer(config: TokenizerConfig(
            dictionaryPath: dictionaryPath,
            configPath: SudachiResources.configPath,
            resourcePath: SudachiResources.resourceDirectory,
            userDictionaryPaths: userDictionaryPaths
        ))
    }
}

// MARK: - SudachiDict distribution helpers

/// One of the three SudachiDict distributions published at
/// https://github.com/WorksApplications/SudachiDict.
///
/// `.core` is the recommended default. Each case knows its approximate
/// ``sizeMB``, conventional ``dicFilename`` inside the zip, and
/// ``downloadURL(version:)`` for fetching the archive.
///
/// This type doesn't perform any I/O — the analyzer is decoupled from
/// dictionary distribution so you can ship a `.dic` inside your app bundle,
/// fetch one at runtime, or proxy through your own CDN. See
/// ``Tokenizer/create(dictionaryPath:userDictionaryPaths:)`` for the recipes.
///
/// ```swift
/// // Decide what you need
/// let dist: SudachiDictDistribution = .core   // ~70 MB
/// let zipURL = dist.downloadURL()
///
/// // ...download with URLSession, extract with a zip library...
///
/// // Then load it
/// let tokenizer = try Tokenizer.create(
///     dictionaryPath: SudachiDictionaryStore.dictionaryPath(for: dist).path
/// )
/// ```
public enum SudachiDictDistribution: String, CaseIterable, CustomStringConvertible, Sendable {
    case small, core, full

    public var description: String { rawValue.capitalized }

    /// Approximate compressed archive size, in megabytes. Useful for budgeting
    /// downloads / UX progress.
    public var sizeMB: Int {
        switch self {
        case .small: return 50
        case .core: return 70
        case .full: return 1000
        }
    }

    /// Conventional name of the `.dic` file inside SudachiDict's published zip
    /// (e.g. `"system_core.dic"`).
    public var dicFilename: String { "system_\(rawValue).dic" }

    /// URL of the `sudachi-dictionary-{version}-{distribution}.zip` archive on
    /// SudachiDict's CDN. Pass a specific version like `"20241021"` to pin, or
    /// leave `nil` for the latest published release.
    public func downloadURL(version: String? = nil) -> URL {
        let v = version ?? "latest"
        let host = "https://d2ej7fkh96fzlu.cloudfront.net/sudachidict"
        return URL(string: "\(host)/sudachi-dictionary-\(v)-\(rawValue).zip")!
    }
}

// MARK: - Local dictionary discovery

/// Conventions for locating user-installed `.dic` files on disk.
///
/// This type performs no network or zip work — fetch a dictionary as
/// described on ``SudachiDictDistribution``, then drop the extracted `.dic`
/// at ``dictionaryPath(for:in:)`` (or anywhere ``findDictionary(in:)``
/// searches: caller-supplied paths, ``defaultDirectory``, or
/// `Bundle.main.resourceURL`).
///
/// ```swift
/// // Quickest path once a .dic is somewhere visible:
/// let tokenizer = try SudachiDictionaryStore.createTokenizer()
/// ```
public enum SudachiDictionaryStore {
    /// Conventional install root: `~/Library/Application Support/SudachiSwift/`
    /// on macOS, the equivalent sandboxed location on iOS.
    public static let defaultDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("SudachiSwift")
    }()

    /// Conventional install path for a distribution. The file may not exist
    /// yet — write your extracted `.dic` here after fetching it.
    public static func dictionaryPath(
        for distribution: SudachiDictDistribution,
        in directory: URL = defaultDirectory
    ) -> URL {
        directory.appendingPathComponent("system_\(distribution.rawValue).dic")
    }

    /// `true` if a `.dic` for `distribution` exists at the conventional path.
    public static func isInstalled(
        _ distribution: SudachiDictDistribution,
        in directory: URL = defaultDirectory
    ) -> Bool {
        FileManager.default.fileExists(atPath: dictionaryPath(for: distribution, in: directory).path)
    }

    /// Look for a `.dic` to load. Searches the caller-supplied paths first,
    /// then ``defaultDirectory``, then `Bundle.main.resourceURL`. Recognised
    /// filenames are `system.dic` plus the per-distribution names
    /// (`system_small.dic`, `system_core.dic`, `system_full.dic`).
    public static func findDictionary(in additionalPaths: [URL] = []) -> URL? {
        var paths = additionalPaths
        paths.append(defaultDirectory)
        if let bundleURL = Bundle.main.resourceURL {
            paths.append(bundleURL)
        }
        let filenames = ["system.dic"] + SudachiDictDistribution.allCases.map(\.dicFilename)
        for path in paths {
            for name in filenames {
                let candidate = path.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Build a tokenizer from the first `.dic` ``findDictionary(in:)`` locates.
    /// Throws ``SudachiError/DictionaryLoadError(message:)`` with an
    /// actionable hint when no dictionary is installed.
    public static func createTokenizer() throws -> Tokenizer {
        guard let path = findDictionary() else {
            throw SudachiError.DictionaryLoadError(
                message: "No .dic file found. Place one at \(defaultDirectory.path) or bundle it with your app."
            )
        }
        return try Tokenizer.create(dictionaryPath: path.path)
    }
}
