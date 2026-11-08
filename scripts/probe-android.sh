#!/bin/bash
set -euo pipefail

sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
sdk=$(cd "$sdk" && pwd -P)
emulator=$sdk/emulator/emulator
adb=$sdk/platform-tools/adb
avdmanager=$sdk/cmdline-tools/latest/bin/avdmanager
build_tools=$sdk/build-tools/35.0.0
android_jar=$sdk/platforms/android-35/android.jar
image=${TWINSIM_ANDROID_IMAGE:-system-images;android-34;google_apis;arm64-v8a}
java_home=${JAVA_HOME:-$(/usr/libexec/java_home)}
export JAVA_HOME=$java_home
export ANDROID_HOME=$sdk ANDROID_SDK_ROOT=$sdk

image_path=$(printf '%s' "$image" | tr ';' '/')
if [[ ! -f "$sdk/$image_path/source.properties" ]]; then
    printf 'Install this Android SDK package first: %s\n' "$image" >&2
    exit 1
fi
for tool in "$emulator" "$adb" "$avdmanager" "$build_tools"/{aapt2,d8,zipalign,apksigner} "$java_home"/bin/{javac,keytool}; do
    if [[ ! -x "$tool" ]]; then
        printf 'Required tool missing: %s\n' "$tool" >&2
        exit 1
    fi
done
[[ -f "$android_jar" ]] || { echo 'Install Android SDK Platform 35 first.' >&2; exit 1; }
"$emulator" -accel-check

scratch=$(mktemp -d "${TMPDIR:-/tmp}/twinsim-android.XXXXXX")
cleanup() {
    status=$?
    if [[ -n ${emulator_pid:-} ]]; then
        kill "$emulator_pid" 2>/dev/null || true
        wait "$emulator_pid" || true
    fi
    if [[ -n ${adb_pid:-} ]]; then
        kill "$adb_pid" 2>/dev/null || true
        wait "$adb_pid" || true
    fi
    if [[ $status -ne 0 ]]; then
        for log in "$scratch"/{emulator,adb}.log; do
            if [[ -f "$log" ]]; then
                printf '\n--- %s ---\n' "${log##*/}" >&2
                grep -v -E 'adb\.pubkey|adb public key' "$log" | tail -n 24 >&2 || true
            fi
        done
    fi
    rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export HOME=$scratch/home ANDROID_USER_HOME=$scratch/android
export ANDROID_AVD_HOME=$scratch/avd ANDROID_EMULATOR_HOME=$scratch/emulator
# This probe only uses local emulator transports. Skip mDNS, including the M6 crash in ADB 37.0.1.
export ADB_MDNS=0
unset ADB_SERVER_SOCKET ANDROID_ADB_SERVER_ADDRESS ADB_VENDOR_KEYS
mkdir -p "$HOME" "$ANDROID_USER_HOME" "$ANDROID_AVD_HOME" "$ANDROID_EMULATOR_HOME"
cd "$scratch"

cat > AndroidManifest.xml <<'XML'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="org.twinsim.probe">
    <uses-sdk android:minSdkVersion="24" android:targetSdkVersion="34" />
    <application android:label="TwinSim Probe" android:debuggable="true">
        <activity android:name=".ProbeActivity" android:exported="true" />
    </application>
</manifest>
XML
cat > ProbeActivity.java <<'JAVA'
package org.twinsim.probe;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;

public class ProbeActivity extends Activity {
    @Override
    public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView message = new TextView(this);
        message.setText("TwinSim Probe");
        setContentView(message);
        Log.i("TwinSimProbe", "ACTIVITY_READY");
    }
}
JAVA
mkdir classes dex
"$java_home/bin/javac" --release 8 -Xlint:-options -classpath "$android_jar" -d classes ProbeActivity.java
"$build_tools/d8" --min-api 24 --lib "$android_jar" --output dex classes/org/twinsim/probe/ProbeActivity.class
"$build_tools/aapt2" link --manifest AndroidManifest.xml -I "$android_jar" -o unsigned.apk
(cd dex && zip -q ../unsigned.apk classes.dex)
"$build_tools/zipalign" -f 4 unsigned.apk aligned.apk
"$java_home/bin/keytool" -genkeypair -keystore probe.jks -storepass twinsim -keypass twinsim \
    -alias probe -keyalg RSA -keysize 2048 -validity 7 -dname CN=TwinSim -noprompt
"$build_tools/apksigner" sign --ks probe.jks --ks-pass pass:twinsim --out probe.apk aligned.apk
"$build_tools/apksigner" verify probe.apk

avd=TwinSim_${scratch##*.}
printf 'no\n' | "$avdmanager" create avd -n "$avd" -k "$image" -d pixel_6
ports=$(python3 - <<'PY'
import socket

for port in range(5584, 5553, -2):
    with socket.socket() as console, socket.socket() as transport, socket.socket() as server:
        try:
            console.bind(("127.0.0.1", port))
            transport.bind(("127.0.0.1", port + 1))
            server.bind(("127.0.0.1", 0))
        except OSError:
            continue
        print(port, server.getsockname()[1])
        break
else:
    raise SystemExit("No free emulator port pair")
PY
)
read -r console_port adb_port <<< "$ports"
export ANDROID_ADB_SERVER_PORT=$adb_port
serial=emulator-$console_port
guest() { "$adb" -H 127.0.0.1 -P "$adb_port" -s "$serial" "$@"; }
retry() {
    local deadline=$((SECONDS + 180))
    until "$@"; do
        kill -0 "$adb_pid" "$emulator_pid" 2>/dev/null || return 1
        if (( SECONDS >= deadline )); then
            printf 'Timed out waiting for %s\n' "$1" >&2
            return 1
        fi
        sleep 1
    done
}
matches() {
    local expected=$1
    shift
    [[ $(guest "$@" 2>/dev/null | tr -d '\r') == "$expected" ]]
}
owns_device() {
    [[ $(guest emu avd name 2>/dev/null | tr -d '\r' | sed -n '1p') == "$avd" ]]
}
rebooted() {
    local boot_id
    boot_id=$(guest shell cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r') || return 1
    [[ -n "$boot_id" && "$boot_id" != "$old_boot_id" ]] && matches 1 shell getprop sys.boot_completed
}

"$adb" -P "$adb_port" nodaemon server > adb.log 2>&1 &
adb_pid=$!
for ((attempt = 0; attempt < 50; attempt++)); do
    kill -0 "$adb_pid" 2>/dev/null || exit 1
    if "$adb" -H 127.0.0.1 -P "$adb_port" server-status >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
(( attempt < 50 )) || { echo 'Private ADB server did not become ready.' >&2; exit 1; }

started=$SECONDS
"$emulator" -avd "$avd" -port "$console_port" -accel on -gpu host -memory 2048 \
    -no-window -no-audio -no-boot-anim -no-snapshot -no-metrics -writable-system > emulator.log 2>&1 &
emulator_pid=$!
retry owns_device
retry matches 1 shell getprop sys.boot_completed
printf 'Boot ready in %ss\n' "$((SECONDS - started))"
printf 'Guest build: '
guest shell getprop ro.build.type
matches arm64-v8a shell getprop ro.product.cpu.abi
matches 2000 shell id -u
guest root
retry matches 0 shell id -u
printf 'Guest UID after adb root: '
guest shell id -u

guest install probe.apk
guest shell am start -W -n org.twinsim.probe/.ProbeActivity
guest logcat -d -s TwinSimProbe:I > app.log
grep -m 1 ACTIVITY_READY app.log
guest exec-out screencap -p > screen.png
file screen.png | grep 'PNG image data'
guest shell am force-stop org.twinsim.probe
guest uninstall org.twinsim.probe

old_boot_id=$(guest shell cat /proc/sys/kernel/random/boot_id | tr -d '\r')
[[ -n "$old_boot_id" ]]
guest disable-verity
guest reboot
retry rebooted
guest root
retry matches 0 shell id -u
guest remount
guest shell 'set -e; marker=$(mktemp /system/.twinsim-probe.XXXXXX); rm "$marker"'
printf 'System write verified. SELinux: '
guest shell getenforce
grep -m 1 'Graphics API Version' emulator.log || true

guest emu kill
wait "$emulator_pid"
unset emulator_pid
echo 'Android probe passed.'
