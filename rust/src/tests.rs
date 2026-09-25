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
