#!/bin/zsh
# Builds a fake home folder for manual QA of DiskSweep's Debug build.
#
#   scripts/make-fixture-home.sh [--large] [path]
#
# The default path is "$(getconf DARWIN_USER_TEMP_DIR)DiskSweepFixtureHome". The fixture
# must live inside this account's temporary directory: DiskSweep's safety validator treats
# the rest of /private as protected. Launch the Debug build with
#
#   -DiskSweepHomeOverride <path>
#
# and every provider, analyzer, the validator, settings, and history use the fixture.
# Nothing here is real data. The folder is deleted and rebuilt on every run, so never
# point this script at a folder you care about.
#
# --large adds the performance fixture from Phase 5 of implementation_plan.md:
# 100k small files in DerivedData, 20k files in Downloads, 500 duplicate pairs, and 500
# sandboxed-app containers.

set -euo pipefail

large=0
if [[ "${1:-}" == "--large" ]]; then
  large=1
  shift
fi

temp_root="$(getconf DARWIN_USER_TEMP_DIR)"
home="${1:-${temp_root}DiskSweepFixtureHome}"
home="${home%/}"

# Refuse anything outside the per-user temporary directory, and never touch the real home.
resolved_temp="$(cd "$temp_root" && pwd -P)"
mkdir -p "$home"
resolved_home="$(cd "$home" && pwd -P)"
case "$resolved_home" in
  "$resolved_temp"/*) ;;
  *) echo "Refusing: $home is not inside $temp_root" >&2; exit 1 ;;
esac
if [[ "$resolved_home" == "$(cd ~ && pwd -P)" ]]; then
  echo "Refusing to use the real home folder." >&2
  exit 1
fi

rm -rf "$resolved_home"
mkdir -p "$resolved_home"
cd "$resolved_home"

# Creates a file of the given size in KB filled with distinct bytes per seed.
blob() { # path sizeKB seed
  mkdir -p "$(dirname "$1")"
  # Repeating a seed-specific line gives files that are equal only when seeds are equal.
  local line
  line="$(printf 'seed-%s-%0200d\n' "$3" 0)"
  { yes "$line" || true; } | head -c "$(( $2 * 1024 ))" > "$1"
}

old() { touch -t 202501010000 "$@"; }   # long ago: past every idle/age threshold

mkdir -p tmp Desktop Documents Library/Logs .Trash

# --- Xcode DerivedData with a Swift package checkout that contains .git (D1) -------------
dd="Library/Developer/Xcode/DerivedData/FixtureApp-abcdefghijk"
blob "$dd/Build/Products/Debug/FixtureApp.app/Contents/MacOS/FixtureApp" 2048 dd1
blob "$dd/Index.noindex/DataStore/v5/units/unit1" 512 dd2
mkdir -p "$dd/SourcePackages/checkouts/Pkg/.git/refs"
echo "ref: refs/heads/main" > "$dd/SourcePackages/checkouts/Pkg/.git/HEAD"
blob "$dd/SourcePackages/checkouts/Pkg/Sources/Pkg/Pkg.swift" 4 pkg
blob "Library/Developer/Xcode/DerivedData/PlainApp-zyxwvutsrqp/Build/Intermediates.noindex/obj.o" 1024 dd3

# --- Package-manager caches -------------------------------------------------------------
mkdir -p ".cargo/git/checkouts/foo-1234/abc1234/.git"
echo "ref: refs/heads/main" > ".cargo/git/checkouts/foo-1234/abc1234/.git/HEAD"
blob ".cargo/git/checkouts/foo-1234/abc1234/src/lib.rs" 64 cargo
blob ".npm/_cacache/content-v2/sha512/ab/blob" 768 npm

# --- User caches, including Poetry (D9) ---------------------------------------------------
blob "Library/Caches/com.example.FixtureCache/Cache.db" 1536 cache1
blob "Library/Caches/com.example.Other/data.bin" 256 cache2
blob "Library/Caches/pypoetry/cache/repositories/pypi/_http/a" 300 poetry1
blob "Library/Caches/pypoetry/artifacts/ab/cd/pkg.whl" 300 poetry2
blob "Library/Caches/pypoetry/virtualenvs/proj-AbC123-py3.12/lib/site.py" 600 poetry3
mkdir -p "Library/Caches/com.example.WithRepo/.git"
echo "ref: refs/heads/main" > "Library/Caches/com.example.WithRepo/.git/HEAD"

# --- Application container cache -----------------------------------------------------------
blob "Library/Containers/com.example.Sandboxed/Data/Library/Caches/blob.bin" 400 container

# --- Logs (old and current) ----------------------------------------------------------------
blob "Library/Logs/FixtureApp/old.log" 128 log1
old "Library/Logs/FixtureApp/old.log"
blob "Library/Logs/FixtureApp/current.log" 16 log2

# --- Temporary files (fixture tmp only) ----------------------------------------------------
blob "tmp/old-download.partial" 256 tmp1
old "tmp/old-download.partial"

# --- Trash ----------------------------------------------------------------------------------
blob ".Trash/Discarded Report.pdf" 512 trash

# --- Downloads: disk image, app bundle, sparse bundle, installers (D3) -----------------------
blob "Downloads/Installer.dmg" 3072 dmg
blob "Downloads/Setup.pkg" 1024 pkg
blob "Downloads/archive.zip" 2048 zip
blob "Downloads/my file.txt" 8 txt
blob "Downloads/Holiday.mov" 4096 mov
old "Downloads/Installer.dmg" "Downloads/Setup.pkg"
mkdir -p "Downloads/Foo.app/Contents/MacOS"
printf '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "Downloads/Foo.app/Contents/Info.plist"
blob "Downloads/Foo.app/Contents/MacOS/Foo" 2048 fooapp
mkdir -p "Downloads/Thing.sparsebundle/bands"
printf '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "Downloads/Thing.sparsebundle/Info.plist"
blob "Downloads/Thing.sparsebundle/bands/0" 2048 sparse

# --- A virtual machine bundle (D3) ---------------------------------------------------------
mkdir -p "VMs/VM.utm/Images"
printf '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "VMs/VM.utm/config.plist"
blob "VMs/VM.utm/Images/disk.img" 5120 vm

# --- Duplicates and hard links (D12) -------------------------------------------------------
blob "Media/a.bin" 2048 dup
cp "Media/a.bin" "Media/b-copy.bin"
ln "Media/a.bin" "Media/a-hardlink.bin"
blob "Media/c.bin" 1536 dup2
cp "Media/c.bin" "Media/Archive/c-copy.bin" 2>/dev/null || { mkdir -p Media/Archive; cp "Media/c.bin" "Media/Archive/c-copy.bin"; }
blob "Media/unique.bin" 2048 unique

# --- JetBrains: an old version superseded by a newer one -----------------------------------
blob "Library/Application Support/JetBrains/PyCharm2023.1/options/ide.general.xml" 4 jb1
blob "Library/Application Support/JetBrains/PyCharm2023.1/index/shard" 1024 jb2
blob "Library/Application Support/JetBrains/PyCharm2024.2/options/ide.general.xml" 4 jb3
find "Library/Application Support/JetBrains/PyCharm2023.1" -exec touch -t 202501010000 {} +

if (( large )); then
  echo "Generating the large performance fixture…"
  big="Library/Developer/Xcode/DerivedData/BigApp-perfperfperf/Build/Intermediates.noindex"
  for d in $(seq 0 99); do
    mkdir -p "$big/d$d"
    for f in $(seq 0 999); do print -n "x" > "$big/d$d/f$f.o"; done
  done
  mkdir -p Downloads/Bulk
  for f in $(seq 0 19999); do print -n "download $f" > "Downloads/Bulk/file-$f.txt"; done
  # Many sandboxed-app containers, so computing Application Caches roots does real work.
  for c in $(seq 0 499); do
    mkdir -p "Library/Containers/com.example.perf$c/Data/Library/Caches"
    print -n "c" > "Library/Containers/com.example.perf$c/Data/Library/Caches/blob"
  done
  mkdir -p Media/Pairs
  for p in $(seq 0 499); do
    blob "Media/Pairs/pair-$p-a.bin" 1100 "pair$p"
    cp "Media/Pairs/pair-$p-a.bin" "Media/Pairs/pair-$p-b.bin"
  done
fi

echo "Fixture home ready: $resolved_home"
echo "Launch the Debug build with: -DiskSweepHomeOverride \"$resolved_home\""
