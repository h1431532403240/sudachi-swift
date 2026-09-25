#!/usr/bin/env bash
#
# build-local.sh — produce the Rust XCFramework and UniFFI Swift bindings,
# then stage them at the locations the root Package.swift expects.
#
# After running this script, `swift build` against the root Package.swift
# will work locally (Examples/, IDE, or any consumer pointing at this repo
# via `.package(path:)`). Published SPM consumers do not need this script;
# the release workflow runs the equivalent steps in CI.
#
# Usage:
#   ./scripts/build-local.sh              # every platform, release profile
#   PROFILE=debug ./scripts/build-local.sh
#   PLATFORMS="macos ios" ./scripts/build-local.sh
#       Only some platforms (any of: macos ios maccatalyst tvos visionos).
#
# Every platform builds with stable Rust; nothing needs nightly. The default
# toolchain must have the target of every requested platform installed:
#   rustup target add aarch64-apple-darwin x86_64-apple-darwin \
#     aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios \
#     aarch64-apple-ios-macabi x86_64-apple-ios-macabi \
#     aarch64-apple-tvos aarch64-apple-tvos-sim \
#     aarch64-apple-visionos aarch64-apple-visionos-sim
# tvOS and visionOS need a Rust release that ships their standard library
# (CI builds with RUST_STABLE from .github/workflows/build.yml).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROFILE="${PROFILE:-release}"
PLATFORMS="${PLATFORMS:-macos ios maccatalyst tvos visionos}"

# cargo-swift bundles its own uniffi_bindgen, which must match the `uniffi`
# version pinned in rust/Cargo.toml (0.11.1 bundles uniffi_bindgen =0.31.1).
# CI installs the version read from this line.
CARGO_SWIFT_VERSION="0.11.1"
installed_cargo_swift="$(cargo swift --version 2>/dev/null | awk '{print $2}' || true)"
if [ "$installed_cargo_swift" != "$CARGO_SWIFT_VERSION" ]; then
    echo "error: cargo-swift $CARGO_SWIFT_VERSION is required (found: ${installed_cargo_swift:-none})."
    echo "  cargo install cargo-swift --version $CARGO_SWIFT_VERSION --locked"
    exit 1
fi

# For each platform: the Rust targets cargo-swift builds, and the slices
# (LibraryIdentifier) it must produce in the XCFramework.
#
# tvOS: cargo-swift's tvOS Simulator slice is a universal of
# aarch64-apple-tvos-sim and x86_64-apple-tvos. The x86_64 one is a Tier 3
# target without a prebuilt standard library, and cargo-swift switches every
# build to `cargo +nightly` as soon as one requested target isn't in
# `rustup target list`. `--exclude-arch x86_64-apple-tvos` (below) drops it,
# so the slice is arm64 only, like the visionOS Simulator slice (Rust has no
# x86_64 visionOS target at all).
read -ra platform_arr <<< "$PLATFORMS"
if [ "${#platform_arr[@]}" -eq 0 ]; then
    echo "error: PLATFORMS is empty."
    exit 1
fi
duplicates="$(printf '%s\n' "${platform_arr[@]}" | sort | uniq -d | tr '\n' ' ')"
if [ -n "$duplicates" ]; then
    echo "error: PLATFORMS lists these more than once: $duplicates"
    exit 1
fi
rust_targets=()
expected_slices=()
for p in "${platform_arr[@]}"; do
    case "$p" in
        macos)
            rust_targets+=(aarch64-apple-darwin x86_64-apple-darwin)
            expected_slices+=(macos-arm64_x86_64) ;;
        ios)
            rust_targets+=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)
            expected_slices+=(ios-arm64 ios-arm64_x86_64-simulator) ;;
        maccatalyst)
            rust_targets+=(aarch64-apple-ios-macabi x86_64-apple-ios-macabi)
            expected_slices+=(ios-arm64_x86_64-maccatalyst) ;;
        tvos)
            rust_targets+=(aarch64-apple-tvos aarch64-apple-tvos-sim)
            expected_slices+=(tvos-arm64 tvos-arm64-simulator) ;;
        visionos)
            rust_targets+=(aarch64-apple-visionos aarch64-apple-visionos-sim)
            expected_slices+=(xros-arm64 xros-arm64-simulator) ;;
        *)
            echo "error: unknown platform '$p' in PLATFORMS (expected any of: macos ios maccatalyst tvos visionos)."
            exit 1 ;;
    esac
done

# Check the targets up front: a missing one would otherwise fail deep inside
# cargo-swift, or (if this toolchain doesn't ship it at all) make cargo-swift
# silently switch every build to `cargo +nightly`. cargo-swift runs rustup
# from rust/, so ask from there too (same toolchain resolution).
if ! command -v rustup >/dev/null 2>&1; then
    echo "error: rustup is required (cargo-swift uses \`rustup target list\` to pick the toolchain)."
    exit 1
fi
toolchain_desc="$(cd rust && rustc -V 2>/dev/null || echo '?')"
installed_targets="$(cd rust && rustup target list --installed)"
missing_targets=()
for t in "${rust_targets[@]}"; do
    if ! grep -Fxq "$t" <<< "$installed_targets"; then
        missing_targets+=("$t")
    fi
done
if [ "${#missing_targets[@]}" -gt 0 ]; then
    echo "error: Rust targets not installed for the default toolchain ($toolchain_desc): ${missing_targets[*]}"
    echo "  rustup target add ${missing_targets[*]}"
    echo "  If rustup doesn't list one of them, this Rust release doesn't ship its standard"
    echo "  library: update stable Rust, or leave that platform out of PLATFORMS."
    exit 1
fi

# cargo-swift writes its self-contained Swift package into `<crate>/SudachiSwift/`.
# We treat that directory as a build artifact and extract only the bits we need.
CARGO_SWIFT_PKG="rust/SudachiSwift"

echo "==> Building XCFramework + UniFFI bindings (platforms: $PLATFORMS, profile: $PROFILE, rust: $toolchain_desc)"
rm -rf "$CARGO_SWIFT_PKG"

# No --xcframework-name: cargo-swift 0.11.1 deprecates it and names the
# XCFramework after the FFI module instead (sudachi_swiftFFI, UniFFI's
# default for this crate; there is no rust/uniffi.toml to change it). The
# name only matters inside $CARGO_SWIFT_PKG, and the script finds the one
# .xcframework there rather than repeating it: the XCFramework is staged as
# SudachiSwift.xcframework, and the module the bindings import is declared by
# the modulemap inside it, not by its file name.
# Bumping CARGO_SWIFT_VERSION requires re-checking the output layout (the
# bindings path and the .xcframework lookup below, and the slice names above)
# before relying on this script.
cargo_args=(--name SudachiSwift --skip-toolchains-check -y)
# No effect unless tvos is requested (see above).
cargo_args+=(--exclude-arch x86_64-apple-tvos)
[ "$PROFILE" = "release" ] && cargo_args+=(--release)
for p in "${platform_arr[@]}"; do
    cargo_args+=(-p "$p")
done

echo "==> cargo swift package ${cargo_args[*]}"
(
    cd rust
    cargo swift package "${cargo_args[@]}"
)

GENERATED_BINDINGS="$CARGO_SWIFT_PKG/Sources/SudachiSwift/sudachi_swift.swift"
# The XCFramework cargo-swift just wrote, whatever its name (see above).
# $CARGO_SWIFT_PKG was removed before the build, so no stale one can match.
generated_xcframeworks=()
for d in "$CARGO_SWIFT_PKG"/*.xcframework; do
    if [ -d "$d" ]; then
        generated_xcframeworks+=("$d")
    fi
done
GENERATED_XCFRAMEWORK="${generated_xcframeworks[0]:-}"

if [ ! -f "$GENERATED_BINDINGS" ] || [ "${#generated_xcframeworks[@]}" -ne 1 ] \
    || [ ! -f "$GENERATED_XCFRAMEWORK/Info.plist" ]; then
    echo "error: cargo-swift did not produce the expected layout (the Swift bindings and exactly one .xcframework in $CARGO_SWIFT_PKG)."
    echo "  cargo-swift version: $(cargo swift --version 2>&1 || echo '?')"
    echo "  contents of $CARGO_SWIFT_PKG:"
    find "$CARGO_SWIFT_PKG" -maxdepth 4 2>&1 || echo "  (missing)"
    echo "  contents of rust/:"
    ls -la rust/ 2>&1
    exit 1
fi

# The XCFramework must hold exactly the slices of the requested platforms,
# each with its library, before anything is staged. (A slice missing from
# the release zip would only show up in an app build for that platform.)
echo "==> Checking the slices in $GENERATED_XCFRAMEWORK"
xcf_plist="$GENERATED_XCFRAMEWORK/Info.plist"
indent() {
    local line
    while IFS= read -r line; do
        printf '    %s\n' "$line"
    done <<< "$1"
}
slice_count="$(plutil -extract AvailableLibraries raw -o - "$xcf_plist")"
actual_slices=()
for ((i = 0; i < slice_count; i++)); do
    slice="$(plutil -extract "AvailableLibraries.$i.LibraryIdentifier" raw -o - "$xcf_plist")"
    library="$(plutil -extract "AvailableLibraries.$i.LibraryPath" raw -o - "$xcf_plist")"
    if [ ! -f "$GENERATED_XCFRAMEWORK/$slice/$library" ]; then
        echo "error: $GENERATED_XCFRAMEWORK/$slice/$library (listed in its Info.plist) is missing."
        exit 1
    fi
    actual_slices+=("$slice")
done
expected_sorted="$(printf '%s\n' "${expected_slices[@]}" | LC_ALL=C sort -u)"
actual_sorted="$( { [ "${#actual_slices[@]}" -eq 0 ] || printf '%s\n' "${actual_slices[@]}"; } | LC_ALL=C sort)"
if [ "$actual_sorted" != "$expected_sorted" ]; then
    echo "error: $GENERATED_XCFRAMEWORK does not hold the expected slices for PLATFORMS=\"$PLATFORMS\"."
    echo "  expected:"
    indent "$expected_sorted"
    echo "  found (Info.plist AvailableLibraries):"
    indent "${actual_sorted:-(none)}"
    echo "  Did the cargo-swift output change (version bump)? Update the slice names in scripts/build-local.sh."
    exit 1
fi
indent "$actual_sorted"

STAGED_BINDINGS="Sources/SudachiSwift/sudachi_swift.swift"
echo "==> Staging Swift bindings at $STAGED_BINDINGS"
cp "$GENERATED_BINDINGS" "$STAGED_BINDINGS"

# Keep a leading U+FEFF in strings returned from Rust. UniFFI's generated
# FfiConverterString decodes with `String(bytes:encoding: .utf8)`, which
# drops a leading BOM, so a morpheme or sentence that starts with U+FEFF came
# back shorter than its byte offsets say (surface != utf8[begin..<end]).
# `String(decoding:as: UTF8.self)` keeps every scalar; Rust strings are
# always valid UTF-8, so its repair of invalid input never applies. The
# expected count guards against a cargo-swift/uniffi bump changing the
# generated code and silently skipping this.
EXPECTED_STRING_DECODES=2
echo "==> Patching $STAGED_BINDINGS to keep a leading BOM in strings from Rust"
patched_decodes="$(perl -0777 -pi -e '
    $n += s/String\(bytes: ((?:[^()]|(\((?:[^()]|(?2))*\)))*?), encoding: String\.Encoding\.utf8\)!/String(decoding: $1, as: UTF8.self)/g;
    END { print STDOUT ($n || 0) }
' "$STAGED_BINDINGS")"
if [ "$patched_decodes" != "$EXPECTED_STRING_DECODES" ] || grep -q 'String(bytes:' "$STAGED_BINDINGS"; then
    echo "error: expected to patch $EXPECTED_STRING_DECODES \`String(bytes: …, encoding: String.Encoding.utf8)!\` in $STAGED_BINDINGS, patched ${patched_decodes:-0}."
    echo "  remaining String(bytes:) calls:"
    grep -n 'String(bytes:' "$STAGED_BINDINGS" || echo "  (none)"
    echo "  The generated string decoding changed (cargo-swift/uniffi bump?): update the pattern or"
    echo "  EXPECTED_STRING_DECODES in scripts/build-local.sh so a leading U+FEFF stays preserved."
    exit 1
fi

echo "==> Staging XCFramework at SudachiSwift.xcframework/"
rm -rf SudachiSwift.xcframework
cp -R "$GENERATED_XCFRAMEWORK" SudachiSwift.xcframework

echo "==> Linking every XCFramework slice for its own platform"
"$REPO_ROOT/scripts/check-xcframework-links.sh" SudachiSwift.xcframework

echo "==> Refreshing bundled resources from sudachi.rs/resources/"
mkdir -p Sources/SudachiSwift/Resources
for f in char.def unk.def rewrite.def sudachi.json; do
    cp "sudachi.rs/resources/$f" "Sources/SudachiSwift/Resources/$f"
done

echo
echo "Done. The root Package.swift can now build locally:"
echo "  swift build"
echo "  cd Examples/BasicUsage && swift run BasicUsage"
