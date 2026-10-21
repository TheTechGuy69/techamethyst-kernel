# Building TechAmethyst with an AI coding agent

TechAmethyst is developed with an AI coding agent (Claude Code) working in a local Kleaf workspace.
The agent is told the rules below. They are written for an agent, but they apply just as well to a human.
The key idea: a broken kernel on this phone means a boot loop, so every step is gated and nothing is ever flashed automatically.

## The project
- **Device:** Redmi Note 14 Pro+ 5G (`amethyst`), SM7635 "volcano" (Snapdragon 7s Gen 3).
  - CPUs 0-3 are Cortex-A520, 4-6 are A720, and 7 is the prime A720.
  - Adreno 810 GPU, 12 GB RAM.
- **Workspace:** a Kleaf/Bazel GKI workspace (`common/` = kernel source, `prebuilts/` + `build/` = toolchain and Kleaf).
- **Features:** one commit on top of an android14-6.1 GKI release tag: `KSU=1 SUSFS=1 BBR=1 NTFS3=1 WLBLOCK=1 TUNE=1 STATUS=1`.
- **Running on:** a ROM with the HyperOS 3.0.306 vendor.
  - All Xiaomi/QCOM drivers are **prebuilt vendor modules** (vendor_dlkm and the vendor_boot ramdisk).
  - Google's GKI modules (zram.ko, ...) are in **system_dlkm**.
  - Only the kernel `Image` inside boot.img is replaced, plus system_dlkm since v1.3.
- **Reference only:** Xiaomi's 6.1.68 kernel OSS, for driver and devicetree reference. It is never built.

## Hard rules
1. **The KMI must match what the prebuilt modules import.**
   - Every symbol imported by the vendor modules (vendor_dlkm + vendor_boot) and by system_dlkm must exist with a matching CRC.
   - Check this **against the actual .ko files** (`tools_ta/kmi_gate.sh`), not only against Google's reference ABI.
   - Don't change struct layouts or exported symbols, except where Google's own release did (KABI reserved slots).
   - If unsure: stop and ask.
2. **Never flash.**
   - The agent produces images, `SHA256SUMS` and `CHANGES.md`.
   - The human tests with `fastboot boot` first and flashes themselves.
3. **Every release is reproducible.**
   - One git branch per release; a released branch is never rewritten.
   - Any file changed outside git is backed up first.
4. **One change per commit,** with a clear message. Rebuild and run the KMI check after each commit, so a bad build can be bisected.
5. **Never break root.** If KernelSU-Next or susfs can't be applied cleanly, stop and report. Don't force hunks.
6. **Ask before anything irreversible or outward-facing:** flashing, deleting, overwriting a known-good image, large downloads, pushing, publishing.

## Workflow per release
1. **Read first.** Report how the previous release was built (scripts, logs, defconfig, Kleaf targets) before changing anything.
2. **Rebuild the previous release unchanged** and confirm it matches: same version string, config and symvers.
3. **Pick the base.**
   - Use the newest android14-6.1 release tag whose ABI is compatible.
   - Compare Google's `android/abi_gki_aarch64.stg` with `stgdiff`. Only KABI reserved-slot uses and enum additions are acceptable.
   - Skip tags that change struct sizes or offsets (2026-09 was skipped because it reworks fscrypt structs).
4. **Plain baseline build** of the new tag with no features. Its `.config` and `vmlinux.symvers` become the reference.
5. **Re-apply the feature commit.** Check susfs hunk by hunk and report fuzz or rejects before fixing anything.
6. **Build, then gate:**
   - `vmlinux.symvers` CRCs vs the baseline,
   - STG (`stg` + `stgdiff`) vs the baseline,
   - and `tools_ta/kmi_gate.sh` over every stock `.ko`. Calibrate the gate on a release that is known to boot first.
7. **system_dlkm** (since v1.3): build the GKI modules from the same tree and pack them in the same layout as stock (`tools_ta/mk_system_dlkm.sh`).
8. **Deliver** boot.img, system_dlkm.img, the AnyKernel3 zip, `SHA256SUMS` and `CHANGES.md` with a test plan.
9. **The human tests:** `fastboot boot` first. Flash only after the checks pass.

## Out of scope
- Log spam from prebuilt Xiaomi modules (it's handled in userspace).
- Anything that needs rebuilding Xiaomi's vendor modules.
- Suspend failures caused by vendor drivers (`icnss`, `alarmtimer` EBUSY). These are noted, never patched.

## Lessons from v1.1–v1.3
- Verify claims before writing them into release notes; one rollback claim in v1.3's notes was wrong until the gate checked it.
- A CRC check only covers the symbols you compare. Check what the modules actually import.
- avbtool uses a random salt by default, so `boot.img` hashes differ between identical builds. Use `SALT=auto` for reproducible images.
