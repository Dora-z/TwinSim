<!-- Paste into AGENTS.md / CLAUDE.md / .cursor/rules / .github/copilot-instructions.md of projects that build mobile apps. -->
## Running the app on emulators (TwinSim)

This Mac has TwinSim for running Android and iOS Simulator builds. Use the `twinsim` CLI
(or the `twinsim` MCP server if connected):

- `twinsim open_app --path <built .apk or simulator .app>` → returns a device id; reuses the device and installed data on later runs.
- `twinsim screenshot --device <id> --output /tmp/screen.png`, `twinsim ui_tree --device <id>` (Android).
- `twinsim tap_element --device <id> --text "<label>"`, `twinsim type_text`, `twinsim press_key --key back`, `twinsim swipe`.
- `twinsim logs --device <id> --filter <tag>`; `twinsim shell --device <id> --command "<cmd>"`.
- iOS Simulator: screenshots and logs only. Device IPAs need host setup (vphone) — report, don't retry.
- `twinsim tools` lists every command; `twinsim help` explains options.
