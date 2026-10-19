#!/usr/bin/env bash
# Downloads the Core ML models prep runs into Models/, pinned to one revision and checked file by file:
#   - Apple's conversion of Depth Anything V2 Small (Apache-2.0, ~48 MB, Hugging Face):
#     Models/DepthAnythingV2SmallF16.mlpackage
#   - EdgeTAM's four video models (Meta, Apache-2.0) in our Core ML conversion, jutsuhq/edgetam-coreml v1.1 (one
#     ~51 MB zip with its LICENSE and NOTICE): Models/EdgeTAM/
# Files already there with the right hash are kept; a folder from a zip is replaced whole when any file differs. The app copies these into Application Support instead of
# downloading them; the same pins are in Sources/SwapjutsuApp/Model/ModelFiles.swift, keep the two in step.
set -euo pipefail
cd "$(dirname "$0")/.."

# fetch <base url> <folder> then "<path> <sha256>" lines on stdin.
fetch() {
    local base=$1 folder=$2 path sha
    while read -r path sha; do
        local file="$folder/$path"
        if [[ -f $file ]] && [[ $(shasum -a 256 "$file" | cut -d' ' -f1) == "$sha" ]]; then continue; fi
        mkdir -p "$(dirname "$file")"
        curl -fsSL -o "$file.part" "$base/$path"
        if [[ $(shasum -a 256 "$file.part" | cut -d' ' -f1) != "$sha" ]]; then
            rm -f "$file.part"
            echo "fetch-models: $file does not match its pinned SHA-256" >&2
            exit 1
        fi
        mv "$file.part" "$file"
        # A new package must be compiled again.
        rm -rf "${file%%.mlpackage/*}.mlmodelc"
    done
    du -sh "$folder"
}

# matches <folder> then "<path> <sha256>" lines on stdin: every file is there with its hash.
matches() {
    local path sha
    while read -r path sha; do
        [[ $(shasum -a 256 "$1/$path" 2>/dev/null | cut -d' ' -f1) == "$sha" ]] || return 1
    done
}

# fetch_zip <zip url> <zip sha256> <folder> then "<path> <sha256>" lines on stdin: the folder is the zip's contents.
fetch_zip() {
    local url=$1 zip_sha=$2 folder=$3 pins
    pins=$(cat)
    if matches "$folder" <<<"$pins"; then
        du -sh "$folder"
        return
    fi
    local staging
    staging=$(mktemp -d "${folder%/*}/.fetch-XXXXXX")
    trap 'rm -rf "$staging"' EXIT
    curl -fsSL -o "$staging/download.zip" "$url"
    if [[ $(shasum -a 256 "$staging/download.zip" | cut -d' ' -f1) != "$zip_sha" ]]; then
        echo "fetch-models: $url does not match its pinned SHA-256" >&2
        exit 1
    fi
    ditto -x -k "$staging/download.zip" "$staging/unpacked"
    if ! matches "$staging/unpacked" <<<"$pins"; then
        echo "fetch-models: a file in $url does not match its pinned SHA-256" >&2
        exit 1
    fi
    # Replaced whole, so no file or compiled .mlmodelc of an earlier copy is left.
    rm -rf "$folder"
    mv "$staging/unpacked" "$folder"
    rm -rf "$staging"
    trap - EXIT
    du -sh "$folder"
}

mkdir -p Models

fetch https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/cfef6f6f2a70783dedc0bfae40cecbc2052285d3/DepthAnythingV2SmallF16.mlpackage \
    Models/DepthAnythingV2SmallF16.mlpackage <<'PINS'
Manifest.json 2883ae290c48fe916dc5ececac03a7d847fa277165a49ef5652fa1d2b9cb55f7
Data/com.apple.CoreML/model.mlmodel 44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042
Data/com.apple.CoreML/weights/weight.bin fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed
PINS

fetch_zip https://github.com/jutsuhq/edgetam-coreml/releases/download/v1.1/edgetam-coreml-v1.1.zip \
    6a4cf09ef7e02f0504155d4f2d949a4882fc764e0fbf773e8f8b11a2f48e07b9 Models/EdgeTAM <<'PINS'
EdgeTAMVideoImageEncoder.mlpackage/Manifest.json a1280c7dc52efa77f8f476c74490c333db9ec76bb40649086981b9dd5cc3e74a
EdgeTAMVideoImageEncoder.mlpackage/Data/com.apple.CoreML/model.mlmodel 617a8c518d561a1152b04f2d619741002e1b0e83a1a0ea70ea878ad2ed120f03
EdgeTAMVideoImageEncoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin 337900984a90039da4d26ad92abc32943ed920b4d8c7434f1ac717e2fbbc108b
EdgeTAMVideoInitializer.mlpackage/Manifest.json d0c76e40b8f183a4963560389d2fccecddca2d368f953f4fe56087206d3508a2
EdgeTAMVideoInitializer.mlpackage/Data/com.apple.CoreML/model.mlmodel bf65c24c715684d64422e8f3d58a4309ae92624a28ee0299e3818e402e129d19
EdgeTAMVideoInitializer.mlpackage/Data/com.apple.CoreML/weights/weight.bin 86d71536e489b5ae5c4388e1213d97921a4e7fc1ef88b76ac2e2e8e51f155a07
EdgeTAMVideoMemoryEncoder.mlpackage/Manifest.json 6eca763508e70798da6b1fb62e1632e2c4da76ac352a1a10be203b3fd50a7e95
EdgeTAMVideoMemoryEncoder.mlpackage/Data/com.apple.CoreML/model.mlmodel b111e7feb0610356ab77fb12c49e6ea1f907278d9465c2707744f4e45db38a1e
EdgeTAMVideoMemoryEncoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin c8a7cda81c1cd0c4fafc94fd14d755d306fa50750dd8d022f974239601dc6f1d
EdgeTAMVideoPropagator.mlpackage/Manifest.json 8cad09783edd4ab5dabca429d9d85df80573a165b2b4b26eb1f0afd4f467a78f
EdgeTAMVideoPropagator.mlpackage/Data/com.apple.CoreML/model.mlmodel 8fdafe96cd169deaa9cdd84b0d43754c4abac7bea4296a2dcbb80706efa4a07f
EdgeTAMVideoPropagator.mlpackage/Data/com.apple.CoreML/weights/weight.bin 54667d6f2d4586c67cedfa46fa102c45f85630b1238a7897ef5cc5fdbde3fb06
LICENSE c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4
NOTICE e4e5146f34236dc370925b97ce122037d8b0a87c839fefc6d53bfc9dc276159c
PINS
