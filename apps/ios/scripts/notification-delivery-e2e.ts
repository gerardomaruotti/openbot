import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { isDynamicRecord, isString } from "@openbot/contracts/runtime-values";
import { createOpenBotLogger } from "@openbot/logging";

const repository = resolve(import.meta.dirname, "../../..");
const output = resolve(repository, ".openbot-build/native-ios/notification-delivery-e2e");
mkdirSync(output, { recursive: true });
const root = mkdtempSync(resolve(output, "run-"));
writeFileSync(
  resolve(output, "report.json"),
  `${JSON.stringify({ passed: false, status: "running", root }, null, 2)}\n`,
);
const child = spawn(process.execPath, ["apps/ios/scripts/simulator/entry.ts", root], {
  cwd: repository,
  stdio: ["ignore", "pipe", "pipe"],
});
let log = "";
child.stdout?.on("data", (data) => {
  log += String(data);
});
child.stderr?.on("data", (data) => {
  log += String(data);
});
interface PushStatus {
  delivered: number;
  denied: number;
  registrations: number;
  activeTurn: string | null;
  threadID: string | null;
  replies: string[];
}
const pause = () => new Promise((resolvePause) => setTimeout(resolvePause, 100));
async function waitFor<A>(read: () => Promise<A | null>, label: string): Promise<A> {
  const deadline = Date.now() + 20_000;
  while (true) {
    const value = await read();
    if (value !== null) return value;
    if (child.exitCode !== null || Date.now() > deadline)
      throw new Error(`Notification fixture failed: ${label}. Read its fixture.log.`);
    await pause();
  }
}
async function execute(command: string, args: string[]) {
  await new Promise<void>((resolveDone, reject) => {
    const task = spawn(command, args, { cwd: repository, stdio: ["ignore", "pipe", "pipe"] });
    let error = "";
    task.stderr?.on("data", (data) => {
      error += String(data);
    });
    task.on("error", reject);
    task.on("exit", (code) =>
      code === 0
        ? resolveDone()
        : reject(new Error(`Notification native check failed (${code}): ${error.slice(0, 1_000)}`)),
    );
  });
}
try {
  const ready = await waitFor(async () => {
    try {
      const value = JSON.parse(readFileSync(resolve(root, "ready.json"), "utf8"));
      return isDynamicRecord(value) && isString(value.apiURL) && isString(value.agentId) && isString(value.hostId)
        ? { apiURL: value.apiURL, agentId: value.agentId, hostId: value.hostId }
        : null;
    } catch {
      return null;
    }
  }, "startup");
  async function action(name: string, body: { text?: string } = {}) {
    const response = await fetch(`${ready.apiURL}/_control/push/${name}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!response.ok) throw new Error(`Notification action ${name} failed (${response.status}).`);
  }
  async function status(): Promise<PushStatus> {
    const response = await fetch(`${ready.apiURL}/_control/push/status`);
    if (!response.ok) throw new Error("No notification fixture status.");
    return response.json();
  }
  async function completed(marker: string, delivered: number, denied: number) {
    return waitFor(async () => {
      const value = await status();
      return value.activeTurn === null &&
        value.replies.includes(`${marker} received`) &&
        value.delivered === delivered &&
        value.denied === denied
        ? value
        : null;
    }, marker);
  }
  await action("setup");
  await action("send", { text: "SIM-PUSH-1" });
  const first = await completed("SIM-PUSH-1", 1, 0);
  const deliveries: Array<{ platform: string; push: { sealed: string } }> = JSON.parse(
    readFileSync(resolve(root, "notification-deliveries.json"), "utf8"),
  );
  const secret = JSON.parse(readFileSync(resolve(root, "notification-secret.json"), "utf8"));
  const openedInput = resolve(root, "native-input.json");
  writeFileSync(
    openedInput,
    JSON.stringify([
      {
        name: "real-host-delivery-opens-in-native",
        sealed: deliveries[0]?.push.sealed,
        secrets: [secret],
        opens: true,
        expected: {
          scope: secret.scope,
          hostID: ready.hostId,
          agentID: ready.agentId,
          threadID: first.threadID,
          title: "Simulator Agent",
          body: "SIM-PUSH-1 received",
        },
      },
    ]),
    { mode: 0o600 },
  );
  await execute(process.execPath, ["apps/ios/scripts/notification-payload-e2e.ts"]);
  await execute(resolve(output, "../notification-payload-e2e/notification-payload"), [openedInput]);

  await action("foreground");
  await action("send", { text: "SIM-PUSH-2" });
  await completed("SIM-PUSH-2", 1, 0);
  await action("remove");
  // The released API changes the active registration before its queued disk write completes.
  await waitFor(async () => ((await status()).registrations === 0 ? true : null), "persisted removal");
  await action("away");
  await waitFor(async () => ((await status()).registrations === 1 ? true : null), "persisted registration");
  await action("revoke");
  await action("send", { text: "SIM-PUSH-3" });
  const revoked = await completed("SIM-PUSH-3", 1, 1);
  const report = {
    passed: true,
    root,
    checks: [
      "real Team API registration and removal",
      "real agent reply creates one sealed delivery",
      "native decoder opens the host delivery",
      "foreground suppresses delivery",
      "account-side session revocation blocks a send while host still has registration",
    ],
    delivered: revoked.delivered,
    authorizationDenied: revoked.denied,
    limits:
      "Isolated account, host and simulated APNs transport. No Apple network delivery, token registration, NSE invocation or physical-device claim.",
  };
  writeFileSync(resolve(output, "report.json"), `${JSON.stringify(report, null, 2)}\n`);
  createOpenBotLogger("native-notification-delivery-e2e").info("Notification delivery checks passed.", report);
} catch (error) {
  writeFileSync(
    resolve(output, "report.json"),
    `${JSON.stringify({ passed: false, status: "failed", root }, null, 2)}\n`,
  );
  throw error;
} finally {
  child.kill("SIGTERM");
  await new Promise<void>((resolveDone) => {
    if (child.exitCode !== null) {
      resolveDone();
      return;
    }
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      resolveDone();
    }, 15_000);
    child.once("exit", () => {
      clearTimeout(timer);
      resolveDone();
    });
  });
  writeFileSync(resolve(root, "fixture.log"), log);
}
