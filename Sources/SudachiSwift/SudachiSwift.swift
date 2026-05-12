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

// MARK: - SudachiDict distribution helpers (Swift-only)
//
// These describe the SudachiDict release archives published at
// https://github.com/WorksApplications/SudachiDict — they are unrelated to
// the analyzer itself, so we keep them out of the FFI surface and provide
// them as plain Swift values for app code that needs to download a dict.

/// One of the three SudachiDict distributions.
public enum SudachiDictDistribution: String, CaseIterable, CustomStringConvertible, Sendable {
    case small, core, full

    public var description: String { rawValue.capitalized }

    /// Approximate compressed size, in megabytes.
    public var sizeMB: Int {
        switch self {
        case .small: return 50
        case .core: return 70
        case .full: return 1000
        }
    }

    /// Conventional `.dic` filename inside the published zip.
    public var dicFilename: String { "system_\(rawValue).dic" }

    /// Download URL for a specific dictionary version, or the latest if nil.
    public func downloadURL(version: String? = nil) -> URL {
        let v = version ?? "latest"
        let host = "https://d2ej7fkh96fzlu.cloudfront.net/sudachidict"
        return URL(string: "\(host)/sudachi-dictionary-\(v)-\(rawValue).zip")!
    }
}

// MARK: - Local dictionary discovery

/// Convenience helpers for locating user-installed `.dic` files. The library
/// itself doesn't download or extract zips — callers do that with
/// `URLSession` and a zip library of their choice, then drop the resulting
/// `.dic` somewhere these helpers can find it.
public enum SudachiDictionaryStore {
    /// Default install directory: `Application Support/SudachiSwift/`.
    public static let defaultDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("SudachiSwift")
    }()

    /// Conventional install path for a distribution. The file may not exist yet.
    public static func dictionaryPath(
        for distribution: SudachiDictDistribution,
        in directory: URL = defaultDirectory
    ) -> URL {
        directory.appendingPathComponent("system_\(distribution.rawValue).dic")
    }

    public static func isInstalled(
        _ distribution: SudachiDictDistribution,
        in directory: URL = defaultDirectory
    ) -> Bool {
        FileManager.default.fileExists(atPath: dictionaryPath(for: distribution, in: directory).path)
    }

    /// Search caller-supplied paths, then `defaultDirectory`, then the host
    /// app's main bundle, for any of the conventional `.dic` filenames.
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

    /// Create a tokenizer using the first dictionary `findDictionary` returns.
    public static func createTokenizer() throws -> Tokenizer {
        guard let path = findDictionary() else {
            throw SudachiError.DictionaryLoadError(
                message: "No .dic file found. Place one at \(defaultDirectory.path) or bundle it with your app."
            )
        }
        return try Tokenizer.create(dictionaryPath: path.path)
    }
}
