//! Swift bindings for sudachi.rs Japanese morphological analyzer
//!
//! This crate provides UniFFI bindings to expose sudachi.rs functionality to Swift.

use std::fs::File;
use std::io::Read;
use std::path::PathBuf;
use std::sync::Arc;

use sudachi::analysis::mlist::MorphemeList;
use sudachi::analysis::morpheme::Morpheme;
use sudachi::analysis::stateful_tokenizer::StatefulTokenizer;
use sudachi::analysis::Mode as SudachiMode;
use sudachi::config::Config;
use sudachi::dic::dictionary::JapaneseDictionary;
use sudachi::dic::header::HeaderVersion;
use sudachi::dic::subset::InfoSubset;
use sudachi::dic::DictionaryAccess;
use sudachi::sentence_splitter::{SentenceSplitter, SplitSentences};

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
    /// Encoded WordId (dictionary index packed with entry index). Mirrors
    /// `Morpheme.word_id()` in the Python binding.
    pub word_id: u32,
    /// Start UTF-8 byte offset in the original text. NOTE: Python's
    /// `Morpheme.begin()` returns a codepoint offset — use `begin_char`
    /// here for parity with sudachipy.
    pub begin: u32,
    /// End UTF-8 byte offset in the original text. See note on `begin`.
    pub end: u32,
    /// Part-of-speech numeric ID
    pub part_of_speech_id: u32,
    /// Dictionary ID (0 for the system dictionary, 1+ for user dictionaries
    /// in the order given, -1 for OOV)
    pub dictionary_id: i32,
    /// Synonym group IDs this morpheme belongs to
    pub synonym_group_ids: Vec<i32>,
    /// Start Unicode codepoint offset in the original text (matches Python's
    /// `Morpheme.begin()`).
    pub begin_char: u32,
    /// End Unicode codepoint offset in the original text.
    pub end_char: u32,
    /// Total cost of the path leading to this morpheme
    pub total_cost: i32,
}

/// A morpheme together with its sub-unit decomposition.
#[derive(Clone, Debug, uniffi::Record)]
pub struct MorphemeWithSubunits {
    /// The primary morpheme (e.g. from C mode).
    pub morpheme: MorphemeInfo,
    /// Sub-unit decomposition (e.g. from A mode). If the morpheme cannot be
    /// split further, this contains exactly one element equal to `morpheme`.
    pub subunits: Vec<MorphemeInfo>,
}

/// A sentence range produced by the sentence splitter.
#[derive(Clone, Debug, uniffi::Record)]
pub struct SentenceRange {
    /// Byte offset begin in original text
    pub begin: u32,
    /// Byte offset end in original text
    pub end: u32,
    /// Sentence text (slice of original)
    pub text: String,
}

// ============ Tokenizer Configuration ============

/// Configuration for creating a Tokenizer
#[derive(Clone, Debug, uniffi::Record)]
pub struct TokenizerConfig {
    /// Path to the system dictionary file (.dic)
    pub dictionary_path: String,
    /// Optional path to sudachi.json config file. When omitted, the default
    /// config embedded in sudachi.rs is used.
    pub config_path: Option<String>,
    /// Optional resource directory (where char.def, unk.def, rewrite.def are
    /// located). Resources are resolved in sudachi.rs order: this directory,
    /// then the config's `path` field, then the config file's directory, then
    /// the defaults embedded in sudachi.rs.
    pub resource_path: Option<String>,
    /// User dictionary files, applied in order. Mirrors the `userDict` array
    /// in `sudachi.json`.
    pub user_dictionary_paths: Vec<String>,
}

// ============ Helpers ============

/// Convert a `Morpheme<T>` into the FFI-friendly `MorphemeInfo` record.
fn morpheme_to_info<T: DictionaryAccess>(m: &Morpheme<T>) -> MorphemeInfo {
    MorphemeInfo {
        surface: m.surface().to_string(),
        part_of_speech: m.part_of_speech().iter().map(|s| s.to_string()).collect(),
        dictionary_form: m.dictionary_form().to_string(),
        normalized_form: m.normalized_form().to_string(),
        reading_form: m.reading_form().to_string(),
        is_oov: m.is_oov(),
        word_id: m.word_id().as_raw(),
        begin: m.begin() as u32,
        end: m.end() as u32,
        part_of_speech_id: m.part_of_speech_id() as u32,
        dictionary_id: m.dictionary_id(),
        synonym_group_ids: m.synonym_group_ids().to_vec(),
        begin_char: m.begin_c() as u32,
        end_char: m.end_c() as u32,
        total_cost: m.total_cost(),
    }
}

// ============ Main Tokenizer Object ============

#[derive(uniffi::Object)]
pub struct Tokenizer {
    dictionary: Arc<JapaneseDictionary>,
}

#[uniffi::export]
impl Tokenizer {
    #[uniffi::constructor]
    pub fn new(config: TokenizerConfig) -> Result<Arc<Self>, SudachiError> {
        ensure_loadable_format(&config.dictionary_path, "System dictionary")?;
        for user_dict in &config.user_dictionary_paths {
            ensure_loadable_format(user_dict, "User dictionary")?;
        }

        // Same construction as sudachi.rs's own CLI / Python binding
        // (`Config::new`), so resource resolution follows upstream.
        let mut cfg = Config::new(
            config.config_path.as_ref().map(PathBuf::from),
            config.resource_path.as_ref().map(PathBuf::from),
            Some(PathBuf::from(&config.dictionary_path)),
        )
        .map_err(|e| SudachiError::ConfigError {
            message: e.to_string(),
        })?;
        cfg.user_dicts
            .extend(config.user_dictionary_paths.iter().map(PathBuf::from));

        let dictionary =
            JapaneseDictionary::from_cfg(&cfg).map_err(|e| SudachiError::DictionaryLoadError {
                message: e.to_string(),
            })?;

        Ok(Arc::new(Self {
            dictionary: Arc::new(dictionary),
        }))
    }

    #[uniffi::constructor]
    pub fn with_dictionary(dictionary_path: String) -> Result<Arc<Self>, SudachiError> {
        Self::new(TokenizerConfig {
            dictionary_path,
            config_path: None,
            resource_path: None,
            user_dictionary_paths: Vec::new(),
        })
    }

    pub fn tokenize(
        &self,
        text: String,
        mode: TokenizeMode,
    ) -> Result<Vec<MorphemeInfo>, SudachiError> {
        Ok(self
            .run_tokenize(&text, mode.into())?
            .iter()
            .map(|m| morpheme_to_info(&m))
            .collect())
    }

    /// Tokenize with `mode`, then split each morpheme into sub-units using
    /// `sub_mode`. Typical use: C (long unit / named entities) with A (max
    /// segmentation). Mirrors `Morpheme.split(mode, add_single)` in the
    /// Python binding: when `add_single` is true, morphemes that cannot
    /// split further get a single-element `subunits` containing themselves;
    /// when false, those entries get an empty `subunits` vector.
    pub fn tokenize_with_subunits(
        &self,
        text: String,
        mode: TokenizeMode,
        sub_mode: TokenizeMode,
        add_single: bool,
    ) -> Result<Vec<MorphemeWithSubunits>, SudachiError> {
        let morphemes = self.run_tokenize(&text, mode.into())?;
        let sub_sudachi_mode: SudachiMode = sub_mode.into();

        let mut results: Vec<MorphemeWithSubunits> = Vec::with_capacity(morphemes.len());
        let mut sub_list: MorphemeList<Arc<JapaneseDictionary>> =
            MorphemeList::empty(self.dictionary.clone());

        for m in morphemes.iter() {
            let info = morpheme_to_info(&m);
            sub_list.clear();
            let did_split = m.split_into(sub_sudachi_mode, &mut sub_list).map_err(|e| {
                SudachiError::TokenizeError {
                    message: e.to_string(),
                }
            })?;

            let subunits: Vec<MorphemeInfo> = if did_split && !sub_list.is_empty() {
                sub_list.iter().map(|sm| morpheme_to_info(&sm)).collect()
            } else if add_single {
                vec![info.clone()]
            } else {
                Vec::new()
            };

            results.push(MorphemeWithSubunits {
                morpheme: info,
                subunits,
            });
        }

        Ok(results)
    }

    /// Look up dictionary entries whose surface matches `query`.
    /// Mirrors `Dictionary.lookup(surface)` in the Python binding.
    ///
    /// Since sudachi.rs 0.7 the query is first normalized by the dictionary's
    /// input-text plugins (e.g. full-width → half-width), so the returned
    /// `surface` and offsets refer to the normalized query, not `query`.
    pub fn lookup(&self, query: String) -> Result<Vec<MorphemeInfo>, SudachiError> {
        let mut list: MorphemeList<Arc<JapaneseDictionary>> =
            MorphemeList::empty(self.dictionary.clone());
        list.lookup(&query, InfoSubset::default())
            .map_err(|e| SudachiError::TokenizeError {
                message: e.to_string(),
            })?;
        Ok(list.iter().map(|m| morpheme_to_info(&m)).collect())
    }

    /// Resolve a part-of-speech ID to its hierarchical components.
    /// Mirrors `Dictionary.pos_of(pos_id)` in the Python binding.
    pub fn pos_of(&self, pos_id: u32) -> Option<Vec<String>> {
        self.dictionary
            .grammar()
            .pos_list
            .get(pos_id as usize)
            .cloned()
    }

    /// Sentence-split `text` using this tokenizer's lexicon to avoid breaking
    /// inside known multi-character expressions.
    pub fn split_sentences(&self, text: String) -> Vec<SentenceRange> {
        collect_sentences(
            SentenceSplitter::new().with_checker(self.dictionary.lexicon()),
            &text,
        )
    }
}

impl Tokenizer {
    fn run_tokenize(
        &self,
        text: &str,
        mode: SudachiMode,
    ) -> Result<MorphemeList<Arc<JapaneseDictionary>>, SudachiError> {
        let mut tokenizer = StatefulTokenizer::new(self.dictionary.clone(), mode);
        tokenizer.reset().push_str(text);
        tokenizer
            .do_tokenize()
            .map_err(|e| SudachiError::TokenizeError {
                message: e.to_string(),
            })?;
        tokenizer
            .into_morpheme_list()
            .map_err(|e| SudachiError::TokenizeError {
                message: e.to_string(),
            })
    }
}

fn collect_sentences<S: SplitSentences>(splitter: S, text: &str) -> Vec<SentenceRange> {
    splitter
        .split(text)
        .map(|(range, slice)| SentenceRange {
            begin: range.start as u32,
            end: range.end as u32,
            text: slice.to_string(),
        })
        .collect()
}

// ============ Free Functions ============

/// Get the library version
#[uniffi::export]
pub fn get_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Rule-based sentence splitter (no lexicon). For lexicon-aware splitting
/// use `Tokenizer.split_sentences` instead.
#[uniffi::export]
pub fn split_sentences(text: String) -> Vec<SentenceRange> {
    collect_sentences(SentenceSplitter::new(), &text)
}

// ============ Dictionary Format ============

/// Binary format of a Sudachi dictionary file.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum DictionaryFormat {
    /// Binary format V1, the only format sudachi.rs 0.7+ can load.
    V1,
    /// Legacy format used by sudachi.rs 0.6 and earlier. Download a V1 build
    /// of the system dictionary and rebuild user dictionaries against it.
    LegacyV0,
    /// Unreadable, not a Sudachi dictionary, or a format this version does
    /// not know.
    Unknown,
}

/// First bytes of a V1 dictionary (sudachi.rs `dic/description.rs`).
const V1_MAGIC_BYTES: &[u8] = b"SudachiBinaryDic";

/// Detect the binary format of the dictionary file at `path` by reading its
/// header only. Useful for deciding whether a previously downloaded `.dic`
/// needs to be replaced.
#[uniffi::export]
pub fn dictionary_format(path: String) -> DictionaryFormat {
    let mut header = [0u8; 16];
    let read = File::open(&path).and_then(|mut f| f.read_exact(&mut header));
    if read.is_err() {
        return DictionaryFormat::Unknown;
    }
    if header == V1_MAGIC_BYTES {
        return DictionaryFormat::V1;
    }
    let legacy_version = u64::from_le_bytes(header[..8].try_into().unwrap());
    match HeaderVersion::from_u64(legacy_version) {
        Some(_) => DictionaryFormat::LegacyV0,
        None => DictionaryFormat::Unknown,
    }
}

/// Fail early with an actionable message for V0 dictionaries. sudachi.rs
/// reads resources before the dictionary header, so without this check a V0
/// dictionary can surface as an unrelated char.def error.
fn ensure_loadable_format(path: &str, kind: &str) -> Result<(), SudachiError> {
    if dictionary_format(path.to_string()) != DictionaryFormat::LegacyV0 {
        return Ok(());
    }
    Err(SudachiError::DictionaryLoadError {
        message: format!(
            "{kind} {path} uses the legacy V0 format, which SudachiSwift 0.7+ (sudachi.rs 0.7+) cannot read. \
             Download a V1 dictionary from https://d2ej7fkh96fzlu.cloudfront.net/sudachidict/v1/ \
             and rebuild user dictionaries against it."
        ),
    })
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
    fn test_split_sentences_empty() {
        let sentences = split_sentences(String::new());
        assert!(sentences.is_empty());
    }

    #[test]
    fn test_split_sentences_japanese() {
        // Two sentences separated by a Japanese full stop.
        let text = "これは最初の文です。これは二番目の文です。";
        let sentences = split_sentences(text.to_string());
        assert_eq!(sentences.len(), 2);

        // The concatenation of slices must reconstruct the original text.
        let joined: String = sentences.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(joined, text);

        // Ranges must be contiguous and cover the whole input.
        assert_eq!(sentences[0].begin, 0);
        assert_eq!(sentences[0].end, sentences[1].begin);
        assert_eq!(sentences.last().unwrap().end as usize, text.len());
    }

    fn upstream_test_resources() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../sudachi.rs/sudachi/tests/resources")
    }

    /// Write `bytes` to a fresh file under the system temp dir.
    fn temp_file(name: &str, bytes: &[u8]) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sudachi-swift-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(name);
        std::fs::write(&path, bytes).unwrap();
        path
    }

    fn test_dictionary_config() -> TokenizerConfig {
        // Built-in plugin class names; the upstream test sudachi.json uses
        // `$exe/...` dynamic plugins, which this crate does not ship.
        let config = r#"{
            "characterDefinitionFile": "char.def",
            "inputTextPlugin": [{ "class": "com.worksap.nlp.sudachi.DefaultInputTextPlugin" }],
            "oovProviderPlugin": [{
                "class": "com.worksap.nlp.sudachi.SimpleOovPlugin",
                "oovPOS": ["名詞", "普通名詞", "一般", "*", "*", "*"],
                "leftId": 8, "rightId": 8, "cost": 6000
            }],
            "pathRewritePlugin": [{
                "class": "com.worksap.nlp.sudachi.JoinNumericPlugin",
                "enableNormalize": true
            }]
        }"#;
        let resources = upstream_test_resources();
        TokenizerConfig {
            dictionary_path: resources.join("system.dic.test").to_string_lossy().into(),
            config_path: Some(
                temp_file("sudachi.json", config.as_bytes())
                    .to_string_lossy()
                    .into(),
            ),
            resource_path: Some(resources.to_string_lossy().into()),
            user_dictionary_paths: vec![resources.join("user.dic.test").to_string_lossy().into()],
        }
    }

    #[test]
    fn test_dictionary_format_detection() {
        let resources = upstream_test_resources();
        let path = |name: &str| resources.join(name).to_string_lossy().to_string();
        assert_eq!(
            dictionary_format(path("system.dic.test")),
            DictionaryFormat::V1
        );
        assert_eq!(
            dictionary_format(path("user.dic.test")),
            DictionaryFormat::V1
        );

        // Legacy system dictionary header (SYSTEM_DICT_VERSION_2) followed by padding.
        let mut v0 = 0xce9f011a92394434u64.to_le_bytes().to_vec();
        v0.extend_from_slice(&[0u8; 32]);
        let v0_path = temp_file("v0.dic", &v0);
        assert_eq!(
            dictionary_format(v0_path.to_string_lossy().into()),
            DictionaryFormat::LegacyV0
        );

        let garbage = temp_file("garbage.dic", b"definitely not a sudachi dictionary");
        assert_eq!(
            dictionary_format(garbage.to_string_lossy().into()),
            DictionaryFormat::Unknown
        );
        let short = temp_file("short.dic", b"Sudachi");
        assert_eq!(
            dictionary_format(short.to_string_lossy().into()),
            DictionaryFormat::Unknown
        );
        assert_eq!(
            dictionary_format("/nonexistent/system.dic".into()),
            DictionaryFormat::Unknown
        );
    }

    #[test]
    fn test_legacy_dictionary_is_rejected_with_actionable_message() {
        let mut v0 = 0xce9f011a92394434u64.to_le_bytes().to_vec();
        v0.extend_from_slice(&[0u8; 32]);
        let v0_path = temp_file("legacy.dic", &v0);
        let err = match Tokenizer::with_dictionary(v0_path.to_string_lossy().into()) {
            Ok(_) => panic!("a V0 dictionary must not load"),
            Err(e) => e,
        };
        match err {
            SudachiError::DictionaryLoadError { message } => {
                assert!(message.contains("legacy V0"), "{message}");
                assert!(message.contains("sudachidict/v1/"), "{message}");
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn test_tokenize_with_upstream_test_dictionary() {
        let tokenizer = Tokenizer::new(test_dictionary_config()).unwrap();
        let morphemes = tokenizer
            .tokenize("東京都".into(), TokenizeMode::C)
            .unwrap();
        let surfaces: Vec<&str> = morphemes.iter().map(|m| m.surface.as_str()).collect();
        assert_eq!(surfaces.concat(), "東京都");
        assert!(morphemes.iter().all(|m| !m.part_of_speech.is_empty()));

        let pos_id = morphemes[0].part_of_speech_id;
        assert_eq!(
            tokenizer.pos_of(pos_id),
            Some(morphemes[0].part_of_speech.clone())
        );
        assert!(!tokenizer.lookup("東京".into()).unwrap().is_empty());
    }

    #[test]
    fn test_split_sentences_single_no_terminator() {
        let text = "no terminator here";
        let sentences = split_sentences(text.to_string());
        assert_eq!(sentences.len(), 1);
        assert_eq!(sentences[0].begin, 0);
        assert_eq!(sentences[0].end as usize, text.len());
        assert_eq!(sentences[0].text, text);
    }
}
