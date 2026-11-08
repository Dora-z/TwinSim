#!/bin/bash
# Builds the samples used for frontend integration testing:
#   TouchProbe.apk        Android launcher app that draws and logs every touch (tag TwinSimTouch)
#   TouchProbe.app        ARM64 iOS Simulator app (SwiftUI)
#   TouchProbeDevice.ipa  ARM64 iOS device IPA (for the host-blocker check)
# Usage: ANDROID_HOME=... DEVELOPER_DIR=... bash scripts/make-test-samples.sh <output-dir>
set -euo pipefail

out=$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)
sdk=${ANDROID_HOME:?Set ANDROID_HOME}
build_tools=$sdk/build-tools/${TWINSIM_BUILD_TOOLS:-35.0.0}
android_jar=$(ls -d "$sdk"/platforms/android-*/android.jar | sort -V | head -1)
java_home=${JAVA_HOME:-}
if [[ -z $java_home ]]; then
    for candidate in "/Volumes/External/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
                     "/Applications/Android Studio.app/Contents/jbr/Contents/Home"; do
        [[ -x $candidate/bin/javac ]] && java_home=$candidate && break
    done
fi
[[ -x $java_home/bin/javac ]] || { echo "Set JAVA_HOME to a JDK 17+" >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/twinsim-samples.XXXXXX")
trap 'rm -rf "$work"' EXIT

# --- Android -----------------------------------------------------------------------------
mkdir -p "$work/apk/src/org/twinsim/touchprobe" "$work/apk/classes" "$work/apk/dex"
cd "$work/apk"
cat > AndroidManifest.xml <<'XML'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="org.twinsim.touchprobe"
          android:versionCode="1" android:versionName="1.0">
    <uses-sdk android:minSdkVersion="24" android:targetSdkVersion="34" />
    <application android:label="TouchProbe">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
XML
cat > src/org/twinsim/touchprobe/MainActivity.java <<'JAVA'
package org.twinsim.touchprobe;

import android.app.Activity;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.os.Bundle;
import android.util.Log;
import android.view.MotionEvent;
import android.view.View;
import java.util.ArrayList;

public class MainActivity extends Activity {
    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        setContentView(new Probe(this));
        Log.i("TwinSimTouch", "READY");
    }

    static class Probe extends View {
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final ArrayList<float[]> taps = new ArrayList<>();
        int count;
        Probe(Context c) { super(c); }

        @Override public boolean onTouchEvent(MotionEvent e) {
            if (e.getAction() == MotionEvent.ACTION_UP) {
                int[] loc = new int[2];
                getLocationOnScreen(loc);
                float x = e.getRawX(), y = e.getRawY();
                taps.add(new float[] { e.getX(), e.getY() });
                if (taps.size() > 12) taps.remove(0);
                count++;
                Log.i("TwinSimTouch", "TAP " + count + " x=" + Math.round(x) + " y=" + Math.round(y));
                invalidate();
            }
            return true;
        }

        @Override protected void onDraw(Canvas canvas) {
            int w = getWidth(), h = getHeight();
            canvas.drawColor(Color.rgb(18, 24, 38));
            paint.setColor(Color.rgb(60, 72, 96));
            paint.setStrokeWidth(2);
            for (int i = 1; i < 10; i++) {
                canvas.drawLine(w * i / 10f, 0, w * i / 10f, h, paint);
                canvas.drawLine(0, h * i / 10f, w, h * i / 10f, paint);
            }
            paint.setColor(Color.WHITE);
            paint.setTextSize(56);
            canvas.drawText("TwinSim TouchProbe", 40, 120, paint);
            paint.setTextSize(40);
            canvas.drawText("taps: " + count, 40, 190, paint);
            for (int i = 0; i < taps.size(); i++) {
                float[] t = taps.get(i);
                paint.setColor(i == taps.size() - 1 ? Color.rgb(255, 196, 0) : Color.rgb(90, 200, 250));
                canvas.drawCircle(t[0], t[1], 28, paint);
            }
        }
    }
}
JAVA
"$java_home/bin/javac" --release 8 -Xlint:-options -classpath "$android_jar" -d classes src/org/twinsim/touchprobe/MainActivity.java
"$build_tools/d8" --min-api 24 --lib "$android_jar" --output dex $(find classes -name '*.class')
"$build_tools/aapt2" link --manifest AndroidManifest.xml -I "$android_jar" -o unsigned.apk
(cd dex && zip -q ../unsigned.apk classes.dex)
"$build_tools/zipalign" -f 4 unsigned.apk aligned.apk
"$java_home/bin/keytool" -genkeypair -keystore probe.jks -storepass twinsim -keypass twinsim -alias probe \
    -keyalg RSA -keysize 2048 -validity 3650 -dname "CN=TwinSim Test" >/dev/null 2>&1
JAVA_HOME=$java_home "$build_tools/apksigner" sign --ks probe.jks --ks-pass pass:twinsim --out "$out/TouchProbe.apk" aligned.apk
JAVA_HOME=$java_home "$build_tools/apksigner" verify "$out/TouchProbe.apk"

# --- iOS ---------------------------------------------------------------------------------
mkdir -p "$work/ios"
cd "$work/ios"
cat > main.swift <<'SWIFT'
import SwiftUI

@main
struct TouchProbeApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("TwinSim TouchProbe").font(.largeTitle.bold())
                Text("iOS Simulator sample").foregroundStyle(.secondary)
                Image(systemName: "hand.tap.fill").font(.system(size: 72)).foregroundStyle(.tint)
            }
            .onAppear { print("TwinSimTouch READY") }
        }
    }
}
SWIFT
plist() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.twinsim.touchprobe</string>
<key>CFBundleExecutable</key><string>TouchProbe</string>
<key>CFBundleName</key><string>TouchProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>$1</string></array>
<key>MinimumOSVersion</key><string>18.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
PLIST
}
mkdir -p TouchProbe.app device/Payload/TouchProbe.app
xcrun --sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios18.0-simulator -O main.swift -o TouchProbe.app/TouchProbe
plist iPhoneSimulator > TouchProbe.app/Info.plist
codesign --force --sign - TouchProbe.app
rm -rf "$out/TouchProbe.app" && cp -R TouchProbe.app "$out/TouchProbe.app"
xcrun --sdk iphoneos swiftc -parse-as-library -target arm64-apple-ios18.0 -O main.swift -o device/Payload/TouchProbe.app/TouchProbe
plist iPhoneOS > device/Payload/TouchProbe.app/Info.plist
(cd device && rm -f "$out/TouchProbeDevice.ipa" && zip -qr "$out/TouchProbeDevice.ipa" Payload)
for f in TouchProbe.app/TouchProbe device/Payload/TouchProbe.app/TouchProbe; do
    printf '%s: %s\n' "$f" "$(xcrun vtool -show-build "$f" | awk '/platform/ { print $2 }')"
done
ls -la "$out"
