// Real AgentService, Codex JSON-RPC process, ChannelService, routine scheduler, timer and SQLite.
// A manual routine run assigns a child task and waits for its result. Its one-time occurrence
// must remain durable but unissued, including startup replay through a fresh scheduler. Once
// the child and root finish normally, the production changed/reconcile/arm path must deliver
// exactly one scheduled request and one result. No channel tasks, receipts or runs are seeded.
// The synthetic provider controls only its protocol output; it never implements scheduling.
// No accounts, personal profile, network, environment overrides or real provider calls are used.
//
// bun scripts/channel-routine-deferred-overlap-e2e.ts --out .openbot-build/<owned-output-folder>
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve, sep } from "node:path";
import { AGENT_PROVIDERS, type ChannelRoutineRun } from "@openbot/contracts/ipc";
import { type DynamicRecord, isDynamicRecord, isString } from "@openbot/contracts/runtime-values";
import { redactText } from "@openbot/logging";
import { Effect } from "effect";
import type { AgentBrowserHost } from "../src/backend/agent/turn-lifecycle";
import { AgentService } from "../src/backend/agent-service";
import { AgentStore } from "../src/backend/agent-store";
import { CodexAppServerClient } from "../src/backend/app-server-client";
import { ChannelRoutineScheduler } from "../src/backend/channel-routine-scheduler";
import { ChannelRoutineStore } from "../src/backend/channel-routine-store";
import { runCauseEffect } from "../src/backend/effect-boundary";
import { MailboxStore } from "../src/backend/mailbox-store";
import { OpenBotDatabase } from "../src/backend/openbot-database";

const ROOT = resolve(import.meta.dirname, "..");
const outFlag = process.argv.indexOf("--out");
const OUT = resolve(
  outFlag >= 0
    ? (process.argv[outFlag + 1] ?? "")
    : join(ROOT, ".openbot-build/reliability-2026-11-15/channel-deferred-overlap-e2e"),
);
assert.ok(OUT.startsWith(resolve(ROOT, ".openbot-build") + sep));
await mkdir(OUT, { recursive: true });
const root = await mkdtemp(join(tmpdir(), "openbot-channel-overlap-"));
const fixtureHome = join(root, "home");
const fakeCodex = join(root, "codex");
const protocolLog = join(root, "protocol.jsonl");
const fixtureConfig = join(root, "fixture.json");
const hold = join(root, "hold-child");
const CHANNEL_ID = "synthetic-deferred-routine";
const ACTOR = { id: "synthetic-owner", name: "Synthetic owner" };
const TARGET = "ROUTINE-DEFERRED-TARGET";
const CHILD = "ROUTINE-DEFERRED-CHILD";
const MANUAL_RESULT = "Synthetic manual result";
const SCHEDULED_RESULT = "Synthetic scheduled result";
const CHILD_RESULT = "Synthetic child result";
const UNRELATED_RESULT = "Synthetic unrelated result";
const errors: string[] = [];
const checks: string[] = [];
interface OverlapObservations {
  manualTaskCount?: number;
  afterDue?: { runs: number; requests: number; active: boolean | undefined };
  final?: {
    runs: number;
    requests: number;
    manualResults: number;
    childResults: number;
    scheduledResults: number;
    statuses: Array<Pick<ChannelRoutineRun, "kind" | "status">>;
    sawEligiblePendingWake: boolean;
  };
  protocolTurns?: number;
  wakeSamples?: Array<{ dueAt: string | null; requestCount: number }>;
}
const observations: OverlapObservations = {};
const admissionEvents: NonNullable<ReturnType<typeof admissionSnapshot>>[] = [];
const clients = new Set<CodexAppServerClient>();
let passed = false;
let failure: string | undefined;
let stopped = false;
let targetId = "";
let scheduler: ChannelRoutineScheduler | null = null;
let sawEligiblePendingWake = false;
const wakeSamples: Array<{ dueAt: string | null; requestCount: number }> = [];

// The process implements only the provider protocol. Channel tools pass through the real
// tool router, and the service owns task admission, dependency release and completion.
const FAKE_CODEX = `#!/usr/bin/env node
const { appendFileSync, existsSync, readFileSync } = require("node:fs");
if (process.argv.includes("--version")) { process.stdout.write("codex-cli 0.160.1\\n"); process.exit(0); }
const LOG = ${JSON.stringify(protocolLog)};
const CONFIG = ${JSON.stringify(fixtureConfig)};
const HOLD = ${JSON.stringify(hold)};
const config = { config: { mcp_servers: {} }, layers: [{ name: { type: "user", file: "/synthetic/config.toml", profile: null }, version: "1", config: { mcp_servers: {} } }] };
let buffer = "", threads = 0, turns = 0, firstRoot = null;
const waiting = new Map();
const log = (value) => appendFileSync(LOG, JSON.stringify(value) + "\\n");
const write = (value) => process.stdout.write(JSON.stringify(value) + "\\n");
process.stdout.on("error", (error) => { if (error.code === "EPIPE") process.exit(0); throw error; });
const finish = (turn, text) => {
  if (text) write({ method: "item/completed", params: { threadId: turn.threadId, turnId: turn.turnId,
    item: { type: "agentMessage", id: "message-" + turn.turnId, text, phase: "final_answer" } } });
  write({ method: "turn/completed", params: { threadId: turn.threadId, turn: { id: turn.turnId, status: "completed" } } });
};
const call = (turn, name, args) => {
  const id = "call-" + turn.turnId;
  waiting.set(id, { turn, name });
  write({ id, method: "item/tool/call", params: { threadId: turn.threadId, turnId: turn.turnId,
    callId: id, namespace: "openbot", tool: "tool_call", arguments: { name: "openbot." + name, arguments: args } } });
};
const answer = (message) => {
  const params = message.params || {};
  switch (message.method) {
    case "initialize": return write({ id: message.id, result: {} });
    case "account/read": return write({ id: message.id, result: { account: { type: "chatgpt", email: "synthetic@example.invalid" } } });
    case "account/rateLimits/read": return write({ id: message.id, result: { rateLimits: { limitId: "codex", primary: null, secondary: null }, rateLimitsByLimitId: null } });
    case "model/list": return write({ id: message.id, result: { data: [{ model: "gpt-6-luna", displayName: "GPT-6 Luna" }] } });
    case "plugin/list": return write({ id: message.id, result: { marketplaces: [] } });
    case "config/read": return write({ id: message.id, result: config });
    case "config/batchWrite": return write({ id: message.id, result: {} });
    case "thread/start": return write({ id: message.id, result: { thread: { id: "thread-" + (++threads), turns: [] } } });
    case "thread/resume": return write({ id: message.id, result: { thread: { id: params.threadId, turns: [] } } });
    case "thread/unsubscribe": return write({ id: message.id, result: { status: "Unsubscribed" } });
    case "thread/name/set": return write({ id: message.id, result: {} });
    case "thread/turns/list":
    case "thread/items/list":
    case "thread/backgroundTerminals/list": return write({ id: message.id, result: { data: [], nextCursor: null } });
    case "thread/read": return write({ id: message.id, result: { thread: { id: params.threadId, turns: [] } } });
    case "turn/start": {
      const turn = { threadId: params.threadId, turnId: "turn-" + (++turns) };
      const text = (params.input || []).map((item) => item.text || "").join("\\n");
      write({ id: message.id, result: { turn: { id: turn.turnId, status: "inProgress", items: [] } } });
      write({ method: "turn/started", params: { threadId: turn.threadId, turn: { id: turn.turnId } } });
      const blocks = [...text.split(/\\n{2,}/), ...text.split("\\n")].flatMap((block) => { try { return [JSON.parse(block)]; } catch { return []; } });
      const packet = blocks.find((value) => value.task && value.agentId);
      log({ method: "turn/start", turnId: turn.turnId, taskId: packet?.task.id ?? null, requestId: packet?.task.requestMessageId ?? null,
        syntheticInput: text.slice(0, 24000) });
      const routing = blocks.find((value) => value.task && value.lead && Array.isArray(value.members));
      if (routing) return setTimeout(() => finish(turn, JSON.stringify({ agentId: routing.lead })), 10);
      if (!packet) return setTimeout(() => finish(turn, "Ready."), 10);
      const task = packet.task;
      if (task.parentTaskId) {
        const timer = setInterval(() => {
          if (existsSync(HOLD)) return;
          clearInterval(timer);
          call(turn, "channel_result", { text: ${JSON.stringify(CHILD_RESULT)} });
        }, 25);
        return;
      }
      const assignment = text.slice(text.lastIndexOf("Current assignment:\\n"));
      if (assignment.startsWith("Current assignment:\\n" + ${JSON.stringify(TARGET)})) {
        if (firstRoot === null) firstRoot = task.id;
        if (task.id === firstRoot && !task.dependencies.length) {
          const owned = JSON.parse(readFileSync(CONFIG, "utf8"));
          return call(turn, "channel_assign", { recipientAgentId: owned.workerId,
            task: ${JSON.stringify(CHILD)}, expectedResult: "Return the synthetic child result.", sourceMessageIds: [task.requestMessageId] });
        }
        return call(turn, "channel_result", { text: task.id === firstRoot ? ${JSON.stringify(MANUAL_RESULT)} : ${JSON.stringify(SCHEDULED_RESULT)} });
      }
      return call(turn, "channel_result", { text: ${JSON.stringify(UNRELATED_RESULT)} });
    }
    case "turn/interrupt": {
      log({ method: "turn/interrupt", turnId: params.turnId });
      write({ id: message.id, result: {} });
      return write({ method: "turn/completed", params: { threadId: params.threadId, turn: { id: params.turnId, status: "interrupted" } } });
    }
    default: return write({ id: message.id, error: { code: -32601, message: "Method not found: " + message.method } });
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
    else if (!message.method && waiting.has(message.id)) {
      const value = waiting.get(message.id); waiting.delete(message.id);
      log({ method: "tool/result", turnId: value.turn.turnId, name: value.name, result: message.result ?? null, error: message.error ?? null });
      // A tool call alone is not an assistant answer. A real provider ends its
      // delegating turn with a short answer, while the channel keeps its dependency.
      finish(value.turn, value.name === "channel_assign" ? "Waiting for the synthetic child." : "Synthetic provider turn finished.");
    }
  }
});
`;

const unused = () => Effect.die(new Error("No browser is used by the synthetic scheduler fixture."));
const browser: AgentBrowserHost = {
  listTabs: () => [],
  beginTakeover: unused,
  endTakeover: () => {},
  resolveUploadTarget: unused,
  handleDynamicTool: unused,
  userControlTabFor: () => null,
  awaitUserControlRelease: unused,
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
const database = new OpenBotDatabase(join(root, "state"));
const store = new AgentStore(join(root, "state"), fixtureHome, database);
const mailbox = new MailboxStore(join(root, "state"), store.sharedRoot, database);
const service = new AgentService({
  store,
  mailbox,
  browser,
  preferredProvider: "codex",
  offProviders: AGENT_PROVIDERS.filter((provider) => provider !== "codex"),
  timezone: () => "UTC",
  bundledExecutables: { codex: fakeCodex, claude: null, grok: null },
  // Existing provider adapter injection, backed by the real process and JSON-RPC implementation.
  // Never starts the real CLI selected by installed-executable discovery.
  clientFactory: (provider) => {
    assert.equal(provider, "codex");
    const client = new CodexAppServerClient(fakeCodex, 3_000);
    // These listeners are registered before the service binds its real handlers.
    // They read owned state only; they do not delay, admit, or answer the provider.
    client.on("notification", (notification) => {
      if (notification.method !== "turn/started" || !isDynamicRecord(notification.params)) return;
      const snapshot = admissionSnapshot("provider-start", notification.params);
      if (snapshot && admissionEvents.length < 200) admissionEvents.push(snapshot);
    });
    client.on("request", (request) => {
      if (request.method !== "item/tool/call" || !isDynamicRecord(request.params)) return;
      const snapshot = admissionSnapshot("provider-tool", request.params);
      if (snapshot && admissionEvents.length < 200) admissionEvents.push(snapshot);
    });
    clients.add(client);
    return client;
  },
});
const runs = new ChannelRoutineStore(database);
const messages = () => service.channels.store.messages(CHANNEL_ID);
const requests = () => messages().filter((entry) => entry.author.id === `routine:${targetId}`);
const results = (text: string) =>
  messages().filter((entry) => entry.author.kind === "agent" && entry.message.text === text);
const taskRows = () => service.channels.store.tasks(CHANNEL_ID);
const targetRuns = () => runs.listRuns(CHANNEL_ID, targetId, 50, true);

/** Synchronous observation of the real owner, before each provider callback is routed. */
function admissionSnapshot(
  boundary: "provider-start" | "provider-tool" | "channel-change",
  params: DynamicRecord = {},
) {
  if (!service.channels.store.exists(CHANNEL_ID)) return null;
  const assignments = service.channels.store.assignments(CHANNEL_ID);
  const agentIds = new Set(assignments.map((assignment) => assignment.agentId));
  const turn = isDynamicRecord(params.turn) ? params.turn : null;
  return {
    observedAt: Date.now(),
    boundary,
    threadId: isString(params.threadId) ? params.threadId : null,
    turnId: isString(params.turnId) ? params.turnId : turn && isString(turn.id) ? turn.id : null,
    assignments: assignments.map(({ id, taskId, agentId, state, turnId, deliveryId, taskRevision }) => ({
      id,
      taskId,
      agentId,
      state,
      turnId,
      deliveryId,
      taskRevision,
    })),
    tasks: service.channels.store.tasks(CHANNEL_ID).map(({ id, ownerAgentId, state, revision, requestMessageId }) => ({
      id,
      ownerAgentId,
      state,
      revision,
      requestMessageId,
    })),
    deliveries: [...agentIds].flatMap((agentId) =>
      service
        .listQueue(agentId)
        .deliveries.filter((delivery) => delivery.status === "starting" || delivery.status === "running")
        .map(({ id, status, turnId }) => ({ agentId, id, status, turnId })),
    ),
  };
}

function owner(): ChannelRoutineScheduler {
  return new ChannelRoutineScheduler({
    channels: service.channels,
    hooks: {
      changed: () => {},
      emitError: (code) => errors.push(code),
      excludedChannels: () => new Set(),
      usageLimited: () => false,
    },
  });
}
function pass(name: string, condition: boolean): void {
  assert.ok(condition, name);
  checks.push(name);
}
function bounded<A, E extends { readonly cause: unknown }>(work: Effect.Effect<A, E>, label: string): Promise<A> {
  return runCauseEffect(
    work.pipe(
      Effect.timeoutOrElse({ duration: 15_000, orElse: () => Effect.die(new Error(`Fixture deadline: ${label}.`)) }),
    ),
  );
}
async function waitFor<T>(name: string, read: () => T | false | null | undefined): Promise<T> {
  const deadline = Date.now() + 15_000;
  for (;;) {
    const value = read();
    if (value) return value;
    if (Date.now() >= deadline) throw new Error(`Fixture deadline: ${name}.`);
    await new Promise((done) => setTimeout(done, 25));
  }
}
function protocol(): DynamicRecord[] {
  let content = "";
  try {
    content = readFileSync(protocolLog, "utf8");
  } catch {
    return [];
  }
  assert.ok(content.length < 1_048_576, "Synthetic provider log exceeds its bound.");
  return content
    .split("\n")
    .filter(Boolean)
    .flatMap((line) => {
      const value = JSON.parse(line);
      return isDynamicRecord(value) ? [value] : [];
    });
}
function committed(run: ChannelRoutineRun): boolean {
  return service.channels.committed(`routine:${run.routineId}`, `channel-routine-run:${run.id}`);
}
service.on("event", (event) => {
  if (event.type === "error") errors.push(event.code);
  if (event.type !== "channels-changed" || event.channelId !== CHANNEL_ID || !scheduler || !targetId) return;
  const admission = admissionSnapshot("channel-change");
  if (admission && admissionEvents.length < 200) admissionEvents.push(admission);
  const dueAt = scheduler.nextDueAt();
  if (wakeSamples.length < 200) wakeSamples.push({ dueAt, requestCount: requests().length });
  if (
    dueAt &&
    new Date(dueAt).getTime() <= Date.now() &&
    requests().length === 1 &&
    targetRuns().some((run) => run.kind === "scheduled" && !committed(run))
  )
    sawEligiblePendingWake = true;
});

try {
  await mkdir(fixtureHome, { recursive: true });
  await writeFile(fakeCodex, FAKE_CODEX, { mode: 0o700 });
  await writeFile(hold, "hold this owned synthetic child\n");
  await bounded(service.initialize(), "initialize owned service");
  const create = async (name: string) => {
    const agent = await bounded(
      service.createAgent({
        name,
        description: "Synthetic routine fixture",
        avatarSeed: name.toLowerCase().replaceAll(" ", "-"),
        avatarHue: null,
        initialMessage: "Hello.",
      }),
      "create synthetic agent",
    );
    await waitFor(`${name} initial turn`, () =>
      service
        .listQueue(agent.id)
        .deliveries.every((delivery) => !["queued", "starting", "running"].includes(delivery.status)),
    );
    return agent;
  };
  const lead = await create("Scheduler Lead"),
    worker = await create("Scheduler Worker");
  await writeFile(fixtureConfig, JSON.stringify({ workerId: worker.id }));
  await bounded(
    service.channels.command(
      {
        type: "save",
        operationId: "create-synthetic-channel",
        channelId: CHANNEL_ID,
        draft: {
          name: "Deferred routine",
          title: "Synthetic channel",
          instructions: "Synthetic fixture only.",
          members: [{ agentId: lead.id }, { agentId: worker.id }],
          leadAgentId: lead.id,
        },
      },
      ACTOR,
    ),
    "create synthetic channel",
  );
  scheduler = owner();
  const base = Math.ceil(Date.now() / 60_000) * 60_000 + 10 * 60_000;
  const createRoutine = (name: string, instruction: string, at: number) => {
    const date = new Date(at).toISOString();
    assert.ok(scheduler);
    return scheduler.create({
      channelId: CHANNEL_ID,
      name,
      instruction,
      active: true,
      timezone: "UTC",
      schedule: { kind: "once", date: date.slice(0, 10), time: date.slice(11, 16) },
      missedPolicy: "run-once",
      limitPolicy: "wait",
    });
  };
  const routine = createRoutine("Target", TARGET, base);
  targetId = routine.id;
  const unrelated = createRoutine("Unrelated", "ROUTINE-DEFERRED-UNRELATED", base + 60_000);
  const manual = await bounded(scheduler.test({ channelId: CHANNEL_ID, routineId: targetId }), "start manual run");
  await waitFor("live manual root and child", () => {
    const tasks = taskRows(),
      rootTask = tasks.find((task) => task.requestMessageId === manual.requestMessageId && task.parentTaskId === null);
    return (
      rootTask?.state === "waiting" &&
      rootTask.dependencies.length === 1 &&
      tasks.some((task) => task.parentTaskId === rootTask.id && task.state === "running")
    );
  });
  const before = taskRows().filter((task) => task.requestMessageId === manual.requestMessageId);
  const assignmentsBefore = service.channels.store
    .assignments(CHANNEL_ID)
    .filter((assignment) => assignment.requestMessageId === manual.requestMessageId);
  observations.manualTaskCount = before.length;
  await bounded(scheduler.processDue(new Date(base + 120_000)), "process due runs");
  observations.afterDue = {
    runs: targetRuns().length,
    requests: requests().length,
    active: runs.get(CHANNEL_ID, targetId)?.active,
  };
  pass("The one-time occurrence retains its durable queued run behind a live manual run", targetRuns().length === 2);
  const scheduled = targetRuns().find((run) => run.kind === "scheduled");
  assert.ok(scheduled);
  pass("The pending run has no channel request or receipt", requests().length === 1 && !committed(scheduled));
  pass(
    "Admission consumes only the one-time trigger",
    runs.get(CHANNEL_ID, targetId)?.active === false && scheduled.status === "queued",
  );
  await waitFor("later unrelated routine result", () => results(UNRELATED_RESULT).length === 1);
  pass("The pending run does not block another due routine", runs.listRuns(CHANNEL_ID, unrelated.id).length === 1);
  assert.deepEqual(
    taskRows().filter((task) => task.requestMessageId === manual.requestMessageId),
    before,
  );
  assert.deepEqual(
    service.channels.store
      .assignments(CHANNEL_ID)
      .filter((assignment) => assignment.requestMessageId === manual.requestMessageId),
    assignmentsBefore,
  );
  checks.push("An overlapping occurrence leaves the root, child, dependencies and assignments unchanged");
  for (const fresh of [false, true]) {
    if (fresh) scheduler = owner();
    await bounded(scheduler.resumePendingRuns(), "resume pending runs");
    await bounded(scheduler.processDue(new Date(base + 120_000)), "process due runs");
    assert.deepEqual(
      taskRows().filter((task) => task.requestMessageId === manual.requestMessageId),
      before,
    );
    assert.deepEqual(
      service.channels.store
        .assignments(CHANNEL_ID)
        .filter((assignment) => assignment.requestMessageId === manual.requestMessageId),
      assignmentsBefore,
    );
    pass(
      `${fresh ? "Fresh" : "Original"} scheduler replay defers the pending request`,
      requests().length === 1 && !committed(scheduled),
    );
    pass(
      `${fresh ? "Fresh" : "Original"} scheduler does not spin on committed or blocked queued rows`,
      scheduler.nextDueAt() === null,
    );
  }
  pass(
    "The overlap does not interrupt a provider turn",
    !protocol().some((entry) => entry.method === "turn/interrupt"),
  );
  await rm(hold);
  await waitFor(
    "normal child, manual root, and scheduled result",
    () =>
      results(CHILD_RESULT).length === 1 &&
      results(MANUAL_RESULT).length === 1 &&
      results(SCHEDULED_RESULT).length === 1 &&
      targetRuns().every((run) => run.status === "succeeded"),
  );
  observations.final = {
    runs: targetRuns().length,
    requests: requests().length,
    manualResults: results(MANUAL_RESULT).length,
    childResults: results(CHILD_RESULT).length,
    scheduledResults: results(SCHEDULED_RESULT).length,
    statuses: targetRuns().map((run) => ({ kind: run.kind, status: run.status })),
    sawEligiblePendingWake,
  };
  pass("Normal completion makes the pending request eligible through changed/reconcile/arm", sawEligiblePendingWake);
  pass(
    "The one-time occurrence completes exactly once",
    requests().length === 2 && results(SCHEDULED_RESULT).length === 1 && committed(scheduled),
  );
  pass(
    "The manual run and child complete exactly once",
    results(MANUAL_RESULT).length === 1 && results(CHILD_RESULT).length === 1,
  );
  pass(
    "Both durable runs succeed through actual task completion",
    targetRuns().length === 2 && targetRuns().every((run) => run.status === "succeeded"),
  );
  scheduler = owner();
  await bounded(scheduler.resumePendingRuns(), "resume pending runs");
  await bounded(scheduler.processDue(new Date(base + 120_000)), "process due runs");
  pass(
    "Fresh-owner recovery after completion creates no request or result duplicate",
    requests().length === 2 && results(SCHEDULED_RESULT).length === 1,
  );
  pass("Completed durable work needs no pending wake", scheduler.nextDueAt() === null);
  assert.equal(database.connection.prepare("PRAGMA quick_check").get()?.quick_check, "ok");
  assert.deepEqual(errors, []);
  passed = true;
} catch (error) {
  failure = redactText(error instanceof Error ? (error.stack ?? error.message) : String(error));
} finally {
  try {
    await bounded(service.stop(), "stop owned service");
    stopped = true;
  } catch (error) {
    passed = false;
    failure = redactText(`Service stop failed: ${String(error)}`);
  }
  for (const client of clients) await bounded(client.stop(), "stop owned provider client");
  database.close();
  observations.protocolTurns = protocol().filter((entry) => entry.method === "turn/start").length;
  observations.wakeSamples = wakeSamples;
  await writeFile(
    join(OUT, "synthetic-provider.jsonl"),
    `${protocol()
      .map((entry) => redactText(JSON.stringify(entry)))
      .join("\n")}\n`,
  );
  await rm(root, { recursive: true, force: true });
  const sources = [
    "scripts/channel-routine-deferred-overlap-e2e.ts",
    "src/backend/channel-routine-scheduler.ts",
    "src/backend/channel-service.ts",
    "src/backend/agent-service.ts",
    "src/backend/routine-timer.ts",
  ];
  const sourceSHA256 = Object.fromEntries(
    await Promise.all(
      sources.map(
        async (path) =>
          [
            path,
            createHash("sha256")
              .update(await readFile(join(ROOT, path)))
              .digest("hex"),
          ] as const,
      ),
    ),
  );
  await writeFile(
    join(OUT, "report.json"),
    `${JSON.stringify(
      {
        passed,
        fixtureReady: observations.manualTaskCount === 2,
        failure,
        checks,
        observations,
        admissionEvents,
        sourceSHA256,
        authoringGate: {
          behavior: "A deferred one-time run preserves live subtasks and resumes exactly once after normal completion.",
          credibleRegression:
            "Dropping the occurrence, dispatching identical text into the live run, or failing to wake durable pending work.",
          distinctOwner:
            "Due-list/crash E2E holds queued work and cannot prove actual dependency preservation and task completion.",
          productionTestSeam: false,
        },
        limits: [
          "Real owner services and provider protocol parser, with an isolated synthetic provider; no real account, model quality or network claim.",
          "Fresh scheduler instances share the same real service and SQLite file; this case does not restart the full process.",
        ],
        cleanup: {
          serviceStopped: stopped,
          providerClientsStopped: [...clients].every((client) => !client.running),
          temporaryProfileRemoved: true,
        },
      },
      null,
      2,
    )}\n`,
  );
  process.stdout.write(
    `${JSON.stringify({ passed, checks: checks.length, report: join(OUT, "report.json"), failure })}\n`,
  );
  if (!passed) process.exitCode = 1;
}
