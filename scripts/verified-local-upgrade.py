#!/usr/bin/env python3
"""Offline local.4 → local.5 replacement with verified startup and rollback."""
import argparse
import fcntl
import hashlib
import http.client
import json
from pathlib import Path
import plistlib
import re
import secrets
import socket
import struct
import subprocess
import tempfile
import time


HELPER = "com.clashfx.app.Helper"
APP_ID = "com.clashfx.app"
OLD = "1.1.11.20-local.4"
NEW = "1.1.11.20-local.5"
TUN_DNS = "198.18.0.2"
INSTALLED = Path("/Applications/ClashFX.app")
HELPER_DIR = Path("/Library/PrivilegedHelperTools")
CORE = HELPER_DIR / (HELPER + ".mihomo_core")


def capture(arguments):
    return subprocess.run(arguments, check=True, capture_output=True, text=True, timeout=12).stdout


def digest(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def verify_bundle(app, version):
    if app.is_symlink() or not app.is_dir():
        raise RuntimeError("App bundle is missing or is a symbolic link")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != APP_ID or info.get("CFBundleShortVersionString") != version:
        raise RuntimeError(f"App identity does not match the expected {version}")
    capture(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    return digest(app / "Contents/MacOS/ClashFX")


def process_at(binary):
    output = capture(["/bin/ps", "-ww", "-axo", "pid=,uid=,args="])
    prefix = str(binary)
    matches = []
    for row in output.splitlines():
        fields = row.split(None, 2)
        if len(fields) == 3 and (fields[2] == prefix or fields[2].startswith(prefix + " ")):
            matches.append((int(fields[0]), int(fields[1]), fields[2][len(prefix):]))
    return matches


def dns_status(host, port, kind):
    request = struct.pack("!HHHHHH", secrets.randbits(16),
                          0x1000, 0, 0, 0, 0)
    with socket.socket(socket.AF_INET, kind) as client:
        client.settimeout(0.65)
        client.connect((host, port))
        if kind == socket.SOCK_DGRAM:
            client.send(request)
            reply = client.recv(2048)
        else:
            client.sendall(struct.pack("!H", len(request)) + request)
            with client.makefile("rb") as stream:
                size = struct.unpack("!H", stream.read(2))[0]
                reply = stream.read(size)
    return len(reply) >= 12 and reply[:2] == request[:2] and reply[2] & 0xF8 == 0x90


def startup_committed(launch_id):
    log_dir = Path.home() / "Library/Logs/ClashFX"
    files = sorted(log_dir.glob("*.log"), key=lambda path: path.stat().st_mtime, reverse=True)[:3]
    marker = f"Runtime listeners verified for launch {launch_id}:".encode()
    for file in files:
        with file.open("rb") as handle:
            handle.seek(max(0, file.stat().st_size - 256 * 1024))
            tail = handle.read()
        start = tail.rfind(marker)
        if start >= 0:
            following = tail[start + len(marker):].split(b"Runtime listeners verified for launch ", 1)[0]
            return b"Enhanced configuration checkpoint confirmed" in following
    return False


def pair_is_approved(app):
    bundled_helper = app / "Contents/Library/LaunchServices" / HELPER
    bundled_core = app / "Contents/Resources/mihomo_core"
    if digest(HELPER_DIR / HELPER) != digest(bundled_helper):
        return False
    core_digest = digest(bundled_core)
    if digest(CORE) != core_digest:
        return False
    display = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(app)], check=True,
                             capture_output=True, text=True, timeout=12).stderr
    cdhash = re.search(r"^CDHash=([0-9a-f]{40})$", display, re.M)
    receipt = plistlib.loads((HELPER_DIR / (HELPER + ".trust.plist")).read_bytes())
    return bool(cdhash and receipt.get("SchemaVersion") == 1 and any(
        item.get("BundleIdentifier") == APP_ID and item.get("ClientCDHash") == cdhash[1]
        and item.get("ApprovedSourcePath") == str(bundled_core.resolve())
        and item.get("CoreSHA256") == core_digest for item in receipt.get("ApprovedClients", [])
    ))


def runtime_ready(app):
    app_processes = process_at(app / "Contents/MacOS/ClashFX")
    core_processes = process_at(CORE)
    if len(app_processes) != 1 or len(core_processes) != 1 or core_processes[0][1] != 0:
        return False
    args = core_processes[0][2].strip()
    split = re.fullmatch(r"-f (.+) -d (.+)", args)
    if not split:
        return False
    config = Path(split[1])
    home = (Path.home() / ".config/clashfx").resolve()
    launch = re.fullmatch(r"\.enhanced_config\.([A-Fa-f0-9-]{36})\.yaml", config.name)
    if config.resolve().parent != home or Path(split[2]).resolve() != home or not launch:
        return False
    if not startup_committed(launch[1]) or not pair_is_approved(app):
        return False
    # Parse only scalar metadata. No Ruby objects are deserialized from YAML.
    ruby = """root = Psych.parse_file(ARGV.fetch(0)).root
pairs = root.children.each_slice(2).map { |k,v|
  [k.value, v.value] if k.is_a?(Psych::Nodes::Scalar) && v.is_a?(Psych::Nodes::Scalar) &&
    %w[external-controller secret mode].include?(k.value)
}
puts JSON.generate(pairs.compact.to_h)"""
    config_info = json.loads(capture(["/usr/bin/ruby", "-rpsych", "-rjson", "-e", ruby, str(config)]))
    port = int(config_info["external-controller"].rsplit(":", 1)[-1])
    headers = {"Authorization": "Bearer " + config_info["secret"]} if config_info.get("secret") else {}
    api = http.client.HTTPConnection("127.0.0.1", port, timeout=0.8)
    try:
        api.request("GET", "/configs", headers=headers)
        response = api.getresponse()
        if response.status != 200:
            return False
        body = json.loads(response.read(512 * 1024))
    finally:
        api.close()
    proxy_port = body.get("mixed-port") or body.get("port")
    tun = body.get("tun", {})
    if not proxy_port or tun.get("enable") is not True or body.get("mode") != config_info.get("mode"):
        return False
    with socket.create_connection(("127.0.0.1", proxy_port), timeout=0.65):
        pass
    route = capture(["/sbin/route", "-n", "get", TUN_DNS])
    routed = re.search(r"^\s*interface:\s*(utun\d+)\s*$", route, re.M)
    device = tun.get("device") or ""
    if not routed or (device.startswith("utun") and device != routed[1]):
        return False
    resolvers = capture(["/usr/sbin/scutil", "--dns"])
    return bool(re.search(r"nameserver\[\d+\]\s*:\s*198\.18\.0\.2\s*$", resolvers, re.M)
                and all(dns_status(TUN_DNS, 53, kind) for kind in (socket.SOCK_DGRAM, socket.SOCK_STREAM))
                and process_at(CORE) == core_processes
                and process_at(app / "Contents/MacOS/ClashFX") == app_processes)


def wait_ready(app, timeout=165):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if runtime_ready(app):
                return
        except (OSError, ValueError, KeyError, TypeError, struct.error, http.client.HTTPException,
                plistlib.InvalidFileException, subprocess.SubprocessError):
            pass
        time.sleep(0.75)
    raise RuntimeError("Timed out waiting for a committed App, Helper, listener and TUN DNS handoff")


def wait_stopped(app, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not process_at(app / "Contents/MacOS/ClashFX") and not process_at(CORE):
            return
        time.sleep(0.4)
    raise RuntimeError("App or external core exit was not confirmed")


def replace_verified(active, staged, backup, start, ready, stop):
    """Move an already-staged App into place. On failure restore and verify the old pair."""
    active.rename(backup)
    try:
        staged.rename(active)
    except (OSError, KeyboardInterrupt) as error:
        backup.rename(active)
        start(active)
        ready(active)
        raise RuntimeError("Could not place candidate; previous version was restored and verified") from error

    try:
        start(active)
        ready(active)
        return "accepted"
    except (Exception, KeyboardInterrupt) as error:
        try:
            # If a graceful stop cannot be verified, leave both bundles intact.
            stop(active)
            active.rename(staged)
            backup.rename(active)
            start(active)
            ready(active)
        except Exception as rollback_error:
            raise RuntimeError(f"Candidate handoff failed; rollback remains unverified: {rollback_error}") from error
        raise RuntimeError("Candidate handoff failed; previous version was restored and verified") from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["check", "install"])
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()
    base = Path(__file__).resolve().parents[2]
    backup = base / f"ClashFX-{OLD}-before-local.5.app"
    with (base / ".swap.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        old_digest = verify_bundle(INSTALLED, OLD)
        new_digest = verify_bundle(args.candidate, NEW)
        if backup.exists() or backup.is_symlink() or backup.parent.stat().st_dev != INSTALLED.parent.stat().st_dev:
            raise RuntimeError("Rollback path is occupied or belongs to another filesystem")
        if args.action == "check":
            print("Candidate and previous App signatures verified")
            return
        wait_ready(INSTALLED, timeout=8)
        with tempfile.TemporaryDirectory(prefix=".clashfx-upgrade-", dir=INSTALLED.parent) as directory:
            staged = Path(directory) / "ClashFX.app"
            capture(["/usr/bin/ditto", str(args.candidate), str(staged)])
            if verify_bundle(staged, NEW) != new_digest:
                raise RuntimeError("Staged candidate changed after preflight")

            def start(app):
                capture(["/usr/bin/open", "-g", str(app)])

            def stop_failed_candidate(app):
                # Use normal application quit so its Helper and DNS settlement can finish.
                processes = process_at(app / "Contents/MacOS/ClashFX")
                if len(processes) == 1:
                    pid = processes[0][0]
                    script = """ObjC.import('AppKit');
function run(argv) {
  const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(argv[0]));
  if (ObjC.unwrap(app.bundleURL.path) === argv[1]) app.terminate;
}"""
                    subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", script, str(pid), str(app)],
                                   capture_output=True, timeout=8, check=False)
                wait_stopped(app, timeout=60)

            print("准备完成。请从 ClashFX 菜单正常退出。启动后如出现配套 Helper 的授权提示，请在系统窗口处理。", flush=True)
            wait_stopped(INSTALLED, timeout=900)
            if verify_bundle(INSTALLED, OLD) != old_digest:
                raise RuntimeError("Previous App changed during shutdown")
            replace_verified(INSTALLED, staged, backup, start, wait_ready, stop_failed_candidate)
            print(f"{NEW} 已启动并通过接管验收。")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error)) from None
