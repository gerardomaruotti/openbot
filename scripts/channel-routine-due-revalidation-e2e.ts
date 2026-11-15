// Runs the real channel scheduler, SQLite stores, mailbox and ChannelService on private temporary
// profiles. A normal channel changed notification mutates the next due candidate after the first
// request commits. The scheduler must use current saved intent, not its old candidate list.
// Owned crash children stop only after real database commits, then the parent reopens the same DB.
// This proves durable channel dispatch, not provider execution or an answered user task. No model,
// account, network, personal routine or production profile is used.
//
// bun scripts/channel-routine-due-revalidation-e2e.ts --out .openbot-build/<owned-output-folder>
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve, sep } from "node:path";
import type { DatabaseSync } from "node:sqlite";
import type { ChannelRoutine, ChannelRoutineRun, RoutineSchedule } from "@openbot/contracts/ipc";
import { isDynamicRecord, isString } from "@openbot/contracts/runtime-values";
import { redactText } from "@openbot/logging";
import { Effect } from "effect";
import { AgentStore } from "../src/backend/agent-store";
import { ChannelImages } from "../src/backend/channel-images";
import { ChannelRoutineScheduler } from "../src/backend/channel-routine-scheduler";
import { ChannelRoutineStore } from "../src/backend/channel-routine-store";
import { ChannelService } from "../src/backend/channel-service";
import type { OrchestrationEventInput } from "../src/backend/database/database-core";
import { runCauseEffect } from "../src/backend/effect-boundary";
import { MailboxStore } from "../src/backend/mailbox-store";
import { OpenBotDatabase } from "../src/backend/openbot-database";

const ROOT = resolve(import.meta.dirname, "..");
const DEADLINE_MS = 15_000;
const CRASH_EXIT = 86;
const OUTPUT_LIMIT = 128 * 1024;
const CHANNEL_ID = "synthetic-channel-schedule";
const ACTOR = { id: "synthetic-owner", name: "Synthetic owner" };
type ScheduleKind = "cron" | "once";
type Mutation = "pause" | "delete" | "reschedule" | "replace" | "edit" | "skip" | "wait" | "unchanged";
type Barrier = "trigger-completed" | "run-created" | "request-committed";

interface Fixture {
  database: OpenBotDatabase;
  agents: AgentStore;
  channels: ChannelService;
  scheduler: ChannelRoutineScheduler;
  runs: ChannelRoutineStore;
  errors: string[];
  limited: Set<string>;
  onChannelChanged: (() => void) | null;
  close(): Promise<void>;
}
interface Seed {
  first: ChannelRoutine;
  target: ChannelRoutine;
  last: ChannelRoutine;
  now: Date;
  future: Date;
}
interface CaseResult {
  name: string;
  passed: boolean;
  observed?: unknown;
  failure?: string;
}
const results: CaseResult[] = [];
const ownedRoots = new Set<string>();
const children = new Set<ChildProcess>();

async function within<T>(work: Promise<T>, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      work,
      new Promise<never>((_done, fail) => {
        timer = setTimeout(() => fail(new Error(`Fixture deadline: ${label}.`)), DEADLINE_MS);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function stopChild(child: ChildProcess): Promise<void> {
  if (!children.has(child)) return;
  const stopped = new Promise<void>((done) => child.once("close", () => done()));
  child.kill("SIGKILL");
  await within(stopped, "stop owned crash child");
  children.delete(child);
}

async function newRoot(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "openbot-channel-due-"));
  ownedRoots.add(root);
  await writeFile(join(root, "owned-fixture"), "openbot-channel-due-v1\n");
  return root;
}

/** A fault after the true committed transaction; it never supplies database results. */
class CrashBarrierDatabase extends OpenBotDatabase {
  afterCommit: ((events: readonly OrchestrationEventInput[]) => void) | null = null;

  override dispatch<T>(
    commandId: string,
    events: OrchestrationEventInput[],
    project: (db: DatabaseSync, sequences: number[]) => T,
  ): T {
    const value = super.dispatch(commandId, events, project);
    this.afterCommit?.(events);
    return value;
  }
}

async function openFixture(root: string, database = new OpenBotDatabase(join(root, "state"))): Promise<Fixture> {
  const agents = new AgentStore(join(root, "state"), join(root, "home"), database);
  const mailbox = new MailboxStore(join(root, "state"), agents.sharedRoot, database);
  await runCauseEffect(agents.initialize());
  await runCauseEffect(mailbox.initialize());
  const agent =
    agents.list().find((candidate) => candidate.name === "Schedule Fixture") ??
    (await runCauseEffect(
      agents.createAgent({
        name: "Schedule Fixture",
        description: "Synthetic schedule fixture",
        avatarSeed: "channel-due",
        avatarHue: null,
      }),
    ));
  const errors: string[] = [];
  const limited = new Set<string>();
  let notify: (() => void) | null = null;
  const channels = new ChannelService(database, mailbox, new ChannelImages(join(root, "channel-images")), {
    agents: () => agents.list(),
    generate: () => Effect.die(new Error("No model runs in the channel scheduling fixture.")),
    schedule: () => {},
    interrupt: () => Effect.void,
    // The dispatch is real, but provider execution belongs to a different E2E owner.
    busy: () => true,
    changed: () => notify?.(),
    error: (error) => errors.push(error instanceof Error ? error.message : String(error)),
  });
  const scheduler = new ChannelRoutineScheduler({
    channels,
    hooks: {
      changed: () => {},
      emitError: (code) => errors.push(code),
      excludedChannels: () => new Set(),
      usageLimited: (channelId) => limited.has(channelId),
    },
  });
  if (!channels.store.exists(CHANNEL_ID)) {
    await runCauseEffect(
      channels.command(
        {
          type: "save",
          operationId: "fixture-create-channel",
          channelId: CHANNEL_ID,
          draft: {
            name: "Schedule fixture",
            title: "Synthetic channel",
            instructions: "Synthetic instructions",
            members: [{ agentId: agent.id }],
            leadAgentId: agent.id,
          },
        },
        ACTOR,
      ),
    );
  }
  return {
    database,
    agents,
    channels,
    scheduler,
    runs: new ChannelRoutineStore(database),
    errors,
    limited,
    get onChannelChanged() {
      return notify;
    },
    set onChannelChanged(value) {
      notify = value;
    },
    async close() {
      notify = null;
      try {
        await within(runCauseEffect(channels.stop()), "stop fixture");
      } finally {
        database.close();
      }
    },
  };
}

function schedule(kind: ScheduleKind, at: Date): RoutineSchedule {
  return kind === "once"
    ? { kind: "once", date: at.toISOString().slice(0, 10), time: at.toISOString().slice(11, 16) }
    : { kind: "custom", expression: `${at.getUTCMinutes()} ${at.getUTCHours()} * * *` };
}

function seed(fixture: Fixture, kind: ScheduleKind, mutation: Mutation): Seed {
  const base = Math.ceil(Date.now() / 60_000) * 60_000 + 10 * 60_000;
  const create = (name: string, at: Date, type: ScheduleKind, limitPolicy: "wait" | "skip" = "wait") =>
    fixture.scheduler.create({
      channelId: CHANNEL_ID,
      name,
      instruction: `@Schedule Fixture Synthetic ${name}`,
      active: true,
      timezone: "UTC",
      schedule: schedule(type, at),
      limitPolicy,
      missedPolicy: "run-once",
    });
  return {
    first: create("First", new Date(base), "once"),
    target: create("Target", new Date(base + 60_000), kind, mutation === "wait" ? "skip" : "wait"),
    last: create("Last", new Date(base + 120_000), "once"),
    now: new Date(base + 180_000),
    future: new Date(base + 10 * 60_000),
  };
}

function requests(fixture: Fixture, routine: Pick<ChannelRoutine, "id">) {
  return fixture.channels.store
    .messages(CHANNEL_ID)
    .filter((entry) => entry.author.kind === "member" && entry.author.id === `routine:${routine.id}`);
}
function runs(fixture: Fixture, routine: Pick<ChannelRoutine, "id">): ChannelRoutineRun[] {
  return fixture.runs.listRuns(CHANNEL_ID, routine.id, 50, true);
}
function requireCommitted(fixture: Fixture, run: ChannelRoutineRun): void {
  assert.ok(run.requestMessageId, "The durable run needs its request identity.");
  assert.equal(
    fixture.channels.committed(`routine:${run.routineId}`, `channel-routine-run:${run.id}`),
    true,
    "The real channel dispatch must commit its retry receipt.",
  );
  const request = fixture.channels.store.message(CHANNEL_ID, run.requestMessageId);
  assert.ok(request, "The committed request must be in durable channel history.");
  assert.equal(request.message.text, run.instruction);
  assert.equal(request.author.id, `routine:${run.routineId}`);
  assert.ok(
    fixture.channels.store.tasks(CHANNEL_ID).some((task) => task.requestMessageId === run.requestMessageId),
    "The real command must create the request's channel task.",
  );
}
function integrity(fixture: Fixture): void {
  assert.equal(fixture.database.connection.prepare("PRAGMA quick_check").get()?.quick_check, "ok");
  assert.deepEqual(fixture.errors, []);
}

async function raceCase(kind: ScheduleKind, mutation: Mutation, result: CaseResult): Promise<void> {
  const fixture = await openFixture(await newRoot());
  try {
    const saved = seed(fixture, kind, mutation);
    let changed = false;
    fixture.onChannelChanged = () => {
      if (changed || requests(fixture, saved.first).length !== 1) return;
      changed = true;
      assert.equal(runs(fixture, saved.target).length, 0, "The change precedes the target's run.");
      const id = { channelId: CHANNEL_ID, routineId: saved.target.id };
      if (mutation === "pause") fixture.scheduler.update({ ...id, active: false });
      else if (mutation === "delete") fixture.scheduler.delete(id);
      else if (mutation === "reschedule" || mutation === "replace") {
        const at = mutation === "replace" ? new Date(saved.target.trigger.nextRunAt) : saved.future;
        const current = fixture.scheduler.update({ ...id, schedule: schedule(kind, at) });
        assert.notEqual(current.trigger.id, saved.target.trigger.id);
        if (mutation === "reschedule") assert.equal(current.trigger.nextRunAt, saved.future.toISOString());
      } else if (mutation === "edit") {
        fixture.scheduler.update({ ...id, name: "Current name", instruction: "@Schedule Fixture Current instruction" });
      } else if (mutation === "skip" || mutation === "wait") {
        fixture.scheduler.update({ ...id, limitPolicy: mutation });
        fixture.limited.add(CHANNEL_ID);
      }
    };
    let passFailure: string | null = null;
    try {
      await within(runCauseEffect(fixture.scheduler.processDue(saved.now)), "due candidate pass");
    } catch (error) {
      passFailure = error instanceof Error ? error.message : String(error);
    }
    fixture.onChannelChanged = null;
    const targetRuns = runs(fixture, saved.target),
      targetRequests = requests(fixture, saved.target);
    result.observed = {
      changed,
      passFailure,
      firstRequests: requests(fixture, saved.first).length,
      targetRuns: targetRuns.length,
      targetRequests: targetRequests.length,
      targetNames: targetRuns.map((run) => run.routineName),
      targetTexts: targetRequests.map((entry) => entry.message.text),
      lastRequests: requests(fixture, saved.last).length,
    };
    assert.equal(changed, true, "A real first request commit must trigger the competing change.");
    assert.equal(passFailure, null, "A changed/deleted candidate must not abort the rest of the due pass.");
    assert.equal(requests(fixture, saved.first).length, 1);
    assert.equal(requests(fixture, saved.last).length, 1, "Later unaffected work must still dispatch once.");
    if (kind === "once" && (mutation === "skip" || mutation === "wait")) {
      assert.equal(
        fixture.scheduler.list(CHANNEL_ID).find((routine) => routine.id === saved.target.id)?.limitPolicy,
        "wait",
      );
    }
    const suppressed =
      ["pause", "delete", "reschedule", "replace"].includes(mutation) || (mutation === "skip" && kind !== "once");
    assert.equal(targetRuns.length, suppressed ? 0 : 1, "Only the current saved occurrence may make a run.");
    assert.equal(
      targetRequests.length,
      suppressed ? 0 : 1,
      "A paused/replaced/future/skipped candidate must not post.",
    );
    if (mutation === "edit") {
      assert.equal(targetRuns[0]?.routineName, "Current name");
      assert.equal(targetRequests[0]?.message.text, "@Schedule Fixture Current instruction");
    }
    for (const run of [...runs(fixture, saved.first), ...targetRuns, ...runs(fixture, saved.last)])
      requireCommitted(fixture, run);
    const replacementTrigger =
      mutation === "replace" ? fixture.runs.get(CHANNEL_ID, saved.target.id)?.trigger.id : null;
    await runCauseEffect(fixture.scheduler.processDue(saved.now));
    await runCauseEffect(fixture.scheduler.resumePendingRuns());
    await runCauseEffect(fixture.scheduler.resumePendingRuns());
    assert.equal(requests(fixture, saved.first).length, 1);
    assert.equal(requests(fixture, saved.last).length, 1);
    assert.equal(
      requests(fixture, saved.target).length,
      mutation === "replace" ? 1 : suppressed ? 0 : 1,
      "Recovery must not duplicate requests; a fresh due replacement must dispatch once.",
    );
    if (replacementTrigger) {
      const replacementRuns = runs(fixture, saved.target);
      assert.equal(replacementRuns.length, 1);
      const replacementRun = replacementRuns[0];
      assert.ok(replacementRun);
      assert.equal(replacementRun.triggerId, replacementTrigger);
      requireCommitted(fixture, replacementRun);
    }
    integrity(fixture);
  } finally {
    await fixture.close();
  }
}

async function crashChild(root: string, barrier: Barrier): Promise<never> {
  // A child may open only a root made by this fixture family, not an arbitrary user profile.
  assert.ok(resolve(root).startsWith(`${resolve(tmpdir()) + sep}openbot-channel-due-`));
  assert.equal(await readFile(join(root, "owned-fixture"), "utf8"), "openbot-channel-due-v1\n");
  const database = new CrashBarrierDatabase(join(root, "state"));
  const fixture = await openFixture(root, database);
  const saved = seed(fixture, "once", "unchanged");
  await writeFile(
    join(root, "seed.json"),
    JSON.stringify({
      routineId: saved.first.id,
      due: saved.first.trigger.nextRunAt,
      now: saved.now.toISOString(),
      barrier,
    }),
  );
  if (barrier === "request-committed") {
    fixture.onChannelChanged = () => {
      if (requests(fixture, saved.first).length === 1) process.exit(CRASH_EXIT);
    };
  } else {
    database.afterCommit = (events) => {
      if (
        events.some((event) => event.aggregateId === saved.first.id && event.eventType === `channel-routine.${barrier}`)
      )
        process.exit(CRASH_EXIT);
    };
  }
  await runCauseEffect(fixture.scheduler.processDue(saved.now));
  throw new Error(`Crash barrier was not reached: ${barrier}.`);
}

async function crashRecovery(barrier: Barrier, result: CaseResult): Promise<void> {
  const root = await newRoot();
  const child = spawn(process.execPath, [import.meta.filename, "--crash-child", root, barrier], {
    cwd: ROOT,
    env: { PATH: process.env.PATH, TMPDIR: tmpdir() },
    stdio: ["ignore", "pipe", "pipe"],
  });
  children.add(child);
  let output = "";
  const capture = (chunk: Buffer) => {
    output += chunk.toString("utf8");
    if (Buffer.byteLength(output) > OUTPUT_LIMIT) {
      child.kill("SIGKILL");
      output = "Owned child output exceeded its bound.";
    }
  };
  child.stdout?.on("data", capture);
  child.stderr?.on("data", capture);
  let exit: number | null;
  try {
    exit = await within(
      new Promise<number | null>((done, fail) => {
        child.once("error", fail);
        child.once("close", (code) => {
          children.delete(child);
          done(code);
        });
      }),
      "owned crash child",
    );
  } finally {
    await stopChild(child);
  }
  assert.equal(exit, CRASH_EXIT, output.slice(0, 8192));
  const value = JSON.parse(await readFile(join(root, "seed.json"), "utf8"));
  assert.ok(isDynamicRecord(value) && isString(value.routineId) && isString(value.due) && isString(value.now));
  const fixture = await openFixture(root);
  try {
    const target = { id: value.routineId };
    const before = runs(fixture, target);
    const initial = {
      barrier,
      beforeRuns: before.length,
      beforeRequests: requests(fixture, target).length,
      activeBefore: fixture.runs.get(CHANNEL_ID, target.id)?.active,
    };
    result.observed = initial;
    assert.equal(before.length, 1, "A consumed one-time trigger must retain one recoverable durable run.");
    fixture.scheduler.skipMissed(new Date(value.now));
    await runCauseEffect(fixture.scheduler.resumePendingRuns());
    await runCauseEffect(fixture.scheduler.resumePendingRuns());
    await runCauseEffect(fixture.scheduler.processDue(new Date(value.now)));
    const after = runs(fixture, target);
    result.observed = { ...initial, afterRuns: after.length, afterRequests: requests(fixture, target).length };
    assert.equal(after.length, 1);
    assert.equal(after[0]?.id, before[0]?.id, "Recovery must retain the original run identity.");
    assert.equal(requests(fixture, target).length, 1, "Crash recovery must dispatch exactly one request.");
    const [run] = after;
    assert.ok(run);
    requireCommitted(fixture, run);
    assert.equal(fixture.runs.get(CHANNEL_ID, target.id)?.active, false);
    integrity(fixture);
  } finally {
    await fixture.close();
  }
}

const childFlag = process.argv.indexOf("--crash-child");
if (childFlag >= 0) {
  const root = process.argv[childFlag + 1],
    barrier = process.argv[childFlag + 2];
  assert.ok(root && (barrier === "trigger-completed" || barrier === "run-created" || barrier === "request-committed"));
  await crashChild(root, barrier);
} else {
  const outFlag = process.argv.indexOf("--out");
  const OUT = resolve(
    outFlag >= 0
      ? (process.argv[outFlag + 1] ?? "")
      : join(ROOT, ".openbot-build/reliability-2026-11-15/channel-scheduler-e2e"),
  );
  assert.ok(
    OUT.startsWith(resolve(ROOT, ".openbot-build") + sep),
    "Output must stay in this repository's ignored build folder.",
  );
  await mkdir(OUT, { recursive: true });
  const runCase = async (name: string, operation: (result: CaseResult) => Promise<void>) => {
    const result: CaseResult = { name, passed: false };
    try {
      await operation(result);
      result.passed = true;
    } catch (error) {
      result.failure = redactText(error instanceof Error ? error.message : String(error));
    }
    results.push(result);
  };
  try {
    for (const kind of ["cron", "once"] satisfies ScheduleKind[]) {
      for (const mutation of ["pause", "delete", "reschedule", "replace", "edit", "unchanged"] satisfies Mutation[]) {
        await runCase(`${kind} current ${mutation}`, (result) => raceCase(kind, mutation, result));
      }
    }
    for (const kind of ["cron", "once"] satisfies ScheduleKind[])
      for (const mutation of ["skip", "wait"] satisfies Mutation[])
        await runCase(`${kind} current ${mutation} policy`, (result) => raceCase(kind, mutation, result));
    for (const barrier of ["trigger-completed", "run-created", "request-committed"] satisfies Barrier[])
      await runCase(`one-time crash after ${barrier}`, (result) => crashRecovery(barrier, result));
  } finally {
    for (const child of children) await stopChild(child);
    for (const root of ownedRoots) await rm(root, { recursive: true, force: true });
    const sources = [
      "scripts/channel-routine-due-revalidation-e2e.ts",
      "src/backend/channel-routine-scheduler.ts",
      "src/backend/channel-routine-store.ts",
      "src/backend/routine-store.ts",
      "src/backend/channel-service.ts",
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
    const passed = results.length === 19 && results.every((item) => item.passed);
    await writeFile(
      join(OUT, "report.json"),
      `${JSON.stringify(
        {
          passed,
          sourceSHA256,
          results,
          authoringGate: {
            behavior: "Current routine intent and durable exactly-once channel dispatch across a crash.",
            credibleRegression: "Stale due snapshots and consuming a one-time trigger before its run commits.",
            distinctOwner: "Existing due-revalidation E2E covers the agent scheduler, not ChannelRoutineScheduler.",
            productionTestSeam: false,
          },
          limits: [
            "Real channel scheduler, SQLite, ChannelService command and retry receipt; no provider execution or answered-task claim.",
            "Private temporary fixture only. Busy agents keep dispatched work queued, so no model, real routine, account, network or user data is used.",
          ],
          cleanup: { ownedChildrenStopped: children.size === 0, ownedTemporaryProfilesRemoved: true },
        },
        null,
        2,
      )}\n`,
    );
    process.stdout.write(
      `${JSON.stringify({
        passed,
        cases: results.length,
        failed: results.filter((item) => !item.passed).map((item) => item.name),
        report: join(OUT, "report.json"),
      })}\n`,
    );
    if (!passed) process.exitCode = 1;
  }
}
