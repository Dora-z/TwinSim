#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
configuration=${TWINSIM_BUILD_CONFIGURATION:-release}
payload=${1:-"$PWD/.build/backend-payload"}
swift build --configuration "$configuration" --product twinsimd -j "${TWINSIM_BUILD_JOBS:-8}"
binary="$(swift build --configuration "$configuration" --show-bin-path)/twinsimd"
helpers="$payload/Contents/Helpers"
notices="$payload/Contents/Resources/BackendNotices"
mkdir -p "$helpers" "$notices"
install -m 755 "$binary" "$helpers/twinsimd"
if [[ -n ${TWINSIM_JIDR_PAYLOAD:-} ]]; then
    : "${TWINSIM_JIDR_NOTICES:?Provide the source directory with LICENSE-APACHE and NOTICE for the bundled Jidr CLI}"
    install -m 755 "$TWINSIM_JIDR_PAYLOAD" "$helpers/jidr"
    install -m 644 "$TWINSIM_JIDR_NOTICES/LICENSE-APACHE" "$notices/jidr-LICENSE-APACHE"
    install -m 644 "$TWINSIM_JIDR_NOTICES/NOTICE" "$notices/jidr-NOTICE"
fi
for helper in "$helpers/twinsimd" "$helpers/jidr"; do
    [[ -f "$helper" ]] || continue
    if [[ -n ${TWINSIM_SIGN_IDENTITY:-} ]]; then
        codesign --force --options runtime --timestamp --sign "$TWINSIM_SIGN_IDENTITY" "$helper"
    else
        codesign --force --sign - "$helper"
    fi
    codesign --verify --strict "$helper"
done
for checkout in .build/checkouts/*; do
    [[ -d "$checkout" ]] || continue
    for license in "$checkout"/LICENSE "$checkout"/LICENSE.* "$checkout"/NOTICE "$checkout"/NOTICE.*; do
        [[ -f "$license" ]] || continue
        install -m 644 "$license" "$notices/${checkout##*/}-${license##*/}"
    done
done
install -m 644 Package.resolved "$notices/Package.resolved"
printf '%s\n' "$helpers/twinsimd"
