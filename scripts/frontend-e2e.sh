#!/bin/bash
# Runs the packaged TwinSim.app self-test against the real bundled backend in an isolated
# TWINSIM_HOME. Host paths are passed through the app's own settings, as a user would set them.
#   ANDROID_HOME / DEVELOPER_DIR   host toolchains (stored with `defaults write com.twinsim.app`)
#   TWINSIM_E2E_DIR                output directory (default .build/e2e)
#   TWINSIM_SELF_TEST_PLATFORMS    subset of android,ios,ipa
set -euo pipefail

cd "$(dirname "$0")/.."
app=${TWINSIM_APP:-$PWD/dist/TwinSim.app}
samples=${TWINSIM_SAMPLES:-$PWD/.build/test-samples}
dir=${TWINSIM_E2E_DIR:-$PWD/.build/e2e}
[[ -x $app/Contents/MacOS/TwinSim ]] || { echo "Build the app first: bash scripts/package-app.sh" >&2; exit 1; }
[[ -f $samples/TouchProbe.apk ]] || { echo "Build samples first: bash scripts/make-test-samples.sh $samples" >&2; exit 1; }

[[ -n ${ANDROID_HOME:-} ]] && defaults write com.twinsim.app androidHome "$ANDROID_HOME"
[[ -n ${DEVELOPER_DIR:-} ]] && defaults write com.twinsim.app developerDir "$DEVELOPER_DIR"

rm -rf "$dir/report"
mkdir -p "$dir/home"
# Launch through LaunchServices, as a Finder double-click would, so the app (and the Simulator
# it boots) runs in the user's GUI session. The ANDROID_HOME/DEVELOPER_DIR of this shell are not
# inherited; the app reads them from its settings.
# (`open --stderr` fails with LaunchServices error -10810 here, so the self-test writes its own log.)
extra=()
[[ -n ${TWINSIM_APPWINDOW_DENSITY:-} ]] && extra+=(--env "TWINSIM_APPWINDOW_DENSITY=$TWINSIM_APPWINDOW_DENSITY")
[[ -n ${TWINSIM_SELFTEST_KEEP_FRIDA:-} ]] && extra+=(--env "TWINSIM_SELFTEST_KEEP_FRIDA=1")
[[ -n ${TWINSIM_SELFTEST_FRIDA_PYTHON:-} ]] && extra+=(--env "TWINSIM_SELFTEST_FRIDA_PYTHON=$TWINSIM_SELFTEST_FRIDA_PYTHON")
open -W -n "$app" ${extra[@]+"${extra[@]}"} \
    --env "TWINSIM_HOME=$dir/home" \
    --env "TWINSIM_SELF_TEST=$dir/report" \
    --env "TWINSIM_SELF_TEST_SAMPLES=$samples" \
    --env "TWINSIM_SELF_TEST_PLATFORMS=${TWINSIM_SELF_TEST_PLATFORMS:-android,ios,ipa,device}" \
    --env "TWINSIM_SELF_TEST_DEVICE_ENGINES=${TWINSIM_SELF_TEST_DEVICE_ENGINES:-android-emulator,ios-simulator}"
grep -E 'PASS|FAIL|finished' "$dir/report/selftest.log" || true
! grep -q '\*\*失败\*\*' "$dir/report/report.md"
