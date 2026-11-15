// Full AgentService process restart across actual native routine due times, on a private SQLite
// profile. A missed run-once catches up, a missed skip records no delivery, and a future one-off
// still executes. Two further process starts must not replay completed work. The synthetic Codex
// process supplies protocol answers only; it never creates routine, mailbox or receipt rows.
// No Mac UI, real account, provider network, production profile or clock override is used.
//
// Authoring gate: existing routine-due-revalidation checks a scheduler and queued deliveries after
// a child crash. It does not exercise AgentService boot ordering, provider readiness and the real
// timer together. A lost boot catch-up, skipped-policy dispatch or replay after a later boot fails
// this owner-boundary check. The existing clientFactory adapter is the only injected boundary.
//
// bun scripts/routine-restart-e2e.ts --out .openbot-build/<fresh-directory>
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { AGENT_PROVIDERS, type Routine, type RoutineRun } from "@openbot/contracts/ipc";
import { type DynamicRecord, isDynamicRecord } from "@openbot/contracts/runtime-values";
import { redactText } from "@openbot/logging";
import { Effect } from "effect";
import type { AgentBrowserHost } from "../src/backend/agent/turn-lifecycle";
import { AgentService } from "../src/backend/agent-service";
import { AgentStore } from "../src/backend/agent-store";
import { CodexAppServerClient } from "../src/backend/app-server-client";
import { runCauseEffect } from "../src/backend/effect-boundary";
import { MailboxStore } from "../src/backend/mailbox-store";
import { OpenBotDatabase } from "../src/backend/openbot-database";

const ROOT = resolve(import.meta.dirname, "..");
const BUILD = join(ROOT, ".openbot-build");
const OVERALL_DEADLINE_MS = 240_000;
const STEP_DEADLINE_MS = 20_000;
const CHILD_OUTPUT_LIMIT = 128 * 1024;
const MARKS = { catchup: "RESTART-CATCHUP", skip: "RESTART-SKIP", future: "RESTART-FUTURE" } as const;
type Phase = "seed" | "catchup" | "future" | "verify";
type Case = keyof typeof MARKS;
function caseRecord<T>(read: (name: Case) => T): Record<Case, T> {
  return { catchup: read("catchup"), skip: read("skip"), future: read("future") };
}
interface Plan {
  agentId: string;
  dueAt: string;
  futureAt: string;
  routines: Record<Case, { id: string; name: string }>;
}
interface State {
  observedAt: string;
  routines: Record<Case, Routine>;
  runs: Record<Case, RoutineRun[]>;
  providerStarts: Record<Case, number>;
  answers: Record<Case, number>;
  queuedDeliveries: number;
  integrity: string;
}
interface PhaseReport {
  phase: Phase;
  pid: number;
  startedAt: string;
  finishedAt: string;
  passed: boolean;
  failure: string | null;
  serviceStopped: boolean;
  state: State | null;
  checks: string[];
  errors: string[];
}
let interrupted = false;
const ownedChildren = new Set<ChildProcess>();
const childClosures = new WeakMap<ChildProcess, Promise<number | null>>();
function trackChild(child: ChildProcess): Promise<number | null> {
  ownedChildren.add(child);
  const closed = new Promise<number | null>((done) => {
    child.once("close", (code) => {
      ownedChildren.delete(child);
      done(code);
    });
  });
  childClosures.set(child, closed);
  return closed;
}
async function closedWithin(child: ChildProcess, milliseconds: number): Promise<boolean> {
  const closed = childClosures.get(child);
  if (!closed) return false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      closed.then(() => true),
      new Promise<false>((done) => {
        timer = setTimeout(() => done(false), milliseconds);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}
async function stopOwnedChild(child: ChildProcess): Promise<boolean> {
  if (!ownedChildren.has(child)) return true;
  try {
    child.kill("SIGTERM");
  } catch {
    return false;
  }
  if (await closedWithin(child, 5_000)) return true;
  try {
    child.kill("SIGKILL");
  } catch {
    return false;
  }
  return closedWithin(child, 2_000);
}
const interrupt = () => {
  interrupted = true;
  for (const child of ownedChildren) child.kill("SIGTERM");
};
process.on("SIGINT", interrupt);
process.on("SIGTERM", interrupt);

function checkRunning(): void {
  if (interrupted) throw new Error("Owned fixture interrupted.");
}
async function waitFor<T>(label: string, read: () => T | null | false | undefined, deadline: number): Promise<T> {
  for (;;) {
    checkRunning();
    const value = read();
    if (value) return value;
    if (Date.now() >= deadline) throw new Error(`Fixture deadline: ${label}.`);
    await new Promise<void>((done) => setTimeout(done, 25));
  }
}
async function waitUntil(at: number): Promise<void> {
  while (Date.now() < at) {
    checkRunning();
    await new Promise<void>((done) => setTimeout(done, Math.min(250, at - Date.now())));
  }
}
async function json<T>(path: string): Promise<T> {
  return JSON.parse(await readFile(path, "utf8"));
}
function safe(value: string, fixture: string): string {
  return redactText(value).replaceAll(fixture, "[owned-fixture]").replaceAll(ROOT, "[repository]").slice(0, 8192);
}
function bounded<A, E extends { readonly cause: unknown }>(work: Effect.Effect<A, E>): Promise<A> {
  return runCauseEffect(
    work.pipe(
      Effect.timeoutOrElse({
        duration: STEP_DEADLINE_MS,
        orElse: () => Effect.die(new Error("Service step deadline.")),
      }),
    ),
  );
}
function fakeCodex(log: string): string {
  return `#!/usr/bin/env node
const { appendFileSync } = require("node:fs");
if (process.argv.includes("--version")) { process.stdout.write("codex-cli 0.160.1\\n"); process.exit(0); }
const LOG = ${JSON.stringify(log)};
const config = { config: { mcp_servers: {} }, layers: [{ name: { type: "user", file: "/synthetic/config.toml", profile: null }, version: "1", config: { mcp_servers: {} } }] };
let buffer = "", threads = 0, turns = 0;
const routineSessions = new Set();
const write = (value) => process.stdout.write(JSON.stringify(value) + "\\n");
process.stdout.on("error", (error) => { if (error.code === "EPIPE") process.exit(0); throw error; });
process.stdin.on("end", () => process.exit(0));
const answer = (message) => {
 const p = message.params || {};
 switch (message.method) {
  case "initialize": return write({ id: message.id, result: {} });
  case "account/read": return write({ id: message.id, result: { account: { type: "chatgpt", email: "synthetic@example.invalid" } } });
  case "account/rateLimits/read": return write({ id: message.id, result: { rateLimits: { limitId: "codex", primary: null, secondary: null }, rateLimitsByLimitId: null } });
  case "model/list": return write({ id: message.id, result: { data: [{ model: "gpt-6-luna", displayName: "GPT-6 Luna" }] } });
  case "plugin/list": return write({ id: message.id, result: { marketplaces: [] } });
  case "config/read": return write({ id: message.id, result: config });
  case "config/batchWrite":
  case "thread/archive":
  case "thread/name/set": return write({ id: message.id, result: {} });
  case "thread/start": {
   const id = "thread-" + process.pid + "-" + (++threads);
   if (p.persistSession === false) routineSessions.add(id);
   return write({ id: message.id, result: { thread: { id, turns: [] } } });
  }
  case "thread/resume": return write({ id: message.id, result: { thread: { id: p.threadId, turns: [] } } });
  case "thread/unsubscribe": return write({ id: message.id, result: { status: "Unsubscribed" } });
  case "thread/turns/list":
  case "thread/items/list":
  case "thread/backgroundTerminals/list": return write({ id: message.id, result: { data: [], nextCursor: null } });
  case "thread/read": return write({ id: message.id, result: { thread: { id: p.threadId, turns: [] } } });
  case "turn/start": {
   const turnId = "turn-" + process.pid + "-" + (++turns);
   const input = (p.input || []).map((item) => item.text || "").join("\\n");
   const routineNames = input.split(String.fromCharCode(10)).filter((line) => line.startsWith("Routine name: ")).map((line) => line.slice("Routine name: ".length));
   const currentRoutine = routineNames.at(-1) || null;
   const mark = routineSessions.has(p.threadId) && ${JSON.stringify(Object.values(MARKS))}.includes(currentRoutine) ? currentRoutine : null;
   if (routineSessions.has(p.threadId) && mark === null) throw new Error("The synthetic provider could not identify the current routine envelope.");
   appendFileSync(LOG, JSON.stringify({ at: new Date().toISOString(), pid: process.pid, method: "turn/start", turnId, mark, routineNames }) + "\\n");
   write({ id: message.id, result: { turn: { id: turnId, status: "inProgress", items: [] } } });
   write({ method: "turn/started", params: { threadId: p.threadId, turn: { id: turnId } } });
   const text = mark ? "Completed " + mark : "Ordinary chat is healthy.";
   write({ method: "item/completed", params: { threadId: p.threadId, turnId, item: { type: "agentMessage", id: "answer-" + turnId, text, phase: "final_answer" } } });
   return write({ method: "turn/completed", params: { threadId: p.threadId, turn: { id: turnId, status: "completed" } } });
  }
  case "turn/interrupt": {
   write({ id: message.id, result: {} });
   return write({ method: "turn/completed", params: { threadId: p.threadId, turn: { id: p.turnId, status: "interrupted" } } });
  }
  default: return write({ id: message.id, error: { code: -32601, message: "Unsupported synthetic method." } });
 }
};
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
 buffer += chunk;
 let newline;
 while ((newline = buffer.indexOf("\\n")) >= 0) {
  const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
  if (!line) continue;
  const message = JSON.parse(line);
  if (message.method && message.id !== undefined) answer(message);
 }
});
`;
}

const unavailable = () => Effect.die(new Error("The restart fixture has no browser service."));
const browser: AgentBrowserHost = {
  listTabs: () => [],
  beginTakeover: unavailable,
  endTakeover: () => {},
  resolveUploadTarget: unavailable,
  handleDynamicTool: unavailable,
  userControlTabFor: () => null,
  awaitUserControlRelease: unavailable,
  onChanged: () => () => {},
  onControlChanged: () => () => {},
  onDocumentChanged: () => () => {},
  clearControls: () => {},
  endControl: () => {},
  close: () => Effect.void,
  clearAgentSession: () => Effect.void,
  shareTab: () => undefined,
  unshareThread: () => undefined,
  agentTab: () => null,
};

async function runPhase(root: string, phase: Phase): Promise<void> {
  const startedAt = new Date().toISOString();
  const provider = join(root, "codex");
  const log = join(root, "protocol.jsonl");
  const database = new OpenBotDatabase(join(root, "state"));
  const store = new AgentStore(join(root, "state"), join(root, "home"), database);
  const mailbox = new MailboxStore(join(root, "state"), store.sharedRoot, database);
  const clients = new Set<CodexAppServerClient>();
  const service = new AgentService({
    store,
    mailbox,
    browser,
    preferredProvider: "codex",
    offProviders: AGENT_PROVIDERS.filter((id) => id !== "codex"),
    timezone: () => "UTC",
    bundledExecutables: { codex: provider, claude: null, grok: null },
    clientFactory: (id) => {
      assert.equal(id, "codex");
      const client = new CodexAppServerClient(provider, 3_000);
      clients.add(client);
      return client;
    },
  });
  const report: PhaseReport = {
    phase,
    pid: process.pid,
    startedAt,
    finishedAt: "",
    passed: false,
    failure: null,
    serviceStopped: false,
    state: null,
    checks: [],
    errors: [],
  };
  service.on("event", (event) => {
    if (event.type === "error") report.errors.push(event.code);
  });
  const check = (name: string, value: boolean) => {
    assert.ok(value, name);
    report.checks.push(name);
  };
  const queueSettled = (id: string) =>
    service.listQueue(id).deliveries.every((delivery) => !["queued", "starting", "running"].includes(delivery.status));
  const readState = async (plan: Plan): Promise<State> => {
    const entries = await readFile(log, "utf8").catch(() => "");
    assert.ok(entries.length <= 1024 * 1024, "Synthetic provider log is bounded.");
    const starts = entries
      .split("\n")
      .filter(Boolean)
      .map((line): DynamicRecord => {
        const entry = JSON.parse(line);
        assert.ok(isDynamicRecord(entry));
        return entry;
      });
    const conversation = await bounded(service.readConversation(plan.agentId));
    const routines = caseRecord((name) => {
      const routine = service.listRoutines(plan.agentId).find((item) => item.id === plan.routines[name].id);
      assert.ok(routine, "The real saved routine is retained.");
      return routine;
    });
    const runs = caseRecord((name) =>
      service.listRoutineRuns({ agentId: plan.agentId, routineId: plan.routines[name].id, limit: 10 }, true),
    );
    const providerStarts = caseRecord((name) => starts.filter((entry) => entry.mark === MARKS[name]).length);
    const answers = caseRecord(
      (name) =>
        conversation.messages.filter(
          (message) =>
            message.author === "assistant" &&
            message.status === "completed" &&
            message.text === `Completed ${MARKS[name]}`,
        ).length,
    );
    const quick = database.connection.prepare("PRAGMA quick_check").get();
    return {
      observedAt: new Date().toISOString(),
      routines,
      runs,
      providerStarts,
      answers,
      queuedDeliveries: mailbox.queuedDeliveryIds(plan.agentId).length,
      integrity: quick?.quick_check === "ok" ? "ok" : "failed",
    };
  };
  const checkCaughtUp = (state: State) => {
    check(
      "One missed run-once completed exactly once",
      state.runs.catchup.length === 1 && state.runs.catchup[0]?.status === "succeeded",
    );
    check(
      "One actual provider start and answer for catch-up",
      state.providerStarts.catchup === 1 && state.answers.catchup === 1,
    );
    check(
      "The missed skip has one cancelled record",
      state.runs.skip.length === 1 &&
        state.runs.skip[0]?.status === "cancelled" &&
        state.runs.skip[0]?.missed?.count === 1,
    );
    check(
      "The skipped occurrence made no delivery or provider turn",
      state.runs.skip[0]?.deliveryId === null && state.providerStarts.skip === 0 && state.answers.skip === 0,
    );
    check("Both missed one-offs are inactive", !state.routines.catchup.active && !state.routines.skip.active);
  };
  try {
    await bounded(service.initialize());
    if (phase === "seed") {
      const agent = await bounded(
        service.createAgent({
          name: "Restart fixture",
          description: "Synthetic restart fixture",
          avatarSeed: "restart-fixture",
          avatarHue: null,
          initialMessage: "Initial control message.",
        }),
      );
      await waitFor("initial ordinary message", () => queueSettled(agent.id), Date.now() + STEP_DEADLINE_MS);
      const due = Math.ceil(Date.now() / 60_000) * 60_000 + 60_000;
      const future = due + 60_000;
      const saved = caseRecord((name) => {
        const at = new Date(name === "future" ? future : due).toISOString();
        const routine = service.createRoutine({
          agentId: agent.id,
          name: MARKS[name],
          instruction: MARKS[name],
          active: true,
          timezone: "UTC",
          schedule: { kind: "once", date: at.slice(0, 10), time: at.slice(11, 16) },
          missedPolicy: name === "skip" ? "skip" : "run-once",
          limitPolicy: "wait",
          runIn: "chat",
        });
        return { id: routine.id, name: routine.name };
      });
      const plan: Plan = {
        agentId: agent.id,
        dueAt: new Date(due).toISOString(),
        futureAt: new Date(future).toISOString(),
        routines: saved,
      };
      await writeFile(join(root, "plan.json"), JSON.stringify(plan));
      report.state = await readState(plan);
      check(
        "All schedules are future at seed shutdown",
        Date.now() < due && Object.values(report.state.routines).every((routine) => routine.active),
      );
      check(
        "No routine ran during setup",
        Object.values(report.state.runs).every((rows) => rows.length === 0),
      );
    } else {
      const plan = await json<Plan>(join(root, "plan.json"));
      if (phase === "catchup") {
        check("This process started after the missed due time", Date.parse(startedAt) > Date.parse(plan.dueAt));
        await waitFor(
          "missed run-once completion",
          () => {
            const rows = service.listRoutineRuns(
              { agentId: plan.agentId, routineId: plan.routines.catchup.id, limit: 10 },
              true,
            );
            return rows.length === 1 && rows[0]?.status === "succeeded";
          },
          Date.now() + STEP_DEADLINE_MS,
        );
      } else if (phase === "future") {
        const before = await readState(plan);
        checkCaughtUp(before);
        check(
          "The healthy future occurrence remains due ahead",
          before.runs.future.length === 0 && before.routines.future.active && Date.now() < Date.parse(plan.futureAt),
        );
        await waitFor(
          "future scheduled completion",
          () => {
            const rows = service.listRoutineRuns(
              { agentId: plan.agentId, routineId: plan.routines.future.id, limit: 10 },
              true,
            );
            return rows.length === 1 && rows[0]?.status === "succeeded";
          },
          Date.parse(plan.futureAt) + STEP_DEADLINE_MS,
        );
      } else {
        const receipt = await bounded(
          service.sendMessage({ agentId: plan.agentId, text: "Verify ordinary chat after the final restart." }),
        );
        const deliveryId = receipt.deliveries[0]?.id;
        assert.ok(deliveryId);
        await waitFor(
          "ordinary chat after completed schedules",
          () => mailbox.getDelivery(deliveryId)?.delivery.status === "completed",
          Date.now() + STEP_DEADLINE_MS,
        );
        check("Ordinary chat completes after the final restart", true);
      }
      report.state = await readState(plan);
      checkCaughtUp(report.state);
      if (phase === "catchup") {
        check(
          "The next future occurrence has not started",
          report.state.runs.future.length === 0 &&
            report.state.providerStarts.future === 0 &&
            Date.now() < Date.parse(plan.futureAt),
        );
      } else {
        check(
          "The future one-off completed exactly once",
          report.state.runs.future.length === 1 && report.state.runs.future[0]?.status === "succeeded",
        );
        check(
          "One actual provider start and answer for the future occurrence",
          report.state.providerStarts.future === 1 && report.state.answers.future === 1,
        );
        check(
          "All one-offs are inactive",
          Object.values(report.state.routines).every((routine) => !routine.active),
        );
      }
    }
    check("SQLite remains valid", report.state.integrity === "ok");
    check("No queued work is left at the checkpoint", report.state.queuedDeliveries === 0);
    check("No service error event was emitted", report.errors.length === 0);
    report.passed = true;
  } catch (error) {
    report.failure = safe(error instanceof Error ? error.message : String(error), root);
  } finally {
    try {
      await bounded(service.stop());
      report.serviceStopped = true;
    } catch {
      report.serviceStopped = false;
    }
    for (const client of clients) await runCauseEffect(client.stop()).catch(() => {});
    database.close();
    report.finishedAt = new Date().toISOString();
    if (!report.serviceStopped) report.passed = false;
    await writeFile(join(root, `${phase}.json`), JSON.stringify(report, null, 2));
  }
  if (!report.passed) throw new Error(report.failure ?? "The owned service did not stop.");
}

const childFlag = process.argv.indexOf("--child");
if (childFlag >= 0) {
  const root = process.argv[childFlag + 1];
  const phase = process.argv[childFlag + 2];
  assert.ok(root);
  assert.ok(phase === "seed" || phase === "catchup" || phase === "future" || phase === "verify");
  await runPhase(root, phase);
} else {
  const outFlag = process.argv.indexOf("--out");
  const output = resolve(
    ROOT,
    outFlag < 0 ? `.openbot-build/routine-restart/${randomUUID()}` : (process.argv[outFlag + 1] ?? ""),
  );
  const inside = relative(BUILD, output);
  assert.ok(inside && inside !== ".." && !inside.startsWith(`..${sep}`) && !isAbsolute(inside));
  await mkdir(resolve(output, ".."), { recursive: true });
  await mkdir(output);
  const started = Date.now();
  const root = await mkdtemp(join(tmpdir(), "openbot-routine-restart-"));
  const phases: PhaseReport[] = [];
  let passed = false;
  let failure: string | null = null;
  let fixtureRemoved = false;
  async function child(phase: Phase): Promise<void> {
    await writeFile(join(root, "current-phase.txt"), phase);
    const processChild = spawn(process.execPath, [import.meta.filename, "--child", root, phase], {
      cwd: ROOT,
      env: { PATH: process.env.PATH, TMPDIR: tmpdir() },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const closed = trackChild(processChild);
    let spawnError: Error | null = null;
    processChild.once("error", (error) => {
      spawnError = error;
    });
    let content = "";
    let outputExceeded = false;
    const capture = (chunk: Buffer) => {
      if (outputExceeded) return;
      content += chunk.toString("utf8");
      if (Buffer.byteLength(content) > CHILD_OUTPUT_LIMIT) {
        outputExceeded = true;
        content = "Child output exceeded its bound.";
        void stopOwnedChild(processChild);
      }
    };
    processChild.stdout?.on("data", capture);
    processChild.stderr?.on("data", capture);
    let timedOut = false;
    let deadline: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_done, fail) => {
      deadline = setTimeout(
        () => {
          timedOut = true;
          void stopOwnedChild(processChild).then((stopped) => {
            fail(new Error(stopped ? "Owned child deadline." : "Owned child did not stop."));
          });
        },
        Math.max(1, started + OVERALL_DEADLINE_MS - Date.now()),
      );
    });
    try {
      const code = await Promise.race([closed, timeout]);
      assert.ok(!timedOut, "Owned child completed before its deadline.");
      assert.ok(!outputExceeded, "Owned child output stayed within its bound.");
      if (spawnError) throw spawnError;
      const report = await json<PhaseReport>(join(root, `${phase}.json`)).catch(() => null);
      if (report) phases.push(report);
      assert.equal(code, 0, safe(content, root));
      assert.ok(report?.passed, `The ${phase} checkpoint passed.`);
    } finally {
      if (deadline) clearTimeout(deadline);
      await stopOwnedChild(processChild);
    }
    process.stdout.write(`PASS ${phase}\n`);
  }
  try {
    await mkdir(join(root, "home"));
    await writeFile(join(root, "codex"), fakeCodex(join(root, "protocol.jsonl")), { mode: 0o700 });
    await child("seed");
    const plan = await json<Plan>(join(root, "plan.json"));
    assert.ok(
      Date.parse(phases[0]?.finishedAt ?? "") < Date.parse(plan.dueAt),
      "The first process stopped before either missed schedule.",
    );
    await waitUntil(Date.parse(plan.dueAt) + 250);
    await child("catchup");
    await child("future");
    await child("verify");
    assert.equal(new Set(phases.map((phase) => phase.pid)).size, 4, "Four separate AgentService processes were used.");
    assert.equal(phases.length, 4);
    assert.ok(phases.every((phase) => phase.passed && phase.serviceStopped));
    passed = true;
  } catch (error) {
    failure = safe(error instanceof Error ? error.message : String(error), root);
  } finally {
    let childrenStopped = true;
    for (const processChild of ownedChildren) {
      if (!(await stopOwnedChild(processChild))) childrenStopped = false;
    }
    if (!childrenStopped) {
      passed = false;
      failure ??= "Owned child cleanup failed; temporary profile retained.";
    }
    for (const file of ["plan.json", "protocol.jsonl"]) {
      const data = await readFile(join(root, file), "utf8").catch(() => null);
      if (data) await writeFile(join(output, file), data);
    }
    const sources = Object.fromEntries(
      await Promise.all(
        [
          "scripts/routine-restart-e2e.ts",
          "src/backend/agent-service.ts",
          "src/backend/agent/routine-scheduler.ts",
          "src/backend/routine-store.ts",
          "src/backend/routine-timer.ts",
          "src/backend/agent/boot-recovery.ts",
        ].map(async (path) => [
          path,
          createHash("sha256")
            .update(await readFile(join(ROOT, path)))
            .digest("hex"),
        ]),
      ),
    );
    if (childrenStopped)
      await rm(root, { recursive: true, force: true }).then(() => {
        fixtureRemoved = true;
      });
    await writeFile(
      join(output, "report.json"),
      JSON.stringify(
        {
          passed,
          failure,
          durationMs: Date.now() - started,
          sources,
          phases,
          cleanup: { fixtureRemoved, childrenStopped, ownedChildCount: ownedChildren.size },
          authoringGate: {
            behavior:
              "Native missed policies, catch-up, future timer work and no completed-work replay across full service process restarts.",
            credibleRegression:
              "Boot ordering omits catch-up or skip settlement, starts skipped work, or replays a completed occurrence.",
            existingGap:
              "Scheduler crash tests stop before mailbox enqueue and assert queued rows, not the full service/provider/timer startup boundary.",
            productionSeam:
              "No new production seam; the existing provider clientFactory supplies a real synthetic JSON-RPC child.",
          },
          limits: [
            "Three distinct one-offs and four service processes, not a long-term reliability rate.",
            "Natural minute-resolution schedules; no clock override, Mac UI, production profile, account or network calls.",
            "Provider protocol output is synthetic. This checks engine persistence and startup, not model tool discovery, real email, computer use or phone notifications.",
            "Clean process exits while work is future or complete. It does not prove safe external side-effect replay after a mid-turn crash.",
          ],
        },
        null,
        2,
      ),
    );
  }
  process.stdout.write(`${JSON.stringify({ passed, failure, report: join(output, "report.json") })}\n`);
  if (!passed) process.exitCode = 1;
}
