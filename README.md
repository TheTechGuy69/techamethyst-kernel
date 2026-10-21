# TechAmethyst kernel

A GKI kernel for the **Redmi Note 14 Pro+ 5G (`amethyst`)**, built from Google's android14-6.1 GKI release tags.
It adds **KernelSU-Next + SUSFS** root and a few small tweaks, and keeps the KMI identical so Xiaomi's prebuilt vendor modules keep loading.

> ⚠️ **Experimental.** All releases are pre-releases. A broken kernel means a boot loop.
> Always test with `fastboot boot` first; it boots once and writes nothing. You need an unlocked bootloader.

## Device
| | |
|---|---|
| Phone | Redmi Note 14 Pro+ 5G, codename `amethyst` |
| SoC | SM7635 "volcano" (Snapdragon 7s Gen 3): 4× Cortex-A520, 3× A720, 1× prime A720; Adreno 810 |
| Vendor | HyperOS 3.0.306 vendor (`OS3.0.306.0.WOPMIXM`), stock kernel `6.1.138-android14-11-g0c3d559bcd85` |
| Kernel | android14-6.1 GKI (Kleaf/Bazel), KMI generation 11 |

## Versions
| Version | GKI base | Linux | `uname -r` | Status |
|---|---|---|---|---|
| v1.1 | android14-6.1-2025-06_r15 (`0c3d559bcd85`) | 6.1.138 | `6.1.138-android14-11-gef638e794666-TechAmethyst` | source only |
| v1.2 | android14-6.1-2025-06_r17 (`b736d0489dcd`) | 6.1.138 | `6.1.138-android14-11-gf7e46d774ebc-TechAmethyst-v1.2` | pre-release; booted OK on the device |
| v1.3 | android14-6.1-2026-06_r14 (`91529065029f`) | 6.1.172 | `6.1.172-android14-11-g0dafe06fba95-TechAmethyst-v1.3` | pre-release; device-tested 2026-10-21 (boot.img + new system_dlkm) |

Details, verification and test plans: [`CHANGES/`](CHANGES/).

## Features
`KSU=1 SUSFS=1 BBR=1 NTFS3=1 WLBLOCK=1 TUNE=1 STATUS=1`
- **KernelSU-Next v3.4.1** (33345), built in, from the pershoot `dev-susfs` fork. Keep the **stock** init_boot (not a KSU-patched one).
- **SUSFS v2.3.0** (susfs4ksu `gki-android14-6.1`): SUS_PATH, SUS_MOUNT, SUS_KSTAT, SPOOF_UNAME, SPOOF_CMDLINE, SUS_MAP, OPEN_REDIRECT.
- **TCP BBR** is the default congestion control.
- **NTFS3** read/write (for USB OTG drives).
- **Wakelock blocker:** write `name1;name2` to `/sys/module/wakeup/parameters/ta_ws_block` (empty = off).
- **`-mtune=cortex-a720`**: scheduling only, no new instructions.
- **Status node:** `/sys/kernel/techamethyst/{version,features}`.
- Everything else is stock GKI (MGLRU on, zram lzo-rle).

## Releases and what to flash
| File | What | Partition |
|---|---|---|
| `boot.img` | the kernel, repacked into the stock boot layout (header v4, stock AVB props) | `boot` |
| `system_dlkm.img` (v1.3) | GKI modules (zram, zsmalloc, bluetooth, ...) built from the same tree | `system_dlkm` inside super, via a ROM build |
| `TechAmethyst-vX.Y-amethyst-*.zip` | AnyKernel3; kernel only | flash from the KernelSU manager or recovery |
| `SHA256SUMS` | checksums | |

- **v1.3 boot.img works on its own with the stock system_dlkm.**
  The import gate found 0 mismatches for the stock 6.1.138 modules against v1.3.
- The new **system_dlkm.img only goes with v1.3**: three of its modules (`usbserial`, `cdc-acm`, `rfcomm`) need a symbol that v1.2 doesn't export.
- A changed system_dlkm also needs dm-verity disabled in vbmeta.

**Test first, then flash:**
```
fastboot boot boot.img                          # one-time boot, nothing written
adb shell uname -r                              # must show the new version
adb shell "su -c 'dmesg | grep -ciE \"disagrees about version|Unknown symbol|module verification failed\"'"   # must be 0
# then check root, Wi-Fi, data, touch, fingerprint, charging, camera, audio
fastboot flash boot boot.img                    # only if everything works
```
Rollback: `fastboot flash boot <your stock boot.img>`. **Back up your stock boot.img before anything else:**
```
adb shell "su -c 'dd if=/dev/block/by-name/boot$(getprop ro.boot.slot_suffix) of=/sdcard/boot_stock.img'"
adb pull /sdcard/boot_stock.img
```

## Repository layout
| Branch / tag | Content |
|---|---|
| `main` | this README, scripts, tools, changelogs |
| `kernel` | full kernel source, one snapshot commit per release (`v1.1` → `v1.2` → `v1.3`) |
| tags `v1.1`, `v1.2`, `v1.3` | the exact kernel source of each release; the GitHub releases point at these tags |

Each snapshot commit message records the AOSP base tag and commit and the original local commit IDs. You can check it like this:
```
git diff android14-6.1-2026-06_r14 v1.3     # in a kernel/common clone with this repo added as a remote
```
That diff is exactly the TechAmethyst changes.

Directory map of `main`:
```
scripts/techamethyst_setup.sh      v1.1: tools, exact source (repo sync), unmodified baseline build, stock compare
scripts/techamethyst_features.sh   v1.1: feature commit (KSU, SUSFS, ...), build, CRC check, pack, zip
tools_ta/kmi_gate.sh               .ko import gate: every import CRC of every prebuilt module vs the new kernel
tools_ta/mk_system_dlkm.sh         system_dlkm.img in the stock layout (EROFS + AVB hashtree footer)
tools_ta/pack_boot.sh              boot.img: swap the kernel in a known-good boot.img, re-add the AVB footer
docs/BUILDING-WITH-AI.md           the rules and workflow used to develop this kernel
```

## How to build
You need WSL2/Linux on an ext4 filesystem (not `/mnt/c`), about 60 GB of free space and 16 GB+ of RAM.

```bash
# 1. Kleaf workspace for the release's manifest branch
#    v1.2: common-android14-6.1-2025-06     v1.3: common-android14-6.1-2026-06
mkdir -p ~/techamethyst && cd ~/techamethyst
repo init -u https://android.googlesource.com/kernel/manifest -b common-android14-6.1-2026-06
repo sync -c --no-tags

# 2. replace common/ with the TechAmethyst source of that release
rm -rf common
git clone -b kernel https://github.com/TheTechGuy69/techamethyst-kernel common
git -C common checkout v1.3

# 3. Kleaf stamp: drop "-maybe-dirty" (same as scripts/techamethyst_features.sh)
sed -i "/stable_scmversion_cmd/s/-maybe-dirty//g" build/kernel/kleaf/impl/stamp.bzl

# 4. build (about 8 minutes once warm)
env -u BUILD_NUMBER tools/bazel run --config=stamp --jobs=8 //common:kernel_aarch64_dist -- --dist_dir=$PWD/out/v1.3
```
`uname -r` contains the git commit (`-g<sha>`). A build from the snapshot commit gets this repo's commit ID rather than the original local one. Code and config are the same.

### Exact values used for the published releases
All of these ran with `TOP=$HOME/techamethyst`, clang r487747c (pinned by the manifest), `JOBS=8` and `BUILD_NUMBER` unset.

| Step | v1.2 | v1.3 |
|---|---|---|
| base tag | `android14-6.1-2025-06_r17` | `android14-6.1-2026-06_r14` |
| build | `... //common:kernel_aarch64_dist -- --dist_dir=$TOP/out/v1.2-c2` | `... --dist_dir=$TOP/out/v1.3-c2` |
| boot.img | same recipe as `tools_ta/pack_boot.sh $TOP/out/v1.2-c2 <v1.1 boot.img> $TOP/out_ta/v1.2 v1.2` (made before the script was generalised) | `tools_ta/pack_boot.sh $TOP/out/v1.3-c2 <v1.1 boot.img> $TOP/out_ta/v1.3 v1.3` |
| AVB salt | `SALT` unset (random) | `SALT` unset (random) |
| system_dlkm | not built | `STOCKIMG=$TOP/out/stock_mods/img/system_dlkm_a.img STOCKTREE=$TOP/out/stock_mods/system_dlkm tools_ta/mk_system_dlkm.sh $TOP/out/v1.3-c2 system_dlkm.img` |
| KMI check | CRC (`vmlinux.symvers`) + STG vs v1.1; the `.ko` gate was run later (vendor_boot only), to calibrate it: `tools_ta/kmi_gate.sh $TOP/out/v1.2-c2/kernel_aarch64_Module.symvers <work> vendor_boot=<dir>` | `tools_ta/kmi_gate.sh $TOP/out/v1.3-c2/kernel_aarch64_Module.symvers <work> vendor_boot=<dir> vendor_dlkm=<dir> system_dlkm=<dir>` |
| zip | AnyKernel3 `020dfec`, `anykernel.sh` from `techamethyst_features.sh` (stage `zip`), `TA_VER=v1.2` | same, `TA_VER=v1.3`, kernel string "boot only - pair with v1.3 system_dlkm" |

Notes:
- **`<v1.1 boot.img>`** is the device's stock boot.img with the v1.1 kernel; `pack_boot.sh` only takes its header, ramdisk and AVB props.
  If you use another boot.img, its own AVB props (fingerprint, security patch) are copied instead.
- **Stock module dirs:**
  - `vendor_boot` = the ramdisk of stock `vendor_boot.img` (`unpack_bootimg.py`, then `lz4 -d | cpio -i`).
  - `vendor_dlkm`/`system_dlkm` = `fsck.erofs --extract` of the partitions from stock `super.img` (`simg2img` + `lpunpack`).
  - Stock images and `.ko` files are **not** in this repo; use your own firmware.
- **Reproducible images:**
  - With `SALT=auto`, `pack_boot.sh` and `mk_system_dlkm.sh` give byte-identical output for identical input.
  - The published v1.2/v1.3 images used a random salt. Their hashes therefore don't match a rebuild, but everything before the AVB footer does.

The v1.1 scripts in `scripts/` default to `$TOP/stock/kernel`, `$TOP/stock/boot.img` and `$TOP/out_ta`.
Every path is overridable: `TOP`, `STOCK`, `BOOT_STOCK`, `WIN_OUT`, `JOBS`, `TA_VER`, and the feature toggles (`KSU`, `SUSFS`, ...).

## License and source
- The kernel is licensed under **GPL-2.0** ([`LICENSE`](LICENSE)). The scripts in this repo are GPL-2.0 too.
- The complete corresponding source of every released binary is the matching tag on the `kernel` branch, together with the build steps above.
  The toolchain and Kleaf come unmodified from the AOSP manifest, apart from the one-line `stamp.bzl` edit.
- The KernelSU-Next and SUSFS parts carry their own GPL-2.0 notices inside the tree.
- No Xiaomi code is redistributed.
  - `boot.img` holds only the kernel built from this source. From the stock image it keeps just the header layout and the AVB props (fingerprint and patch-level strings); the ramdisk is empty.
  - `system_dlkm.img` holds only GKI modules built from this source, plus the stock partition's `etc/` metadata: `build.prop`, `fs_config_*` and `NOTICE.xml.gz`, copied unchanged so the partition matches the stock layout.

## Credits
- [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) and the [pershoot](https://github.com/pershoot/KernelSU-Next) dev-susfs fork
- [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) by simonpunk
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3) by osm0sis
- Google's Android Common Kernel and Kleaf

## Disclaimer
No warranty. You flash at your own risk. If it breaks, rollback is your stock boot.img.
