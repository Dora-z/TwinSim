#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
build_root="$PWD/.build"
source_dir="$build_root/upstream/jidr"
tools="$build_root/upstream/protoc-36.2"
revision=728475ece48a40e120806ca03546e4fa3a8f2876
mkdir -p "$source_dir" "$tools"
if [[ ! -d "$source_dir/.git" ]]; then
    git -C "$source_dir" init -q
fi
if ! git -C "$source_dir" cat-file -e "$revision^{commit}" 2>/dev/null; then
    git -C "$source_dir" fetch --depth=1 https://github.com/AbdurahmanAlmehdi/jidr.git "$revision"
fi
git -C "$source_dir" checkout --detach "$revision"

if [[ -z ${PROTOC:-} ]]; then
    if [[ ! -x "$tools/bin/protoc" ]]; then
        archive="$tools/protoc.zip"
        curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 -o "$archive" \
            https://github.com/protocolbuffers/protobuf/releases/download/v36.2/protoc-36.2-osx-aarch_64.zip
        printf '%s  %s\n' 9cd98a532c5c5e0c4161314de0225de27e4c8a323917b6ea7b1b714d3ae23466 "$archive" | shasum -a 256 -c
        unzip -oq "$archive" -d "$tools"
    fi
    export PROTOC="$tools/bin/protoc"
fi

export JIDR_PROTO_VENDORED=1 CARGO_TARGET_DIR="$build_root/jidr-target"
(cd "$source_dir" && cargo build --locked --release -p jidr -j "${TWINSIM_BUILD_JOBS:-6}")
printf '%s\n' "$CARGO_TARGET_DIR/release/jidr"
