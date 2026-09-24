#!/usr/bin/env python3
"""Generate THIRD_PARTY_NOTICES.md from rust/Cargo.lock.

Usage (from anywhere; paths are resolved relative to this script):

    python3 scripts/generate-third-party-notices.py            # write the file
    python3 scripts/generate-third-party-notices.py --check    # exit 1 if stale
    python3 scripts/generate-third-party-notices.py --offline  # no network
    python3 scripts/generate-third-party-notices.py --compare-archive \
        SudachiSwift.xcframework/ios-arm64/libsudachi_swift.a

What it does (no compilation):

1. `cargo fetch --locked` so every registry crate's source is on disk.
2. `cargo metadata --locked --filter-platform <triple>` for every Apple
   target the XCFramework ships, then walks the resolve graph from
   `sudachi-swift` along NORMAL dependency edges only. Build-script and dev
   dependencies and proc-macro crates never end up in the static library, so
   they are skipped. The union over all targets is what gets listed.
3. For each crate: name, version, declared license expression, repository,
   and the full text of the license/notice files in the crate's source
   directory. Identical texts are printed once and linked.
4. Adds fixed sections for sudachi.rs, the bundled resources, the Rust
   standard library and the MPL-2.0 UniFFI crates.

Standard library only. The output is deterministic: no timestamps, no
absolute paths, stable sort orders.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST = REPO_ROOT / "rust" / "Cargo.toml"
OUTPUT = REPO_ROOT / "THIRD_PARTY_NOTICES.md"
SUBMODULE = REPO_ROOT / "sudachi.rs"
RESOURCES = REPO_ROOT / "Sources" / "SudachiSwift" / "Resources"

# Every Rust target triple that ends up in SudachiSwift.xcframework
# (scripts/build-local.sh, including the nightly/tier-3 slices).
TARGETS = [
    "aarch64-apple-ios",
    "aarch64-apple-ios-sim",
    "x86_64-apple-ios",
    "aarch64-apple-darwin",
    "x86_64-apple-darwin",
    "aarch64-apple-tvos",
    "aarch64-apple-tvos-sim",
    "aarch64-apple-visionos",
    "aarch64-apple-visionos-sim",
]

# Top-level files (case-insensitive prefix match) treated as license/notice
# files. COPYRIGHT and AUTHORS are included because some licenses refer to
# them (e.g. "Copyright 2017 The Fancy Regex Authors").
NOTICE_PREFIXES = ("LICENSE", "LICENCE", "COPYING", "NOTICE", "UNLICENSE",
                   "COPYRIGHT", "AUTHORS")

CRATES_IO = "registry+https://github.com/rust-lang/crates.io-index"

# Crates that are part of the Rust standard library build (seen as object
# files in libsudachi_swift.a). Used only by --compare-archive.
STD_CRATES = {
    "std", "core", "alloc", "compiler_builtins", "panic_unwind", "panic_abort",
    "unwind", "std_detect", "addr2line", "gimli", "object", "miniz_oxide",
    "adler2", "adler", "rustc_demangle", "rustc_std_workspace_core",
    "rustc_std_workspace_alloc", "rustc_std_workspace_std", "hashbrown",
    "cfg_if", "libc",
}


def die(msg: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(2)


def run(cmd: list[str]) -> str:
    try:
        res = subprocess.run(cmd, cwd=REPO_ROOT, check=True,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True)
    except FileNotFoundError:
        die(f"command not found: {cmd[0]}")
    except subprocess.CalledProcessError as exc:
        die(f"`{' '.join(cmd)}` failed:\n{exc.stderr}")
    return res.stdout


def version_key(version: str) -> tuple:
    core = re.split(r"[-+]", version, maxsplit=1)[0]
    nums = tuple(int(p) if p.isdigit() else 0 for p in core.split("."))
    return (nums, version)


def pkg_key(pkg: dict) -> tuple:
    return (pkg["name"].lower(), version_key(pkg["version"]))


def is_proc_macro(pkg: dict) -> bool:
    return any("proc-macro" in t["kind"] for t in pkg["targets"])


# --------------------------------------------------------------------------
# Dependency graph
# --------------------------------------------------------------------------

def linked_packages(offline: bool) -> tuple[list[dict], dict]:
    """Return (packages linked into the static library, root package)."""
    extra = ["--offline"] if offline else []
    run(["cargo", "fetch", "--locked", "--manifest-path", str(MANIFEST),
         *extra])

    linked: dict[str, dict] = {}
    root_pkg = None
    for triple in TARGETS:
        meta = json.loads(run([
            "cargo", "metadata", "--locked", "--format-version", "1",
            "--manifest-path", str(MANIFEST), "--filter-platform", triple,
            *extra,
        ]))
        packages = {p["id"]: p for p in meta["packages"]}
        nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
        root = meta["resolve"]["root"]
        if root is None:
            die("cargo metadata returned no resolve root")
        root_pkg = packages[root]
        workspace = set(meta["workspace_members"])

        seen = {root}
        stack = [root]
        while stack:
            node = nodes[stack.pop()]
            for dep in node["deps"]:
                # kind None == normal dependency ("build"/"dev" are skipped).
                if not any(k["kind"] is None for k in dep["dep_kinds"]):
                    continue
                pid = dep["pkg"]
                if pid in seen:
                    continue
                seen.add(pid)
                if is_proc_macro(packages[pid]):
                    continue
                stack.append(pid)
                if pid not in workspace:
                    linked.setdefault(pid, packages[pid])
    return sorted(linked.values(), key=pkg_key), root_pkg


# --------------------------------------------------------------------------
# License / notice files
# --------------------------------------------------------------------------

def is_notice_name(name: str) -> bool:
    return name.upper().startswith(NOTICE_PREFIXES)


def notice_files_in(directory: Path) -> list[Path]:
    found: list[Path] = []
    for name in sorted(os.listdir(directory)):
        path = directory / name
        if path.is_file() and is_notice_name(name):
            found.append(path)
        elif path.is_dir() and name.upper() == "LICENSES":  # REUSE layout
            found.extend(p for p in sorted(path.iterdir()) if p.is_file())
    return found


def notice_files(pkg: dict) -> tuple[list[Path], Path]:
    """Files for a package plus the directory they are relative to.

    For path dependencies (e.g. sudachi inside the sudachi.rs submodule) the
    crate directory often has no license file; walk up to, but not including,
    the repository root.
    """
    crate_dir = Path(pkg["manifest_path"]).resolve().parent
    files = notice_files_in(crate_dir)
    lf = pkg.get("license_file")
    if lf:
        extra = (crate_dir / lf).resolve()
        if extra.is_file() and extra not in [f.resolve() for f in files]:
            files.append(extra)
    if files or pkg.get("source") is not None:
        return files, crate_dir
    directory = crate_dir.parent
    while directory != REPO_ROOT and REPO_ROOT in directory.parents:
        files = notice_files_in(directory)
        if files:
            return files, directory
        directory = directory.parent
    return [], crate_dir


def normalize_text(raw: bytes) -> str:
    text = raw.decode("utf-8", errors="replace")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = [line.rstrip() for line in text.split("\n")]
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines)


class TextPool:
    """Deduplicates identical license texts, numbered by first use."""

    def __init__(self) -> None:
        self.ids: dict[str, int] = {}
        self.texts: list[str] = []
        self.users: list[list[str]] = []

    def add(self, text: str, user: str) -> int:
        if text not in self.ids:
            self.ids[text] = len(self.texts) + 1
            self.texts.append(text)
            self.users.append([])
        tid = self.ids[text]
        self.users[tid - 1].append(user)
        return tid


def text_link(tid: int) -> str:
    return f"[license text {tid}](#license-text-{tid})"


def fence_for(text: str) -> str:
    longest = max((len(m) for m in re.findall(r"`+", text)), default=0)
    return "`" * max(3, longest + 1)


# --------------------------------------------------------------------------
# Helpers for fixed sections
# --------------------------------------------------------------------------

def git_head(path: Path) -> str | None:
    try:
        res = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"],
                             check=True, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    sha = res.stdout.strip()
    return sha if re.fullmatch(r"[0-9a-f]{40}", sha) else None


def sudachi_copyright(crate_dir: Path) -> str | None:
    """Year range from the 'Copyright (c) Y[-Y] Works Applications' headers."""
    years: set[int] = set()
    pattern = re.compile(
        r"Copyright \(c\) (\d{4})(?:\s*-\s*(\d{4}))? Works Applications")
    src = crate_dir / "src"
    for path in sorted(src.rglob("*.rs")) if src.is_dir() else []:
        head = path.read_text(encoding="utf-8", errors="replace")[:2000]
        for m in pattern.finditer(head):
            years.add(int(m.group(1)))
            if m.group(2):
                years.add(int(m.group(2)))
    if not years:
        return None
    lo, hi = min(years), max(years)
    span = f"{lo}" if lo == hi else f"{lo}-{hi}"
    return f"Copyright (c) {span} Works Applications Co., Ltd."


def vcs_info(pkg: dict) -> tuple[str, str] | None:
    path = Path(pkg["manifest_path"]).parent / ".cargo_vcs_info.json"
    try:
        info = json.loads(path.read_text(encoding="utf-8"))
        return info["git"]["sha1"], info.get("path_in_vcs", "")
    except (OSError, KeyError, ValueError):
        return None


def repo_url(pkg: dict) -> str | None:
    url = (pkg.get("repository") or "").strip()
    return url.rstrip("/") or None


def github_tree(pkg: dict) -> str | None:
    url, info = repo_url(pkg), vcs_info(pkg)
    if not url or not info or "github.com/" not in url:
        return None
    url = re.sub(r"\.git$", "", url)
    sha, sub = info
    return f"{url}/tree/{sha}" + (f"/{sub}" if sub else "")


def md_escape_cell(value: str) -> str:
    return value.replace("|", "\\|")


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------

def render(packages: list[dict], root_pkg: dict) -> str:
    pool = TextPool()
    out: list[str] = []
    w = out.append

    sudachi = [p for p in packages
               if p["name"] == "sudachi" and p.get("source") is None]
    registry = [p for p in packages if p.get("source") is not None]
    other_path = [p for p in packages
                  if p.get("source") is None and p not in sudachi]
    mpl = [p for p in registry if "MPL" in (p.get("license") or "")]

    # ---- header ---------------------------------------------------------
    w("# Third-party notices")
    w("")
    w("<!-- Generated by scripts/generate-third-party-notices.py from "
      "rust/Cargo.lock. Do not edit by hand. -->")
    w("")
    w("SudachiSwift is licensed under the Apache License 2.0 (see "
      "[LICENSE](LICENSE)). The prebuilt `SudachiSwift.xcframework` is a "
      "static library (`libsudachi_swift.a`) compiled from Rust. It contains "
      "sudachi.rs, the Rust crates listed below and the Rust standard "
      "library, and the Swift package bundles resource files from "
      "sudachi.rs. If you ship an app that uses SudachiSwift, include these "
      "notices in the app's acknowledgements.")
    w("")
    w("## What this file covers")
    w("")
    w(f"- **Rust crates**: every crate that `rust/Cargo.lock` resolves as a "
      f"normal dependency of `{root_pkg['name']}` {root_pkg['version']} for "
      f"the Apple targets in the XCFramework "
      f"({', '.join(f'`{t}`' for t in TARGETS)}). Build-script and dev "
      f"dependencies and proc-macro crates only run at build time and are "
      f"not listed. The binary can contain fewer of these crates, because "
      f"the compiler drops crates the code never uses. Apart from the Rust "
      f"standard library, it contains no crate outside this list.")
    w("- For each crate: version, the license expression declared in its "
      "`Cargo.toml`, repository, and the full text of every license or "
      "notice file in the published crate (`LICENSE*`, `LICENCE*`, "
      "`COPYING*`, `NOTICE*`, `UNLICENSE`, `COPYRIGHT*`, `AUTHORS*`). A "
      "crate that ships none of these is marked as such. Identical texts "
      "are printed once under [License texts](#license-texts) and linked "
      "from each crate.")
    w("- [sudachi.rs](#sudachirs), the [bundled resources]"
      "(#bundled-resources), the [Rust standard library]"
      "(#rust-standard-library) and the [MPL-2.0 UniFFI crates]"
      "(#mpl-20-components-uniffi).")
    w("")
    w("Not covered:")
    w("")
    w("- The Sudachi system dictionary (`system_*.dic`, SudachiDict), which "
      "you download separately. SudachiDict is licensed under Apache-2.0 "
      "and contains parts of UniDic, which is under the BSD 3-Clause license "
      "(Copyright (c) 2011-2013, The UniDic Consortium), and, in the core "
      "and full dictionaries, NEologd data (see the zip's `LEGAL` for all "
      "attributions). If your app ships a `.dic`, include the `LEGAL` and "
      "`LICENSE-2.0.txt` files from the dictionary zip in its "
      "acknowledgements.")
    w("- Tools that only run at build time: cargo-swift, uniffi-bindgen, "
      "proc macros and build scripts.")
    w("")
    w("### Regenerating")
    w("")
    w("Run this from the repository root whenever `rust/Cargo.lock` or the "
      "`sudachi.rs` submodule changes:")
    w("")
    w("```sh")
    w("python3 scripts/generate-third-party-notices.py")
    w("```")
    w("")
    w("It runs `cargo fetch --locked` and `cargo metadata --locked` (no "
      "build) and needs only Python 3 and cargo. The output is "
      "deterministic. `--check` exits with status 1 when the committed file "
      "is out of date.")
    w("")

    # ---- summary table --------------------------------------------------
    w("## Summary")
    w("")
    w("| Component | Version | License | Source |")
    w("| --- | --- | --- | --- |")
    for p in sudachi + other_path:
        w(f"| {p['name']} | {p['version']} | "
          f"`{md_escape_cell(p.get('license') or 'see license file')}` | "
          f"path dependency |")
    for p in registry:
        src = "crates.io" if p["source"] == CRATES_IO else p["source"]
        w(f"| {p['name']} | {p['version']} | "
          f"`{md_escape_cell(p.get('license') or 'see license file')}` | "
          f"{md_escape_cell(src)} |")
    w("| Rust standard library | toolchain | `MIT OR Apache-2.0` "
      "(see below) | rust-lang/rust |")
    w("")

    # ---- sudachi.rs -----------------------------------------------------
    sudachi_tid = None
    if sudachi:
        p = sudachi[0]
        crate_dir = Path(p["manifest_path"]).resolve().parent
        rel_dir = crate_dir.relative_to(REPO_ROOT).as_posix()
        w("## sudachi.rs")
        w("")
        w(f"The `sudachi` crate {p['version']} is compiled into the static "
          f"library. It is a path dependency on the `sudachi.rs` git "
          f"submodule (`{rel_dir}`), not a crates.io package.")
        w("")
        w(f"- License: `{p.get('license')}`")
        cr = sudachi_copyright(crate_dir)
        if cr:
            w(f"- Copyright: {cr} (from the source file headers)")
        if repo_url(p):
            w(f"- Repository: <{repo_url(p)}>")
        sha = git_head(SUBMODULE)
        if sha and repo_url(p):
            w(f"- Source for this build: <{repo_url(p)}/tree/{sha}>")
        files, base = notice_files(p)
        if files:
            links = []
            for f in files:
                rel = f.relative_to(REPO_ROOT).as_posix()
                tid = pool.add(normalize_text(f.read_bytes()),
                               f"sudachi {p['version']} (`{rel}`)")
                sudachi_tid = sudachi_tid or tid
                links.append(f"`{rel}`: {text_link(tid)}")
            w(f"- License file: {'; '.join(links)}")
        else:
            w("- License file: none found in the submodule.")
        w("")

    # ---- bundled resources ---------------------------------------------
    w("## Bundled resources")
    w("")
    w("The Swift package bundles these files from "
      "`Sources/SudachiSwift/Resources` into apps as SwiftPM resources:")
    w("")
    w("| File | Origin |")
    w("| --- | --- |")
    resource_names = sorted(os.listdir(RESOURCES)) if RESOURCES.is_dir() \
        else []
    for name in resource_names:
        ours = RESOURCES / name
        theirs = SUBMODULE / "resources" / name
        if not ours.is_file():
            continue
        if theirs.is_file() and theirs.read_bytes() == ours.read_bytes():
            origin = f"identical to `sudachi.rs/resources/{name}`"
        elif theirs.is_file():
            origin = f"modified copy of `sudachi.rs/resources/{name}`"
        else:
            origin = "not in `sudachi.rs/resources` (SudachiSwift)"
        w(f"| `{name}` | {origin} |")
    w("")
    licence_ref = f" ({text_link(sudachi_tid)})" if sudachi_tid else ""
    w("Files taken from `sudachi.rs/resources` are distributed under "
      f"sudachi.rs's Apache-2.0 license{licence_ref}. sudachi.rs ships no "
      "separate notice for them.")
    w("")
    char_def = RESOURCES / "char.def"
    if char_def.is_file():
        head = char_def.read_text(encoding="utf-8", errors="replace")
        id_match = re.search(r"\$Id:[^$\n]*\$", head[:1000])
        title = "charcter category map" in head[:1000]
        if id_match or title:
            parts = []
            if title:
                parts.append("the title `Japanese charcter category map` "
                             "(misspelling included)")
            if id_match:
                parts.append(f"the Subversion keyword `{id_match.group(0)}`")
            w(f"`char.def` appears to originate outside sudachi.rs. Its "
              f"header has {' and '.join(parts)}. The title and layout of "
              f"that header match MeCab's `mecab-ipadic/char.def` "
              f"(<https://github.com/taku910/mecab/blob/master/"
              f"mecab-ipadic/char.def>), whose keyword is a different CVS "
              f"revision from 2006. That points to MeCab's `char.def`, most "
              f"likely by way of the `char.def` that UniDic distributes for "
              f"MeCab. This has not been checked against a UniDic release. "
              f"The file has no copyright or license text of its own.")
            w("")

    # ---- Rust standard library -----------------------------------------
    w("## Rust standard library")
    w("")
    w("`libsudachi_swift.a` also contains the Rust standard library "
      "compiled for each target: `std`, `core`, `alloc` and the crates they "
      "depend on, for example `compiler_builtins`, `panic_unwind`, "
      "`unwind`, `std_detect`, `addr2line`, `gimli`, `object`, "
      "`miniz_oxide`, `adler2`, `rustc-demangle`, `hashbrown`, `libc` and "
      "`cfg-if`.")
    w("")
    w("- License: `MIT OR Apache-2.0`. `compiler_builtins` is "
      "`MIT AND Apache-2.0 WITH LLVM-exception AND (MIT OR Apache-2.0)`: it "
      "contains code ported from LLVM's compiler-rt and the MIT-licensed "
      "`libm`.")
    w("- Copyright: The Rust Project Developers "
      "(see <https://thanks.rust-lang.org>). Copyrights in the Rust "
      "Standard Library are retained by their contributors.")
    w("- Repository: <https://github.com/rust-lang/rust> (`library/`)")
    w("- License texts: <https://github.com/rust-lang/rust/blob/master/"
      "LICENSE-MIT>, <https://github.com/rust-lang/rust/blob/master/"
      "LICENSE-APACHE>, <https://github.com/rust-lang/rust/blob/master/"
      "COPYRIGHT>")
    w("- The exact notices for a given toolchain, including the "
      "standard library's own third-party dependencies, ship with it as "
      "`share/doc/rust/COPYRIGHT-library.html` under "
      "`rustc --print sysroot`.")
    w("")

    # ---- MPL-2.0 --------------------------------------------------------
    w("## MPL-2.0 components (UniFFI)")
    w("")
    if mpl:
        items = [f"`{p['name']}` {p['version']}" for p in mpl]
        names = items[0] if len(items) == 1 else \
            ", ".join(items[:-1]) + " and " + items[-1]
        w(f"{names} are licensed under the Mozilla Public License 2.0 "
          f"(<https://mozilla.org/MPL/2.0/>). They are used unmodified from "
          f"crates.io. As MPL-2.0 section 3.2 requires for distribution in "
          f"Executable Form, their Source Code Form is available here:")
        w("")
        for p in mpl:
            name, ver = p["name"], p["version"]
            line = (f"- `{name}` {ver}: "
                    f"<https://crates.io/crates/{name}/{ver}> (source "
                    f"archive <https://static.crates.io/crates/{name}/"
                    f"{name}-{ver}.crate>)")
            tree = github_tree(p)
            if tree:
                line += f", git <{tree}>"
            w(line)
        w("")
        bindgen_tree = None
        uniffi = next((p for p in mpl if p["name"] == "uniffi"), None)
        if uniffi is not None:
            tree = github_tree(uniffi)
            info = vcs_info(uniffi)
            if tree and info:
                bindgen_tree = tree.rsplit("/tree/", 1)[0] + \
                    f"/tree/{info[0]}/uniffi_bindgen"
        text = ("`Sources/SudachiSwift/sudachi_swift.swift` is generated by "
                "UniFFI's Swift binding generator (`uniffi_bindgen`, "
                "MPL-2.0) from its Swift templates. It is distributed in "
                "source form in this repository")
        if bindgen_tree:
            text += f"; the generator's source is at <{bindgen_tree}>"
        w(text + ".")
        w("")
    else:
        w("No MPL-2.0 crates are linked.")
        w("")

    # ---- per-crate notices ---------------------------------------------
    w("## Rust crates")
    w("")
    for p in other_path + registry:
        name, ver = p["name"], p["version"]
        w(f"### {name} {ver}")
        w("")
        lic = p.get("license")
        w(f"- License: `{lic}`" if lic else
          "- License: not declared as an SPDX expression; see the license "
          "file below")
        repo = repo_url(p)
        w(f"- Repository: <{repo}>" if repo else "- Repository: not declared")
        if p.get("source") == CRATES_IO:
            w(f"- crates.io: <https://crates.io/crates/{name}/{ver}>")
        files, base = notice_files(p)
        if files:
            links = []
            for f in files:
                rel = f.relative_to(base).as_posix()
                tid = pool.add(normalize_text(f.read_bytes()),
                               f"{name} {ver} (`{rel}`)")
                links.append(f"`{rel}`: {text_link(tid)}")
            w("- License files:")
            for link in links:
                w(f"  - {link}")
        else:
            note = ("- License files: none. The published crate ships no "
                    "license or notice file, so the license is the SPDX "
                    "expression above")
            if repo:
                note += f"; see the repository (<{repo}>) for its text"
            if lic and "MPL" in lic:
                note += (" and [MPL-2.0 components]"
                         "(#mpl-20-components-uniffi) for the source link")
            w(note + ".")
        w("")

    # ---- license texts --------------------------------------------------
    w("## License texts")
    w("")
    for tid, text in enumerate(pool.texts, start=1):
        w(f"### License text {tid}")
        w("")
        w("Used by: " + "; ".join(pool.users[tid - 1]) + ".")
        w("")
        fence = fence_for(text)
        w(f"{fence}text")
        w(text)
        w(fence)
        w("")

    return "\n".join(out).rstrip("\n") + "\n"


# --------------------------------------------------------------------------
# Archive comparison (informational, stderr only)
# --------------------------------------------------------------------------

def compare_archive(archive: Path, packages: list[dict],
                    root_pkg: dict) -> None:
    members = run(["ar", "-t", str(archive)]).splitlines()
    in_archive = set()
    for m in members:
        match = re.match(r"^([A-Za-z0-9_]+)-[0-9a-f]{16}\.", m)
        if match:
            in_archive.add(match.group(1))
    listed = {p["name"].replace("-", "_") for p in packages}
    listed |= {t["name"].replace("-", "_") for t in root_pkg["targets"]
               if "staticlib" in t["kind"]}
    print(f"archive: {archive}", file=sys.stderr)
    print(f"  crate names in archive: {len(in_archive)}", file=sys.stderr)
    extra = sorted(in_archive - listed - STD_CRATES)
    print("  in archive, not listed (and not std): "
          f"{', '.join(extra) or '(none)'}", file=sys.stderr)
    std = sorted(in_archive & STD_CRATES - listed)
    print(f"  std/runtime crates in archive: {', '.join(std) or '(none)'}",
          file=sys.stderr)
    missing = sorted(listed - in_archive)
    print("  listed, not in archive (unused, dropped by rustc): "
          f"{', '.join(missing) or '(none)'}", file=sys.stderr)



def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--output", type=Path, default=OUTPUT,
                        help="output path (default: THIRD_PARTY_NOTICES.md)")
    parser.add_argument("--check", action="store_true",
                        help="do not write; exit 1 if the output is stale")
    parser.add_argument("--offline", action="store_true",
                        help="pass --offline to cargo")
    parser.add_argument("--compare-archive", type=Path, metavar="LIB_A",
                        help="report which listed crates appear as object "
                             "files in a static library (stderr only)")
    args = parser.parse_args()

    if not (SUBMODULE / "sudachi" / "Cargo.toml").is_file():
        die("sudachi.rs submodule is not checked out "
            "(git submodule update --init)")

    packages, root_pkg = linked_packages(args.offline)
    content = render(packages, root_pkg)

    if args.compare_archive:
        compare_archive(args.compare_archive, packages, root_pkg)

    output = args.output if args.output.is_absolute() \
        else Path.cwd() / args.output
    if args.check:
        current = output.read_text(encoding="utf-8") if output.is_file() \
            else None
        if current != content:
            print(f"{output.name} is out of date; run "
                  f"python3 scripts/generate-third-party-notices.py",
                  file=sys.stderr)
            return 1
        print(f"{output.name} is up to date", file=sys.stderr)
        return 0
    # open(newline=) rather than Path.write_text(newline=), which needs Python 3.10+
    # (macOS ships 3.9 as /usr/bin/python3).
    with open(output, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)
    print(f"wrote {output} ({len(packages)} crates)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
