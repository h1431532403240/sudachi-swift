//
//  SudachiSwift+Convenience.swift
//  SudachiSwift
//
//  Convenience extensions for SudachiSwift that automatically use bundled resources.
//

import Foundation

// MARK: - Resource Bundle Access

/// Provides access to bundled resources (char.def, unk.def, sudachi.json, etc.)
public enum SudachiResources {

    /// The bundle containing SudachiSwift resources
    public static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle(for: BundleToken.self)
        #endif
    }

    /// Path to the bundled sudachi.json configuration file
    public static var configPath: String? {
        bundle.path(forResource: "sudachi", ofType: "json")
    }

    /// Path to the bundled resources directory
    /// This is the directory containing char.def, unk.def, etc.
    public static var resourceDirectory: String? {
        // Resources are copied to the bundle root, so we return the bundle's resource path
        bundle.resourcePath
    }

    /// Check if all required resources are available
    public static var hasRequiredResources: Bool {
        guard let resourceDir = resourceDirectory else { return false }
        let fm = FileManager.default
        let requiredFiles = ["char.def", "unk.def"]
        return requiredFiles.allSatisfy { file in
            fm.fileExists(atPath: (resourceDir as NSString).appendingPathComponent(file))
        }
    }
}

#if !SWIFT_PACKAGE
private class BundleToken {}
#endif

// MARK: - Tokenizer Convenience Extensions

public extension Tokenizer {

    /// Create a tokenizer with just a dictionary path.
    /// Uses bundled resources (char.def, unk.def, sudachi.json) automatically.
    ///
    /// - Parameter dictionaryPath: Path to the system dictionary file (.dic)
    /// - Returns: A configured Tokenizer ready to use
    /// - Throws: SudachiError if initialization fails
    ///
    /// Example:
    /// ```swift
    /// let tokenizer = try Tokenizer.create(dictionaryPath: "/path/to/system.dic")
    /// let morphemes = try tokenizer.tokenize(text: "東京都", mode: .a)
    /// ```
    static func create(dictionaryPath: String) throws -> Tokenizer {
        let config = TokenizerConfig(
            dictionaryPath: dictionaryPath,
            configPath: SudachiResources.configPath,
            resourcePath: SudachiResources.resourceDirectory,
            userDictionaryPath: nil
        )
        return try Tokenizer(config: config)
    }

    /// Create a tokenizer with a dictionary path and optional user dictionary.
    /// Uses bundled resources (char.def, unk.def, sudachi.json) automatically.
    ///
    /// - Parameters:
    ///   - dictionaryPath: Path to the system dictionary file (.dic)
    ///   - userDictionaryPath: Optional path to a user dictionary file
    /// - Returns: A configured Tokenizer ready to use
    /// - Throws: SudachiError if initialization fails
    static func create(dictionaryPath: String, userDictionaryPath: String?) throws -> Tokenizer {
        let config = TokenizerConfig(
            dictionaryPath: dictionaryPath,
            configPath: SudachiResources.configPath,
            resourcePath: SudachiResources.resourceDirectory,
            userDictionaryPath: userDictionaryPath
        )
        return try Tokenizer(config: config)
    }
}
