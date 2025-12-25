// SudachiSwift - Swift bindings for sudachi.rs Japanese morphological analyzer
//
// This file re-exports the UniFFI-generated bindings and provides
// additional Swift-idiomatic convenience APIs.

@_exported import SudachiSwiftFFI

// MARK: - Convenience Extensions

extension MorphemeInfo: CustomStringConvertible {
    /// Human-readable description of the morpheme
    public var description: String {
        "\(surface)\t\(partOfSpeech.joined(separator: ","))\t\(normalizedForm)"
    }
}

extension MorphemeInfo: Identifiable {
    /// Unique identifier based on position in text
    public var id: String {
        "\(begin)-\(end)-\(surface)"
    }
}

extension TokenizeMode: CustomStringConvertible {
    /// Human-readable description of the tokenization mode
    public var description: String {
        switch self {
        case .a: return "Short (A)"
        case .b: return "Middle (B)"
        case .c: return "Long (C)"
        }
    }
}

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
    public static var resourceDirectory: String? {
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

// MARK: - Tokenizer Convenience Methods

extension Tokenizer {
    /// Create a tokenizer with just a dictionary path.
    /// Uses bundled resources (char.def, unk.def, sudachi.json) automatically.
    ///
    /// - Parameter dictionaryPath: Path to the system dictionary file (.dic)
    /// - Returns: A configured Tokenizer ready to use
    /// - Throws: SudachiError if initialization fails
    public static func create(dictionaryPath: String) throws -> Tokenizer {
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
    public static func create(dictionaryPath: String, userDictionaryPath: String?) throws -> Tokenizer {
        let config = TokenizerConfig(
            dictionaryPath: dictionaryPath,
            configPath: SudachiResources.configPath,
            resourcePath: SudachiResources.resourceDirectory,
            userDictionaryPath: userDictionaryPath
        )
        return try Tokenizer(config: config)
    }

    /// Tokenize text using the default mode (C - long unit mode)
    ///
    /// - Parameter text: Japanese text to analyze
    /// - Returns: Array of morpheme information
    /// - Throws: SudachiError if tokenization fails
    public func tokenize(_ text: String) throws -> [MorphemeInfo] {
        try tokenize(text: text, mode: .c)
    }
}

// MARK: - Error Handling

extension SudachiError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .DictionaryLoadError(let message):
            return "Failed to load dictionary: \(message)"
        case .ConfigError(let message):
            return "Configuration error: \(message)"
        case .TokenizeError(let message):
            return "Tokenization failed: \(message)"
        case .InvalidArgument(let message):
            return "Invalid argument: \(message)"
        }
    }
}

// MARK: - Dictionary Type Extensions

extension DictionaryType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .small: return "Small"
        case .core: return "Core"
        case .full: return "Full"
        }
    }

    /// Recommended dictionary type for most use cases
    public static var recommended: DictionaryType { .core }

    /// All available dictionary types
    public static var allTypes: [DictionaryType] { [.small, .core, .full] }
}

// MARK: - Dictionary Info Extensions

extension DictionaryInfo: CustomStringConvertible {
    public var description: String {
        "\(name) (\(sizeMb)MB) - \(self.descriptionField)"
    }

    /// Formatted size string (e.g., "70 MB" or "1 GB")
    public var formattedSize: String {
        if sizeMb >= 1000 {
            return String(format: "%.1f GB", Double(sizeMb) / 1000.0)
        }
        return "\(sizeMb) MB"
    }

    // Note: 'description' field from Rust is renamed to avoid conflict
    private var descriptionField: String {
        // Access the description field from the underlying struct
        self.`description`
    }
}

// MARK: - Dictionary Manager

/// Manages Sudachi dictionary downloads and caching
public final class DictionaryManager {

    /// Shared instance
    public static let shared = DictionaryManager()

    /// Default directory for storing dictionaries
    public let defaultDirectory: URL

    /// Errors that can occur during dictionary operations
    public enum DictionaryError: LocalizedError {
        case downloadFailed(Error)
        case extractionFailed(Error)
        case fileNotFound(String)
        case invalidData

        public var errorDescription: String? {
            switch self {
            case .downloadFailed(let error):
                return "Dictionary download failed: \(error.localizedDescription)"
            case .extractionFailed(let error):
                return "Failed to extract dictionary: \(error.localizedDescription)"
            case .fileNotFound(let path):
                return "Dictionary file not found: \(path)"
            case .invalidData:
                return "Invalid dictionary data"
            }
        }
    }

    public init(directory: URL? = nil) {
        if let dir = directory {
            self.defaultDirectory = dir
        } else {
            // Default to Application Support/SudachiSwift
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.defaultDirectory = appSupport.appendingPathComponent("SudachiSwift")
        }
    }

    /// Get information about all available dictionaries
    public func availableDictionaries(version: String? = nil) -> [DictionaryInfo] {
        getAllDictionaryInfo(version: version)
    }

    /// Get information about a specific dictionary type
    public func dictionaryInfo(for type: DictionaryType, version: String? = nil) -> DictionaryInfo {
        getDictionaryInfo(dictType: type, version: version)
    }

    /// Get the download URL for a dictionary
    public func downloadUrl(for type: DictionaryType, version: String? = nil) -> URL {
        URL(string: getDictionaryDownloadUrl(dictType: type, version: version))!
    }

    /// Path to the dictionary file for a given type (may not exist yet)
    public func dictionaryPath(for type: DictionaryType) -> URL {
        defaultDirectory.appendingPathComponent("system_\(type).dic")
    }

    /// Check if a dictionary is already downloaded
    public func isDictionaryInstalled(_ type: DictionaryType) -> Bool {
        FileManager.default.fileExists(atPath: dictionaryPath(for: type).path)
    }

    /// Find the first available installed dictionary
    public func findInstalledDictionary() -> (type: DictionaryType, path: URL)? {
        // Prefer core > full > small
        let preferenceOrder: [DictionaryType] = [.core, .full, .small]
        for type in preferenceOrder {
            let path = dictionaryPath(for: type)
            if FileManager.default.fileExists(atPath: path.path) {
                return (type, path)
            }
        }
        return nil
    }

    /// Search for dictionary in common locations
    public func searchForDictionary(in additionalPaths: [URL] = []) -> URL? {
        var searchPaths = additionalPaths

        // Add default directory
        searchPaths.append(defaultDirectory)

        // Add bundle paths
        if let bundlePath = Bundle.main.resourceURL {
            searchPaths.append(bundlePath)
        }

        // Common dictionary filenames
        let filenames = ["system.dic", "system_core.dic", "system_small.dic", "system_full.dic"]

        for searchPath in searchPaths {
            for filename in filenames {
                let fullPath = searchPath.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: fullPath.path) {
                    return fullPath
                }
            }
        }

        return nil
    }

    /// Create a tokenizer using the first available dictionary
    /// - Throws: SudachiError if no dictionary is found or loading fails
    public func createTokenizer() throws -> Tokenizer {
        guard let path = searchForDictionary() else {
            throw SudachiError.DictionaryLoadError(
                message: "No dictionary found. Please download a dictionary first."
            )
        }
        return try Tokenizer.create(dictionaryPath: path.path)
    }

    #if canImport(Foundation)
    /// Download a dictionary (async)
    @available(iOS 15.0, macOS 12.0, tvOS 15.0, visionOS 1.0, *)
    public func downloadDictionary(
        _ type: DictionaryType,
        version: String? = nil,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> URL {
        let url = downloadUrl(for: type, version: version)

        // Create directory if needed
        try FileManager.default.createDirectory(
            at: defaultDirectory,
            withIntermediateDirectories: true
        )

        // Download
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DictionaryError.downloadFailed(
                NSError(domain: "SudachiSwift", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "HTTP error"
                ])
            )
        }

        // Extract zip and find .dic file
        let extractedPath = try extractDictionary(from: tempURL, type: type)

        // Clean up temp file
        try? FileManager.default.removeItem(at: tempURL)

        return extractedPath
    }

    private func extractDictionary(from zipURL: URL, type: DictionaryType) throws -> URL {
        // Note: In production, you'd use a proper zip library like ZIPFoundation
        // For now, we'll use the command line unzip on macOS/iOS Simulator
        #if os(macOS) || targetEnvironment(simulator)
        let destinationPath = dictionaryPath(for: type)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", zipURL.path, "-d", tempDir.path]
        try process.run()
        process.waitUntilExit()

        // Find .dic file
        let contents = try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for item in contents {
            if item.pathExtension == "dic" {
                try FileManager.default.moveItem(at: item, to: destinationPath)
                try? FileManager.default.removeItem(at: tempDir)
                return destinationPath
            }
            // Check subdirectories
            if item.hasDirectoryPath {
                let subContents = try FileManager.default.contentsOfDirectory(
                    at: item,
                    includingPropertiesForKeys: nil
                )
                for subItem in subContents where subItem.pathExtension == "dic" {
                    try FileManager.default.moveItem(at: subItem, to: destinationPath)
                    try? FileManager.default.removeItem(at: tempDir)
                    return destinationPath
                }
            }
        }

        throw DictionaryError.fileNotFound("No .dic file found in archive")
        #else
        // On iOS device, extraction requires ZIPFoundation or similar
        throw DictionaryError.extractionFailed(
            NSError(domain: "SudachiSwift", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "ZIP extraction requires ZIPFoundation library on iOS device"
            ])
        )
        #endif
    }
    #endif
}
