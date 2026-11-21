#!/usr/bin/env python3
"""Exercise production desktop bundles on a dedicated hosted macOS guest."""
import argparse
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import threading
import time
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


hosted = module("backend", "run-hosted-helper-tun-acceptance.py")
upgrade = module("replacement", "verified-local-upgrade.py")
APP, APP_ID = upgrade.INSTALLED, upgrade.APP_ID
PIN, CHOICE, SELECTOR = "Fixture-Pinned", "Fixture-Choice", "Fixture-Select"
PROFILE, SECRET = "local5-disposable", "fixture-control-secret"
API_PORT, PROXY_PORT, DNS_PORT = 19325, 17890, 17874


def run(*args, timeout=20, check=True):
    return subprocess.run([str(arg) for arg in args], check=check, timeout=timeout,
                          capture_output=True, text=True)


def sudo(*args, **kwargs):
    return run("/usr/bin/sudo", "-n", *args, **kwargs)


def wait(predicate, seconds, error):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        answer = predicate()
        if answer:
            return answer
        time.sleep(0.3)
    raise RuntimeError(error)


def version(app):
    return plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"]


def log_cursor():
    return {p: p.stat().st_size for p in (Path.home() / "Library/Logs/ClashFX").glob("*.log")}


def since(cursor):
    recent = []
    for file in log_cursor():
        with file.open("rb") as handle:
            handle.seek(min(cursor.get(file, 0), file.stat().st_size))
            recent.append(handle.read().decode(errors="replace"))
    return "\n".join(recent)


def api(path):
    client = http.client.HTTPConnection("127.0.0.1", API_PORT, timeout=2)
    try:
        client.request("GET", path, headers={"Authorization": "Bearer " + SECRET})
        answer = client.getresponse()
        assert answer.status == 200
        return json.loads(answer.read())
    finally:
        client.close()


def profile(expected_dns):
    # The TUN core hijacks both transports at each listed address, regardless of
    # the scheme. Exercise a real DNS handoff failure by moving the TUN DNS peer.
    fake_range = "198.18.0.1/16" if expected_dns else "198.19.0.1/16"
    hijack = "198.18.0.2:53" if expected_dns else "198.19.0.2:53"
    reject_unowned = "" if expected_dns else "  - IP-CIDR,198.18.0.2/32,REJECT,no-resolve"
    return f"""mixed-port: {PROXY_PORT}
allow-lan: false
bind-address: 127.0.0.1
external-controller: 127.0.0.1:{API_PORT}
secret: {SECRET}
mode: rule
log-level: info
profile:
  store-selected: true
tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: true
  dns-hijack: ["{hijack}"]
dns:
  enable: true
  listen: 127.0.0.1:{DNS_PORT}
  enhanced-mode: fake-ip
  fake-ip-range: {fake_range}
  nameserver: ["1.1.1.1", "8.8.8.8"]
proxies:
  - {{name: {PIN}, type: socks5, server: 127.0.0.1, port: 9}}
  - {{name: {CHOICE}, type: socks5, server: 127.0.0.1, port: 8}}
proxy-groups:
  - {{name: {SELECTOR}, type: select, proxies: [DIRECT, {CHOICE}]}}
rules:
{reject_unowned}
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - MATCH,DIRECT
"""


class NeutralHealth(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_):
        pass


class Guest:
    def __init__(self, directory, report):
        self.directory, self.report = directory, report
        self.home = Path.home() / ".config/clashfx"
        self.config = self.home / (PROFILE + ".yaml")
        self.disk = self.home / ".enhanced-recovery/confirmed-v2.json"
        self.cursor = {}
        self.inject = False
        self.observed_failure = False
        self.failed_launch_logs = ""
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), NeutralHealth)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def seed_selection(self):
        records = [{"group": SELECTOR, "selected": CHOICE, "config": PROFILE}]
        run("/usr/bin/defaults", "write", APP_ID, "SavedProxyModels", "-data",
            json.dumps(records).encode().hex())

    def seed(self):
        self.home.mkdir(parents=True)
        self.config.write_text(profile(True))
        settings = [
            ("selectConfigName", "string", PROFILE), ("selectOutBoundMode", "string", "rule"),
            ("proxyPort", "int", PROXY_PORT), ("enhancedMode", "bool", "true"),
            ("enhancedModeUseCustomConfig", "bool", "true"), ("claudeProxyLockEnabled", "bool", "true"),
            ("claudeProxyLockTarget", "string", PIN), ("proxyPortAutoSet", "bool", "true"),
            ("hideDockIcon", "bool", "true"), ("SUEnableAutomaticChecks", "bool", "false"),
        ]
        for key, kind, value in settings:
            run("/usr/bin/defaults", "write", APP_ID, key, "-" + kind, value)
        self.seed_selection()

    def install_bound_helper(self, app):
        signature = run("/usr/bin/codesign", "-dv", "--verbose=4", app).stderr
        cdhash = re.search(r"^CDHash=([a-f0-9]{40})$", signature, re.M)[1]
        core = app / "Contents/Resources/mihomo_core"
        helper = app / "Contents/Library/LaunchServices" / upgrade.HELPER
        generator = SimpleNamespace(
            probe_app=app, probe_executable=app / "Contents/MacOS/ClashFX", probe_core=core,
            approved_client_cdhashes={str(app): cdhash}, expected_embedded_helper_sha256=upgrade.digest(helper),
            install_generator_source=self.directory / "legacy.swift", install_generator=self.directory / "generator",
            install_fixture_path=self.directory / "input.json", production_install_script=self.directory / "production.sh",
            instrumented_install_script=self.directory / "unused.sh", metadata_stage_report=self.directory / "unused.json",
        )
        generator._production_install_constants = lambda: hosted.AcceptanceHarness._production_install_constants(generator)
        hosted.AcceptanceHarness._generate_production_install_script(generator)
        if not upgrade.HELPER_DIR.exists():
            sudo("/usr/bin/install", "-d", "-o", "root", "-g", "wheel", "-m", "755", upgrade.HELPER_DIR)
        result = sudo("/bin/bash", generator.production_install_script, timeout=110, check=False)
        if result.returncode:
            raise RuntimeError("production Helper installer failed\n" + result.stderr[-3000:])
        assert upgrade.pair_is_approved(app)

    def start(self, app):
        actual = version(app)
        print("Starting complete desktop bundle", actual, flush=True)
        self.config.write_text(profile(not (self.inject and actual == upgrade.NEW)))
        if actual == upgrade.OLD:
            self.seed_selection()
        self.install_bound_helper(app)
        self.cursor = log_cursor()
        run("/usr/bin/open", "-g", "-n", app)
        wait(lambda: upgrade.process_at(app / "Contents/MacOS/ClashFX"), 20, "App process never appeared")

    def stop(self, app):
        processes = upgrade.process_at(app / "Contents/MacOS/ClashFX")
        if processes:
            assert len(processes) == 1
            jxa = """ObjC.import("AppKit");
function run(argv) {
    const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(argv[0]));
    if (ObjC.unwrap(app.bundleURL.path) !== argv[1] || !app.terminate) throw Error("quit rejected");
}"""
            run("/usr/bin/osascript", "-l", "JavaScript", "-e", jxa, processes[0][0], app)
        upgrade.wait_stopped(app, 75)
        print("Full App and managed core exited", flush=True)

    def ready(self, app):
        actual = version(app)
        if self.inject and actual == upgrade.NEW:
            try:
                wait(lambda: "TUN DNS takeover did not answer on both transports" in since(self.cursor),
                     90, "real candidate did not reach injected TUN takeover failure")
            finally:
                self.failed_launch_logs = since(self.cursor)
            self.observed_failure = True
            self.report["injectedFailureObserved"] = "tun-dns-takeover"
            print("Actual candidate reported failed TUN DNS takeover", flush=True)
            upgrade.wait_ready(app, timeout=4)
            raise AssertionError("production readiness verifier accepted failed TUN")

        upgrade.wait_ready(app, timeout=140)
        assert api("/proxies")["proxies"][SELECTOR]["now"] == CHOICE
        assert any(rule.get("proxy") == PIN and "process" in rule.get("type", "").lower()
                   and "claude" in rule.get("payload", "").lower() for rule in api("/rules")["rules"])
        assert run("/usr/bin/defaults", "read", APP_ID, "claudeProxyLockTarget").stdout.strip() == PIN
        app_pid = upgrade.process_at(app / "Contents/MacOS/ClashFX")[0][0]
        core_pid = upgrade.process_at(upgrade.CORE)[0][0]
        route = run("/sbin/route", "-n", "get", upgrade.TUN_DNS).stdout
        utun = re.search(r"^\s*interface:\s*(utun\d+)\s*$", route, re.M)[1]
        answers = run("/usr/bin/dscacheutil", "-q", "host", "-a", "name",
                      f"local5-fixture-{core_pid}.example.com", timeout=10).stdout
        addresses = re.findall(r"ip_address:\s*(\d+\.\d+\.\d+\.\d+)", answers)
        assert any(ipaddress.ip_address(value) in hosted.FAKE_IP_NETWORK for value in addresses)
        client = http.client.HTTPConnection("127.0.0.1", PROXY_PORT, timeout=4)
        try:
            client.request("GET", f"http://127.0.0.1:{self.server.server_port}/check")
            assert client.getresponse().status == 204
        finally:
            client.close()
        result = {"version": actual, "appPID": app_pid, "corePID": core_pid, "utun": utun,
                  "authenticatedAPI": True, "udpAndTcpTUN": True, "systemFakeIP": True,
                  "localProxy204": True, "fixtureSelections": True, "fixtureLockRule": True}
        self.report["launches"].append(result)
        print(json.dumps(result, sort_keys=True), flush=True)
        return result

    def checkpoint(self):
        if not self.disk.is_file():
            return False
        saved = json.loads(self.disk.read_text())
        return (saved["version"] == 2 and saved["binding"]["profile"] == PROFILE and
                saved["binding"]["mode"] == "rule" and saved["binding"]["claudeLockTarget"] == PIN and
                saved["selections"].get(SELECTOR) == CHOICE)

    def cleanup(self, network):
        self.server.shutdown()
        try:
            if APP.exists():
                self.stop(APP)
        finally:
            sudo("/bin/launchctl", "bootout", f"system/{upgrade.HELPER}", check=False)
            for service, dns in network.items():
                sudo("/usr/sbin/networksetup", "-setdnsservers", service, *(dns or ["Empty"]), check=False)
                for key in ("webproxy", "securewebproxy", "socksfirewallproxy"):
                    sudo("/usr/sbin/networksetup", f"-set{key}state", service, "off", check=False)
            sudo("/usr/bin/chflags", "nouchg", upgrade.CORE, hosted.TRUST_RECEIPT_PATH, check=False)
            for path in (upgrade.CORE, hosted.TRUST_RECEIPT_PATH, hosted.INSTALLED_HELPER_PATH, hosted.LAUNCH_DAEMON_PATH):
                sudo("/bin/rm", "-f", path, check=False)
            if APP.exists():
                shutil.rmtree(APP)


def baseline_dns():
    assert not re.search(r"Enable\s*:\s*1\b", run("/usr/sbin/scutil", "--proxy").stdout)
    services = run("/usr/sbin/networksetup", "-listallnetworkservices").stdout.splitlines()[1:]
    return {service: [item for item in run("/usr/sbin/networksetup", "-getdnsservers", service).stdout.splitlines()
                      if item and "any DNS Servers" not in item]
            for service in services if service and not service.startswith("*")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("old", "candidate", "report"):
        parser.add_argument("--" + option, required=True, type=Path)
    args = parser.parse_args()
    failures, uid = hosted.hosted_runner_gate()
    if (failures != ["effective uid must be 0"] or uid <= 0 or Path.home() != Path("/Users/runner")
            or os.environ.get("GITHUB_REPOSITORY") != "khywjt/ClashFX"
            or os.environ.get("GITHUB_REF") != "refs/heads/codex/local5-full-handoff-20261121"):
        raise SystemExit(f"This fixture requires the dedicated hosted macOS guest: {failures}")
    sudo("/usr/bin/true")
    hosted.verify_clean_guest_before_mutation()
    assert not APP.exists() and not (Path.home() / ".config/clashfx").exists()
    upgrade.verify_bundle(args.old, upgrade.OLD)
    upgrade.verify_bundle(args.candidate, upgrade.NEW)
    network = baseline_dns()
    report = {"status": "failed", "sha": os.environ["GITHUB_SHA"], "launches": [],
              "consoleUser": run("/usr/bin/stat", "-f", "%Su", "/dev/console").stdout.strip()}
    try:
        with tempfile.TemporaryDirectory(prefix="local5-desktop-", dir=os.environ["RUNNER_TEMP"]) as temp:
            root = Path(temp)
            guest = Guest(root, report)
            staged, backup = root / "candidate.app", root / "previous.app"
            try:
                guest.seed()
                run("/usr/bin/ditto", args.old, APP, timeout=45)
                guest.start(APP)
                old = guest.ready(APP)
                guest.stop(APP)

                run("/usr/bin/ditto", args.candidate, staged, timeout=45)
                assert upgrade.replace_verified(APP, staged, backup, guest.start, guest.ready, guest.stop) == "accepted"
                new = report["launches"][-1]
                assert old["appPID"] != new["appPID"] and old["corePID"] != new["corePID"]
                report["fullHandoff"] = True
                wait(guest.checkpoint, 14, "candidate did not persist the verified disk checkpoint")

                guest.stop(APP)
                for name in ("cache.db", ".cache.db"):
                    (guest.home / name).unlink(missing_ok=True)
                run("/usr/bin/defaults", "delete", APP_ID, "SavedProxyModels", check=False)
                guest.start(APP)
                cold = guest.ready(APP)
                assert new["appPID"] != cold["appPID"] and new["corePID"] != cold["corePID"]
                assert "stage=readback verified launch=" in since(guest.cursor)
                report["coldRecoveryFromDisk"] = True

                guest.stop(APP)
                APP.rename(staged)
                backup.rename(APP)
                guest.start(APP)
                guest.ready(APP)
                guest.stop(APP)
                guest.inject = True
                try:
                    upgrade.replace_verified(APP, staged, backup, guest.start, guest.ready, guest.stop)
                except RuntimeError as error:
                    assert "previous version was restored and verified" in str(error), str(error)
                assert guest.observed_failure and version(APP) == upgrade.OLD
                assert report["launches"][-1]["version"] == upgrade.OLD
                report["failedTakeoverRolledBack"] = True
            except BaseException:
                for label, lines in [("Failed candidate", guest.failed_launch_logs),
                                     ("Latest launch", since(guest.cursor))]:
                    print(label, flush=True)
                    relevant = [line for line in lines.splitlines()
                                if re.search(r"(?i)helper|takeover|enhanced mode|verification|readback|runtime configuration|listener|error", line)]
                    print("\n".join(relevant[-40:]), flush=True)
                raise
            finally:
                guest.cleanup(network)
        assert not upgrade.process_at(upgrade.CORE)
        assert baseline_dns() == network
        report["guestNetworkRestored"] = True
        report["status"] = "passed"
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(json.dumps(report, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
