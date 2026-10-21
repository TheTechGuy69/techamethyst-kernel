#!/usr/bin/env bash
# techamethyst_features.sh - TechAmethyst kernel: features on top of the verified stock baseline
#
#  v1.0  -TechAmethyst version string, KernelSU Next built-in, TCP BBR default, NTFS3, wakelock blocker
#  v1.1  SUSFS (root hiding, pershoot KernelSU-Next dev-susfs + susfs4ksu), -mtune=cortex-a720,
#        /sys/kernel/techamethyst status node, AnyKernel3 flashable zip
#
# Safety: builds -> KMI check against out/baseline (every exported symbol CRC must match) -> boot.img
# repacked from YOUR stock boot. It never flashes anything.
#
# Run in WSL from ~:
#   bash techamethyst_features.sh            # prep + build + kmi + pack + zip
#   bash techamethyst_features.sh prep|build|kmi|pack|zip
# Toggles (1/0): KSU=1 SUSFS=1 BBR=1 NTFS3=1 WLBLOCK=1 TUNE=1 STATUS=1   TA_VER=v1.1   JOBS=8
#   SUSFS=0 -> official KernelSU-Next $KSU_TAG (= v1.0 behaviour)
set -euo pipefail

TOP=${TOP:-$HOME/techamethyst}
JOBS=${JOBS:-8}
BRAND=${BRAND:-TechAmethyst}
TA_VER=${TA_VER:-v1.1}
KSU=${KSU:-1}; SUSFS=${SUSFS:-1}; BBR=${BBR:-1}; NTFS3=${NTFS3:-1}; WLBLOCK=${WLBLOCK:-1}; TUNE=${TUNE:-1}; STATUS=${STATUS:-1}
KSU_TAG=${KSU_TAG:-v3.4.1}                                            # official KernelSU-Next (SUSFS=0)
KSU_SUSFS_REPO=${KSU_SUSFS_REPO:-https://github.com/pershoot/KernelSU-Next}   # KernelSU-Next + SUSFS fork (SUSFS=1)
KSU_SUSFS_REF=${KSU_SUSFS_REF:-dev-susfs}
SUSFS_REPO=${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}
SUSFS_BRANCH=${SUSFS_BRANCH:-gki-android14-6.1}
SUSFS_DEV_REPO=${SUSFS_DEV_REPO:-https://gitlab.com/pershoot/susfs4ksu.git}
SUSFS_DEV_BRANCH=${SUSFS_DEV_BRANCH:-gki-android14-6.1-dev}
BOOT_STOCK=${BOOT_STOCK:-$TOP/stock/boot.img}
WIN_OUT=${WIN_OUT:-$TOP/out_ta}                 # where finished images/zips are copied
OUT=$TOP/out/techamethyst-$TA_VER
BOOT_NAME=techamethyst_${TA_VER}_boot.img
LOG=$TOP/features.log
C=$TOP/common
DEFC=$C/arch/arm64/configs/gki_defconfig

mkdir -p "$TOP/out" "$WIN_OUT"; exec > >(tee -a "$LOG") 2>&1
say(){ printf '\n\033[1;35m[TechAmethyst] %s\033[0m\n' "$*"; }
die(){ printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*"; exit 1; }
[ -d "$C/.git" ] || die "no source at $TOP (run techamethyst_setup.sh first)"
git -C "$C" rev-parse -q --verify techamethyst-base >/dev/null || die "branch techamethyst-base missing (run setup sync)"

# set CONFIG_X in gki_defconfig: setcfg CONFIG_X y|n|"string"
setcfg(){
  local k=$1 v=$2 line
  if [ "$v" = n ]; then line="# $k is not set"; else line="$k=$v"; fi
  sed -i "/^$k=/d; /^# $k is not set/d" "$DEFC"
  echo "$line" >> "$DEFC"
}

# ------------------------------------------------------------------ SUSFS kernel patches (gki-android14-6.1)
apply_susfs(){
  say "SUSFS kernel patches ($SUSFS_BRANCH)"
  local S=$TOP/susfs4ksu
  if [ -d "$S/.git" ]; then
    git -C "$S" fetch -q origin "$SUSFS_BRANCH" && git -C "$S" checkout -q -f FETCH_HEAD
  else
    git clone -q -b "$SUSFS_BRANCH" "$SUSFS_REPO" "$S"
  fi
  # same as the WildKernels CI for KernelSU-Next: add pershoot's two newest dev commits (API match with dev-susfs)
  if git -C "$S" fetch -q "$SUSFS_DEV_REPO" "$SUSFS_DEV_BRANCH" 2>/dev/null; then
    local c
    for c in $(git -C "$S" log ..FETCH_HEAD --format=%h -n 2 | tac); do
      git -C "$S" -c user.name=ta -c user.email=ta@local cherry-pick "$c" >/dev/null 2>&1 \
        && echo "  + pershoot $c" || { git -C "$S" cherry-pick --abort 2>/dev/null || true; echo "  ~ skipped $c"; }
    done
  fi
  echo "  susfs4ksu @ $(git -C "$S" log -1 --format='%h %s')"
  local P=$S/kernel_patches/50_add_susfs_in_$SUSFS_BRANCH.patch
  [ -f "$P" ] || die "SUSFS patch not found: $P"
  cp "$S"/kernel_patches/fs/* "$C/fs/"
  cp "$S"/kernel_patches/include/linux/* "$C/include/linux/"

  # 6.1 sublevel <= 141: the patch expects <linux/dma-buf.h> in fs/proc/base.c (temporary context fix)
  local sub fake=0; sub=$(sed -n 's/^SUBLEVEL = //p' "$C/Makefile")
  if [ "$sub" -le 141 ] && ! grep -q '^#include <linux/dma-buf.h>$' "$C/fs/proc/base.c"; then
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' "$C/fs/proc/base.c"; fake=1
  fi
  ( cd "$C" && patch -p1 --forward --no-backup-if-mismatch < "$P" ) > "$TOP/out/susfs_patch.log" 2>&1 || true
  [ "$fake" = 1 ] && sed -i '/^#include <linux\/dma-buf.h>$/d' "$C/fs/proc/base.c"
  local rej; rej=$(cd "$C" && find . -name '*.rej' | head -20)
  if [ -n "$rej" ]; then
    echo "$rej"; tail -30 "$TOP/out/susfs_patch.log"
    die "SUSFS patch did not apply cleanly (rejects above). Send me out/susfs_patch.log and the .rej files."
  fi
  if grep -q 'VMA_PAD_START(' "$C/fs/proc/task_mmu.c" && ! grep -qE '#include <linux/pgsize_migration(_inline)?\.h>|define VMA_PAD_START' "$C/fs/proc/task_mmu.c"; then
    sed -i '1a #ifndef VMA_PAD_START\n#define VMA_PAD_START(vma) ((vma)->vm_end)\n#endif' "$C/fs/proc/task_mmu.c"
  fi
  grep -c '^patching file' "$TOP/out/susfs_patch.log" | sed 's/^/  files patched: /'
  local k
  for k in CONFIG_KSU_SUSFS CONFIG_KSU_SUSFS_SUS_PATH CONFIG_KSU_SUSFS_SUS_MOUNT CONFIG_KSU_SUSFS_SUS_KSTAT \
           CONFIG_KSU_SUSFS_SPOOF_UNAME CONFIG_KSU_SUSFS_ENABLE_LOG CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
           CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG CONFIG_KSU_SUSFS_SUS_MAP CONFIG_KSU_SUSFS_OPEN_REDIRECT; do
    setcfg "$k" y
  done
}

# ------------------------------------------------------------------ prep: fresh branch + all patches
stage_prep(){
  say "prep: fresh 'techamethyst' branch from the verified stock commit"
  git -C "$C" checkout -q -f -B techamethyst techamethyst-base
  git -C "$C" clean -qfdx

  # --- kleaf housekeeping (same steps every GKI custom-kernel CI uses)
  sed -i 's/check_defconfig//' "$C/build.config.gki"                       # we edit gki_defconfig directly
  rm -f "$C"/android/abi_gki_protected_exports_*                           # our kernel has its own module-signing key,
  perl -ni -e 'print unless /^\s*"protected_exports_list"\s*:/' "$C/BUILD.bazel"   # so stock system_dlkm .ko count as unsigned
  grep -q '"protected_exports_list"' "$C/BUILD.bazel" && die "protected_exports_list still in BUILD.bazel"
  [ -f "$TOP/build/kernel/kleaf/impl/stamp.bzl" ] && sed -i "/stable_scmversion_cmd/s/-maybe-dirty//g" "$TOP/build/kernel/kleaf/impl/stamp.bzl"
  sed -i 's/-dirty//' "$C/scripts/setlocalversion"

  # --- 1. branding: 6.1.138-android14-11-g<sha>-TechAmethyst
  grep -q '^echo "\$res"$' "$C/scripts/setlocalversion" || die "setlocalversion layout changed - send me its last 10 lines"
  sed -i "s/^echo \"\\\$res\"\$/echo \"\$res-$BRAND\"/" "$C/scripts/setlocalversion"
  echo "  branding: $(tail -1 "$C/scripts/setlocalversion")"

  # --- 2. KernelSU Next built-in
  [ "$SUSFS" = 1 ] && [ "$KSU" != 1 ] && die "SUSFS needs KSU=1"
  if [ "$KSU" = 1 ]; then
    local K ref
    if [ "$SUSFS" = 1 ]; then
      K=$TOP/KernelSU-Next-susfs; ref=$KSU_SUSFS_REF
      [ -d "$K/.git" ] || git clone -q "$KSU_SUSFS_REPO" "$K"
      git -C "$K" fetch -q --tags origin "$ref"
      git -C "$K" checkout -q -f FETCH_HEAD
    else
      K=$TOP/KernelSU-Next; ref=$KSU_TAG
      [ -d "$K/.git" ] || git clone -q https://github.com/KernelSU-Next/KernelSU-Next "$K"
      git -C "$K" fetch -q --tags origin
      git -C "$K" checkout -q -f "$KSU_TAG"
    fi
    [ -f "$K/.git/shallow" ] && { git -C "$K" fetch -q --unshallow origin || echo "  (warning: shallow KernelSU clone, version number may be low)"; }
    local KSU_TAG; KSU_TAG=$(git -C "$K" describe --tags --abbrev=0 2>/dev/null || echo "$ref")
    say "KernelSU Next $KSU_TAG from $ref @ $(git -C "$K" rev-parse --short HEAD) (built-in)"
    local kver=$((30000 + $(git -C "$K" rev-list --count HEAD)))
    rm -rf "$C/drivers/kernelsu"; cp -rL "$K/kernel" "$C/drivers/kernelsu"   # -L: kernel/include/uapi is a symlink to ../../uapi
    [ -f "$C/drivers/kernelsu/include/uapi/app_profile.h" ] || die "KSU uapi headers missing after copy"
    # Bazel's sandbox has no KernelSU git repo -> bake the real version in, or the manager sees "version 1"
    sed -i "s/^KSU_VERSION_FALLBACK := 1\$/KSU_VERSION_FALLBACK := $kver/; s/^KSU_VERSION_TAG_FALLBACK := v0.0.1\$/KSU_VERSION_TAG_FALLBACK := $KSU_TAG/" "$C/drivers/kernelsu/Kbuild"
    grep -q "KSU_VERSION_FALLBACK := $kver" "$C/drivers/kernelsu/Kbuild" || die "could not set KSU version in Kbuild"
    grep -q 'kernelsu/' "$C/drivers/Makefile" || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$C/drivers/Makefile"
    grep -q 'drivers/kernelsu/Kconfig' "$C/drivers/Kconfig" || sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' "$C/drivers/Kconfig"
    setcfg CONFIG_KSU y
    echo "  KSU version $kver ($KSU_TAG)"
  fi

  # --- 3. TCP BBR as default (fq qdisc is already built in)
  if [ "$BBR" = 1 ]; then
    setcfg CONFIG_TCP_CONG_ADVANCED y
    setcfg CONFIG_TCP_CONG_CUBIC y
    setcfg CONFIG_TCP_CONG_BBR y
    setcfg CONFIG_TCP_CONG_BIC n          # these default to =m -> would add unexpected .ko files
    setcfg CONFIG_TCP_CONG_WESTWOOD n
    setcfg CONFIG_TCP_CONG_HTCP n
    setcfg CONFIG_DEFAULT_BBR y
    setcfg CONFIG_DEFAULT_TCP_CONG '"bbr"'
  fi

  # --- 4. NTFS3 (USB OTG drives formatted on Windows)
  [ "$NTFS3" = 1 ] && setcfg CONFIG_NTFS3_FS y

  # --- 5. wakelock blocker: /sys/module/wakeup/parameters/ta_ws_block = "name1;name2"  (empty = off)
  if [ "$WLBLOCK" = 1 ]; then
    python3 - "$C/drivers/base/power/wakeup.c" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
anchor = "static void wakeup_source_report_event(struct wakeup_source *ws, bool hard)\n{\n"
if anchor not in s: sys.exit("wakeup.c anchor not found")
helper = r'''/* TechAmethyst wakelock blocker: ';'-separated wakeup source names, empty = disabled */
static char ta_ws_block[512];
module_param_string(ta_ws_block, ta_ws_block, sizeof(ta_ws_block), 0644);

static bool ta_ws_blocked(const char *name)
{
	const char *p = ta_ws_block;
	size_t n;

	if (!name || !*p)
		return false;
	n = strlen(name);
	while (*p) {
		const char *e = strchrnul(p, ';');

		if ((size_t)(e - p) == n && !strncmp(p, name, n))
			return true;
		p = *e ? e + 1 : e;
	}
	return false;
}

'''
i = s.index(anchor); j = s.rfind("/**", 0, i)          # keep the kernel-doc comment attached to its function
if j < 0 or i - j > 600: j = i
s = s[:j] + helper + s[j:i] + anchor + "\tif (unlikely(ta_ws_blocked(ws->name)))\n\t\treturn;\n\n" + s[i+len(anchor):]
s = s.replace("#include <linux/wakeup_reason.h>\n", "#include <linux/wakeup_reason.h>\n#include <linux/moduleparam.h>\n", 1)
open(p, "w").write(s)
print("  wakelock blocker added")
PY
  fi

  # --- 6. SUSFS kernel side (KernelSU-Next fork above already carries the SUSFS addon)
  [ "$SUSFS" = 1 ] && apply_susfs

  # --- 7. scheduling tuned for Cortex-A720 (-mtune only: no new instructions, no KMI effect)
  if [ "$TUNE" = 1 ]; then
    printf '\n# TechAmethyst: tune instruction scheduling for SM7635 (Cortex-A720 + A520); ISA unchanged\nKBUILD_CFLAGS += $(call cc-option,-mtune=cortex-a720)\n' >> "$C/arch/arm64/Makefile"
  fi

  # --- 8. /sys/kernel/techamethyst/{version,features}
  if [ "$STATUS" = 1 ]; then
    local feats="ksu=$KSU susfs=$SUSFS bbr=$BBR ntfs3=$NTFS3 wlblock=$WLBLOCK tune=$TUNE"
    cat > "$C/kernel/techamethyst.c" <<EOF
// SPDX-License-Identifier: GPL-2.0
/* TechAmethyst status node: /sys/kernel/techamethyst/{version,features} */
#include <linux/init.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>

static ssize_t version_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{
	return sysfs_emit(buf, "%s\n", "$BRAND $TA_VER");
}

static ssize_t features_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{
	return sysfs_emit(buf, "%s\n", "$feats");
}

static struct kobj_attribute ta_version_attr = __ATTR_RO(version);
static struct kobj_attribute ta_features_attr = __ATTR_RO(features);

static struct attribute *ta_attrs[] = {
	&ta_version_attr.attr,
	&ta_features_attr.attr,
	NULL,
};

static const struct attribute_group ta_group = {
	.attrs = ta_attrs,
};

static int __init techamethyst_init(void)
{
	struct kobject *kobj = kobject_create_and_add("techamethyst", kernel_kobj);

	if (!kobj)
		return -ENOMEM;
	return sysfs_create_group(kobj, &ta_group);
}
late_initcall(techamethyst_init);
EOF
    grep -q 'techamethyst.o' "$C/kernel/Makefile" || printf '\nobj-y += techamethyst.o\n' >> "$C/kernel/Makefile"
  fi

  git -C "$C" add -A
  git -C "$C" commit -qm "$BRAND $TA_VER: KSU=$KSU SUSFS=$SUSFS BBR=$BBR NTFS3=$NTFS3 WLBLOCK=$WLBLOCK TUNE=$TUNE STATUS=$STATUS"
  say "prep done: $(git -C "$C" log -1 --format='%h %s')"
}

# ------------------------------------------------------------------ build
stage_build(){
  say "build (only changed files recompile; ~5-15 min)"
  cd "$TOP"
  env -u BUILD_NUMBER tools/bazel run --config=stamp --jobs="$JOBS" \
      //common:kernel_aarch64_dist -- --dist_dir="$OUT"
  ls -la "$OUT" | grep -E ' Image$|vmlinux.symvers|boot.img' || true
}

# ------------------------------------------------------------------ KMI check: the bootloop gate
stage_kmi(){
  say "KMI check vs stock baseline"
  local B=$TOP/out/baseline/vmlinux.symvers N=$OUT/vmlinux.symvers
  [ -f "$B" ] && [ -f "$N" ] || die "missing vmlinux.symvers (baseline or new build)"
  set +e
  awk 'NR==FNR{crc[$2]=$1;next}
       ($2 in crc){seen[$2]=1; if(crc[$2]!=$1){chg++; if(chg<=20) print "  CHANGED", $2, crc[$2], "->", $1}}
       END{for(s in crc) if(!(s in seen)){miss++; if(miss<=20) print "  MISSING", s}
           printf "  exported symbols: %d   changed CRC: %d   missing: %d\n", length(crc), chg+0, miss+0
           exit (chg+miss)>0}' "$B" "$N"
  local rc=$?
  set -e
  [ $rc -eq 0 ] || die "KMI BROKEN - vendor modules would fail to load. Do NOT flash. Send me this log."
  local ver; ver=$(strings "$OUT/Image" | grep -m1 '^Linux version' || true)
  echo "  $ver"
  "$C/scripts/extract-ikconfig" "$OUT/Image" > "$OUT/config.txt" 2>/dev/null || true
  for k in CONFIG_KSU=y CONFIG_KSU_SUSFS=y CONFIG_KSU_SUSFS_SUS_PATH=y CONFIG_KSU_SUSFS_SUS_MOUNT=y CONFIG_TCP_CONG_BBR=y 'CONFIG_DEFAULT_TCP_CONG="bbr"' CONFIG_NTFS3_FS=y CONFIG_EXFAT_FS=y CONFIG_LRU_GEN_ENABLED=y; do
    grep -qx "$k" "$OUT/config.txt" && echo "  [on ] $k" || echo "  [off] $k"
  done
  say "KMI OK - every stock exported symbol has the same CRC"
}

# ------------------------------------------------------------------ pack: your stock boot.img with our kernel
stage_pack(){
  say "pack boot image from your stock boot"
  [ -f "$BOOT_STOCK" ] || die "stock boot not found at $BOOT_STOCK - back it up first (dd command), or set BOOT_STOCK=..."
  local MKB; MKB=$(dirname "$(find "$TOP/tools" "$TOP/build" -name unpack_bootimg.py -print -quit 2>/dev/null)")
  [ -f "$MKB/mkbootimg.py" ] || die "mkbootimg tools not found in the synced tree"
  local W=$TOP/out/pack; rm -rf "$W"; mkdir -p "$W"
  python3 "$MKB/unpack_bootimg.py" --boot_img "$BOOT_STOCK" --out "$W/stock" --format=mkbootimg > "$W/args.txt"
  echo "  stock args: $(cat "$W/args.txt")"
  local kfmt; kfmt=$(file -b "$W/stock/kernel")
  echo "  stock kernel: ${kfmt:0:60}"
  case "$kfmt" in
    gzip*) gzip -9c "$OUT/Image" > "$W/stock/kernel";;
    LZ4*)  lz4 -l -12 -fq "$OUT/Image" "$W/stock/kernel";;
    *)     cp "$OUT/Image" "$W/stock/kernel";;
  esac
  ( cd "$W" && eval python3 "$MKB/mkbootimg.py" "$(sed "s|$W/||g" args.txt)" --output "$W/techamethyst_boot.img" )
  python3 "$MKB/unpack_bootimg.py" --boot_img "$W/techamethyst_boot.img" --out "$W/verify" >/dev/null
  grep -aq -- "-$BRAND" "$W/verify/kernel" || die "repacked image does not contain the new kernel"
  # AVB hash footer, same layout as stock (100 MB partition, same props) so it can be FLASHED, not just booted
  local AVB; AVB=$(find "$TOP/prebuilts" "$TOP/build" "$TOP/tools" -name avbtool -type f -perm -u+x -print -quit 2>/dev/null || true)
  [ -n "$AVB" ] || die "avbtool not found in the synced tree"
  "$AVB" info_image --image "$BOOT_STOCK" > "$W/stock_avb.txt" 2>&1 || true
  local psize; psize=$(stat -c%s "$BOOT_STOCK")
  local props=()
  while IFS= read -r l; do props+=(--prop "$l"); done < <(sed -n "s/^ *Prop: \(.*\) -> '\(.*\)'\s*$/\1:\2/p" "$W/stock_avb.txt")
  echo "  avb: partition $psize bytes, $(( ${#props[@]} / 2 )) props copied from stock footer"
  "$AVB" add_hash_footer --image "$W/techamethyst_boot.img" --partition_name boot \
      --partition_size "$psize" --hash_algorithm sha256 "${props[@]}"
  [ "$(stat -c%s "$W/techamethyst_boot.img")" = "$psize" ] || die "footer size mismatch"
  "$AVB" info_image --image "$W/techamethyst_boot.img" | grep -E "Image size|Partition Name|Prop" | head -8 || true
  cp "$W/techamethyst_boot.img" "$WIN_OUT/$BOOT_NAME"
  ls -la "$BOOT_STOCK" "$WIN_OUT/$BOOT_NAME"
  say "ready: $WIN_OUT/$BOOT_NAME"
  cat <<'EOF'
Test plan (nothing has been flashed):
  1. KernelSU is now INSIDE the kernel -> init_boot must be STOCK (not the KSU-patched one).
  2. fastboot boot techamethyst_boot.img     (one-time boot, a reboot returns to the stock kernel)
     after it passes:  fastboot flash boot techamethyst_boot.img   (image now has a stock-layout AVB footer)
     If your bootloader refuses 'fastboot boot', tell me before flashing anything.
  3. Checks:  adb shell uname -r                              -> ...-TechAmethyst
              adb shell "su -c 'lsmod | wc -l'"               -> same count as stock
              touch / fingerprint / charging / wifi / mobile data / camera / audio
Rollback any time:  fastboot flash boot boot_stock.img
EOF
}

# ------------------------------------------------------------------ zip: AnyKernel3 (flash from KSU manager / recovery)
stage_zip(){
  say "AnyKernel3 zip"
  local A=$TOP/AnyKernel3 Z=$TOP/out/ak3
  [ -d "$A/.git" ] || git clone -q --depth 1 https://github.com/osm0sis/AnyKernel3 "$A"
  rm -rf "$Z"; mkdir -p "$Z"
  cp -r "$A"/. "$Z"/; rm -rf "$Z/.git" "$Z/.github" "$Z/README.md" "$Z"/ramdisk "$Z"/patch "$Z"/modules
  cat > "$Z/anykernel.sh" <<EOF
### AnyKernel3 Ramdisk Mod Script - $BRAND $TA_VER for Redmi Note 14 Pro+ 5G (amethyst)
properties() { '
kernel.string=$BRAND $TA_VER by TheTechGuy69 (amethyst, android14-6.1 GKI)
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=amethyst
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### boot shell variables (GKI: kernel lives in boot, ramdisk in init_boot -> only swap the kernel)
BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;

split_boot;
flash_boot;
EOF
  cp "$OUT/Image" "$Z/Image"
  local zipname="${BRAND}-${TA_VER}-amethyst-$(date +%Y%m%d).zip"
  ( cd "$Z" && zip -qr9 "$TOP/out/$zipname" . -x '.git*' )
  cp "$TOP/out/$zipname" "$WIN_OUT/$zipname"
  ls -la "$WIN_OUT/$zipname"
  say "zip ready: $WIN_OUT/$zipname (for release / no-PC updates; for testing use the boot.img)"
}

case "${1:-all}" in
  prep) stage_prep;; build) stage_build;; kmi) stage_kmi;; pack) stage_pack;; zip) stage_zip;;
  all) stage_prep; stage_build; stage_kmi; stage_pack; stage_zip;;
  *) die "usage: $0 [all|prep|build|kmi|pack|zip]";;
esac
