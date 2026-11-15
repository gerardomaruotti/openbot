import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { createOpenBotLogger } from "@openbot/logging";

const root = resolve(import.meta.dirname, "../../..");
const output = resolve(root, ".openbot-build/native-ios/recovery-e2e");
mkdirSync(output, { recursive: true });
const fixture = mkdtempSync(resolve(output, "workspace-"));
const executable = resolve(output, "workspace-recovery");
const logger = createOpenBotLogger("native-workspace-recovery-e2e");

async function run(command: string, args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: root, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (data) => {
      stdout += String(data);
    });
    child.stderr.on("data", (data) => {
      stderr += String(data);
    });
    child.on("error", reject);
    child.on("exit", (code) =>
      code === 0
        ? resolve(stdout)
        : reject(new Error(`Workspace E2E failed (${code}): ${stderr.slice(0, 2000)} ${stdout.slice(0, 1000)}`)),
    );
  });
}

await run("xcrun", [
  "swiftc",
  "-swift-version",
  "6",
  "-default-isolation",
  "MainActor",
  "-target",
  "arm64-apple-macos14.0",
  "apps/ios/Sources/Models/Conversation.swift",
  "apps/ios/Sources/Connection/ConnectionTypes.swift",
  "apps/ios/Sources/Connection/LiveWorkspaceState.swift",
  "apps/ios/Sources/Connection/LiveWorkspaceDisk.swift",
  "apps/ios/scripts/workspace-recovery-e2e.swift",
  "-o",
  executable,
]);
const write = JSON.parse(await run(executable, ["write", fixture]));
// A new process reopens the same encrypted file after the interrupted send.
const recovery = JSON.parse(await run(executable, ["recover", fixture]));
const report = {
  passed: true,
  ...write,
  ...recovery,
  fixture,
  limits: "Real filesystem/crypto/process restart. No Keychain, WebRTC, provider, or device UI claim.",
};
writeFileSync(resolve(output, "report.json"), `${JSON.stringify(report, null, 2)}\n`);
logger.info("Native workspace recovery passed.", report);
