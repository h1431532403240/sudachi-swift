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
#   ./scripts/build-local.sh              # macOS + iOS, release profile
#   PROFILE=debug ./scripts/build-local.sh
#   NIGHTLY=1 PLATFORMS="macos ios tvos visionos" ./scripts/build-local.sh
#       Use Rust nightly with `-Z build-std` to also target tvOS / visionOS.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROFILE="${PROFILE:-release}"
PLATFORMS="${PLATFORMS:-macos ios}"
NIGHTLY="${NIGHTLY:-0}"

# cargo-swift writes its self-contained Swift package into `<crate>/SudachiSwift/`.
# We treat that directory as a build artifact and extract only the bits we need.
CARGO_SWIFT_PKG="rust/SudachiSwift"

echo "==> Building XCFramework + UniFFI bindings (platforms: $PLATFORMS, profile: $PROFILE, nightly: $NIGHTLY)"
rm -rf "$CARGO_SWIFT_PKG"

cargo_cmd=(cargo swift package)
[ "$NIGHTLY" = "1" ] && cargo_cmd=(cargo +nightly -Z build-std swift package)

cargo_args=(--name SudachiSwift --skip-toolchains-check -y)
[ "$PROFILE" = "release" ] && cargo_args+=(--release)
read -ra platform_arr <<< "$PLATFORMS"
for p in "${platform_arr[@]}"; do
    cargo_args+=(-p "$p")
done

(
    cd rust
    "${cargo_cmd[@]}" "${cargo_args[@]}"
)

GENERATED_BINDINGS="$CARGO_SWIFT_PKG/Sources/SudachiSwift/sudachi_swift.swift"
GENERATED_XCFRAMEWORK="$CARGO_SWIFT_PKG/RustFramework.xcframework"

if [ ! -f "$GENERATED_BINDINGS" ]; then
    echo "error: expected generated bindings at $GENERATED_BINDINGS" >&2
    exit 1
fi
if [ ! -d "$GENERATED_XCFRAMEWORK" ]; then
    echo "error: expected XCFramework at $GENERATED_XCFRAMEWORK" >&2
    exit 1
fi

echo "==> Staging Swift bindings at Sources/SudachiSwift/sudachi_swift.swift"
cp "$GENERATED_BINDINGS" Sources/SudachiSwift/sudachi_swift.swift

echo "==> Staging XCFramework at SudachiSwift.xcframework/"
rm -rf SudachiSwift.xcframework
cp -R "$GENERATED_XCFRAMEWORK" SudachiSwift.xcframework

echo "==> Refreshing bundled resources from sudachi.rs/resources/"
mkdir -p Sources/SudachiSwift/Resources
for f in char.def unk.def rewrite.def sudachi.json; do
    cp "sudachi.rs/resources/$f" "Sources/SudachiSwift/Resources/$f"
done

echo
echo "Done. The root Package.swift can now build locally:"
echo "  swift build"
echo "  cd Examples/BasicUsage && swift run BasicUsage"
