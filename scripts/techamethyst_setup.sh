#!/usr/bin/env bash
# techamethyst_setup.sh - TechAmethyst kernel, step 1: tools + exact source + unmodified baseline build
#
# Target: stock kernel 6.1.138-android14-11-g0c3d559bcd85-ab14529422 (amethyst, HyperOS 3.0.306)
# The script NEVER touches the phone. It only builds in WSL and compares with the stock kernel.
#
# Run in WSL (NOT under /mnt/c - Bazel needs a Linux filesystem):
#   bash techamethyst_setup.sh            # all stages
#   bash techamethyst_setup.sh deps|find|sync|build|compare   # one stage
#
# Needs: ~60 GB free in ~, 16 GB+ RAM for WSL (see .wslconfig note at the bottom), internet.
set -euo pipefail

SHA=${SHA:-0c3d559bcd85}                       # from stock version string (-g0c3d559bcd85)
WANT_VER=${WANT_VER:-6.1.138-android14-11}
TOP=${TOP:-$HOME/techamethyst}
STOCK=${STOCK:-$TOP/stock/kernel}                # stock kernel Image (the "kernel" from your unpacked stock boot.img)
JOBS=${JOBS:-$(nproc)}
LOG=$TOP/setup.log
G=https://android.googlesource.com

mkdir -p "$TOP"; exec > >(tee -a "$LOG") 2>&1
say(){ printf '\n\033[1;36m[TechAmethyst] %s\033[0m\n' "$*"; }
die(){ printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*"; exit 1; }

case "$(pwd)" in /mnt/*) die "run from your WSL home (cd ~), not from /mnt/c";; esac

# ---------------------------------------------------------------- 1. build tools
stage_deps(){
  say "1/5 installing build tools"
  sudo apt-get update -qq
  sudo apt-get install -y -qq git curl python3 python-is-python3 rsync zip unzip lz4 cpio kmod \
       bc bison flex build-essential libssl-dev libelf-dev ccache binutils-aarch64-linux-gnu >/dev/null
  mkdir -p "$HOME/bin"
  if ! command -v repo >/dev/null; then
    curl -sSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/bin/repo"
    chmod +x "$HOME/bin/repo"
  fi
  export PATH="$HOME/bin:$PATH"
  grep -q 'HOME/bin' "$HOME/.bashrc" || echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
  git config --global user.name  >/dev/null || git config --global user.name  "TechAmethyst"
  git config --global user.email >/dev/null || git config --global user.email "techamethyst@localhost"
  git config --global color.ui false
  repo version | head -2
}

# ---------------------------------------------------------------- 2. find which release branch has the stock commit
stage_find(){
  say "2/5 locating commit $SHA in kernel/common (blobless fetch, small)"
  local P=$TOP/probe
  if [ ! -d "$P" ]; then git init -q --bare "$P"; git -C "$P" remote add aosp $G/kernel/common; fi
  git -C "$P" fetch -q --filter=blob:none aosp \
      '+refs/heads/android14-6.1*:refs/remotes/aosp/android14-6.1*' \
      '+refs/tags/android14-6.1*:refs/tags/android14-6.1*' || die "fetch failed (network?)"
  local full; full=$(git -C "$P" rev-parse -q --verify "$SHA^{commit}") || die "commit $SHA not found in android14-6.1 branches"
  echo "full sha: $full"
  git -C "$P" log -1 --format='%cd  %s' "$full"
  # prefer a dated release branch (android14-6.1-2025-MM), oldest that contains it
  local br; br=$(git -C "$P" branch -r --contains "$full" | sed 's|^ *aosp/||' | grep -E '^android14-6\.1-20[0-9]{2}-[0-9]{2}$' | sort | head -1 || true)
  local tag; tag=$(git -C "$P" tag --contains "$full" | grep -E '^android14-6\.1[.-]' | sort -V | head -1 || true)
  # release tags look like android14-6.1-2025-06_r15 -> release branch android14-6.1-2025-06
  if [ -z "$br" ] && [[ "$tag" =~ ^(android14-6\.1-20[0-9]{2}-[0-9]{2})_r[0-9]+$ ]]; then br=${BASH_REMATCH[1]}; fi
  echo "release branch: ${br:-none}   first tag: ${tag:-none}"
  # manifest branch must exist, else fall back to the main one
  local mb=common-android14-6.1
  if [ -n "$br" ] && git ls-remote --exit-code $G/kernel/manifest "refs/heads/common-$br" >/dev/null 2>&1; then mb=common-$br; fi
  echo "manifest branch: $mb"
  printf 'FULL=%s\nMANIFEST=%s\nTAG=%s\n' "$full" "$mb" "$tag" > "$TOP/source.env"
}

# ---------------------------------------------------------------- 3. sync source and pin common/ to the stock commit
stage_sync(){
  [ -f "$TOP/source.env" ] || stage_find
  . "$TOP/source.env"; export PATH="$HOME/bin:$PATH"
  say "3/5 repo sync ($MANIFEST) - this is the long one (~15-25 GB)"
  cd "$TOP"
  [ -d .repo ] || repo init -q -u $G/kernel/manifest -b "$MANIFEST" --depth=1
  # Google deletes old release branches (android14-6.1-2025-06 is gone) but keeps the tags,
  # so override common/ via a local manifest: the release tag if it IS the stock commit, else the sha.
  local rev="$FULL"
  if [ -n "${TAG:-}" ] && [ "$(git -C "$TOP/probe" rev-parse -q --verify "$TAG^{commit}" || true)" = "$FULL" ]; then rev="refs/tags/$TAG"; fi
  echo "common/ revision: $rev"
  mkdir -p .repo/local_manifests
  python3 -c '
import sys, glob, xml.etree.ElementTree as ET
rev = sys.argv[1]; p = None; remote = None
for f in sorted(glob.glob(".repo/manifests/*.xml")):
    try: m = ET.parse(f).getroot()
    except Exception: continue
    d = m.find("default")
    if d is not None and d.get("remote"): remote = remote or d.get("remote")
    for e in m.iter("project"):
        if e.get("path") == "common" and p is None: p = e
if p is None: sys.exit("no project with path=common in .repo/manifests")
for a in ("upstream", "dest-branch"): p.attrib.pop(a, None)
p.set("revision", rev); p.set("clone-depth", "1")
if "remote" not in p.attrib and remote: p.set("remote", remote)
out = ET.Element("manifest")
ET.SubElement(out, "remove-project", name=p.get("name"))
out.append(p)
ET.indent(out); print(ET.tostring(out, encoding="unicode"))
' "$rev" > .repo/local_manifests/techamethyst.xml || die "could not build local manifest"
  cat .repo/local_manifests/techamethyst.xml
  repo sync -q -c --no-tags --no-clone-bundle -j"$JOBS" || repo sync -c --no-tags -j4 || die "repo sync failed"
  # make sure common/ is exactly the stock commit
  if [ "$(git -C common rev-parse HEAD)" != "$FULL" ]; then
    git -C common fetch -q aosp "$FULL" || git -C common fetch -q --unshallow aosp || git -C common fetch -q aosp
  fi
  git -C common checkout -q -B techamethyst-base "$FULL"
  say "common/ is at: $(git -C common log -1 --format='%h %s')"
  grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL) ' common/Makefile | tr '\n' ' '; echo
}

# ---------------------------------------------------------------- 4. unmodified GKI build (kleaf)
stage_build(){
  cd "$TOP"; [ -x tools/bazel ] || die "source not synced (run: $0 sync)"
  say "4/5 building unmodified GKI (kernel_aarch64_dist) - 30-90 min first time"
  # BUILD_NUMBER + stamp make the version string match stock: ...-g0c3d559bcd85-ab14529422
  BUILD_NUMBER=14529422 tools/bazel run --config=stamp --jobs="$JOBS" \
      //common:kernel_aarch64_dist -- --dist_dir="$TOP/out/baseline"
  ls -la "$TOP/out/baseline" | grep -E 'Image|vmlinux|System.map|abi' || true
}

# ---------------------------------------------------------------- 5. compare with stock
stage_compare(){
  say "5/5 comparing with stock kernel"
  local B=$TOP/out/baseline/Image C=$TOP/out/compare
  [ -f "$B" ] || die "no baseline Image (run: $0 build)"
  [ -f "$STOCK" ] || die "stock kernel not found at $STOCK (set STOCK=/path/to/kernel)"
  mkdir -p "$C"
  set +e +o pipefail   # comparison only: never abort silently (grep -m1 + pipefail = SIGPIPE exit)
  # stock may be compressed (gzip/lz4) - unpack to a plain Image first
  local S="$C/stock_Image"
  case "$(file -b "$STOCK")" in
    gzip*) gzip -dc "$STOCK" > "$S";;
    LZ4*)  lz4 -dcq "$STOCK" > "$S";;
    *)     cp "$STOCK" "$S";;
  esac
  echo "stock file: $(file -b "$STOCK" | cut -c1-70)"
  local sv bv; sv=$(strings "$S" | grep -m1 '^Linux version'); bv=$(strings "$B" | grep -m1 '^Linux version')
  STOCK="$S"
  printf 'stock : %s\nours  : %s\n' "$sv" "$bv" | tee "$C/version.txt"
  local ext=$TOP/common/scripts/extract-ikconfig
  "$ext" "$STOCK" > "$C/stock.config" 2>/dev/null || echo "(stock has no IKCONFIG)"
  "$ext" "$B"     > "$C/ours.config"  2>/dev/null || true
  if [ -s "$C/stock.config" ] && [ -s "$C/ours.config" ]; then
    diff <(grep -v '^#' "$C/stock.config" | sort) <(grep -v '^#' "$C/ours.config" | sort) > "$C/config.diff" || true
    echo "config diff lines: $(wc -l < "$C/config.diff")  (0 = identical .config)"
    head -30 "$C/config.diff"
  fi
  printf 'size  stock %s  ours %s\n' "$(stat -c%s "$STOCK")" "$(stat -c%s "$B")"
  sha256sum "$STOCK" "$B" | tee "$C/sha256.txt"
  echo
  if echo "$bv" | grep -q "$WANT_VER-g${SHA}"; then
    say "BASELINE OK: same tree + same version string. Byte-identical is NOT expected (timestamps/paths)."
    echo "Next step: techamethyst_features.sh (LOCALVERSION, KernelSU Next built-in, SUSFS, BBR/fq, exFAT/NTFS3 + ABI check)."
  else
    say "version mismatch - send me $C/version.txt and $LOG"
  fi
}

case "${1:-all}" in
  deps) stage_deps;; find) stage_find;; sync) stage_sync;; build) stage_build;; compare) stage_compare;;
  all)  stage_deps; stage_find; stage_sync; stage_build; stage_compare;;
  *) die "usage: $0 [all|deps|find|sync|build|compare]";;
esac

say "done. Log: $LOG"
cat <<'EOF'
Reminders:
  * Nothing was flashed. Back up the stock boot first if you haven't yet:
      adb shell "su -c 'dd if=/dev/block/by-name/boot$(getprop ro.boot.slot_suffix) of=/sdcard/boot_stock.img'"
      adb pull /sdcard/boot_stock.img ~/techamethyst/stock/boot.img     (or set BOOT_STOCK=...)
  * If Bazel gets killed (OOM), create C:\Users\<you>\.wslconfig with:
      [wsl2]
      memory=16GB
      swap=16GB
    then in PowerShell: wsl --shutdown, and run: bash techamethyst_setup.sh build
EOF
