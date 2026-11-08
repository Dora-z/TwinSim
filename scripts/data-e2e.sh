#!/bin/bash
# Live test of moving the data directory (internal disk -> external drive) and deleting devices.
# Seeds an internal-disk data directory from an earlier test home that holds an Android AVD and an
# iOS Simulator device, points the app's Settings at it, and lets the in-app self-test move it.
#   TWINSIM_DATA_SEED   test home with devices (default .build/agent-e2e/home from agent-e2e.py)
#   TWINSIM_DATA_SRC    internal-disk source (default ~/TwinSimMoveTest/TwinSim)
#   TWINSIM_DATA_DEST   destination (default .build/data-e2e/TwinSim on this repository's volume)
set -euo pipefail
cd "$(dirname "$0")/.."
app=${TWINSIM_APP:-$PWD/dist/TwinSim.app}
seed=${TWINSIM_DATA_SEED:-$PWD/.build/agent-e2e/home}
src=${TWINSIM_DATA_SRC:-$HOME/TwinSimMoveTest/TwinSim}
dest=${TWINSIM_DATA_DEST:-$PWD/.build/data-e2e/TwinSim}
report=$PWD/.build/data-e2e/report
[[ -f $seed/state.json ]] || { echo "Seed $seed missing: run scripts/agent-e2e.py first" >&2; exit 1; }

osascript -e 'tell application id "com.twinsim.app" to quit' >/dev/null 2>&1 || true
sleep 2
previous=$(defaults read com.twinsim.app dataDirectory 2>/dev/null || true)
restore() {
    if [[ -n $previous ]]; then defaults write com.twinsim.app dataDirectory "$previous"
    else defaults delete com.twinsim.app dataDirectory >/dev/null 2>&1 || true; fi
}
trap restore EXIT

rm -rf "$src" "$dest" "$report"
mkdir -p "$(dirname "$src")" "$(dirname "$dest")"
echo "Seeding $src from $seed"
ditto "$seed" "$src"
rm -rf "$src/scratch" "$src/.lock" "$src/agent.sock"
# Make the seed self-contained: its AVD files still point at the seed location.
find "$src/jidr/data/avd" -name '*.ini' -print0 | xargs -0 sed -i '' "s#$seed#$src#g"
defaults write com.twinsim.app dataDirectory "$src"

open -W -n "$app" \
    --env "TWINSIM_SELF_TEST=$report" \
    --env "TWINSIM_SELF_TEST_SAMPLES=$PWD/.build/test-samples" \
    --env "TWINSIM_SELF_TEST_PLATFORMS=data" \
    --env "TWINSIM_SELF_TEST_MOVE_TO=$dest"
grep -E 'PASS|FAIL|finished' "$report/selftest.log" || true
! grep -q '\*\*失败\*\*' "$report/report.md"
