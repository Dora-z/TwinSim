#!/bin/bash
set -euo pipefail

if ! xcrun --find simctl >/dev/null 2>&1; then
    echo 'Set DEVELOPER_DIR to the Contents/Developer directory of a full Xcode installation.' >&2
    exit 1
fi

xcodebuild -version
printf '\nInstalled Simulator runtimes:\n'
xcrun simctl list -j runtimes

scratch=$(mktemp -d "${TMPDIR:-/tmp}/twinsim-ios.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
printf 'int main(void) { return 0; }\n' > "$scratch/main.c"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios18.0-simulator "$scratch/main.c" -o "$scratch/simulator"
xcrun --sdk iphoneos clang -target arm64-apple-ios18.0 "$scratch/main.c" -o "$scratch/device"

for target in simulator device; do
    file "$scratch/$target"
    xcrun vtool -show-build "$scratch/$target" | awk '/platform/ { print $2 }'
done
[[ $(xcrun vtool -show-build "$scratch/simulator" | awk '/platform/ { print $2 }') == IOSSIMULATOR ]]
[[ $(xcrun vtool -show-build "$scratch/device" | awk '/platform/ { print $2 }') == IOS ]]

printf '\nvphone host settings (read-only):\n'
csrutil status
if ! csrutil allow-research-guests status; then
    echo 'Research Guests status unavailable.'
fi
echo 'iOS toolchain probe passed. This probe does not boot a Simulator or a VM.'
