---
name: twinsim
description: Run and test Android apps (APK) and iOS Simulator apps (.app) on this Mac through TwinSim — open an app in an emulator/simulator, take screenshots, read the UI tree, tap/type/swipe, read logs, run guest shell commands (root on research profiles), start the built-in frida-server. Use when the user asks to run, try, test, inspect or debug a mobile app or emulator here.
---

# TwinSim

TwinSim is a macOS app that manages Android emulators and iOS Simulators. Drive it with the `twinsim` command (it talks to the running TwinSim.app and starts it in the background if needed). If `twinsim` is not on PATH, use `/Applications/TwinSim.app/Contents/Helpers/twinsim`.

If the TwinSim MCP server is connected (tools named `mcp__twinsim__*`), prefer those tools; they are the same operations.

## Workflow

1. `twinsim status` — components, devices, imported apps.
2. Open the app (imports the file if needed; reuses a background device and existing install):
   `twinsim open_app --path /abs/path/app.apk` → JSON with the device `id`.
3. Look: `twinsim screenshot --device <id> --output /tmp/s.png`, then read the PNG.
   Android: `twinsim ui_tree --device <id>` lists elements with `center=(x,y)`.
4. Act (Android):
   - `twinsim tap_element --device <id> --text "Sign in"` (or `--resourceId login`, `--contentDesc …`)
   - `twinsim tap --device <id> --x 540 --y 1200` (CLI coordinates are guest pixels = full-resolution screenshot pixels)
   - `twinsim type_text --device <id> --text "hello"`; `twinsim press_key --device <id> --key enter|back|home`
   - `twinsim swipe --device <id> --x1 540 --y1 1800 --x2 540 --y2 600` (scroll down)
   - `twinsim wait_for_text --device <id> --text "Welcome"`
5. Verify with another screenshot / ui_tree. Debug with `twinsim logs --device <id> --filter MyTag --lines 300` and `twinsim shell --device <id> --command "dumpsys activity top | head -40"`.
6. `twinsim stop_device --device <id>` when finished (the user may want it left running — ask if unsure).

`twinsim call <tool> '<json>'` runs any tool with JSON arguments; `twinsim tools` lists all of them.

## Facts and limits

- Android: touch, keys, text, swipe, UI tree, shell, logcat, file push/pull, port forwarding. Profiles `android-research` and `android-google-apis` have adb root (`verify_root`), `set_writable_system`, snapshots, and `frida_server` (built-in frida-server 17.x; returns `127.0.0.1:<port>` for `frida -H` — the host client must be Frida 17).
- iOS Simulator (`.app` built for the simulator): screenshots and logs only — no input. iOS logs can take up to a minute; retry on `OUTPUT_LIMIT`.
- Device `.ipa` files need the iOS research VM (vphone). If the result says `RESEARCH_GUESTS_DISABLED` or another vphone setup code, tell the user — the host needs manual setup; do not retry.
- First boot of a device takes 30–60 s; `open_app` waits. If a result says an operation is still running, run `twinsim wait_operation --operationId <id>`.
- Never pass `--acceptLicenses true` to `install_component` without the user's explicit agreement to the license text it shows.
- Exit status 1 means the tool reported an error; read the message and the `Hint:` line.
