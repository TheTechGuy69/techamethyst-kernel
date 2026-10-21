#!/bin/bash
# Build a TechAmethyst system_dlkm.img with the same layout as stock system_dlkm_a.img:
# stock etc/ + new GKI modules (lib/modules/<rel> and flatten/), EROFS lz4hc, fixed time, stock UUID,
# single selinux label, AVB hashtree footer (FEC 2 roots) with the stock props.
# usage: mk_system_dlkm.sh <kleaf dist dir> <out img>
# env:   STOCKIMG=<stock system_dlkm_a.img>      (default $TOP/out/stock_mods/img/system_dlkm_a.img)
#        STOCKTREE=<that image extracted>         (default $TOP/out/stock_mods/system_dlkm;
#                                                  make it with: fsck.erofs --extract=DIR STOCKIMG)
#        SALT=auto|<hex>   reproducible hashtree salt (unset = random, as used for v1.3)
#        TOP=...           workspace (default ~/techamethyst)
set -euo pipefail
DIST=$1; OUTIMG=$2
TOP=${TOP:-$HOME/techamethyst}
STOCKIMG=${STOCKIMG:-$TOP/out/stock_mods/img/system_dlkm_a.img}
STOCKTREE=${STOCKTREE:-$TOP/out/stock_mods/system_dlkm}
W=${WORK:-$TOP/out/system_dlkm_build}
BIN=$TOP/prebuilts/kernel-build-tools/linux-x86/bin
AVB=$(find "$TOP/prebuilts" "$TOP/build" "$TOP/tools" -name avbtool -type f -perm -u+x -print -quit)

rm -rf "$W"; mkdir -p "$W/tree"
cp -a "$STOCKTREE/etc" "$W/tree/etc"
tar xzf "$DIST/system_dlkm_staging_archive.tar.gz" -C "$W/tree"
rel=$(ls "$W/tree/lib/modules")
[ "$(echo "$rel" | wc -l)" = 1 ] || { echo "expected one release dir, got: $rel"; exit 1; }
echo "release dir: $rel"

# same module set as stock (by file name), in both trees
oldrel=$(ls "$STOCKTREE/lib/modules")
diff <(cd "$STOCKTREE/lib/modules/$oldrel" && find . -name '*.ko' -printf '%f\n' | sort) \
     <(cd "$W/tree/lib/modules/$rel" && find . -name '*.ko' -printf '%f\n' | sort) > "$W/modset.diff" \
  && echo "lib/modules: same .ko set as stock ($(find "$W/tree/lib/modules" -name '*.ko' | wc -l))" \
  || { echo "lib/modules .ko set differs from stock:"; cat "$W/modset.diff"; exit 1; }
diff <(ls "$STOCKTREE/flatten/lib/modules" | sort) <(ls "$W/tree/flatten/lib/modules" | sort) > "$W/flat.diff" \
  && echo "flatten: same file set as stock" || { echo "flatten differs:"; cat "$W/flat.diff"; exit 1; }
diff <(ls "$STOCKTREE/lib/modules/$oldrel" | grep -v '\.ko$' | sort) <(ls "$W/tree/lib/modules/$rel" | grep -v '\.ko$' | sort) \
  && echo "modules.* metadata: same file set as stock" || { echo "modules.* metadata set differs"; exit 1; }
diff "$STOCKTREE/flatten/lib/modules/modules.load" "$W/tree/flatten/lib/modules/modules.load" >/dev/null \
  && echo "modules.load order: identical to stock" || echo "NOTE: modules.load order differs from stock"

# normalise modes like stock (dirs 0755, files 0644)
find "$W/tree" -type d -exec chmod 0755 {} +; find "$W/tree" -type f -exec chmod 0644 {} +
printf '/system_dlkm(/.*)?\tu:object_r:system_dlkm_file:s0\n' > "$W/file_contexts"
uuid=$(dump.erofs -s "$STOCKIMG" | sed -n 's/^Filesystem UUID: *//p')
mkfs.erofs -zlz4hc -T1230768000 -U "$uuid" --all-root --mount-point=/system_dlkm \
  --file-contexts="$W/file_contexts" "$W/fs.img" "$W/tree" > "$W/mkfs.log" 2>&1 || { cat "$W/mkfs.log"; exit 1; }
fsck.erofs "$W/fs.img" > /dev/null && echo "fsck.erofs: OK"

# AVB hashtree footer like stock (unsigned, FEC 2 roots, same props)
"$AVB" info_image --image "$STOCKIMG" > "$W/stock_avb.txt"
props=()
while IFS= read -r l; do props+=(--prop "$l"); done < <(sed -n "s/^ *Prop: \(.*\) -> '\(.*\)'\s*$/\1:\2/p" "$W/stock_avb.txt")
cp "$W/fs.img" "$OUTIMG"
# smallest partition size (4K steps) whose max image size fits the fs (what --dynamic_partition_size does)
fs=$(stat -c%s "$OUTIMG"); psz=$fs
while :; do
  psz=$((psz+4096))
  max=$(PATH=$BIN:$PATH "$AVB" add_hashtree_footer --partition_size $psz --hash_algorithm sha256 --fec_num_roots 2 --calc_max_image_size)
  [ "$max" -ge "$fs" ] && break
done
echo "avb partition size: $psz (fs $fs)"
salt=()
case "${SALT:-}" in
  "")   ;;
  auto) salt=(--salt "$(sha256sum "$OUTIMG" | cut -d' ' -f1)");;
  *)    [[ "$SALT" =~ ^[0-9a-fA-F]+$ ]] || { echo "SALT must be hex or 'auto'"; exit 1; }; salt=(--salt "$SALT");;
esac
[ ${#salt[@]} -gt 0 ] && echo "avb salt: ${salt[1]}"
PATH=$BIN:$PATH "$AVB" add_hashtree_footer --image "$OUTIMG" --partition_name system_dlkm \
  --partition_size $psz --hash_algorithm sha256 --fec_num_roots 2 "${salt[@]}" "${props[@]}"
"$AVB" info_image --image "$OUTIMG" > "$W/new_avb.txt"
diff <(grep -E 'Algorithm|Partition Name|Hash Algorithm|FEC num|Data Block|Hash Block|Prop' "$W/stock_avb.txt") \
     <(grep -E 'Algorithm|Partition Name|Hash Algorithm|FEC num|Data Block|Hash Block|Prop' "$W/new_avb.txt") \
  && echo "AVB footer: same settings + props as stock"
diff <(dump.erofs -s "$STOCKIMG" | grep -vE 'blocks|inode count|created|root nid|metadata start') \
     <(dump.erofs -s "$OUTIMG"   | grep -vE 'blocks|inode count|created|root nid|metadata start') \
  && echo "EROFS superblock features/UUID: same as stock"
ls -l "$STOCKIMG" "$OUTIMG" | awk '{print $5, $9}'
