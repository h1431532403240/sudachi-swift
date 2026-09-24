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
    /// The dictionary file itself ships separately from this package — the
    /// zip is 40 – 140 MB depending on which distribution you pick. See
    /// ``SudachiDictDistribution`` for download URLs and
    /// ``SudachiDictionaryStore`` for conventional install paths.
    ///
    /// The dictionary must be in binary format **V1** (sudachi.rs 0.7+). V0
    /// dictionaries from SudachiSwift 0.6 and earlier fail to load with a
    /// ``SudachiError/DictionaryLoadError(message:)`` that says so; check a
    /// file with ``dictionaryFormat(path:)``.
    ///
    /// **iOS / app bundle:** download a zip from
    /// ``SudachiDictDistribution/downloadURL(version:)`` on your dev machine,
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
    ///     (mirrors `userDict` in `sudachi.json`). Each must be built (V1) against
    ///     the exact system dictionary passed in `dictionaryPath`.
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
/// ``downloadURL(version:)`` for fetching the V1-format archive this version
/// of SudachiSwift can load.
///
/// This type doesn't perform any I/O — the analyzer is decoupled from
/// dictionary distribution so you can ship a `.dic` inside your app bundle,
/// fetch one at runtime, or proxy through your own CDN. See
/// ``Tokenizer/create(dictionaryPath:userDictionaryPaths:)`` for the recipes.
///
/// ```swift
/// // Decide what you need
/// let dist: SudachiDictDistribution = .core   // ~77 MB
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

    /// Approximate compressed archive size, in megabytes (V1 zips of the
    /// 20260723 release). Useful for budgeting downloads / UX progress.
    public var sizeMB: Int {
        switch self {
        case .small: return 42
        case .core: return 77
        case .full: return 137
        }
    }

    /// Conventional name of the `.dic` file inside SudachiDict's published zip
    /// (e.g. `"system_core.dic"`).
    public var dicFilename: String { "system_\(rawValue).dic" }

    /// URL of the V1-format `sudachi-dictionary-{version}-{distribution}.zip`
    /// archive on SudachiDict's CDN. Pass a specific version like `"20260723"`
    /// to pin, or leave `nil` for `"latest"`.
    ///
    /// `"latest"` moves whenever SudachiDict publishes a new release, and a
    /// user dictionary only loads with the exact system `.dic` file it was
    /// built against (its signature, not just the release date: the PyPI
    /// `sudachidict_*` packages are separate builds). If you ship user
    /// dictionaries, pin `version:` and build them against this download.
    ///
    /// V1 builds exist from `20260723` onwards: earlier versions have no V1
    /// build and return HTTP 404, so check the response status before
    /// unzipping.
    public func downloadURL(version: String? = nil) -> URL {
        let v = version ?? "latest"
        let host = "https://d2ej7fkh96fzlu.cloudfront.net/sudachidict/v1"
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

    /// Conventional install path for a distribution. Neither the file nor
    /// `directory` (``defaultDirectory`` unless you pass one) necessarily
    /// exists yet: create the directory with
    /// `FileManager.createDirectory(at:withIntermediateDirectories:attributes:)`
    /// before writing your extracted `.dic` here.
    public static func dictionaryPath(
        for distribution: SudachiDictDistribution,
        in directory: URL = defaultDirectory
    ) -> URL {
        directory.appendingPathComponent("system_\(distribution.rawValue).dic")
    }

    /// `true` if a `.dic` whose header says format V1 exists at
    /// ``dictionaryPath(for:in:)``. Only the header is checked: an
    /// interrupted download still reports `true`, so verify the size or
    /// checksum of a download before moving it into place.
    ///
    /// A V0 dictionary left over from SudachiSwift 0.6 reports `false`, so a
    /// "download if not installed" flow downloads again — but the old file
    /// is still in place. Delete it before moving the new one in
    /// (`FileManager.moveItem(at:to:)` fails when the destination exists), or
    /// use `FileManager.replaceItemAt(_:withItemAt:backupItemName:options:)`,
    /// and create the directory first if it doesn't exist yet.
    public static func isInstalled(
        _ distribution: SudachiDictDistribution,
        in directory: URL = defaultDirectory
    ) -> Bool {
        dictionaryFormat(path: dictionaryPath(for: distribution, in: directory).path) == .v1
    }

    /// Look for a `.dic` to load. Searches the caller-supplied paths first,
    /// then ``defaultDirectory``, then `Bundle.main.resourceURL`. Recognised
    /// filenames are `system.dic` plus the per-distribution names
    /// (`system_small.dic`, `system_core.dic`, `system_full.dic`), tried in
    /// that order in each location.
    ///
    /// Returns the first match whose ``dictionaryFormat(path:)`` is
    /// ``DictionaryFormat/v1``, so a V0 file left over from SudachiSwift 0.6
    /// doesn't hide a loadable dictionary elsewhere in the search order. Only
    /// if no V1 file exists does it fall back to the first match in another
    /// format, so that loading it reports why it can't be used (e.g. the
    /// legacy-V0 error; a V0 file is preferred over an unreadable one for that
    /// reason). Returns `nil` when nothing matches.
    public static func findDictionary(in additionalPaths: [URL] = []) -> URL? {
        var paths = additionalPaths
        paths.append(defaultDirectory)
        if let bundleURL = Bundle.main.resourceURL {
            paths.append(bundleURL)
        }
        let filenames = ["system.dic"] + SudachiDictDistribution.allCases.map(\.dicFilename)
        var legacyFallback: URL?
        var otherFallback: URL?
        for path in paths {
            for name in filenames {
                let candidate = path.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
                switch dictionaryFormat(path: candidate.path) {
                case .v1:
                    return candidate
                case .legacyV0:
                    legacyFallback = legacyFallback ?? candidate
                case .unknown:
                    otherFallback = otherFallback ?? candidate
                }
            }
        }
        return legacyFallback ?? otherFallback
    }

    /// Build a tokenizer from the `.dic` ``findDictionary(in:)`` picks: the
    /// first V1 dictionary in its search order, or, if there is none, the
    /// first matching file in another format.
    ///
    /// Throws ``SudachiError/DictionaryLoadError(message:)`` with an
    /// actionable hint when no dictionary is installed, or when no V1 file
    /// was found and the fallback is a legacy V0 dictionary.
    public static func createTokenizer() throws -> Tokenizer {
        guard let path = findDictionary() else {
            throw SudachiError.DictionaryLoadError(
                message: "No .dic file found. Place a V1 dictionary (see SudachiDictDistribution.downloadURL()) at \(defaultDirectory.path) or bundle it with your app."
            )
        }
        return try Tokenizer.create(dictionaryPath: path.path)
    }
}
