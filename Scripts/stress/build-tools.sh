#!/bin/sh
# Builds procstat (a `ps` for a bootstrap that ships none, see procstat.c)
# for an iOS device into OUT (default: build/stress), ad-hoc signed with
# ldid and the entitlements that let it read every process.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
out=${OUT:-$root/build/stress}
mkdir -p "$out"
xcrun -sdk iphoneos clang -arch arm64 -O2 -Wall -o "$out/procstat" "$root/Scripts/stress/procstat.c"
ldid -S"$root/Scripts/stress/procstat.entitlements" "$out/procstat"
echo "$out/procstat"
