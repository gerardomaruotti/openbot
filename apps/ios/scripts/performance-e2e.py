#!/usr/bin/env python3
"""Stage a separate native benchmark app; device tools own launch and input."""
import hashlib
import json
import pathlib
import subprocess
import sys
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = ROOT / ".openbot-build/native-ios/performance-audit"
action, stage, device = sys.argv[1:4]
folder = OUT / stage
folder.mkdir(parents=True, exist_ok=True)
metadata_path = folder / "native-benchmark.json"

def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()

if action == "prepare":
    bundle = "com.gerardomaruotti.openbot.native.performance." + str(uuid.uuid4())
    spec = {
        "name": "NativePerformance", "options": {"deploymentTarget": {"iOS": "26.0"}},
        "settings": {"base": {
            "SWIFT_VERSION": "6.0", "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
            "SWIFT_OPTIMIZATION_LEVEL": "-O", "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "PRODUCT_BUNDLE_IDENTIFIER": bundle, "OPENBOT_NATIVE_APP_ID": bundle,
            "OPENBOT_NATIVE_APNS_ENVIRONMENT": "development", "CODE_SIGN_STYLE": "Automatic",
            "CODE_SIGN_ENTITLEMENTS": str(ROOT / "apps/ios/Configuration/App.entitlements"),
            "TARGETED_DEVICE_FAMILY": "1,2", "GENERATE_INFOPLIST_FILE": "YES",
            "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
            "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        }},
        "targets": {"NativePerformance": {
            "type": "application", "platform": "iOS",
            "sources": [
                {"path": str(ROOT / "apps/ios/Sources"), "excludes": ["App/OpenBotApp.swift"]},
                {"path": str(ROOT / "apps/ios/NotificationShared")},
                {"path": str(ROOT / "apps/ios/Resources"), "buildPhase": "resources"},
                {"path": str(ROOT / "apps/ios/AppIcon.icon"), "buildPhase": "resources"},
                {"path": str(ROOT / "packages/i18n/native/Localizable.xcstrings"), "buildPhase": "resources"},
                {"path": str(ROOT / "apps/ios/scripts/performance-app.swift")},
            ],
            "info": {"path": str(folder / "Info.plist"), "properties": {
                "CFBundleDisplayName": "OpenBot Benchmark", "OpenBotContainingAppID": bundle,
                "OpenBotAccountURL": "http://127.0.0.1:9", "OpenBotPushRelayTopic": "",
                "OpenBotNotificationKeychainGroup": "$(AppIdentifierPrefix)" + bundle + ".notifications",
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
            }},
        }},
        "schemes": {"NativePerformance": {"build": {"targets": {"NativePerformance": "all"}}}},
    }
    spec_path = folder / "project.json"
    spec_path.write_text(json.dumps(spec, indent=2) + "\n")
    sources = sorted((ROOT / "apps/ios/Sources").rglob("*.swift"))
    sources += [ROOT / "apps/ios/scripts/performance-app.swift"]
    fingerprints = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    run("xcodegen", "generate", "--spec", str(spec_path))
    log = folder / "build.log"
    with log.open("w") as output:
        subprocess.run(["xcodebuild", "-quiet", "-project", str(folder / "NativePerformance.xcodeproj"),
            "-scheme", "NativePerformance", "-configuration", "Release", "-jobs", "2",
            "-destination", "platform=iOS Simulator,id=" + device,
            "-derivedDataPath", str(folder / "DerivedData"), "build"],
            cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, check=True)
    assert all(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == value for p, value in fingerprints.items())
    app = folder / "DerivedData/Build/Products/Release-iphonesimulator/NativePerformance.app"
    run("xcrun", "simctl", "bootstatus", device, "-b")
    run("xcrun", "simctl", "install", device, str(app))
    container = run("xcrun", "simctl", "get_app_container", device, bundle, "data")
    metadata = {"deviceID": device, "bundleID": bundle, "app": str(app),
                "reportPath": str(pathlib.Path(container) / "Documents/performance-results.json"),
                "sourceFiles": fingerprints, "stage": stage,
                "limits": "Separate simulator app executes actual production model and storage code with isolated synthetic inputs; no live provider, network or physical-device timing."}
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata, indent=2))
elif action == "collect":
    metadata = json.loads(metadata_path.read_text())
    report = json.loads(pathlib.Path(metadata["reportPath"]).read_text())
    report["source"] = metadata
    (folder / "native-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
elif action == "cleanup":
    metadata = json.loads(metadata_path.read_text())
    assert metadata["deviceID"] == device and metadata["bundleID"].startswith("com.gerardomaruotti.openbot.native.performance.")
    run("xcrun", "simctl", "uninstall", device, metadata["bundleID"])
    print("Owned benchmark app removed.")
else:
    raise SystemExit("Use prepare, collect or cleanup.")
