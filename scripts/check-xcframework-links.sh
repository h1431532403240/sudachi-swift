#!/usr/bin/env bash
#
# check-xcframework-links.sh — link every static-library slice of the
# XCFramework into a throwaway dylib for its own platform and architecture.
#
# `xcodebuild` builds of the package only compile the Swift module and do a
# partial link (`ld -r`), which never pulls libsudachi_swift.a in. This check
# force-references every UniFFI entry point the Swift bindings call, so the
# linker has to resolve the objects behind them (and everything they use)
# against the right SDK. A slice built for the wrong platform, a missing
# architecture or an unresolved symbol fails here instead of in an app.
#
# Usage: ./scripts/check-xcframework-links.sh [path/to/SudachiSwift.xcframework]

set -euo pipefail

XCF="${1:-SudachiSwift.xcframework}"
if [ ! -f "$XCF/Info.plist" ]; then
    echo "error: $XCF/Info.plist not found"
    exit 1
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# One line per slice: identifier, platform, variant (or "-"), binary path,
# comma-separated architectures.
python3 - "$XCF/Info.plist" > "$OUT/slices.txt" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    info = plistlib.load(f)
for lib in info["AvailableLibraries"]:
    print(lib["LibraryIdentifier"], lib["SupportedPlatform"],
          lib.get("SupportedPlatformVariant", "-"),
          lib.get("BinaryPath", lib["LibraryPath"]),
          ",".join(lib["SupportedArchitectures"]))
PY

failures=0
while read -r id platform variant binary archs; do
    lib="$XCF/$id/$binary"
    case "$platform/$variant" in
        macos/-)             sdk=macosx;           os=macos10.15;  suffix="" ;;
        ios/-)               sdk=iphoneos;         os=ios13.0;     suffix="" ;;
        ios/simulator)       sdk=iphonesimulator;  os=ios13.0;     suffix="-simulator" ;;
        ios/maccatalyst)     sdk=macosx;           os=ios13.1;     suffix="-macabi" ;;
        tvos/-)              sdk=appletvos;        os=tvos13.0;    suffix="" ;;
        tvos/simulator)      sdk=appletvsimulator; os=tvos13.0;    suffix="-simulator" ;;
        xros/-)              sdk=xros;             os=xros1.0;     suffix="" ;;
        xros/simulator)      sdk=xrsimulator;      os=xros1.0;     suffix="-simulator" ;;
        *)
            echo "error: $id: unknown platform $platform/$variant"
            failures=$((failures + 1))
            continue ;;
    esac

    # The FFI entry points exported by this slice (same set in every slice).
    undefined=()
    while read -r sym; do
        undefined+=("-Wl,-u,$sym")
    done < <(nm -gU "$lib" 2>/dev/null | awk '$2 == "T" && $3 ~ /^_(uniffi|ffi)_sudachi_swift_/ { print $3 }' | sort -u)
    if [ "${#undefined[@]}" -eq 0 ]; then
        echo "error: $id: no UniFFI symbols found in $lib"
        failures=$((failures + 1))
        continue
    fi

    for arch in ${archs//,/ }; do
        triple="$arch-apple-$os$suffix"
        if xcrun --sdk "$sdk" clang -target "$triple" -dynamiclib \
            "${undefined[@]}" "$lib" -o "$OUT/$id-$arch.dylib" \
            -Wl,-w 2> "$OUT/$id-$arch.log"; then
            echo "  ok  $id ($triple, ${#undefined[@]} entry points)"
        else
            echo "FAIL  $id ($triple):"
            sed 's/^/      /' "$OUT/$id-$arch.log" | head -20
            failures=$((failures + 1))
        fi
    done
done < "$OUT/slices.txt"

if [ "$failures" -gt 0 ]; then
    echo "error: $failures slice link check(s) failed."
    exit 1
fi
echo "All XCFramework slices link."
