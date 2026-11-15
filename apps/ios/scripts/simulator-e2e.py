#!/usr/bin/env python3
"""App-owned native journey; apptest supplies the checkout lock and simulator lease."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
RUN = Path(sys.argv[1]).resolve()
DERIVED = Path(sys.argv[2]).resolve()
journey = sys.argv[3] if len(sys.argv) > 3 else "messaging"
if journey not in {"messaging", "assistant", "routines", "replies", "agents", "persistence", "samples", "context", "receipt-recovery", "permissions", "quiet"}:
    raise SystemExit("Unknown native journey.")
test_class = {
    "messaging": "NativeMessagingJourney",
    "assistant": "NativeAssistantFeaturesJourney/testNativeAssistantFeatures",
    "routines": "NativeAssistantFeaturesJourney/testNativeRoutineReview",
    "replies": "NativeAssistantFeaturesJourney/testNativeReplies",
    "agents": "NativeAssistantFeaturesJourney/testNativeAgentManagement",
    "persistence": "NativePersistenceJourney",
    "samples": "NativeSampleJourney/testSampleReactionAndRestart",
    "context": "NativeSampleJourney/testContextPreviewAndEdgeNavigation",
    "receipt-recovery": "NativeReceiptRecoveryJourney",
    "permissions": "NativePermissionRecoveryJourney",
    "quiet": "NativeQuietInterfaceJourney",
}[journey]
RUN.mkdir(parents=True, exist_ok=True)
device = os.environ.get("SIMPOOL_LEASED_UDID")
if not device:
    raise SystemExit("Run this through apptest run native-ui to acquire a simulator lease.")
bun = os.environ.get("BUN_BINARY") or shutil.which("bun") or str(
    ROOT / ".openbot-build/native-ios/tooling/node_modules/.bin/bun"
)
fixture = RUN / "fixture"
result = RUN / "native-ui.xcresult"
bundle_id = None
with (RUN / "fixture.log").open("w") as log:
    service = subprocess.Popen(
        [bun, "apps/ios/scripts/simulator/entry.ts", str(fixture)], cwd=ROOT,
        stdout=log, stderr=subprocess.STDOUT,
    )
    try:
        deadline = time.monotonic() + 30
        ready = fixture / "ready.json"
        while not ready.exists():
            if service.poll() is not None:
                raise RuntimeError("Simulator host exited. Read fixture.log.")
            if time.monotonic() > deadline:
                raise RuntimeError("Simulator host did not become ready. Read fixture.log.")
            time.sleep(0.1)
        config = json.loads(ready.read_text())
        subprocess.run(["xcodegen", "generate", "--spec", "apps/ios/project.yml"], cwd=ROOT, check=True)
        bundle_id = "com.gerardomaruotti.openbot.native.simulator.run" + uuid.uuid4().hex
        xcode = [
            "xcodebuild", "-project", "apps/ios/OpenBotNative.xcodeproj",
            "-scheme", "OpenBotNativeSimulator", "-configuration", "Simulator",
            "-destination", "platform=iOS Simulator,id=" + device,
            "-derivedDataPath", str(DERIVED), "-jobs", "2",
            "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
            "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "1200" if journey != "messaging" else "600",
            "OPENBOT_NATIVE_SIMULATOR_BUNDLE_ID=" + bundle_id,
            "OPENBOT_NATIVE_ACCOUNT_URL=" + config["apiURL"],
            "OPENBOT_NATIVE_FIXTURE_URL=" + config["apiURL"],
        ]
        subprocess.run(xcode + ["build-for-testing"], cwd=ROOT, check=True)
        app_path = DERIVED / "Build/Products/Simulator-iphonesimulator/OpenBotNative.app"
        subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], cwd=ROOT, check=True)
        subprocess.run(["xcrun", "simctl", "install", device, str(app_path)], cwd=ROOT, check=True)
        container = subprocess.check_output(["xcrun", "simctl", "get_app_container", device, bundle_id, "data"],
                                            cwd=ROOT, text=True).strip()
        (fixture / "native-container.json").write_text(json.dumps({
            "bundleID": bundle_id, "deviceID": device, "container": container,
        }) + "\n")
        # Fresh UUID installs can lack a local notification client until the next
        # normal boot on this runtime. Use only our exclusively leased simulator;
        # keep its data and let iOS register the installed app through public lifecycle.
        subprocess.run(["xcrun", "simctl", "shutdown", device], cwd=ROOT, check=True)
        subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], cwd=ROOT, check=True)
        (RUN / "simulator-preparation.json").write_text(json.dumps({
            "deviceID": device, "bundleID": bundle_id, "stagedApp": str(app_path),
            "normalRestartAfterInstall": True, "dataErased": False,
            "notificationPermissionOverride": False,
        }, indent=2) + "\n")
        build = subprocess.run(xcode + ["-only-testing:OpenBotNativeUITests/" + test_class, "-resultBundlePath", str(result), "test-without-building"], cwd=ROOT)
        summary = json.loads(subprocess.check_output([
            "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)
        ], cwd=ROOT, text=True))
        (RUN / "native-ui-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        passed = build.returncode == 0 and summary.get("result") == "Passed" and summary.get("passedTests", 0) >= 1 and not summary.get("failedTests", 0)
        if os.environ.get("OPENBOT_NATIVE_INSPECT_AFTER_TESTS") == "1":
            handoff = {
                "deviceID": device, "bundleID": bundle_id, "apiURL": config["apiURL"],
                "appPath": str(DERIVED / "Build/Products/Simulator-iphonesimulator/OpenBotNative.app"),
                "finishFile": str(RUN / "inspection-complete"),
                "testsPassed": passed,
                "limits": "Synthetic provider; no live model, TURN, APNs or physical-device proof."
            }
            (RUN / "inspection.json").write_text(json.dumps(handoff, indent=2) + "\n")
            deadline = time.monotonic() + 600
            while not (RUN / "inspection-complete").exists():
                if service.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Simulator inspection ended without a completion marker.")
                time.sleep(0.2)
        if not passed:
            raise RuntimeError("No passing native UI journey executed. Read native-ui-summary.json.")
    finally:
        if (fixture / "ready.json").exists() and service.poll() is None:
            try:
                endpoint = json.loads((fixture / "ready.json").read_text())["apiURL"]
                with urllib.request.urlopen(endpoint + "/_control/status", timeout=2) as response:
                    (RUN / "host-final-status.json").write_bytes(response.read())
            except (OSError, ValueError):
                pass
        service.terminate()
        try:
            service.wait(timeout=15)
        except subprocess.TimeoutExpired:
            service.kill()
            service.wait()
        if bundle_id:
            subprocess.run(["xcrun", "simctl", "uninstall", device, bundle_id],
                           cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
