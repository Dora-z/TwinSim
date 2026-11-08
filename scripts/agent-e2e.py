#!/usr/bin/env python3
"""Live test of the AI integration: speaks MCP (JSON-RPC over stdio) to `twinsim mcp` like an AI
client would, then exercises the CLI. TwinSim.app is NOT started beforehand: the first tool call
must launch it in the background. Uses an isolated TWINSIM_HOME.

  python3 scripts/agent-e2e.py [--app dist/TwinSim.app] [--samples .build/test-samples] [--out .build/agent-e2e]
"""
import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--app", default="dist/TwinSim.app")
parser.add_argument("--samples", default=".build/test-samples")
parser.add_argument("--out", default=".build/agent-e2e")
args = parser.parse_args()

app = Path(args.app).resolve()
cli = app / "Contents/Helpers/twinsim"
samples = Path(args.samples).resolve()
out = Path(args.out).resolve()
shutil.rmtree(out, ignore_errors=True)
(out / "home").mkdir(parents=True)
env = dict(os.environ, TWINSIM_HOME=str(out / "home"), TWINSIM_APP=str(app), TWINSIM_MAX_EDGE="640")
env.pop("ANDROID_HOME", None)
env.pop("DEVELOPER_DIR", None)
started = time.time()
results = []
log_lines = []


def log(text):
    line = f"[{time.time() - started:6.1f}s] {text}"
    print(line, flush=True)
    log_lines.append(line)


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    log(f"{'PASS' if ok else 'FAIL'} {name}" + (f" — {detail}" if detail else ""))
    return ok


class MCP:
    def __init__(self):
        self.proc = subprocess.Popen([str(cli), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=open(out / "mcp-stderr.log", "w"), env=env, text=True, bufsize=1)
        self.next_id = 1

    def request(self, method, params=None):
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            msg["params"] = params
        self.next_id += 1
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("MCP server closed stdout")
        reply = json.loads(line)
        assert reply.get("id") == msg["id"], reply
        return reply

    def notify(self, method):
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
        self.proc.stdin.flush()

    def call(self, name, **arguments):
        t = time.time()
        reply = self.request("tools/call", {"name": name, "arguments": arguments})
        result = reply.get("result", {})
        texts = "\n".join(c["text"] for c in result.get("content", []) if c["type"] == "text")
        images = [c for c in result.get("content", []) if c["type"] == "image"]
        return result.get("isError", False), texts, images, time.time() - t


def save_image(image, name):
    ext = "png" if image["mimeType"] == "image/png" else "jpg"
    path = out / f"{name}.{ext}"
    path.write_bytes(base64.b64decode(image["data"]))
    return path


def image_size(path):
    info = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)], capture_output=True, text=True).stdout
    w = int(re.search(r"pixelWidth: (\d+)", info).group(1))
    h = int(re.search(r"pixelHeight: (\d+)", info).group(1))
    return w, h


def touches(mcp, device):
    _, text, _, _ = mcp.call("shell", device=device, command="logcat -d -s TwinSimTouch:I")
    return [(int(x), int(y)) for x, y in re.findall(r"x=(\d+) y=(\d+)", text)]


mcp = MCP()
android = ios = None
try:
    init = mcp.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "agent-e2e", "version": "1"}})["result"]
    mcp.notify("notifications/initialized")
    check("MCP initialize", init["serverInfo"]["name"] == "twinsim" and "tools" in init["capabilities"],
          f"protocol {init['protocolVersion']}, instructions {len(init.get('instructions', ''))} chars")
    tools = mcp.request("tools/list")["result"]["tools"]
    check("tools/list", len(tools) >= 25, f"{len(tools)} tools")

    err, text, _, dt = mcp.call("status")
    status = json.loads(text) if not err else {}
    check("status (auto-launches TwinSim.app)", not err and "components" in status, f"{dt:.1f}s")
    log("components: " + ", ".join(f"{c['id']}={c['status']}" for c in status.get("components", [])))

    err, text, _, dt = mcp.call("install_component", componentId="android-display")
    check("install_component android-display", not err, text.splitlines()[0] if text else "")

    err, text, _, dt = mcp.call("open_app", path=str(samples / "TouchProbe.apk"))
    opened = json.loads(text) if not err else {}
    android = opened.get("id")
    check("open_app APK", not err and opened.get("state") == "ready", f"{dt:.1f}s profile {opened.get('profile')} {text[:200] if err else ''}")

    if android:
        err, text, images, _ = mcp.call("screenshot", device=android)
        path = save_image(images[0], "android-screenshot") if images else None
        size = image_size(path) if path else None
        check("screenshot returns scaled image", not err and size and max(size) == 640, f"{size} {text}")

        err, text, _, _ = mcp.call("tap", device=android, x=180, y=320)   # image space, scale 0.5 → guest (360,640)
        time.sleep(1)
        seen = touches(mcp, android)
        check("tap maps image → guest pixels", not err and seen and seen[-1] == (360, 640), f"{text} guest saw {seen[-1:]}")

        err, text, _, _ = mcp.call("ui_tree", device=android)
        check("ui_tree", not err and "TouchProbe" in text, text.splitlines()[0] if text else "")
        (out / "android-ui-tree.txt").write_text(text)

        err, text, _, _ = mcp.call("logs", device=android, filter="TwinSimTouch", lines=500)
        check("logs with filter", not err and "TAP" in text, f"{len(text.splitlines())} lines")

        err, text, _, _ = mcp.call("verify_root", device=android)
        check("verify_root", not err and "UID 0" in text, text)

        err, text, _, _ = mcp.call("shell", device=android, command="id -u && getprop ro.build.version.release")
        check("shell", not err and "exit 0" in text, " ".join(text.split()))

        # Navigate system UI by elements: Settings → search → type → wait.
        mcp.call("shell", device=android, command="am start -W -a android.settings.SETTINGS >/dev/null")
        err, text, _, _ = mcp.call("wait_for_text", device=android, text="Network", timeoutSeconds=20)
        check("wait_for_text (Settings opened)", not err, text[:160])
        (out / "settings-ui-tree.txt").write_text(mcp.call("ui_tree", device=android)[1])
        err, text, _, _ = mcp.call("tap_element", device=android, text="Display")
        check("tap_element 'Display' (scrolls to find)", not err, text.splitlines()[0] if text else "")
        err, text, _, _ = mcp.call("wait_for_text", device=android, text="Dark theme", timeoutSeconds=20)
        check("element tap navigated (Dark theme visible)", not err, text[:160])
        err, _, _, _ = mcp.call("press_key", device=android, key="back")
        check("press_key back", not err)
        err, text, _, _ = mcp.call("tap_element", device=android, contentDesc="Search settings")
        if err:
            err, text, _, _ = mcp.call("tap_element", device=android, text="Search settings")
        check("tap_element search field", not err, text.splitlines()[0] if text else "")
        time.sleep(1.5)
        err, text, _, _ = mcp.call("type_text", device=android, text="dark theme")
        err2, text2, _, _ = mcp.call("wait_for_text", device=android, text="Dark theme", timeoutSeconds=15)
        check("type_text into search", not err and not err2, text2[:160])
        err, text, images, _ = mcp.call("screenshot", device=android)
        if images:
            save_image(images[0], "android-settings-search")
        err, text, _, _ = mcp.call("swipe", device=android, x1=320, y1=500, x2=320, y2=200)
        check("swipe", not err, text)

        err, text, _, _ = mcp.call("port_forward", device=android, guestPort=27042)
        port = re.search(r"127\.0\.0\.1:(\d+)", text)
        check("port_forward", not err and port, text)
        if port:
            err, _, _, _ = mcp.call("remove_port_forward", device=android, localPort=int(port.group(1)))
            check("remove_port_forward", not err)

        err, text, _, dt = mcp.call("open_app", app="org.twinsim.touchprobe")
        check("open_app again reuses device", not err and json.loads(text)["id"] == android, f"{dt:.1f}s")

    # CLI (one-shot process, guest-pixel coordinates).
    cli_env = {k: v for k, v in env.items() if k != "TWINSIM_MAX_EDGE"}   # CLI default: full resolution
    run = lambda *a: subprocess.run([str(cli), *a], capture_output=True, text=True, env=cli_env, timeout=600)
    if android:
        r = run("screenshot", "--device", android[:8], "--output", str(out / "cli-screenshot.png"))
        check("CLI screenshot (device id prefix)", r.returncode == 0 and (out / "cli-screenshot.png").exists()
              and image_size(out / "cli-screenshot.png") == (720, 1280), r.stdout.strip().splitlines()[-1] if r.stdout else r.stderr)
        r = run("call", "list_devices", "{}")
        check("CLI call list_devices", r.returncode == 0 and android in r.stdout)
    for fmt in ["openai", "anthropic", "gemini", "mcp"]:
        r = run("tools", "--format", fmt)
        try:
            data = json.loads(r.stdout)
            count = len(data["function_declarations"]) if fmt == "gemini" else len(data)
        except Exception:
            count = 0
        check(f"CLI tools --format {fmt}", r.returncode == 0 and count >= 25, f"{count} tools")
    r = run("tap", "--device", "no-such-device", "--x", "1", "--y", "1")
    check("CLI error exit + hint", r.returncode == 1 and "DEVICE_NOT_FOUND" in r.stdout, r.stdout.strip().splitlines()[0])

    # iOS Simulator.
    err, text, _, dt = mcp.call("open_app", path=str(samples / "TouchProbe.app"))
    ios = json.loads(text)["id"] if not err else None
    check("open_app Simulator .app", not err, f"{dt:.1f}s {text[:200] if err else ''}")
    if ios:
        err, text, images, _ = mcp.call("screenshot", device=ios)
        size = image_size(save_image(images[0], "ios-screenshot")) if images else None
        check("iOS screenshot", not err and size and max(size) == 640, f"{size}")
        err, text, _, _ = mcp.call("tap", device=ios, x=10, y=10)
        check("iOS tap reports unsupported", err and "CAPABILITY_UNSUPPORTED" in text, text.splitlines()[0])

    # Device IPA on a host without Research Guests.
    err, text, _, _ = mcp.call("open_app", path=str(samples / "TouchProbeDevice.ipa"))
    check("IPA blocked with reason", err and "RESEARCH_GUESTS_DISABLED" in text, text.splitlines()[0])

    # License consent is never auto-accepted.
    err, text, _, _ = mcp.call("install_component", componentId="android-runtime")
    check("license consent requires user", not err and "requires accepting" in text, text.splitlines()[0][:160])

    err, _, _, _ = mcp.call("show_device", device=android or ios)
    check("show_device", not err)
    # Permanent deletion through MCP (iOS workspace; recreated on the next open_app).
    if ios:
        err, text, _, _ = mcp.call("delete_device", device=ios)
        listed = mcp.call("list_devices")[1]
        check("delete_device removes the device", not err and ios not in listed, text)
        ios = None
finally:
    for device in [android, ios]:
        if device:
            err, text, _, dt = mcp.call("stop_device", device=device)
            check(f"stop_device {device[:8]}", not err and '"state" : "stopped"' in text, f"{dt:.1f}s")
    mcp.proc.stdin.close()
    mcp.proc.wait(timeout=10)
    subprocess.run(["osascript", "-e", 'tell application id "com.twinsim.app" to quit'], capture_output=True)

passed = sum(1 for _, ok, _ in results if ok)
report = [f"# TwinSim AI 集成联调", "", f"- 结果: {passed}/{len(results)} 通过", "", "| 检查 | 结果 | 说明 |", "| --- | --- | --- |"]
report += [f"| {n} | {'通过' if ok else '**失败**'} | {d.replace('|', '/')} |" for n, ok, d in results]
report += ["", "```", *log_lines, "```"]
(out / "report.md").write_text("\n".join(report))
log(f"{passed}/{len(results)} passed")
sys.exit(0 if passed == len(results) else 1)
