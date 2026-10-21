#!/bin/bash
# TechAmethyst KMI gate: every symbol imported by the given prebuilt .ko sets must exist in the new
# kernel (vmlinux + GKI modules, from Module.symvers) with the CRC recorded in the module's __versions,
# or be exported by another module in the checked sets.
# usage: kmi_gate.sh <new Module.symvers> <workdir> <label>=<dir> [<label>=<dir> ...]
set -uo pipefail
SYMVERS=$1; W=$2; shift 2
mkdir -p "$W"; : > "$W/imports.tsv"; : > "$W/mod_exports.txt"
declare -A NMODS
for set in "$@"; do
  label=${set%%=*}; dir=${set#*=}; n=0
  while IFS= read -r ko; do
    n=$((n+1)); m=$(basename "$ko" .ko)
    modprobe --dump-modversions "$ko" 2>/dev/null | awk -v l="$label" -v m="$m" '{print l"\t"m"\t"$2"\t"$1}' >> "$W/imports.tsv"
    # symbols this module exports (__ksymtab_<sym>), for inter-module deps
    nm "$ko" 2>/dev/null | awk -v l="$label" -v m="$m" '$3 ~ /^__ksymtab_/ {s=$3; sub(/^__ksymtab_/,"",s); print s"\t"l":"m}' >> "$W/mod_exports.txt"
  done < <(find "$dir" -name '*.ko')
  NMODS[$label]=$n
done
awk -F'\t' -v W="$W" '
  FILENAME==ARGV[1] { crc[$2]=$1; next }               # Module.symvers: crc sym owner type
  FILENAME==ARGV[2] { prov[$1]=$2; next }              # module exports
  {
    lab=$1; mod=$2; sym=$3; want=$4; n[lab]++
    if (sym in crc) {
      if (tolower(crc[sym]) != tolower(want)) { bad[lab]++; print lab"\t"mod"\t"sym"\twant "want"\thave "crc[sym] > W"/mismatch.txt" }
    } else if (sym in prov) {
      viamod[lab]++                                     # provided by a prebuilt module (CRC theirs, unchanged)
    } else { miss[lab]++; print lab"\t"mod"\t"sym"\twant "want"\tMISSING" > W"/mismatch.txt" }
  }
  END {
    printf "%-12s %8s %8s %10s %8s %8s\n", "set", "imports", "kernel", "via-module", "CRC-bad", "missing"
    for (l in n) { printf "%-12s %8d %8d %10d %8d %8d\n", l, n[l], n[l]-viamod[l]-miss[l], viamod[l], bad[l]+0, miss[l]+0; tb+=bad[l]; tm+=miss[l] }
    exit (tb+tm) > 0
  }' "$SYMVERS" "$W/mod_exports.txt" "$W/imports.tsv"
rc=$?
for l in "${!NMODS[@]}"; do echo "modules[$l]=${NMODS[$l]}"; done
touch "$W/mismatch.txt"; echo "mismatch lines: $(wc -l < "$W/mismatch.txt")"
exit $rc
