#!/bin/bash
# Pack a TechAmethyst boot.img: swap the kernel in a known-good boot.img (stock boot, or a previous
# TechAmethyst boot.img made from it), keep header/ramdisk/cmdline, re-add the AVB hash footer with the
# same partition size and props.
# usage: pack_boot.sh <kleaf dist dir> <template boot.img> <out dir> <version, e.g. v1.3>
# env:   SALT=auto   AVB salt = sha256 of the image before the footer -> byte-reproducible boot.img
#        SALT=<hex>  use this salt;  unset = random salt (avbtool default; used for v1.2/v1.3)
#        TOP=...     workspace (default ~/techamethyst)
set -euo pipefail
TOP=${TOP:-$HOME/techamethyst}
OUT=$1
TPL=$2
W=$TOP/out/pack-$4
D=$3
MKB=$(dirname "$(find "$TOP/tools" "$TOP/build" -name unpack_bootimg.py -print -quit)")
AVB=$(find "$TOP/prebuilts" "$TOP/build" "$TOP/tools" -name avbtool -type f -perm -u+x -print -quit)

rm -rf "$W"; mkdir -p "$W" "$D"
python3 "$MKB/unpack_bootimg.py" --boot_img "$TPL" --out "$W/tpl" --format=mkbootimg > "$W/args.txt"
echo "template args: $(cat "$W/args.txt")"
file -b "$W/tpl/kernel" | grep -q 'ARM64 boot executable' || { echo "template kernel not raw Image"; exit 1; }
cp "$OUT/Image" "$W/tpl/kernel"
( cd "$W" && eval python3 "$MKB/mkbootimg.py" "$(sed "s|$W/||g" args.txt)" --output "$W/boot.img" )

python3 "$MKB/unpack_bootimg.py" --boot_img "$W/boot.img" --out "$W/verify" --format=mkbootimg > "$W/verify_args.txt"
cmp -s "$W/verify/kernel" "$OUT/Image" || { echo "kernel in boot.img != the built Image"; exit 1; }
diff <(sed "s|$W/tpl/||g" "$W/args.txt") <(sed "s|$W/verify/||g" "$W/verify_args.txt") || { echo "header args differ from template"; exit 1; }
grep -aq -- "-TechAmethyst-$4" "$W/verify/kernel" || { echo "version -TechAmethyst-$4 not found in kernel"; exit 1; }

"$AVB" info_image --image "$TPL" > "$W/tpl_avb.txt"
psize=$(stat -c%s "$TPL")
props=()
while IFS= read -r l; do props+=(--prop "$l"); done < <(sed -n "s/^ *Prop: \(.*\) -> '\(.*\)'\s*$/\1:\2/p" "$W/tpl_avb.txt")
echo "avb: partition $psize bytes, $(( ${#props[@]} / 2 )) props from template footer"
salt=()
case "${SALT:-}" in
  "")   ;;
  auto) salt=(--salt "$(sha256sum "$W/boot.img" | cut -d' ' -f1)");;
  *)    [[ "$SALT" =~ ^[0-9a-fA-F]+$ ]] || { echo "SALT must be hex or 'auto'"; exit 1; }; salt=(--salt "$SALT");;
esac
[ ${#salt[@]} -gt 0 ] && echo "avb salt: ${salt[1]}"
"$AVB" add_hash_footer --image "$W/boot.img" --partition_name boot \
    --partition_size "$psize" --hash_algorithm sha256 "${salt[@]}" "${props[@]}"
[ "$(stat -c%s "$W/boot.img")" = "$psize" ]
"$AVB" info_image --image "$W/boot.img" > "$W/new_avb.txt"
diff <(grep -E 'Image size|Partition Name|Prop' "$W/tpl_avb.txt") <(grep -E 'Image size|Partition Name|Prop' "$W/new_avb.txt") && echo "avb layout + props match template"
cp "$W/boot.img" "$D/boot.img"
