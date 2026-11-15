import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import {
  isBrowserTakeoverRequest,
  isClientAgentModelOption,
  isClientAgentSummary,
  isRoutine,
  isRoutineRun,
} from "@openbot/contracts/ipc";
import { isDynamicRecord, isString } from "@openbot/contracts/runtime-values";
import { decodeTeamProtocolV2Json, type TeamProtocolV2Json } from "@openbot/contracts/team-protocol/v2";
import { type Browser, chromium, type Page } from "playwright-core";

// Authoring gate: native UI tests own presentation and touch. This script owns the independent
// Swift/JS DTO adaptation, pre-dispatch revision checks, notification isolation and stream lifetime.
// A dropped gate, truncated result or stale view can pass a positive UI journey but fails here.
// Account, Signal, RTC, AgentService, routine records, attention and BrowserViewGateway are real.
// Only the native bridge adapter, tool-free provider and external local page are substituted.
// No production test seam is required. No email, website, model or personal account is used.
const repository = resolve(import.meta.dirname, "../../..");
const output = join(repository, ".openbot-build/native-ios/assistant-features-e2e");
mkdirSync(output, { recursive: true });
const root = mkdtempSync(join(output, "run-"));
const fixture = join(root, "fixture");
const htmlArgument = process.argv.indexOf("--html");
const htmlPath = htmlArgument >= 0 ? process.argv[htmlArgument + 1] : undefined;
const browserCloseOnly = process.argv.includes("--browser-close");
const recoveryPartialOnly = process.argv.includes("--recovery-partial");
const replyOnly = process.argv.includes("--reply");
const report: {
  passed: boolean;
  status: string;
  root: string;
  bundleSha256?: string;
  inputHtmlSha256?: string;
  scenario: string;
  checks: Array<{ name: string; evidence: Record<string, boolean | number> }>;
  failure?: string;
  cleanup?: { browserClosed: boolean; fixtureExited: boolean };
  limits: string[];
} = {
  passed: false,
  status: "running",
  root,
  scenario: browserCloseOnly ? "browser-close" : recoveryPartialOnly ? "recovery-partial" : replyOnly ? "reply" : "all",
  checks: [],
  limits: [
    "Headless real shared transport, not SwiftUI rendering, VoiceOver, physical device or APNs proof.",
    "Browser DOM uses a labelled local Chromium page, not Electron CDP or a real sign-in.",
    "Host-key persistence is acknowledged by the native adapter; peer authentication and framing remain real.",
    "Owner session exercised; member-role enforcement remains covered by the existing host route tests.",
  ],
};
const save = () => {
  const content = `${JSON.stringify(report, null, 2)}\n`;
  writeFileSync(join(root, "report.json"), content, { mode: 0o600 });
  writeFileSync(join(output, "report.json"), content, { mode: 0o600 });
};
save();
class CheckFailed extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}
function check(value: unknown, code: string): asserts value {
  if (!value) throw new CheckFailed(code);
}
const delay = (milliseconds: number) => new Promise<void>((done) => setTimeout(done, milliseconds));
const child = spawn(process.execPath, ["apps/ios/scripts/simulator/entry.ts", fixture], {
  cwd: repository,
  detached: true,
  stdio: ["ignore", "pipe", "pipe"],
});
let fixtureLog = "",
  fixtureExited = false,
  spawnFailed = false;
child.stdout?.on("data", (data) => {
  fixtureLog += String(data);
});
child.stderr?.on("data", (data) => {
  fixtureLog += String(data);
});
child.once("error", () => {
  spawnFailed = true;
});
const exited = new Promise<void>((done) =>
  child.once("exit", () => {
    fixtureExited = true;
    done();
  }),
);
let browser: Browser | undefined;
let stage = "startup";
async function waitFor<T>(read: () => Promise<T | null>, code: string): Promise<T> {
  const deadline = Date.now() + 45_000;
  while (Date.now() < deadline) {
    check(!spawnFailed && !fixtureExited, "fixture-exited");
    const value = await read();
    if (value !== null) return value;
    await delay(100);
  }
  throw new CheckFailed(code);
}
interface Ready {
  apiURL: string;
  hostId: string;
  agentId: string;
}
interface Reply {
  ok: boolean;
  value?: TeamProtocolV2Json;
  code?: string;
}
type BridgeMessage =
  | { type: "event"; event: TeamProtocolV2Json }
  | { type: "pin"; hostId: string; publicKey: string }
  | { type: "fetch"; url: string; method: string; headers: Record<string, string>; body: string | null };
type BridgeReply = true | { status: number; body: string; headers: Record<string, string> };
interface Frame {
  viewId: string;
  sequence: number;
  width: number;
  height: number;
  valid: boolean;
}
interface Status {
  activeTurnId: string | null;
  queue: { queued: number; starting: number; running: number };
  providerTurns: number;
  pendingBrowserTakeovers: number;
  browserAnswers: Array<{ success: boolean; cancelled: boolean; status: string | null }>;
  routineFaults: {
    secondaryPlaceFailures: number;
    failedPlaceRoutineId: string | null;
    recoveryCreates: Array<{ agentId: string; routineId: string }>;
  };
  browserSurface: {
    secretSubmitted: number;
    secretSubmitAttempts: number;
    secretTakeovers: number;
    viewsStarted: number;
    viewsStopped: number;
    completedTakeovers: number;
    pageClicks: number;
    pageKeys: number;
    pageWheels: number;
    pageTextLength: number;
  };
  features: {
    agents: Array<{
      id: string;
      name: string;
      instructionsLength: number;
      notifications: boolean;
      updatedAt: string | null;
    }>;
    routines: Array<{
      id: string;
      agentId: string;
      name: string;
      active: boolean;
      runIn: string;
      limitPolicy: string;
      missedPolicy: string;
      updatedAt: string;
      runs: Array<{ id: string; status: string; kind: string }>;
    }>;
    preferences: { server: string | null; agents: Array<{ agentId: string; level: string }> };
    reactions: Array<{ id: string; reaction?: string | null }>;
  };
  rpc: Array<{ kind: string; path?: string }>;
}
declare global {
  interface Window {
    nativeAssistantBridge: (message: BridgeMessage) => Promise<BridgeReply>;
    assistantEvents: TeamProtocolV2Json[];
    assistantFrames: Frame[];
    openbotNative: { execute: (command: Record<string, TeamProtocolV2Json>) => Promise<Reply> };
  }
}
function value(reply: Reply, code: string) {
  check(reply.ok && reply.value !== undefined, code);
  return reply.value;
}
function object(data: TeamProtocolV2Json | undefined, code: string) {
  check(isDynamicRecord(data), code);
  return data;
}
function array(data: TeamProtocolV2Json | undefined, code: string) {
  check(Array.isArray(data), code);
  return data;
}
function string(data: unknown, code: string): string {
  check(isString(data), code);
  return data;
}
const call = (page: Page, command: Record<string, TeamProtocolV2Json>): Promise<Reply> =>
  page.evaluate<Reply, string>((input) => window.openbotNative.execute(JSON.parse(input)), JSON.stringify(command));
const count = (status: Status, path: string) =>
  status.rpc.filter((entry) => entry.kind === "request" && entry.path === path).length;

async function nativePage(ready: Ready, source: string): Promise<Page> {
  check(browser, "browser-unavailable");
  const page = await browser.newPage();
  const origin = new URL(ready.apiURL).origin;
  await page.exposeFunction("nativeAssistantBridge", async (message: unknown): Promise<BridgeReply> => {
    check(isDynamicRecord(message), "invalid-native-message");
    if (message.type === "pin" || message.type === "event") return true;
    check(message.type === "fetch" && isString(message.url) && isString(message.method), "invalid-native-fetch");
    const url = new URL(message.url);
    check(url.origin === origin, "nonfixture-native-fetch");
    check(isDynamicRecord(message.headers) && (message.body === null || isString(message.body)), "invalid-native-body");
    const headers = Object.fromEntries(
      Object.entries(message.headers).filter((entry): entry is [string, string] => isString(entry[1])),
    );
    const response = await fetch(url, {
      method: message.method,
      headers,
      ...(message.body === null ? {} : { body: message.body }),
      redirect: "error",
      signal: AbortSignal.timeout(20_000),
    });
    return {
      status: response.status,
      body: await response.text(),
      headers: Object.fromEntries(response.headers.entries()),
    };
  });
  await page.goto(`${origin}/_fixture/host`);
  await page.evaluate(() => {
    window.assistantEvents = [];
    window.assistantFrames = [];
    Object.assign(window, {
      webkit: {
        messageHandlers: {
          openbotNative: {
            postMessage: async (message: BridgeMessage) => {
              if (message.type === "event") {
                const envelope = message.event;
                const event =
                  envelope && typeof envelope === "object" && !Array.isArray(envelope) ? envelope.event : null;
                if (
                  envelope &&
                  typeof envelope === "object" &&
                  !Array.isArray(envelope) &&
                  typeof envelope.hostId === "string" &&
                  event &&
                  typeof event === "object" &&
                  !Array.isArray(event) &&
                  event.type === "native-browser-frame" &&
                  typeof event.viewId === "string" &&
                  typeof event.jpeg === "string" &&
                  typeof event.sequence === "number" &&
                  typeof event.width === "number" &&
                  typeof event.height === "number"
                ) {
                  const bytes = Uint8Array.from(atob(event.jpeg), (character) => character.charCodeAt(0));
                  let valid = false;
                  try {
                    const image = await createImageBitmap(new Blob([bytes], { type: "image/jpeg" }));
                    valid = image.width === event.width && image.height === event.height;
                    image.close();
                  } catch {
                    /* Only boolean image validation is retained. */
                  }
                  window.assistantFrames.push({
                    viewId: event.viewId,
                    sequence: event.sequence,
                    width: event.width,
                    height: event.height,
                    valid,
                  });
                  if (window.assistantFrames.length > 128) window.assistantFrames.shift();
                  // The actual native viewer acknowledges after decoding/drawing, not on receipt.
                  void window.openbotNative.execute({
                    type: "browserSessionFrameDone",
                    hostId: envelope.hostId,
                    viewId: event.viewId,
                    sequence: event.sequence,
                    drawn: valid,
                  });
                } else {
                  window.assistantEvents.push(envelope);
                  if (window.assistantEvents.length > 256) window.assistantEvents.shift();
                }
              }
              return window.nativeAssistantBridge(message);
            },
          },
        },
      },
    });
  });
  await page.addScriptTag({ content: source });
  const response = await fetch(`${origin}/_control/connect-link`, { signal: AbortSignal.timeout(10_000) });
  check(response.ok, "connect-link-refused");
  const link = object(decodeTeamProtocolV2Json(await response.json()), "invalid-connect-link");
  const paired = await call(page, {
    type: "pair",
    link: string(link.url, "missing-connect-url").replace("openbot-native-simulator:", "openbot:"),
    deviceId: randomUUID(),
  });
  check(paired.ok, "pair-refused");
  const hosts = array(value(await call(page, { type: "hosts" }), "hosts-refused"), "invalid-hosts");
  check(
    hosts.some((host) => isDynamicRecord(host) && host.hostId === ready.hostId),
    "host-not-discovered",
  );
  check((await call(page, { type: "connect", hostId: ready.hostId })).ok, "connect-refused");
  return page;
}

try {
  const ready = await waitFor(async (): Promise<Ready | null> => {
    try {
      const data = decodeTeamProtocolV2Json(JSON.parse(readFileSync(join(fixture, "ready.json"), "utf8")));
      return isDynamicRecord(data) && isString(data.apiURL) && isString(data.hostId) && isString(data.agentId)
        ? { apiURL: data.apiURL, hostId: data.hostId, agentId: data.agentId }
        : null;
    } catch {
      return null;
    }
  }, "fixture-not-ready");
  const status = async (): Promise<Status> => {
    const response = await fetch(`${ready.apiURL}/_control/status`, { signal: AbortSignal.timeout(10_000) });
    check(response.ok, "status-refused");
    return response.json();
  };
  const candidates = [
    process.env.OPENBOT_NATIVE_CHROME,
    join(
      homedir(),
      "Library/Caches/ms-playwright/chromium_headless_shell-1248/chrome-headless-shell-mac-arm64/chrome-headless-shell",
    ),
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  ].filter(isString);
  const executablePath = candidates.find(existsSync);
  check(executablePath, "chrome-unavailable");
  browser = await chromium.launch({ executablePath, headless: true });
  check([browserCloseOnly, recoveryPartialOnly, replyOnly].filter(Boolean).length <= 1, "select-one-focused-scenario");
  let source: string;
  if (htmlArgument >= 0) {
    check(htmlPath, "missing-html-path");
    const html = readFileSync(resolve(htmlPath), "utf8");
    const script = html.match(/<script>([\s\S]*)<\/script>/u)?.[1];
    check(script, "html-script-missing");
    source = script;
    report.inputHtmlSha256 = createHash("sha256").update(html).digest("hex");
  } else {
    const build = await Bun.build({
      entrypoints: [join(repository, "apps/ios/Transport/team-peer.ts")],
      target: "browser",
      format: "iife",
      minify: true,
      define: { "process.env.NODE_ENV": JSON.stringify("production") },
      plugins: [
        {
          name: "native-check-without-translations",
          setup(builder) {
            builder.onLoad({ filter: /packages[\\/]i18n[\\/]src[\\/]source-catalogs\.ts$/ }, () => ({
              contents: "export function sourceTranslation(){return undefined;}",
              loader: "ts",
            }));
          },
        },
      ],
    });
    check(build.success && build.outputs[0], "bundle-failed");
    source = await build.outputs[0].text();
  }
  writeFileSync(join(root, "team-peer.js"), source, { mode: 0o600 });
  report.bundleSha256 = createHash("sha256").update(source).digest("hex");
  const page = await nativePage(ready, source);
  const run = async (type: string, fields: Record<string, TeamProtocolV2Json> = {}) => {
    const reply = await call(page, { type, hostId: ready.hostId, ...fields });
    return value(reply, `${type}-refused-${reply.code ?? "missing-result"}`);
  };
  const agents = async () => array(object(await run("agents"), "invalid-roster").agents, "invalid-agents");
  const agent = async (id: string) => {
    const found = (await agents()).find((item) => isDynamicRecord(item) && item.id === id);
    check(isClientAgentSummary(found) && isDynamicRecord(found), "agent-not-found");
    return found;
  };
  const history = async (agentId: string) => object(await run("history", { agentId }), "invalid-history");
  const send = async (text: string) => {
    await page.evaluate(() => {
      window.assistantEvents = [];
    });
    await run("send", { agentId: ready.agentId, text, clientMessageId: randomUUID(), timezone: "Europe/Rome" });
  };
  const settled = () =>
    waitFor(async () => {
      const state = await status();
      return state.activeTurnId === null &&
        state.pendingBrowserTakeovers === 0 &&
        state.queue.queued === 0 &&
        state.queue.starting === 0 &&
        state.queue.running === 0
        ? state
        : null;
    }, "turn-not-settled");
  const handoff = (kind: "secret" | "interactive" | "reload" = "secret") =>
    waitFor(async () => {
      const events = await page.evaluate(() => window.assistantEvents);
      for (const envelope of events.toReversed()) {
        if (
          !isDynamicRecord(envelope) ||
          envelope.type !== "team" ||
          envelope.hostId !== ready.hostId ||
          !isDynamicRecord(envelope.event)
        )
          continue;
        const event = envelope.event;
        const requests =
          event.type === "browser-takeover-requested"
            ? [event.request]
            : event.type === "runtime-snapshot" &&
                isDynamicRecord(event.snapshot) &&
                Array.isArray(event.snapshot.pendingBrowserTakeovers)
              ? event.snapshot.pendingBrowserTakeovers
              : [];
        const request = requests.find(
          (item) =>
            isBrowserTakeoverRequest(item) &&
            item.agentId === ready.agentId &&
            (kind === "reload"
              ? item.secret?.requiresReload === true
              : kind === "interactive"
                ? item.secret === undefined
                : item.secret !== undefined && item.secret.requiresReload !== true),
        );
        if (isBrowserTakeoverRequest(request)) return decodeTeamProtocolV2Json(request);
      }
      return null;
    }, "browser-request-missing");

  const closePendingView = async (request: TeamProtocolV2Json): Promise<string> => {
    stage = "browser-close-during-pending-open";
    const cancelledView = "assistant-cancelled-pending";
    const replacementView = "assistant-browser-dom";
    const before = (await status()).browserSurface;
    const openAndClose = (openingView: string, closingView: string) =>
      page.evaluate<{ opened: Reply; closed: Reply }, string>(
        async (serialized) => {
          const input: {
            hostId: string;
            openingView: string;
            closingView: string;
            browserTakeover: TeamProtocolV2Json;
          } = JSON.parse(serialized);
          // execute starts synchronously, then awaits its real attention read. Close this view in that
          // same JavaScript turn, before the read can complete. No timeout or mocked snapshot is used.
          const opening = window.openbotNative.execute({
            type: "browserSessionOpen",
            hostId: input.hostId,
            viewId: input.openingView,
            browserTakeover: input.browserTakeover,
          });
          const closed = await window.openbotNative.execute({
            type: "browserSessionClose",
            hostId: input.hostId,
            viewId: input.closingView,
          });
          return { opened: await opening, closed };
        },
        JSON.stringify({ hostId: ready.hostId, openingView, closingView, browserTakeover: request }),
      );
    const result = await openAndClose(cancelledView, cancelledView);
    const after = (await status()).browserSurface;
    const cancelledFrames = (await page.evaluate(() => window.assistantFrames)).filter(
      (item) => item.viewId === cancelledView,
    );
    const evidence = {
      closeAccepted: result.closed.ok,
      pendingOpenRefused: !result.opened.ok && result.opened.code === "sendFailed",
      hostViewsOpened: after.viewsStarted - before.viewsStarted,
      cancelledFrames: cancelledFrames.length,
      cancelledInputRefused: false,
      replacementSurvivedLateClose: false,
    };
    report.checks.push({ name: "close-during-pending-browser-open", evidence });
    check(
      evidence.closeAccepted &&
        evidence.pendingOpenRefused &&
        evidence.hostViewsOpened === 0 &&
        evidence.cancelledFrames === 0,
      "closed-pending-open-reached-host",
    );
    const input = await call(page, {
      type: "browserSessionInput",
      hostId: ready.hostId,
      viewId: cancelledView,
      inputs: [{ type: "key", action: "down", key: "Enter", code: "Enter", text: "", modifiers: 0 }],
    });
    evidence.cancelledInputRefused = !input.ok && input.code === "sendFailed";
    check(evidence.cancelledInputRefused, "cancelled-pending-view-accepted-input");
    // The old close must also leave an unrelated view's pending attention read alone.
    const replacement = await openAndClose(replacementView, cancelledView);
    check(replacement.opened.ok && replacement.closed.ok, "old-close-cancelled-unrelated-pending-view");
    const shown = await waitFor(
      async () =>
        (await page.evaluate(() => window.assistantFrames)).findLast(
          (item) => item.viewId === replacementView && item.valid,
        ) ?? null,
      "replacement-browser-frame-missing",
    );
    // A delayed close for the cancelled view must not cancel a different open view.
    await run("browserSessionClose", { viewId: cancelledView });
    const clicksBefore = (await status()).browserSurface.pageClicks;
    const pointer = (action: string) => ({
      type: "pointer",
      action,
      x: 0.5,
      y: 0.405,
      sequence: shown.sequence,
      button: "left",
      clickCount: 1,
      deltaX: 0,
      deltaY: 0,
      modifiers: 0,
    });
    await run("browserSessionInput", { viewId: replacementView, inputs: [pointer("down"), pointer("up")] });
    await waitFor(
      async () => ((await status()).browserSurface.pageClicks > clicksBefore ? true : null),
      "late-close-disabled-replacement-view",
    );
    evidence.replacementSurvivedLateClose = true;
    return replacementView;
  };

  const partialRecoverySave = async (agentId: string) => {
    stage = "recovery-secondary-place-failure";
    const listing = object(await run("routinesList", { agentId }), "recovery-routine-list-dto");
    check(listing.recovery === true && listing.runPlaces === true, "recovery-fixture-capabilities-missing");
    const before = await status();
    const armed = await fetch(`${ready.apiURL}/_control/routines/fail-secondary-place`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ enabled: true }),
      signal: AbortSignal.timeout(10_000),
    });
    check(armed.ok, "secondary-place-fault-not-armed");
    const name = "Synthetic recovery partial save";
    const response = await call(page, {
      type: "routineCreate",
      hostId: ready.hostId,
      agentId,
      input: {
        name,
        instruction: "SIM-RECOVERY",
        active: false,
        timezone: "Europe/Rome",
        schedule: { kind: "daily", time: "23:58" },
        limitPolicy: "skip",
        missedPolicy: "run-once",
        runIn: "thread",
      },
    });
    const after = await status();
    const saved = after.features.routines.filter((item) => item.agentId === agentId && item.name === name);
    const evidence = {
      unconfirmedReported: !response.ok && response.code === "unconfirmed",
      committedRecords: saved.length,
      secondaryFailures: after.routineFaults.secondaryPlaceFailures - before.routineFaults.secondaryPlaceFailures,
      recoveryCreates: after.routineFaults.recoveryCreates.length - before.routineFaults.recoveryCreates.length,
      actualChatPlace: saved[0]?.runIn === "chat",
      savedPoliciesPreserved: saved[0]?.limitPolicy === "skip" && saved[0]?.missedPolicy === "run-once",
      readDidNotReplayCreate: false,
      explicitSameRecordReconciled: false,
      reconciledRecordDeleted: false,
    };
    report.checks.push({ name: "recovery-partial-save-requires-review", evidence });
    check(evidence.unconfirmedReported, "partial-recovery-save-reported-success");
    const record = saved[0];
    check(
      record &&
        evidence.committedRecords === 1 &&
        evidence.secondaryFailures === 1 &&
        evidence.recoveryCreates === 1 &&
        evidence.actualChatPlace &&
        evidence.savedPoliciesPreserved &&
        after.routineFaults.failedPlaceRoutineId === record.id,
      "partial-recovery-save-owner-state",
    );
    await run("routinesList", { agentId });
    const refreshed = object(await run("routinesList", { agentId }), "partial-save-refresh-dto");
    const current = array(refreshed.routines, "partial-save-refresh-routines").find(
      (item) => isDynamicRecord(item) && item.id === record.id,
    );
    check(isRoutine(current), "partial-saved-record-not-recoverable");
    const afterRead = await status();
    evidence.readDidNotReplayCreate =
      afterRead.routineFaults.recoveryCreates.length === after.routineFaults.recoveryCreates.length &&
      afterRead.features.routines.filter((item) => item.agentId === agentId && item.name === name).length === 1 &&
      afterRead.routineFaults.secondaryPlaceFailures === after.routineFaults.secondaryPlaceFailures;
    check(evidence.readDidNotReplayCreate, "partial-save-read-replayed-mutation");
    const reconciled = object(
      await run("routineUpdate", {
        agentId,
        routineId: current.id,
        expectedUpdatedAt: current.updatedAt,
        changes: { runIn: "thread" },
      }),
      "partial-save-reconcile-dto",
    );
    check(isRoutine(reconciled), "partial-save-reconcile-wire");
    const final = await status();
    evidence.explicitSameRecordReconciled =
      reconciled.id === record.id &&
      reconciled.runIn === "thread" &&
      final.features.routines.some(
        (item) =>
          item.id === record.id &&
          item.runIn === "thread" &&
          item.limitPolicy === "skip" &&
          item.missedPolicy === "run-once",
      ) &&
      final.features.routines.filter((item) => item.agentId === agentId && item.name === name).length === 1 &&
      final.routineFaults.recoveryCreates.length === after.routineFaults.recoveryCreates.length;
    check(evidence.explicitSameRecordReconciled, "partial-save-reconcile-duplicated-or-lost-policy");
    await run("routineDelete", { agentId, routineId: reconciled.id, expectedUpdatedAt: reconciled.updatedAt });
    evidence.reconciledRecordDeleted = !(await status()).features.routines.some((item) => item.id === reconciled.id);
    check(evidence.reconciledRecordDeleted, "partial-save-record-not-deleted");
  };

  const linkedReply = async (otherAgentId: string) => {
    stage = "reply-parent-pagination-and-deduplication";
    await settled();
    const seeded = await fetch(`${ready.apiURL}/_control/seed-history`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
      signal: AbortSignal.timeout(10_000),
    });
    check(seeded.ok, "reply-history-seed-refused");
    const latest = await history(ready.agentId);
    check(
      !array(latest.messages, "reply-latest-messages").some(
        (message) => isDynamicRecord(message) && message.text === "SIM-HISTORY-01",
      ),
      "reply-parent-not-older-than-latest-page",
    );
    let olderPage = latest;
    let parent: TeamProtocolV2Json | undefined;
    const seenCursors = new Set<string>();
    for (let pageNumber = 0; pageNumber < 20; pageNumber++) {
      parent = array(olderPage.messages, "reply-older-messages").find(
        (message) => isDynamicRecord(message) && message.text === "SIM-HISTORY-01",
      );
      if (parent !== undefined) break;
      const info = object(olderPage.pageInfo, "reply-older-page-info");
      check(
        info.hasOlder === true && isString(info.olderCursor) && !seenCursors.has(info.olderCursor),
        "reply-parent-cursor-unavailable",
      );
      seenCursors.add(info.olderCursor);
      olderPage = object(
        await run("history", { agentId: ready.agentId, before: info.olderCursor }),
        "reply-older-page",
      );
    }
    const target = object(parent, "reply-older-parent-missing");
    const parentId = string(target.id, "reply-older-parent-id");
    const parentText = string(target.text, "reply-older-parent-text");
    const crossReceipt = object(
      await run("send", {
        agentId: otherAgentId,
        text: "SIM-CROSS-1",
        clientMessageId: randomUUID(),
        timezone: "Europe/Rome",
      }),
      "cross-reply-receipt",
    );
    const foreign = await waitFor(async () => {
      const other = await history(otherAgentId);
      const rows = array(other.messages, "reply-foreign-history");
      const input = rows.find(
        (message) => isDynamicRecord(message) && message.id === crossReceipt.conversationMessageId,
      );
      return isDynamicRecord(input) &&
        isString(input.turnId) &&
        other.activeTurnId === null &&
        rows.some(
          (message) =>
            isDynamicRecord(message) &&
            message.author === "assistant" &&
            message.turnId === input.turnId &&
            message.status === "completed",
        )
        ? input
        : null;
    }, "reply-foreign-input-not-completed");
    check(
      isDynamicRecord(foreign) && isString(foreign.id) && foreign.id !== parentId,
      "reply-foreign-target-unavailable",
    );
    const foreignId = foreign.id;
    const text = "Synthetic reply text. SIM-LINKED-REPLY";
    const clientMessageId = randomUUID();
    const sendReply = () =>
      run("send", {
        agentId: ready.agentId,
        text,
        clientMessageId,
        timezone: "Europe/Rome",
        replyToMessageId: parentId,
      });
    const first = object(await sendReply(), "reply-receipt-dto");
    const receiptId = string(first.conversationMessageId, "reply-receipt-message-id");
    const completed = await waitFor(async () => {
      const page = await history(ready.agentId);
      const messages = array(page.messages, "reply-completed-messages");
      const reply = messages.find((message) => isDynamicRecord(message) && message.id === receiptId);
      if (!isDynamicRecord(reply) || !isString(reply.turnId) || reply.turnId.length === 0 || page.activeTurnId !== null)
        return null;
      const answers = messages.filter(
        (message) =>
          isDynamicRecord(message) &&
          message.author === "assistant" &&
          message.turnId === reply.turnId &&
          message.status === "completed" &&
          message.itemType !== "commentary" &&
          message.itemType !== "reasoning" &&
          isString(message.text) &&
          message.text.length > 0,
      );
      return answers.length > 0 ? { page, reply, answers } : null;
    }, "reply-turn-association-unavailable");
    const references = object(completed.page.references, "reply-references-dto");
    const reference = references[parentId];
    const providerInputs = readFileSync(join(fixture, "provider-turns.jsonl"), "utf8")
      .split("\n")
      .filter(Boolean)
      .map((line) => decodeTeamProtocolV2Json(JSON.parse(line)));
    const providerInput = providerInputs.find(
      (item) =>
        isDynamicRecord(item) &&
        item.turnId === completed.reply.turnId &&
        isString(item.text) &&
        item.text.includes(parentText) &&
        item.text.includes(text),
    );
    const evidence = {
      olderCursorPagesRead: seenCursors.size,
      exactReplyLinkStored: completed.reply.replyToMessageId === parentId,
      plainUserTextPreserved: completed.reply.text === text,
      olderParentReferenceAvailable:
        isDynamicRecord(reference) && reference.id === parentId && reference.text === parentText,
      actualTurnAssociation: completed.answers.length > 0,
      providerReceivedSelectedContext: providerInput !== undefined,
      sameReceiptOnRetry: false,
      storedInputsAfterRetry: 0,
      providerTurnsAddedOnRetry: 0,
      invalidTargetsBlockedBeforePost: 0,
    };
    report.checks.push({ name: "specific-message-reply-context-and-deduplication", evidence });
    check(evidence.exactReplyLinkStored, "reply-target-not-preserved");
    check(
      evidence.plainUserTextPreserved &&
        evidence.olderParentReferenceAvailable &&
        evidence.actualTurnAssociation &&
        evidence.providerReceivedSelectedContext,
      "reply-context-or-turn-metadata-lost",
    );
    const beforeRetry = await status();
    const retry = object(await sendReply(), "reply-retry-receipt");
    const retriedMessages = array((await history(ready.agentId)).messages, "reply-retry-history");
    const afterRetry = await status();
    evidence.sameReceiptOnRetry = retry.conversationMessageId === receiptId;
    evidence.storedInputsAfterRetry = retriedMessages.filter(
      (message) => isDynamicRecord(message) && message.author === "user" && message.text === text,
    ).length;
    evidence.providerTurnsAddedOnRetry = afterRetry.providerTurns - beforeRetry.providerTurns;
    const retried = retriedMessages.find((message) => isDynamicRecord(message) && message.id === receiptId);
    check(
      evidence.sameReceiptOnRetry &&
        evidence.storedInputsAfterRetry === 1 &&
        evidence.providerTurnsAddedOnRetry === 0 &&
        isDynamicRecord(retried) &&
        retried.replyToMessageId === parentId,
      "reply-retry-created-or-retargeted-input",
    );
    const path = `/v1/agents/${encodeURIComponent(ready.agentId)}/messages`;
    for (const invalidTarget of [randomUUID(), foreignId]) {
      const before = await status();
      const refused = await call(page, {
        type: "send",
        hostId: ready.hostId,
        agentId: ready.agentId,
        text: "This invalid reply must not be stored.",
        clientMessageId: randomUUID(),
        timezone: "Europe/Rome",
        replyToMessageId: invalidTarget,
      });
      const after = await status();
      check(
        !refused.ok &&
          refused.code === "sendFailed" &&
          count(after, path) === count(before, path) &&
          after.providerTurns === before.providerTurns,
        "foreign-or-missing-reply-target-posted",
      );
      evidence.invalidTargetsBlockedBeforePost++;
    }
  };

  if (browserCloseOnly) {
    await send("SIM-BROWSER");
    const secret = await handoff();
    await run("browserSecretRespond", { browserTakeover: secret, decision: "takeover" });
    const request = await handoff("interactive");
    await closePendingView(request);
    await run("browserTakeoverRespond", { browserTakeover: request, decision: "cancel" });
    await settled();
    await waitFor(async () => {
      const state = (await status()).browserSurface;
      return state.viewsStarted === state.viewsStopped ? true : null;
    }, "focused-browser-view-not-released");
  } else if (recoveryPartialOnly) {
    await partialRecoverySave(ready.agentId);
  } else if (replyOnly) {
    const other = object(
      await run("createAgent", {
        input: {
          name: "Synthetic reply peer",
          description: "No external actions.",
          avatarSeed: "reply-peer",
          avatarHue: null,
          initialMessage: "SIM-REPLY-PEER",
        },
      }),
      "reply-peer-create",
    );
    const otherId = string(other.id, "reply-peer-id");
    await waitFor(async () => {
      const data = await history(otherId);
      return data.activeTurnId === null &&
        array(data.messages, "reply-peer-messages").some(
          (message) => isDynamicRecord(message) && message.author === "assistant" && message.status === "completed",
        )
        ? true
        : null;
    }, "reply-peer-not-ready");
    await send("SIM-REPLY-START");
    await settled();
    await linkedReply(otherId);
    await run("deleteAgent", { agentId: otherId, expectedUpdatedAt: (await agent(otherId)).updatedAt });
  } else {
    stage = "agent-model-crud";
    const models = array(await run("agentModels"), "invalid-models");
    check(models.length > 0 && models.every(isClientAgentModelOption), "model-dto-invalid");
    const model = models.find((item) => isDynamicRecord(item) && item.provider === "codex");
    check(isDynamicRecord(model) && isString(model.id), "synthetic-model-missing");
    const created = object(
      await run("createAgent", {
        input: {
          name: "Synthetic managed agent",
          description: "No external actions.",
          avatarSeed: "assistant-features",
          avatarHue: null,
          initialMessage: "SIM-AGENT-SETUP",
          provider: "codex",
          model: model.id,
        },
      }),
      "create-agent-dto",
    );
    const createdId = string(created.id, "created-agent-id");
    check(created.canManage === true && created.canDelete === true, "created-agent-permissions");
    await waitFor(async () => {
      const data = await history(createdId);
      return data.activeTurnId === null &&
        Array.isArray(data.messages) &&
        data.messages.some(
          (message) =>
            isDynamicRecord(message) &&
            message.author === "assistant" &&
            isString(message.text) &&
            message.text.length > 0,
        )
        ? data
        : null;
    }, "created-agent-setup-not-completed");
    const original = await agent(createdId);
    const edited = object(
      await run("updateAgent", {
        agentId: createdId,
        expectedUpdatedAt: original.updatedAt,
        patch: { name: "Synthetic managed agent edited", description: "Edited harmless instructions." },
      }),
      "edited-agent-dto",
    );
    check(
      edited.name === "Synthetic managed agent edited" &&
        edited.canManage === true &&
        edited.canDelete === true &&
        (await agent(createdId)).description === "Edited harmless instructions.",
      "agent-update-not-saved",
    );
    check(
      edited.updatedAt !== original.updatedAt &&
        (await status()).features.agents.some(
          (item) =>
            item.id === createdId &&
            item.name === edited.name &&
            item.instructionsLength === "Edited harmless instructions.".length,
        ),
      "agent-owner-readback-missing",
    );
    const agentPath = `/v1/agents/${encodeURIComponent(createdId)}`;
    const beforeStaleAgent = count(await status(), agentPath);
    for (const type of ["updateAgent", "deleteAgent"]) {
      const response = await call(page, {
        type,
        hostId: ready.hostId,
        agentId: createdId,
        expectedUpdatedAt: original.updatedAt,
        ...(type === "updateAgent" ? { patch: { name: "Stale form must not save" } } : {}),
      });
      check(!response.ok && response.code === "sendFailed", "stale-agent-write-not-refused");
    }
    check(
      count(await status(), agentPath) === beforeStaleAgent && (await agent(createdId)).name === edited.name,
      "stale-agent-write-reached-host",
    );
    report.checks.push({
      name: "agent-model-crud-and-stale-forms",
      evidence: {
        modelOptions: models.length,
        setupCompleted: true,
        savedReadback: true,
        staleWritesBlockedBeforePost: 2,
      },
    });

    stage = "routines-revisions-history";
    const listing = object(await run("routinesList", { agentId: createdId }), "routine-list-dto");
    const routine = object(
      await run("routineCreate", {
        agentId: createdId,
        input: {
          name: "Synthetic paused routine",
          instruction: "SIM-ROUTINE",
          active: false,
          timezone: "Europe/Rome",
          schedule: { kind: "daily", time: "23:59" },
          ...(listing.runPlaces === true ? { runIn: "thread" } : {}),
          ...(listing.recovery === true ? { limitPolicy: "skip", missedPolicy: "run-once" } : {}),
        },
      }),
      "created-routine-dto",
    );
    check(isRoutine(routine), "routine-wire-invalid");
    const routineId = routine.id;
    const routineList = async () =>
      array(
        object(await run("routinesList", { agentId: createdId }), "routine-list-dto").routines,
        "routine-list-invalid",
      );
    const currentRoutine = async () => {
      const found = (await routineList()).find((item) => isDynamicRecord(item) && item.id === routineId);
      check(isRoutine(found), "routine-not-found");
      return found;
    };
    const resumed = object(
      await run("routineUpdate", {
        agentId: createdId,
        routineId,
        expectedUpdatedAt: routine.updatedAt,
        changes: { active: true, name: "Synthetic routine edited" },
      }),
      "routine-resume-dto",
    );
    check(
      isRoutine(resumed) &&
        resumed.active &&
        resumed.trigger.schedule.kind === "daily" &&
        resumed.trigger.schedule.time === "23:59" &&
        resumed.timezone === "Europe/Rome",
      "routine-untouched-schedule-changed",
    );
    check(resumed.updatedAt !== routine.updatedAt, "routine-revision-did-not-change");
    const routineMutations = (state: Status) =>
      state.rpc.filter(
        (entry) =>
          entry.kind === "request" &&
          (entry.path === "/v1/routines-once/update" ||
            entry.path === "/v1/admin/routine-recovery/routines/save" ||
            entry.path === `/v1/agents/${createdId}/routines/${routineId}` ||
            entry.path === `/v1/agents/${createdId}/routines/${routineId}/test`),
      ).length;
    const beforeStaleRoutine = routineMutations(await status());
    for (const type of ["routineUpdate", "routineDelete", "routineTest"]) {
      const response = await call(page, {
        type,
        hostId: ready.hostId,
        agentId: createdId,
        routineId,
        expectedUpdatedAt: routine.updatedAt,
        ...(type === "routineUpdate" ? { changes: { active: false } } : {}),
      });
      check(!response.ok && response.code === "sendFailed", "stale-routine-write-not-refused");
    }
    check(
      routineMutations(await status()) === beforeStaleRoutine && (await currentRoutine()).active,
      "stale-routine-write-reached-host",
    );
    const paused = object(
      await run("routineUpdate", {
        agentId: createdId,
        routineId,
        expectedUpdatedAt: resumed.updatedAt,
        changes: { active: false, ...(listing.runPlaces === true ? { runIn: "chat" } : {}) },
      }),
      "routine-pause-dto",
    );
    check(
      isRoutine(paused) && !paused.active && (listing.runPlaces !== true || paused.runIn === "chat"),
      "routine-pause-not-saved",
    );
    const queued = object(
      await run("routineTest", { agentId: createdId, routineId, expectedUpdatedAt: paused.updatedAt }),
      "routine-test-dto",
    );
    check(isRoutineRun(queued) && queued.kind === "manual", "manual-run-dto-invalid");
    const completedRun = await waitFor(async () => {
      const runs = array(await run("routineRuns", { agentId: createdId, routineId, limit: 50 }), "routine-runs-dto");
      const found = runs.find((item) => isDynamicRecord(item) && item.id === queued.id);
      check(found === undefined || isRoutineRun(found), "run-history-wire-invalid");
      return isRoutineRun(found) && found.status === "succeeded" && found.deliveryId !== null ? found : null;
    }, "manual-routine-did-not-complete");
    const delivered = await history(createdId);
    check(
      Array.isArray(delivered.messages) &&
        delivered.messages.some((message) => isDynamicRecord(message) && message.id === completedRun.deliveryId),
      "routine-run-delivery-missing",
    );
    check(
      (await status()).features.routines.some(
        (item) =>
          item.id === routineId &&
          !item.active &&
          item.runs.some(
            (item) => item.id === completedRun.id && item.status === "succeeded" && item.kind === "manual",
          ),
      ),
      "routine-owner-completion-missing",
    );
    if (listing.once === true) {
      const once = object(
        await run("routineCreate", {
          agentId: createdId,
          input: {
            name: "Synthetic once routine",
            instruction: "SIM-ONCE",
            active: false,
            timezone: "Europe/Rome",
            schedule: { kind: "once", date: "2099-01-02", time: "09:00" },
          },
        }),
        "once-create-dto",
      );
      check(
        isRoutine(once) && (await routineList()).some((item) => isDynamicRecord(item) && item.id === once.id),
        "once-routine-not-listed",
      );
      await run("routineDelete", { agentId: createdId, routineId: once.id, expectedUpdatedAt: once.updatedAt });
      check(
        !(await routineList()).some((item) => isDynamicRecord(item) && item.id === once.id),
        "once-routine-not-deleted",
      );
    }
    report.checks.push({
      name: "routine-revision-preservation-and-real-completion",
      evidence: {
        staleWritesBlockedBeforePost: 3,
        untouchedSchedulePreserved: true,
        pausedManualRunSucceeded: true,
        deliveryPersisted: true,
        onceExercised: listing.once === true,
        recoveryPoliciesExercised: listing.recovery === true,
      },
    });
    if (listing.recovery === true) await partialRecoverySave(createdId);

    stage = "reactions-and-member-alerts";
    await send("SIM-REACTION");
    await settled();
    const messages = array((await history(ready.agentId)).messages, "history-messages-invalid");
    const target = messages.find((message) => isDynamicRecord(message) && message.author === "assistant");
    check(isDynamicRecord(target) && isString(target.id), "reaction-target-missing");
    await run("setReaction", { agentId: ready.agentId, messageId: target.id, emoji: "👍" });
    const reaction = async () =>
      array((await history(ready.agentId)).messages, "reaction-history-invalid").find(
        (message) => isDynamicRecord(message) && message.id === target.id,
      );
    check(object(await reaction(), "reaction-target-gone").reaction === "👍", "reaction-not-persisted");
    check(
      (await status()).features.reactions.some((item) => item.id === target.id && item.reaction === "👍"),
      "reaction-owner-readback-missing",
    );
    const reactionPath = `/v1/agents/${ready.agentId}/reactions`,
      beforeInvalidReaction = count(await status(), reactionPath);
    const refusedReaction = await call(page, {
      type: "setReaction",
      hostId: ready.hostId,
      agentId: ready.agentId,
      messageId: randomUUID(),
      emoji: "👍",
    });
    check(
      !refusedReaction.ok && count(await status(), reactionPath) === beforeInvalidReaction,
      "missing-reaction-target-posted",
    );
    await run("setReaction", { agentId: ready.agentId, messageId: target.id, emoji: null });
    check(object(await reaction(), "reaction-target-gone").reaction == null, "reaction-not-cleared");
    const globalNotifications = (await agent(createdId)).notifications;
    const preferences = object(await run("notificationPreferences"), "preferences-dto");
    await run("setAgentNotificationLevel", { agentId: createdId, level: "nothing" });
    const muted = object(await run("notificationPreferences"), "mute-readback-dto");
    check(
      array(muted.agents, "mute-agents-dto").some(
        (item) => isDynamicRecord(item) && item.agentId === createdId && item.level === "nothing",
      ) && (await agent(createdId)).notifications === globalNotifications,
      "member-mute-changed-global-agent",
    );
    const muteOwner = (await status()).features;
    check(
      muteOwner.preferences.agents.some((item) => item.agentId === createdId && item.level === "nothing") &&
        muteOwner.agents.find((item) => item.id === createdId)?.notifications === globalNotifications,
      "member-preference-owner-readback-missing",
    );
    await run("setAgentNotificationLevel", { agentId: createdId, level: null });
    const inherited = object(await run("notificationPreferences"), "unmute-readback-dto");
    check(
      !array(inherited.agents, "unmute-agents-dto").some(
        (item) => isDynamicRecord(item) && item.agentId === createdId && item.level !== null,
      ),
      "member-unmute-not-inherited",
    );
    await run("setServerNotificationLevel", { level: "needs-me" });
    check(
      object(await run("notificationPreferences"), "server-preference-dto").server === "needs-me",
      "server-preference-not-saved",
    );
    await run("setServerNotificationLevel", { level: preferences.server ?? null });
    report.checks.push({
      name: "reaction-roundtrip-and-member-alert-isolation",
      evidence: {
        reactionAddedAndRemoved: true,
        nonexistentTargetBlockedBeforePost: true,
        muteInheritsAgain: true,
        globalNotificationsUnchanged: true,
        serverPreferenceReversed: true,
      },
    });

    await linkedReply(createdId);

    stage = "browser-secret-submit";
    await send("SIM-BROWSER");
    const direct = await handoff();
    const support = object(
      await run("browserSessionCapabilities", { browserTakeover: direct }),
      "browser-capabilities-dto",
    );
    check(support.view === true && support.secret === true, "browser-fixture-support-missing");
    const directOpen = await call(page, {
      type: "browserSessionOpen",
      hostId: ready.hostId,
      viewId: "must-not-open",
      browserTakeover: direct,
    });
    check(!directOpen.ok && directOpen.code === "incompatible", "direct-secret-opened-interactive-view");
    const beforeSecret = (await status()).browserSurface.secretSubmitted;
    await run("browserSecretRespond", { browserTakeover: direct, decision: "submit", secret: "NATIVE-SYNTHETIC-ONLY" });
    const directDone = await settled();
    check(
      directDone.browserSurface.secretSubmitted === beforeSecret + 1 &&
        directDone.browserAnswers.at(-1)?.success === true,
      "secret-real-result-missing",
    );
    report.checks.push({
      name: "direct-secret-handoff",
      evidence: { interactiveViewBlocked: true, actualSubmitAcceptedOnce: true },
    });

    stage = "browser-dom-and-cleanup";
    await send("SIM-BROWSER");
    const beforeTakeover = await handoff();
    await run("browserSecretRespond", { browserTakeover: beforeTakeover, decision: "takeover" });
    const interactive = await handoff("interactive");
    const viewId = await closePendingView(interactive);
    stage = "browser-dom-and-cleanup";
    const frame = () =>
      waitFor(
        async () =>
          (await page.evaluate(() => window.assistantFrames)).findLast(
            (item) => item.viewId === viewId && item.valid,
          ) ?? null,
        "browser-jpeg-missing",
      );
    const pointer = (action: string, x: number, y: number, sequence: number, deltaY = 0) => ({
      type: "pointer",
      action,
      x,
      y,
      sequence,
      button: "left",
      clickCount: 1,
      deltaX: 0,
      deltaY,
      modifiers: 0,
    });
    const click = async (x: number, y: number) => {
      const shown = await frame();
      await run("browserSessionInput", {
        viewId,
        inputs: [pointer("down", x, y, shown.sequence), pointer("up", x, y, shown.sequence)],
      });
    };
    const beforeDOM = (await status()).browserSurface;
    await click(0.5, 0.405);
    await waitFor(
      async () => ((await status()).browserSurface.pageClicks > beforeDOM.pageClicks ? true : null),
      "browser-click-not-in-dom",
    );
    await click(0.5, 0.615);
    await run("browserSessionInput", {
      viewId,
      inputs: [
        { type: "key", action: "down", key: "a", code: "KeyA", text: "", modifiers: 0 },
        { type: "key", action: "char", key: "a", code: "KeyA", text: "a", modifiers: 0 },
        { type: "key", action: "up", key: "a", code: "KeyA", text: "", modifiers: 0 },
      ],
    });
    await run("browserSessionInput", { viewId, inputs: [{ type: "paste", text: "SYNTHETIC" }] });
    await run("browserSessionInput", {
      viewId,
      inputs: [
        { type: "key", action: "down", key: "Enter", code: "Enter", text: "", modifiers: 0 },
        { type: "key", action: "up", key: "Enter", code: "Enter", text: "", modifiers: 0 },
      ],
    });
    const wheelFrame = await frame();
    await run("browserSessionInput", { viewId, inputs: [pointer("wheel", 0.5, 0.8, wheelFrame.sequence, 120)] });
    await waitFor(async () => {
      const observed = (await status()).browserSurface;
      return observed.pageKeys > beforeDOM.pageKeys &&
        observed.pageTextLength >= beforeDOM.pageTextLength + 10 &&
        observed.pageWheels > beforeDOM.pageWheels
        ? true
        : null;
    }, "browser-text-wheel-not-in-dom");
    await run("active", { value: false });
    await waitFor(async () => {
      const observed = (await status()).browserSurface;
      return observed.viewsStarted === observed.viewsStopped ? observed : null;
    }, "inactive-view-not-released");
    const staleInput = await call(page, {
      type: "browserSessionInput",
      hostId: ready.hostId,
      viewId,
      inputs: [pointer("down", 0.5, 0.405, wheelFrame.sequence)],
    });
    check(!staleInput.ok && staleInput.code === "sendFailed", "inactive-view-accepted-input");
    await run("active", { value: true });
    const beforeComplete = count(await status(), "/v1/browser-takeovers/respond");
    const wrong = { ...object(interactive, "interactive-wire"), tabId: "stale-synthetic-tab" };
    const refused = await call(page, {
      type: "browserTakeoverRespond",
      hostId: ready.hostId,
      browserTakeover: wrong,
      decision: "complete",
    });
    check(
      !refused.ok &&
        refused.code === "sendFailed" &&
        count(await status(), "/v1/browser-takeovers/respond") === beforeComplete,
      "stale-browser-complete-posted",
    );
    await run("browserTakeoverRespond", { browserTakeover: interactive, decision: "complete" });
    const completed = await settled();
    check(
      completed.browserAnswers.at(-1)?.success === true && completed.browserAnswers.at(-1)?.cancelled === false,
      "browser-complete-tool-result-missing",
    );
    report.checks.push({
      name: "interactive-browser-dom-and-inactive-cleanup",
      evidence: {
        jpegDecoded: true,
        actualDOMClick: true,
        actualDOMTextAndWheel: true,
        staleCompleteBlockedBeforePost: true,
        inactiveViewReleased: true,
        inactiveInputRefused: true,
        actualToolCompleted: true,
      },
    });

    stage = "browser-reload-and-cancel";
    await send("SIM-BROWSER-RELOAD");
    const beforeReload = await handoff();
    await run("browserSecretRespond", {
      browserTakeover: beforeReload,
      decision: "submit",
      secret: "NATIVE-SYNTHETIC-ONLY",
    });
    const reloaded = await handoff("reload");
    const secretPosts = count(await status(), "/v1/browser-secrets/respond");
    const staleSecret = await call(page, {
      type: "browserSecretRespond",
      hostId: ready.hostId,
      browserTakeover: beforeReload,
      decision: "submit",
      secret: "NATIVE-SYNTHETIC-ONLY",
    });
    check(
      !staleSecret.ok &&
        staleSecret.code === "sendFailed" &&
        count(await status(), "/v1/browser-secrets/respond") === secretPosts,
      "pre-reload-secret-replayed",
    );
    await run("browserSessionOpen", { viewId: "assistant-browser-cancel", browserTakeover: reloaded });
    await waitFor(
      async () =>
        (await page.evaluate(() => window.assistantFrames)).some(
          (item) => item.viewId === "assistant-browser-cancel" && item.valid,
        )
          ? true
          : null,
      "reload-jpeg-missing",
    );
    await run("browserTakeoverRespond", { browserTakeover: reloaded, decision: "cancel" });
    const cancelled = await settled();
    check(cancelled.browserAnswers.at(-1)?.cancelled === true, "browser-cancel-real-result-missing");
    await waitFor(async () => {
      const observed = (await status()).browserSurface;
      return observed.viewsStarted === observed.viewsStopped ? true : null;
    }, "cancel-view-not-released");
    report.checks.push({
      name: "reload-request-freshness-and-cancel",
      evidence: {
        metadataChangeObserved: true,
        oldSecretBlockedBeforePost: true,
        actualToolCancelled: true,
        allViewsReleased: true,
      },
    });

    stage = "delete-owned-records";
    const lastRoutine = await currentRoutine();
    await run("routineDelete", { agentId: createdId, routineId, expectedUpdatedAt: lastRoutine.updatedAt });
    check(
      !(await routineList()).some((item) => isDynamicRecord(item) && item.id === routineId),
      "routine-delete-not-persisted",
    );
    check(!(await status()).features.routines.some((item) => item.id === routineId), "routine-owner-delete-missing");
    const lastAgent = await agent(createdId);
    await run("deleteAgent", { agentId: createdId, expectedUpdatedAt: lastAgent.updatedAt });
    check(
      !(await agents()).some((item) => isDynamicRecord(item) && item.id === createdId),
      "agent-delete-not-persisted",
    );
    check(!(await status()).features.agents.some((item) => item.id === createdId), "agent-owner-delete-missing");
    report.checks.push({ name: "owned-record-deletion", evidence: { routineRemoved: true, agentRemoved: true } });
  }
  report.passed = true;
  report.status = "passed";
} catch (error) {
  report.status = "failed";
  report.failure = `${stage}:${error instanceof CheckFailed ? error.code : "unexpected-error"}`;
  process.exitCode = 1;
} finally {
  let browserClosed = browser === undefined;
  try {
    await browser?.close();
    browserClosed = true;
  } catch {
    report.passed = false;
    report.status = "failed";
    report.failure ??= "cleanup:browser-close";
    process.exitCode = 1;
  }
  child.kill("SIGTERM");
  await Promise.race([exited, delay(8_000)]);
  if (child.pid) {
    try {
      process.kill(-child.pid, "SIGTERM");
    } catch {
      /* Owned group already exited. */
    }
  }
  if (!fixtureExited) {
    child.kill("SIGKILL");
    await Promise.race([exited, delay(2_000)]);
    if (child.pid) {
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch {
        /* Owned group already exited. */
      }
    }
  }
  writeFileSync(join(root, "fixture.log"), fixtureLog, { mode: 0o600 });
  report.cleanup = { browserClosed, fixtureExited };
  if (!fixtureExited) {
    report.passed = false;
    report.status = "failed";
    report.failure ??= "cleanup:fixture-exit";
    process.exitCode = 1;
  }
  save();
  console.log(
    JSON.stringify({
      passed: report.passed,
      status: report.status,
      report: join(output, "report.json"),
      ...(report.failure ? { failure: report.failure } : {}),
    }),
  );
}
