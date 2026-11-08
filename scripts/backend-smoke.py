#!/usr/bin/env python3
"""Exercise the real backend with a caller-provided APK and Simulator app."""

import argparse
from contextlib import suppress
import json
from pathlib import Path
import threading
import time
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--handshake", type=Path, required=True)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--simulator-app", type=Path, required=True)
    parser.add_argument("--android-profile", default="android-google-apis")
    parser.add_argument("--screenshots", type=Path, required=True)
    parser.add_argument("--video", action="store_true")
    parser.add_argument("--writable-system", action="store_true")
    parser.add_argument("--frida-server", type=Path)
    args = parser.parse_args()
    handshake = next(json.loads(line) for line in args.handshake.read_text().splitlines()
                     if line.startswith("{") and '"token"' in line)
    headers = {"Authorization": "Bearer " + handshake["token"]}
    prefix = handshake["url"] + "/v1"
    args.screenshots.mkdir(parents=True, exist_ok=True)

    def request(path, payload=None, *, accept=200, extra=None):
        data = None if payload is None else json.dumps(payload).encode()
        request_headers = headers | (extra or {})
        if data is not None:
            request_headers["Content-Type"] = "application/json"
        try:
            response = urlopen(Request(prefix + path, data, request_headers), timeout=45)
        except HTTPError as error:
            response = error
        with response:
            body = response.read()
            assert response.status == accept, (path, response.status, body[:2000])
            if response.headers.get_content_type() == "application/json":
                return json.loads(body)
            return body

    def wait(accepted, timeout=360):
        stop = time.monotonic() + timeout
        while time.monotonic() < stop:
            state = request("/operations/" + accepted["operationId"])
            if state["state"] == "succeeded":
                return state["result"]
            assert state["state"] in {"queued", "running"}, state
            time.sleep(1)
        raise TimeoutError(accepted["operationId"])

    request("/health", extra={"Authorization": "Bearer invalid"}, accept=401)
    request("/health", extra={"Origin": "https://example.com"}, accept=403)
    request("/health")
    components = {item["id"]: item for item in request("/components")}
    print("Components:", {name: item["status"] for name, item in components.items()}, flush=True)
    android_component = "android-google-apis" if args.android_profile == "android-google-apis" else "android-runtime"
    for component in [android_component, "ios-simulator-runtime"]:
        wait(request(f"/components/{component}/install", {}, accept=202))
    if args.video:
        wait(request("/components/android-display/install", {}, accept=202))
    for app, profile, platform in [
        (args.apk, args.android_profile, "android"),
        (args.simulator_app, "ios-development", "ios"),
    ]:
        artifact = request("/artifacts/import", {"path": str(app.resolve())}, accept=201)
        assert request("/artifacts/import", {"path": str(app.resolve())}, accept=201)["id"] == artifact["id"]
        launch = "/artifacts/" + artifact["id"] + "/launch"
        request_body = {"profileId": profile}
        identity = {"Idempotency-Key": f"smoke-{time.time_ns()}-{platform}"}
        op = request(launch, request_body, accept=202, extra=identity)
        assert request(launch, request_body, accept=202, extra=identity) == op
        assert request(launch, {}, accept=409, extra=identity)["code"] == "IDEMPOTENCY_CONFLICT"
        device = op["instanceId"]
        path = "/instances/" + device
        try:
            result = wait(op)
            assert result["bundleId"] == artifact["bundleId"]
            assert request(path)["state"] == "ready"
            image = request(path + "/screenshot")
            assert image.startswith(b"\x89PNG\r\n\x1a\n"), image[:80]
            (args.screenshots / f"{platform}.png").write_bytes(image)
            assert request(path + "/logs?lines=50")["text"]
            if platform == "android" and args.video:
                with urlopen(Request(prefix + path + "/video", headers=headers), timeout=30) as stream:
                    assert stream.headers.get_content_type() == "video/h264"
                    assert stream.read(4) == b"\x00\x00\x00\x01"
            if platform == "android" and profile != "android-aosp":
                root = wait(request(path + "/actions/root", {}, accept=202))
                assert root["uid"] == "0"
                shell = wait(request(path + "/actions/shell", {"argv": ["id", "-u"]}, accept=202))
                if profile != "android-magisk":
                    assert shell["stdout"].strip() == "0"
            if platform == "android" and args.writable_system:
                writable = path + "/actions/writable-system"
                wait(request(writable, {"value": "on"}, accept=202))
                try:
                    shell = {"argv": ["sh", "-c", 'set -e; p=$(mktemp /system/.twinsim-smoke.XXXXXX); rm "$p"; echo writable']}
                    assert wait(request(path + "/actions/shell", shell, accept=202))["stdout"].strip() == "writable"
                    print("android: /system write verified", flush=True)
                finally:
                    wait(request(writable, {"value": "off"}, accept=202))
            reopened = wait(request(launch, request_body, accept=202))
            assert reopened["instanceId"] == device
            if platform == "android" and args.frida_server:
                def action(name, body):
                    return wait(request(path + "/actions/" + name, body, accept=202))

                verify_frida(
                    args.frida_server.resolve(),
                    artifact["bundleId"],
                    action,
                    lambda remote: request(path + "/guest-file?" + urlencode({"path": remote})),
                )
            wait(request(path + "/actions/uninstall", {"bundleId": artifact["bundleId"]}, accept=202))
            print(f"{platform}: import, open, screenshot, logs, reopen, uninstall passed", flush=True)
        finally:
            wait(request(path + "/actions/stop", {}, accept=202))
            assert request(path)["state"] == "stopped"


def verify_frida(server_file, bundle, action, pull):
    import frida

    server = "/data/local/tmp/twinsim-frida-smoke"
    log = server + ".log"
    marker = server + ".txt"
    port = pid = None
    try:
        action("guest-push", {"localPath": str(server_file), "remotePath": server})
        launch = f"chmod 700 {server}; {server} --listen=127.0.0.1:27042 >{log} 2>&1 </dev/null & echo $!"
        pid = int(action("shell", {"argv": ["sh", "-c", launch]})["stdout"].strip())
        port = int(action("forward", {"guestPort": 27042})["localPort"])
        app_pid = int(action("shell", {"argv": ["pidof", bundle]})["stdout"].split()[0])
        last_error = None
        for _ in range(20):
            try:
                device = frida.get_device_manager().add_remote_device(f"127.0.0.1:{port}")
                session = device.attach(app_pid)
                break
            except (frida.ServerNotRunningError, frida.TransportError, frida.ProcessNotFoundError) as error:
                last_error = error
                time.sleep(1)
        else:
            raise RuntimeError(f"Frida failed to attach: {last_error}; guest log: {pull(log)!r}")

        try:
            seen = threading.Event()
            messages = []

            def on_message(message, _):
                messages.append(message)
                seen.set()

            script = session.create_script("send(Process.arch)")
            script.on("message", on_message)
            script.load()
            assert seen.wait(10) and messages[0].get("payload") == "arm64", messages
        finally:
            session.detach()
        action("shell", {"argv": ["sh", "-c", f"printf verified > {marker}"]})
        assert pull(marker) == b"verified"
        print("android: guest file transfer, forwarding, and Frida attach passed", flush=True)
    finally:
        if port is not None:
            with suppress(Exception):
                action("unforward", {"localPort": port})
        if pid is not None:
            with suppress(Exception):
                action("shell", {"argv": ["kill", str(pid)]})
        with suppress(Exception):
            action("shell", {"argv": ["rm", "-f", server, log, marker]})


if __name__ == "__main__":
    main()
