//! Swift bindings for sudachi.rs Japanese morphological analyzer
//!
//! This crate provides UniFFI bindings to expose sudachi.rs functionality to Swift.

use std::borrow::Cow;
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};
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

/// Errors thrown by this library.
///
/// In Swift, `message` gives the bare message for display
/// (`localizedDescription` is UniFFI's debug description of the case).
///
/// An internal failure (a Rust panic, which should not happen) is thrown as
/// a different `Error` type, not as `SudachiError`, so keep a generic
/// `catch` after `catch let error as SudachiError`.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SudachiError {
    /// A dictionary or resource file could not be loaded (missing, legacy
    /// V0, or built against another system dictionary).
    #[error("Failed to load dictionary: {message}")]
    DictionaryLoadError { message: String },

    /// The config file could not be read or parsed. The message starts with
    /// the config file's path.
    #[error("Failed to load config: {message}")]
    ConfigError { message: String },

    /// Analysis failed, e.g. because the input is too long (see
    /// `Tokenizer.tokenize`).
    #[error("Tokenization failed: {message}")]
    TokenizeError { message: String },

    /// An argument is invalid, e.g. an empty `dictionaryPath`.
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
    /// Dictionary ID: 0 = system; 1+ = user dictionaries, numbered with the
    /// config file's `userDict` entries first, then `userDictionaryPaths`;
    /// -1 = OOV.
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
    /// Sub-unit decomposition (e.g. from A mode). If the morpheme can't be
    /// split further, this is `[morpheme]` when `add_single` was true and
    /// empty when it was false.
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
///
/// Dictionaries and the config file are trusted input: load them only from
/// sources you control. A malformed or tampered `.dic` can crash the process
/// instead of throwing, and a plugin `class` in the config that isn't one of
/// the built-in `com.worksap.nlp.sudachi.*` names is loaded as a native
/// library, so its code runs in your process.
#[derive(Clone, Debug, uniffi::Record)]
pub struct TokenizerConfig {
    /// Path to the system dictionary file (.dic), in binary format V1. A
    /// relative path resolves like resources (see `resourcePath`, then the
    /// current directory); prefer absolute paths. An empty path throws
    /// `InvalidArgument`.
    ///
    /// Dictionaries are memory-mapped while a Tokenizer uses them: to update
    /// one, move a new file into place (rename), never overwrite or truncate
    /// the file in place, which can crash the process.
    pub dictionary_path: String,
    /// Optional path to sudachi.json config file. When omitted, the default
    /// config embedded in sudachi.rs is used. Use only a config you control
    /// (see the note on trusted input above). A load error message starts
    /// with this path.
    pub config_path: Option<String>,
    /// Optional resource directory (where char.def, unk.def, rewrite.def are
    /// located). Resources are resolved in sudachi.rs order: this directory,
    /// then the config's `path` field, then the config file's directory, then
    /// the defaults embedded in sudachi.rs. A missing directory or file is not
    /// an error: resolution silently falls back to the next location and, in
    /// the end, to the built-in defaults.
    pub resource_path: Option<String>,
    /// User dictionary files, applied in order and appended after the config
    /// file's `userDict` entries. Relative paths resolve like resources
    /// (`resourcePath`, the config's `path` field, the config file's
    /// directory, then the current directory), not against the system `.dic`'s
    /// directory, so prefer absolute paths.
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

/// A loaded system dictionary (plus user dictionaries) and the analyzer.
///
/// Loading a dictionary takes tens of milliseconds or more, so create one
/// Tokenizer and reuse it; it can be shared across threads. Dictionaries and
/// config files are trusted input (see `TokenizerConfig`).
#[derive(uniffi::Object)]
pub struct Tokenizer {
    dictionary: Arc<JapaneseDictionary>,
}

#[uniffi::export]
impl Tokenizer {
    /// Load the dictionaries described by `config`.
    ///
    /// Throws `InvalidArgument` when `dictionaryPath` is empty,
    /// `ConfigError` when the config file can't be read or parsed, and
    /// `DictionaryLoadError` when a dictionary or resource can't be loaded
    /// (including legacy V0 dictionaries).
    #[uniffi::constructor]
    pub fn new(config: TokenizerConfig) -> Result<Arc<Self>, SudachiError> {
        if config.dictionary_path.is_empty() {
            // Upstream would resolve "" to the first resource directory and
            // fail with an unrelated "Invalid argument (os error 22)".
            return Err(SudachiError::InvalidArgument {
                message: "dictionaryPath is empty; pass the path of a V1 system .dic file".into(),
            });
        }
        // Same construction as the sudachi.rs CLI (`Config::new`), so
        // resource and dictionary path resolution follows upstream. It only
        // fails while loading the config file.
        let mut cfg = Config::new(
            config.config_path.as_ref().map(PathBuf::from),
            config.resource_path.as_ref().map(PathBuf::from),
            Some(PathBuf::from(&config.dictionary_path)),
        )
        .map_err(|e| SudachiError::ConfigError {
            message: match &config.config_path {
                Some(path) => format!("{path}: {e}"),
                None => e.to_string(),
            },
        })?;
        cfg.user_dicts
            .extend(config.user_dictionary_paths.iter().map(PathBuf::from));

        // Must run before `from_cfg`, which parses char.def before it reads
        // the dictionary header.
        ensure_dictionaries_loadable(&cfg)?;

        let dictionary =
            JapaneseDictionary::from_cfg(&cfg).map_err(|e| SudachiError::DictionaryLoadError {
                message: e.to_string(),
            })?;

        Ok(Arc::new(Self {
            dictionary: Arc::new(dictionary),
        }))
    }

    /// Load the system dictionary at `dictionaryPath` with the config and
    /// resources embedded in sudachi.rs. Throws like `init(config:)`.
    #[uniffi::constructor]
    pub fn with_dictionary(dictionary_path: String) -> Result<Arc<Self>, SudachiError> {
        Self::new(TokenizerConfig {
            dictionary_path,
            config_path: None,
            resource_path: None,
            user_dictionary_paths: Vec::new(),
        })
    }

    /// Split `text` into morphemes using `mode`.
    ///
    /// Input limit: throws `TokenizeError` when `text` is longer than 49,149
    /// UTF-8 bytes (about 16,000 Japanese characters), or when input
    /// normalization expands it past 65,535 bytes (e.g. `㍿` → `株式会社`).
    /// Split long text with the free function `splitSentences(text:)` and
    /// tokenize each range; a range
    /// can itself be longer when the text has no sentence-ending punctuation,
    /// so cut such a range further (e.g. at line breaks). The same limit
    /// applies to `tokenizeWithSubunits` and `lookup`.
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
    ///
    /// Throws `TokenizeError` for input over the limit described on
    /// `tokenize`.
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
    /// Several entries can share the same surface and offsets (homographs).
    ///
    /// Throws `TokenizeError` for input over the limit described on
    /// `tokenize`.
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
    ///
    /// Caveat: with sudachi.rs 0.6.11–0.7.0, a boundary right after a lexicon
    /// entry such as `。` is not split when more text follows (upstream
    /// `sentence_detector` bug), so real dictionaries often return the whole
    /// text as one range. Since sudachi.rs 0.7.0 it also stops splitting
    /// after the first ASCII `"`. Use the free function `splitSentences(text:)`, which works around the
    /// ASCII `"` issue, for rule-based splitting.
    pub fn split_sentences(&self, text: String) -> Vec<SentenceRange> {
        collect_sentences(
            SentenceSplitter::new().with_checker(self.dictionary.lexicon()),
            &text,
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

/// Split `analyzed` with `splitter`, taking each range's text from
/// `original`, which must have the same byte length and char boundaries as
/// `analyzed` (see `mask_ascii_double_quotes`).
fn collect_sentences<S: SplitSentences>(
    splitter: S,
    analyzed: &str,
    original: &str,
) -> Vec<SentenceRange> {
    debug_assert_eq!(analyzed.len(), original.len());
    splitter
        .split(analyzed)
        .map(|(range, _)| SentenceRange {
            begin: range.start as u32,
            end: range.end as u32,
            text: original[range].to_string(),
        })
        .collect()
}

/// Replace every ASCII `"` with `'`, which the sentence detector doesn't
/// treat specially. Both are one byte, so byte offsets and char boundaries
/// are unchanged.
///
/// sudachi.rs 0.7.0 (upstream PR #340) added `"` to both its opening and
/// closing bracket sets, and the opening check wins, so after the first
/// ASCII `"` no sentence boundary is found. sudachi.rs 0.6.11 and Sudachi
/// (Java) 0.8.2 treat `"` as an ordinary character, as the masked text
/// makes 0.7.0 do.
fn mask_ascii_double_quotes(text: &str) -> Cow<'_, str> {
    if text.contains('"') {
        Cow::Owned(text.replace('"', "'"))
    } else {
        Cow::Borrowed(text)
    }
}

// ============ Free Functions ============

/// Get the library version
#[uniffi::export]
pub fn get_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Rule-based sentence splitter (no lexicon, no dictionary needed). For
/// lexicon-aware splitting see `Tokenizer.splitSentences(text:)`, which has known
/// upstream issues.
///
/// Works around a sudachi.rs 0.7.0 regression where no sentence was split
/// after the first ASCII `"`: the splitter runs on a copy of `text` with
/// every ASCII `"` replaced by `'` (same byte offsets), and each range's
/// `text` is sliced from the original `text`. Results match sudachi.rs
/// 0.6.11 and Sudachi (Java) 0.8.2.
///
/// Useful for chunking long text before `Tokenizer.tokenize` (see its input
/// limit). When no sentence ends within the first 4,096 characters, the
/// rest of the text comes back as one range, which can exceed that limit.
#[uniffi::export]
pub fn split_sentences(text: String) -> Vec<SentenceRange> {
    collect_sentences(
        SentenceSplitter::new(),
        &mask_ascii_double_quotes(&text),
        &text,
    )
}

// ============ Dictionary Format ============

/// Binary format of a Sudachi dictionary file.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum DictionaryFormat {
    /// The header says binary format V1, the only format sudachi.rs 0.7+ can
    /// load (only the header is read: truncation beyond it isn't detected).
    V1,
    /// Legacy format used by sudachi.rs 0.6 and earlier. Download a V1 build
    /// of the system dictionary and rebuild user dictionaries against it.
    LegacyV0,
    /// Unreadable, not a Sudachi dictionary, or a format this version does
    /// not know.
    Unknown,
}

/// First bytes of a V1 dictionary (sudachi.rs `dic/description.rs`).
const V1_MAGIC_BYTES: &[u8; 16] = b"SudachiBinaryDic";
/// Little-endian u64 that follows the magic in a V1 header.
const V1_FORMAT_VERSION: u64 = 1;
/// Magic plus format version.
const V1_HEADER_LEN: usize = V1_MAGIC_BYTES.len() + 8;

/// Detect the binary format of the dictionary file at `path` by reading its
/// header (the first 24 bytes) only. Useful for deciding whether a
/// previously downloaded `.dic` needs to be replaced.
#[uniffi::export]
pub fn dictionary_format(path: String) -> DictionaryFormat {
    detect_dictionary_format(Path::new(&path))
}

fn detect_dictionary_format(path: &Path) -> DictionaryFormat {
    let mut header = [0u8; V1_HEADER_LEN];
    // A V0 file shorter than this can't be a real dictionary either.
    if File::open(path)
        .and_then(|mut f| f.read_exact(&mut header))
        .is_err()
    {
        return DictionaryFormat::Unknown;
    }
    let (magic, version) = header.split_at(V1_MAGIC_BYTES.len());
    if magic == V1_MAGIC_BYTES {
        let version = u64::from_le_bytes(version.try_into().expect("8-byte version field"));
        return if version == V1_FORMAT_VERSION {
            DictionaryFormat::V1
        } else {
            DictionaryFormat::Unknown
        };
    }
    let legacy_version = u64::from_le_bytes(header[..8].try_into().expect("8-byte V0 header"));
    match HeaderVersion::from_u64(legacy_version) {
        Some(_) => DictionaryFormat::LegacyV0,
        None => DictionaryFormat::Unknown,
    }
}

/// Fail early with an actionable message when a dictionary that
/// `JapaneseDictionary::from_cfg` would open is V0. sudachi.rs parses
/// char.def before the dictionary header, so without this check a V0
/// dictionary can surface as an unrelated char.def error or a bare
/// "Invalid description: V0 version".
///
/// Checks the paths exactly as upstream resolves them (`resourcePath`, the
/// config's `path` field, the config file's directory, then the current
/// directory), including `userDict` entries from a custom config file. When
/// resolution fails, the check is skipped so `from_cfg` reports the real
/// error.
fn ensure_dictionaries_loadable(cfg: &Config) -> Result<(), SudachiError> {
    let Ok(system_dict) = cfg.resolved_system_dict() else {
        return Ok(());
    };
    ensure_loadable_format(&system_dict, "System dictionary")?;
    let Ok(user_dicts) = cfg.resolved_user_dicts() else {
        return Ok(());
    };
    for user_dict in &user_dicts {
        ensure_loadable_format(user_dict, "User dictionary")?;
    }
    Ok(())
}

fn ensure_loadable_format(path: &Path, kind: &str) -> Result<(), SudachiError> {
    if detect_dictionary_format(path) != DictionaryFormat::LegacyV0 {
        return Ok(());
    }
    Err(SudachiError::DictionaryLoadError {
        message: format!(
            "{kind} {} uses the legacy V0 format, which SudachiSwift 0.7+ (sudachi.rs 0.7+) cannot read. \
             Download a V1 dictionary from https://d2ej7fkh96fzlu.cloudfront.net/sudachidict/v1/ \
             and rebuild user dictionaries against it.",
            path.display()
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

    fn path_string(path: &Path) -> String {
        path.to_string_lossy().into_owned()
    }

    /// Write `bytes` to `dir/name` and return the full path.
    fn write_file(dir: &Path, name: &str, bytes: &[u8]) -> PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, bytes).unwrap();
        path
    }

    /// V0 system dictionary header (SYSTEM_DICT_VERSION_2).
    const V0_SYSTEM_VERSION: u64 = 0xce9f011a92394434;
    /// V0 user dictionary header (USER_DICT_VERSION_3).
    const V0_USER_VERSION: u64 = 0xca9811756ff64fb0;

    /// A synthetic V0 dictionary: the version header followed by padding.
    fn v0_dictionary(version: u64) -> Vec<u8> {
        let mut bytes = version.to_le_bytes().to_vec();
        bytes.extend_from_slice(&[0u8; 32]);
        bytes
    }

    /// A V1 header (magic + little-endian format version) followed by `tail`.
    fn v1_header(version: u64, tail: &[u8]) -> Vec<u8> {
        let mut bytes = V1_MAGIC_BYTES.to_vec();
        bytes.extend_from_slice(&version.to_le_bytes());
        bytes.extend_from_slice(tail);
        bytes
    }

    /// Write a sudachi.json into `dir` that uses built-in plugin class names
    /// (the upstream test sudachi.json uses `$exe/...` dynamic plugins, which
    /// this crate does not ship) and lists `user_dicts` in `userDict`.
    fn write_test_config(dir: &Path, user_dicts: &[&str]) -> PathBuf {
        // `{:?}` of plain ASCII file names is valid JSON.
        let config = format!(
            r#"{{
                "userDict": {user_dicts:?},
                "characterDefinitionFile": "char.def",
                "inputTextPlugin": [{{ "class": "com.worksap.nlp.sudachi.DefaultInputTextPlugin" }}],
                "oovProviderPlugin": [{{
                    "class": "com.worksap.nlp.sudachi.SimpleOovPlugin",
                    "oovPOS": ["名詞", "普通名詞", "一般", "*", "*", "*"],
                    "leftId": 8, "rightId": 8, "cost": 6000
                }}],
                "pathRewritePlugin": [{{
                    "class": "com.worksap.nlp.sudachi.JoinNumericPlugin",
                    "enableNormalize": true
                }}]
            }}"#
        );
        write_file(dir, "sudachi.json", config.as_bytes())
    }

    /// Upstream V1 test system + user dictionaries, with the config written
    /// into `config_dir` (which must outlive the call to `Tokenizer::new`).
    fn test_dictionary_config(config_dir: &Path) -> TokenizerConfig {
        let resources = upstream_test_resources();
        TokenizerConfig {
            dictionary_path: path_string(&resources.join("system.dic.test")),
            config_path: Some(path_string(&write_test_config(config_dir, &[]))),
            resource_path: Some(path_string(&resources)),
            user_dictionary_paths: vec![path_string(&resources.join("user.dic.test"))],
        }
    }

    /// The `DictionaryLoadError` message `Tokenizer::new(config)` fails with.
    fn load_error_message(config: TokenizerConfig) -> String {
        match Tokenizer::new(config) {
            Ok(_) => panic!("the tokenizer must not load"),
            Err(SudachiError::DictionaryLoadError { message }) => message,
            Err(other) => panic!("unexpected error: {other:?}"),
        }
    }

    fn assert_actionable_v0_message(message: &str, kind: &str, path: &Path) {
        assert!(message.starts_with(kind), "{message}");
        assert!(message.contains(&path_string(path)), "{message}");
        assert!(message.contains("legacy V0"), "{message}");
        assert!(message.contains("sudachidict/v1/"), "{message}");
    }

    #[test]
    fn test_dictionary_format_detection() {
        let resources = upstream_test_resources();
        let format_of = |path: &Path| dictionary_format(path_string(path));
        assert_eq!(
            format_of(&resources.join("system.dic.test")),
            DictionaryFormat::V1
        );
        assert_eq!(
            format_of(&resources.join("user.dic.test")),
            DictionaryFormat::V1
        );

        let dir = tempfile::tempdir().unwrap();
        let file = |name: &str, bytes: &[u8]| write_file(dir.path(), name, bytes);

        let v0_system = file("v0_system.dic", &v0_dictionary(V0_SYSTEM_VERSION));
        assert_eq!(format_of(&v0_system), DictionaryFormat::LegacyV0);
        let v0_user = file("v0_user.dic", &v0_dictionary(V0_USER_VERSION));
        assert_eq!(format_of(&v0_user), DictionaryFormat::LegacyV0);

        // Only the header is read, so a V1 header alone reports V1.
        let v1_header_only = file("v1_header_only.dic", &v1_header(1, &[]));
        assert_eq!(format_of(&v1_header_only), DictionaryFormat::V1);
        // The magic with any other format version is not V1.
        let v2 = file("v2.dic", &v1_header(2, &[0u8; 32]));
        assert_eq!(format_of(&v2), DictionaryFormat::Unknown);
        let v0_marker = file("v1_magic_v0.dic", &v1_header(0, &[0u8; 32]));
        assert_eq!(format_of(&v0_marker), DictionaryFormat::Unknown);
        // The magic without the version field.
        let magic_only = file("magic_only.dic", V1_MAGIC_BYTES);
        assert_eq!(format_of(&magic_only), DictionaryFormat::Unknown);

        let garbage = file("garbage.dic", b"definitely not a sudachi dictionary");
        assert_eq!(format_of(&garbage), DictionaryFormat::Unknown);
        let short = file("short.dic", b"Sudachi");
        assert_eq!(format_of(&short), DictionaryFormat::Unknown);
        let empty = file("empty.dic", b"");
        assert_eq!(format_of(&empty), DictionaryFormat::Unknown);
        assert_eq!(format_of(dir.path()), DictionaryFormat::Unknown);
        assert_eq!(
            format_of(Path::new("/nonexistent/system.dic")),
            DictionaryFormat::Unknown
        );
    }

    #[test]
    fn test_legacy_dictionary_is_rejected_with_actionable_message() {
        let dir = tempfile::tempdir().unwrap();
        let v0_path = write_file(dir.path(), "legacy.dic", &v0_dictionary(V0_SYSTEM_VERSION));
        let message = match Tokenizer::with_dictionary(path_string(&v0_path)) {
            Ok(_) => panic!("a V0 dictionary must not load"),
            Err(SudachiError::DictionaryLoadError { message }) => message,
            Err(other) => panic!("unexpected error: {other:?}"),
        };
        assert_actionable_v0_message(&message, "System dictionary", &v0_path);
    }

    #[test]
    fn test_legacy_user_dictionary_from_config_user_dict_is_rejected() {
        // The V0 user dictionary is listed only in the custom config's
        // `userDict` (not in `user_dictionary_paths`), by a relative name that
        // upstream resolves against the config file's directory.
        let dir = tempfile::tempdir().unwrap();
        let v0_user = write_file(
            dir.path(),
            "legacy_user.dic",
            &v0_dictionary(V0_USER_VERSION),
        );
        let resources = upstream_test_resources();
        let config = TokenizerConfig {
            dictionary_path: path_string(&resources.join("system.dic.test")),
            config_path: Some(path_string(&write_test_config(
                dir.path(),
                &["legacy_user.dic"],
            ))),
            resource_path: Some(path_string(&resources)),
            user_dictionary_paths: Vec::new(),
        };
        assert_actionable_v0_message(&load_error_message(config), "User dictionary", &v0_user);
    }

    #[test]
    fn test_relative_legacy_system_dictionary_resolved_via_resource_path_is_rejected() {
        // Upstream resolves a relative dictionary path against resource_path
        // before the current directory, so the check must look there too.
        let name = "legacy_system_in_resource_path.dic";
        assert!(!Path::new(name).exists(), "CWD must not contain {name}");
        let dir = tempfile::tempdir().unwrap();
        let v0_system = write_file(dir.path(), name, &v0_dictionary(V0_SYSTEM_VERSION));
        let config = TokenizerConfig {
            dictionary_path: name.into(),
            config_path: None,
            resource_path: Some(path_string(dir.path())),
            user_dictionary_paths: Vec::new(),
        };
        assert_actionable_v0_message(&load_error_message(config), "System dictionary", &v0_system);
    }

    #[test]
    fn test_relative_v1_dictionaries_resolved_via_resource_path_load() {
        // The pre-check must not get in the way of relative V1 paths that
        // upstream resolves against resource_path.
        for name in ["system.dic.test", "user.dic.test"] {
            assert!(!Path::new(name).exists(), "CWD must not contain {name}");
        }
        let dir = tempfile::tempdir().unwrap();
        let config = TokenizerConfig {
            dictionary_path: "system.dic.test".into(),
            user_dictionary_paths: vec!["user.dic.test".into()],
            ..test_dictionary_config(dir.path())
        };
        let tokenizer = Tokenizer::new(config).unwrap();
        let surfaces: Vec<String> = tokenizer
            .tokenize("東京都".into(), TokenizeMode::C)
            .unwrap()
            .into_iter()
            .map(|m| m.surface)
            .collect();
        assert_eq!(surfaces.concat(), "東京都");
    }

    #[test]
    fn test_tokenize_with_upstream_test_dictionary() {
        let dir = tempfile::tempdir().unwrap();
        let tokenizer = Tokenizer::new(test_dictionary_config(dir.path())).unwrap();
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

    /// `(begin, end, text)` of each range, for compact assertions.
    fn sentence_tuples(sentences: &[SentenceRange]) -> Vec<(u32, u32, &str)> {
        sentences
            .iter()
            .map(|s| (s.begin, s.end, s.text.as_str()))
            .collect()
    }

    #[test]
    fn test_split_sentences_after_ascii_double_quote() {
        // sudachi.rs 0.7.0 alone returns this as one sentence.
        let text = "彼は\"はい\"と言った。次の文です。";
        let first = "彼は\"はい\"と言った。";
        let end = first.len() as u32;
        let sentences = split_sentences(text.into());
        assert_eq!(
            sentence_tuples(&sentences),
            [(0, end, first), (end, text.len() as u32, "次の文です。")]
        );
        // The offsets are those of the masked text the splitter saw.
        let masked: Vec<_> = SentenceSplitter::new()
            .split(&text.replace('"', "'"))
            .map(|(range, _)| (range.start as u32, range.end as u32))
            .collect();
        let offsets: Vec<_> = sentences.iter().map(|s| (s.begin, s.end)).collect();
        assert_eq!(offsets, masked);
    }

    #[test]
    fn test_split_sentences_opening_ascii_double_quote_starts_a_sentence() {
        // sudachi.rs 0.7.0 alone attaches the opening quote to the previous
        // sentence: ["一文目です。\"", "引用\"から始まる文。三文目です。"].
        let text = "一文目です。\"引用\"から始まる文。三文目です。";
        let texts: Vec<String> = split_sentences(text.into())
            .into_iter()
            .map(|s| s.text)
            .collect();
        assert_eq!(
            texts,
            ["一文目です。", "\"引用\"から始まる文。", "三文目です。"]
        );
    }

    #[test]
    fn test_split_sentences_only_ascii_double_quotes() {
        let text = "\"\"\"";
        assert_eq!(
            sentence_tuples(&split_sentences(text.into())),
            [(0, 3, text)]
        );
    }

    #[test]
    fn test_empty_dictionary_path_is_invalid_argument() {
        match Tokenizer::with_dictionary(String::new()) {
            Err(SudachiError::InvalidArgument { message }) => {
                assert!(message.contains("dictionaryPath"), "{message}")
            }
            Err(other) => panic!("unexpected error: {other:?}"),
            Ok(_) => panic!("an empty dictionary path must not load"),
        }
    }

    #[test]
    fn test_config_error_names_the_config_path() {
        let dir = tempfile::tempdir().unwrap();
        let missing = path_string(&dir.path().join("missing.json"));
        let invalid = path_string(&write_file(dir.path(), "invalid.json", b"{ not json"));
        for config_path in [missing, invalid] {
            let config = TokenizerConfig {
                config_path: Some(config_path.clone()),
                ..test_dictionary_config(dir.path())
            };
            match Tokenizer::new(config) {
                Err(SudachiError::ConfigError { message }) => {
                    assert!(
                        message.starts_with(&format!("{config_path}: ")),
                        "{message}"
                    )
                }
                Err(other) => panic!("unexpected error: {other:?}"),
                Ok(_) => panic!("{config_path} must not load"),
            }
        }
    }
}
