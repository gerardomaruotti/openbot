import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { createOpenBotLogger } from "@openbot/logging";
import { pushNotificationKeys, sealPushNotification } from "@openbot/team-client/push-notification-seal";

const root = resolve(import.meta.dirname, "../../..");
const output = resolve(root, ".openbot-build/native-ios/notification-payload-e2e");
mkdirSync(output, { recursive: true });
const secret = randomBytes(32);
const keys = pushNotificationKeys(secret);
const record = {
  scope: "synthetic-account-host-membership",
  hostID: "synthetic-host",
  name: "Synthetic Mac",
  secret: secret.toString("base64"),
};
const content = {
  serverId: record.scope,
  agentId: "synthetic-agent",
  threadId: "synthetic-thread",
  kind: "reply" as const,
  title: "Synthetic Agent",
  body: "SYNTHETIC-PUSH-BODY",
};
const sealed = sealPushNotification(content, keys, randomBytes(16));
function tampered(position: number) {
  const bytes = Buffer.from(sealed, "base64url");
  bytes[position] = (bytes[position] ?? 0) ^ 1;
  return bytes.toString("base64url");
}
const fixtures = [
  { name: "host-seal-opens-in-native-code", sealed, secrets: [record], opens: true },
  {
    name: "authenticated-failure-kind-survives-native-decode",
    sealed: sealPushNotification({ ...content, kind: "failed" }, keys, randomBytes(16)),
    secrets: [record],
    kind: "failed",
    opens: true,
  },
  { name: "missing-keys", sealed, secrets: [], opens: false },
  { name: "wrong-key", sealed, secrets: [{ ...record, secret: randomBytes(32).toString("base64") }], opens: false },
  { name: "wrong-scope", sealed, secrets: [{ ...record, scope: "different-membership" }], opens: false },
  ...[0, 16, Buffer.from(sealed, "base64url").length - 1].map((position) => ({
    name: `modified-${position}`,
    sealed: tampered(position),
    secrets: [record],
    opens: false,
  })),
  { name: "invalid-base64", sealed: "not valid base64", secrets: [record], opens: false },
  { name: "short-payload", sealed: randomBytes(32).toString("base64url"), secrets: [record], opens: false },
  { name: "oversized-payload", sealed: "A".repeat(3_601), secrets: [record], opens: false },
  {
    name: "invalid-routing-agent",
    sealed: sealPushNotification({ ...content, agentId: "" }, keys, randomBytes(16)),
    secrets: [record],
    opens: false,
  },
];
const input = resolve(output, "synthetic-fixtures.json");
const executable = resolve(output, "notification-payload");
writeFileSync(input, JSON.stringify(fixtures), { mode: 0o600 });
async function run(command: string, args: string[]): Promise<string> {
  return new Promise((resolveOutput, reject) => {
    const child = spawn(command, args, { cwd: root, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "",
      stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += String(chunk);
    });
    child.stderr.on("data", (chunk) => {
      stderr += String(chunk);
    });
    child.on("error", reject);
    child.on("exit", (code) =>
      code === 0
        ? resolveOutput(stdout)
        : reject(new Error(`Notification interoperability failed (${code}): ${stderr.slice(0, 1_500)}`)),
    );
  });
}
await run("xcrun", [
  "swiftc",
  "-swift-version",
  "6",
  "apps/ios/NotificationShared/NotificationPayload.swift",
  "apps/ios/scripts/notification-payload-e2e.swift",
  "-o",
  executable,
]);
const result = JSON.parse(await run(executable, [input]));
const report = {
  ...result,
  checks: fixtures.map((f) => f.name),
  limits:
    "Real host seal and native CryptoKit decoder in separate processes. No APNs delivery, Keychain sharing or notification extension invocation claim.",
};
writeFileSync(resolve(output, "report.json"), `${JSON.stringify(report, null, 2)}\n`);
createOpenBotLogger("native-notification-payload-e2e").info("Notification interoperability passed.", report);
