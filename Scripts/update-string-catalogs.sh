#!/bin/sh
# Regenerates each target's Resources/Localizable.xcstrings from the strings used in source.
#
# Compiles the package from scratch with `-emit-localized-strings`, groups the extracted
# .stringsdata files by target and merges them with `xcstringstool sync`. Existing translations
# are kept; strings no longer used in source are marked stale.
#
# Usage: Scripts/update-string-catalogs.sh   (from the package root; needs Xcode 15+)
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"
xcrun swift build --scratch-path "$WORK/build" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/strings" >/dev/null

python3 -I - "$WORK/strings" "$ROOT/Sources" <<'EOF'
import json, os, shutil, sys

strings_dir, sources = sys.argv[1], os.path.realpath(sys.argv[2]) + os.sep
missing_comments = []
for name in sorted(os.listdir(strings_dir)):
    path = os.path.join(strings_dir, name)
    if not name.endswith(".stringsdata"):
        continue
    data = json.load(open(path))
    source = os.path.realpath(data["source"])
    entries = [e for table in data["tables"].values() for e in table]
    if not source.startswith(sources) or not entries:
        continue  # generated files (resource accessors) or files without strings
    target = source[len(sources):].split(os.sep)[0]
    missing_comments += [f"{source}:{e['location']['startingLine']} {e['key']!r}" for e in entries if not e.get("comment")]
    os.makedirs(os.path.join(strings_dir, target), exist_ok=True)
    shutil.move(path, os.path.join(strings_dir, target, name))

if missing_comments:
    print("Strings without a translator comment (add `comment:`):", *missing_comments, sep="\n  ")
    sys.exit(1)
EOF

for dir in "$WORK"/strings/*/; do
    target=$(basename "$dir")
    catalog="Sources/$target/Resources/Localizable.xcstrings"
    [ -f "$catalog" ] || { echo "No catalog for $target at $catalog"; exit 1; }
    xcrun xcstringstool sync "$catalog" --stringsdata "$dir"*.stringsdata
    count=$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["strings"]))' "$catalog")
    echo "$target: $count keys"
done
