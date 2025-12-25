//! Swift bindings for sudachi.rs Japanese morphological analyzer
//!
//! This crate provides UniFFI bindings to expose sudachi.rs functionality to Swift.

use std::sync::Arc;

use sudachi::analysis::stateful_tokenizer::StatefulTokenizer;
use sudachi::analysis::Mode as SudachiMode;
use sudachi::config::ConfigBuilder;
use sudachi::dic::dictionary::JapaneseDictionary;

uniffi::setup_scaffolding!();

// ============ Error Handling ============

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SudachiError {
    #[error("Failed to load dictionary: {message}")]
    DictionaryLoadError { message: String },

    #[error("Failed to load config: {message}")]
    ConfigError { message: String },

    #[error("Tokenization failed: {message}")]
    TokenizeError { message: String },

    #[error("Invalid argument: {message}")]
    InvalidArgument { message: String },
}

// ============ Dictionary Type ============

/// Type of Sudachi dictionary
#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum DictionaryType {
    /// Small dictionary (~50MB) - minimum vocabulary
    Small,
    /// Core dictionary (~70MB) - basic vocabulary (recommended)
    Core,
    /// Full dictionary (~1GB) - complete vocabulary
    Full,
}

impl DictionaryType {
    fn as_str(&self) -> &'static str {
        match self {
            DictionaryType::Small => "small",
            DictionaryType::Core => "core",
            DictionaryType::Full => "full",
        }
    }
}

// ============ Tokenization Mode ============

/// Tokenization granularity mode
#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum TokenizeMode {
    /// Short unit mode - maximum segmentation (equivalent to UniDic short unit)
    A,
    /// Middle unit mode - word-like segmentation
    B,
    /// Long unit mode - minimal segmentation, extracts named entities
    C,
}

impl From<TokenizeMode> for SudachiMode {
    fn from(mode: TokenizeMode) -> Self {
        match mode {
            TokenizeMode::A => SudachiMode::A,
            TokenizeMode::B => SudachiMode::B,
            TokenizeMode::C => SudachiMode::C,
        }
    }
}

// ============ Morpheme Data ============

/// Information about a single morpheme (token)
#[derive(Clone, Debug, uniffi::Record)]
pub struct MorphemeInfo {
    /// Surface form (original text as it appears)
    pub surface: String,
    /// Part-of-speech tags (hierarchical, up to 6 levels)
    pub part_of_speech: Vec<String>,
    /// Dictionary form (lemma)
    pub dictionary_form: String,
    /// Normalized form
    pub normalized_form: String,
    /// Reading form in katakana
    pub reading_form: String,
    /// Whether this is an out-of-vocabulary word
    pub is_oov: bool,
    /// Word ID in dictionary (-1 for OOV)
    pub word_id: i32,
    /// Start byte offset in original text
    pub begin: u32,
    /// End byte offset in original text
    pub end: u32,
}

// ============ Tokenizer Configuration ============

/// Configuration for creating a Tokenizer
#[derive(Clone, Debug, uniffi::Record)]
pub struct TokenizerConfig {
    /// Path to the system dictionary file (.dic)
    pub dictionary_path: String,
    /// Optional path to sudachi.json config file
    pub config_path: Option<String>,
    /// Optional path to resource directory (where char.def, unk.def are located)
    /// If not provided, will use the parent directory of config_path or dictionary_path
    pub resource_path: Option<String>,
    /// Optional path to user dictionary file
    pub user_dictionary_path: Option<String>,
}

// ============ Main Tokenizer Object ============

/// Japanese morphological analyzer powered by sudachi.rs
#[derive(uniffi::Object)]
pub struct Tokenizer {
    dictionary: Arc<JapaneseDictionary>,
}

#[uniffi::export]
impl Tokenizer {
    /// Create a new tokenizer with the given configuration
    #[uniffi::constructor]
    pub fn new(config: TokenizerConfig) -> Result<Arc<Self>, SudachiError> {
        use std::path::Path;

        // Build configuration using ConfigBuilder for proper handling
        let mut builder = match &config.config_path {
            Some(path) => ConfigBuilder::from_file(path.as_ref())
                .map_err(|e| SudachiError::ConfigError {
                    message: e.to_string(),
                })?,
            None => ConfigBuilder::empty(),
        };

        // Set system dictionary path
        builder = builder.system_dict(&config.dictionary_path);

        // Set resource path (for char.def, unk.def, etc.)
        let resource_path = config.resource_path.clone().or_else(|| {
            // Try to derive from config_path or dictionary_path
            config.config_path.as_ref()
                .and_then(|p| Path::new(p).parent())
                .or_else(|| Path::new(&config.dictionary_path).parent())
                .map(|p| p.to_string_lossy().to_string())
        });

        if let Some(res_path) = resource_path {
            builder = builder.resource_path(res_path);
        }

        // Add user dictionary if provided
        if let Some(user_dict) = &config.user_dictionary_path {
            builder = builder.user_dict(user_dict);
        }

        let sudachi_config = builder.build();

        let dictionary = JapaneseDictionary::from_cfg(&sudachi_config).map_err(|e| {
            SudachiError::DictionaryLoadError {
                message: e.to_string(),
            }
        })?;

        Ok(Arc::new(Self {
            dictionary: Arc::new(dictionary),
        }))
    }

    /// Create a tokenizer with just a dictionary path (no config file)
    #[uniffi::constructor]
    pub fn with_dictionary(dictionary_path: String) -> Result<Arc<Self>, SudachiError> {
        Self::new(TokenizerConfig {
            dictionary_path,
            config_path: None,
            resource_path: None,
            user_dictionary_path: None,
        })
    }

    /// Tokenize text and return morpheme information
    pub fn tokenize(
        &self,
        text: String,
        mode: TokenizeMode,
    ) -> Result<Vec<MorphemeInfo>, SudachiError> {
        let mut tokenizer = StatefulTokenizer::new(&*self.dictionary, mode.into());

        tokenizer.reset().push_str(&text);
        tokenizer
            .do_tokenize()
            .map_err(|e| SudachiError::TokenizeError {
                message: e.to_string(),
            })?;

        let morphemes =
            tokenizer
                .into_morpheme_list()
                .map_err(|e| SudachiError::TokenizeError {
                    message: e.to_string(),
                })?;

        let results: Vec<MorphemeInfo> = morphemes
            .iter()
            .map(|m| MorphemeInfo {
                surface: m.surface().to_string(),
                part_of_speech: m.part_of_speech().iter().map(|s| s.to_string()).collect(),
                dictionary_form: m.dictionary_form().to_string(),
                normalized_form: m.normalized_form().to_string(),
                reading_form: m.reading_form().to_string(),
                is_oov: m.is_oov(),
                word_id: m.word_id().word() as i32,
                begin: m.begin() as u32,
                end: m.end() as u32,
            })
            .collect();

        Ok(results)
    }

    /// Get the wrapper version
    pub fn version(&self) -> String {
        env!("CARGO_PKG_VERSION").to_string()
    }
}

// ============ Convenience Functions ============

/// Quick tokenization without creating a persistent Tokenizer object
///
/// This is useful for one-off tokenization but less efficient for repeated use.
/// For multiple tokenizations, create a Tokenizer instance and reuse it.
#[uniffi::export]
pub fn tokenize_text(
    text: String,
    dictionary_path: String,
    mode: TokenizeMode,
) -> Result<Vec<MorphemeInfo>, SudachiError> {
    let tokenizer = Tokenizer::with_dictionary(dictionary_path)?;
    tokenizer.tokenize(text, mode)
}

/// Get the library version
#[uniffi::export]
pub fn get_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

// ============ Dictionary Management ============

/// Base URL for dictionary downloads
const DICTIONARY_BASE_URL: &str = "https://d2ej7fkh96fzlu.cloudfront.net/sudachidict";

/// Get the download URL for a specific dictionary type and version
///
/// - `dict_type`: The type of dictionary (small, core, full)
/// - `version`: Optional version string (e.g., "20241021"). If None, uses "latest"
///
/// Returns the URL to download the dictionary zip file
#[uniffi::export]
pub fn get_dictionary_download_url(dict_type: DictionaryType, version: Option<String>) -> String {
    let version_str = version.as_deref().unwrap_or("latest");
    let dict_name = format!("sudachi-dictionary-{}-{}", version_str, dict_type.as_str());
    format!("{}/{}.zip", DICTIONARY_BASE_URL, dict_name)
}

/// Get information about a dictionary type
#[derive(Clone, Debug, uniffi::Record)]
pub struct DictionaryInfo {
    /// Dictionary type name
    pub name: String,
    /// Approximate size in MB
    pub size_mb: u32,
    /// Description
    pub description: String,
    /// Download URL
    pub download_url: String,
    /// Filename inside the zip (e.g., "system_core.dic")
    pub dic_filename: String,
}

/// Get information about available dictionaries
#[uniffi::export]
pub fn get_dictionary_info(dict_type: DictionaryType, version: Option<String>) -> DictionaryInfo {
    let (name, size_mb, description) = match dict_type {
        DictionaryType::Small => ("small", 50, "Minimum vocabulary dictionary"),
        DictionaryType::Core => ("core", 70, "Basic vocabulary dictionary (recommended)"),
        DictionaryType::Full => ("full", 1000, "Complete vocabulary dictionary"),
    };

    DictionaryInfo {
        name: name.to_string(),
        size_mb,
        description: description.to_string(),
        download_url: get_dictionary_download_url(dict_type, version),
        dic_filename: format!("system_{}.dic", name),
    }
}

/// Get all available dictionary types with their info
#[uniffi::export]
pub fn get_all_dictionary_info(version: Option<String>) -> Vec<DictionaryInfo> {
    vec![
        get_dictionary_info(DictionaryType::Small, version.clone()),
        get_dictionary_info(DictionaryType::Core, version.clone()),
        get_dictionary_info(DictionaryType::Full, version),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_version() {
        let version = get_version();
        assert!(!version.is_empty());
    }

    #[test]
    fn test_mode_conversion() {
        assert!(matches!(SudachiMode::from(TokenizeMode::A), SudachiMode::A));
        assert!(matches!(SudachiMode::from(TokenizeMode::B), SudachiMode::B));
        assert!(matches!(SudachiMode::from(TokenizeMode::C), SudachiMode::C));
    }

    #[test]
    fn test_dictionary_url_latest() {
        let url = get_dictionary_download_url(DictionaryType::Core, None);
        assert_eq!(
            url,
            "https://d2ej7fkh96fzlu.cloudfront.net/sudachidict/sudachi-dictionary-latest-core.zip"
        );
    }

    #[test]
    fn test_dictionary_url_versioned() {
        let url = get_dictionary_download_url(DictionaryType::Full, Some("20241021".to_string()));
        assert_eq!(
            url,
            "https://d2ej7fkh96fzlu.cloudfront.net/sudachidict/sudachi-dictionary-20241021-full.zip"
        );
    }

    #[test]
    fn test_dictionary_info() {
        let info = get_dictionary_info(DictionaryType::Core, None);
        assert_eq!(info.name, "core");
        assert_eq!(info.dic_filename, "system_core.dic");
        assert!(info.download_url.contains("core"));
    }

    #[test]
    fn test_all_dictionary_info() {
        let all_info = get_all_dictionary_info(None);
        assert_eq!(all_info.len(), 3);
        assert_eq!(all_info[0].name, "small");
        assert_eq!(all_info[1].name, "core");
        assert_eq!(all_info[2].name, "full");
    }
}
