#!/usr/bin/env bash
# Writes Sources/SwapjutsuApp/Resources/ThirdPartyNotices.txt: the license of every package compiled into the app,
# and of the libraries mlx-swift vendors, as MIT and Apache-2.0 ask of a binary distribution. Run it after
# `swift package resolve` whenever Package.resolved changes, and commit the result.
set -euo pipefail
cd "$(dirname "$0")/.."

checkouts=.build/checkouts
[[ -d $checkouts ]] || { echo "error: no $checkouts; run swift package resolve first" >&2; exit 1; }
out=Sources/SwapjutsuApp/Resources/ThirdPartyNotices.txt

# swift-syntax only builds macros at compile time; nothing of it ships.
packages=$(python3 -I -c '
import json
for pin in json.load(open("Package.resolved"))["pins"]:
    if pin["identity"] != "swift-syntax":
        print(pin["identity"], pin["location"], pin["state"].get("version") or pin["state"]["revision"][:12])
')

section() {
    printf '\n%s\n%s\n%s\n\n' "================================================================================" "$1" \
        "================================================================================"
}

{
    echo "Swapjutsu includes the following open-source software. Each is distributed under its own license,"
    echo "reproduced below with its copyright and NOTICE files."
    while read -r identity location version; do
        dir=$(find "$checkouts" -maxdepth 1 -iname "$identity" | head -n 1)
        [[ -n $dir ]] || { echo "error: $identity is not in $checkouts" >&2; exit 1; }
        section "$identity $version (${location%.git})"
        for file in "$dir"/LICENSE* "$dir"/NOTICE*; do [[ -f $file ]] && { cat "$file"; echo; }; done
        if [[ $identity == mlx-swift ]]; then
            for vendored in mlx mlx-c fmt json metal-cpp; do
                section "$vendored (vendored in mlx-swift, Source/Cmlx/$vendored)"
                for file in "$dir/Source/Cmlx/$vendored"/LICENSE* "$dir/Source/Cmlx/$vendored"/NOTICE*; do
                    [[ -f $file ]] && { cat "$file"; echo; }
                done
            done
        fi
    done <<<"$packages"
} >"$out"
echo "$out"
