import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { isDynamicRecord, isString } from "@openbot/contracts/runtime-values";
import { decodeTeamProtocolV2Json, type TeamProtocolV2Json } from "@openbot/contracts/team-protocol/v2";
import { type Browser, chromium, type Page } from "playwright-core";

// The UI journey owns rendering and touch actions. This test owns the bridge's independent
// complete-context/freshness contract: altered or missing review data must not reach the host.
// All account, Signal, RTC, protocol, history, attention, receipts and tool results are real.
// Only native message-handler/Keychain acknowledgments and the tool-free provider are adapters.
// An optional old bundle demonstrates the actual regression; no production test seam is added.
const repository = resolve(import.meta.dirname, "../../..");
const output = join(repository, ".openbot-build/native-ios/confirmation-context-e2e");
mkdirSync(output, { recursive: true });
const root = mkdtempSync(join(output, "run-"));
const fixture = join(root, "fixture");
const baselineArgument = process.argv.indexOf("--baseline");
const baselinePath =
  baselineArgument >= 0 ? process.argv[baselineArgument + 1] : process.env.OPENBOT_CONFIRMATION_BASELINE_HTML;
const report: {
  passed: boolean;
  status: string;
  root: string;
  baseline: {
    supplied: boolean;
    sha256?: string;
    fullPreviewTailAvailable?: boolean;
    syntheticSendAccepted?: boolean;
    hostResponses?: number;
  };
  checks: Array<{ name: string; evidence: Record<string, boolean | number> }>;
  failure?: string;
  cleanup?: { browserClosed: boolean; fixtureExited: boolean };
  limits: string[];
} = {
  passed: false,
  status: "running",
  root,
  baseline: { supplied: !!baselinePath },
  checks: [],
  limits: [
    "Headless shared transport; no SwiftUI rendering, VoiceOver, physical device or APNs claim.",
    "Synthetic draft and browser target only; no email, external site, model or production account is used.",
    "The native bridge adapter acknowledges host-key persistence; the shared peer still verifies host identity and authentication.",
  ],
};
const saveReport = () =>
  writeFileSync(join(output, "report.json"), `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
saveReport();

class CheckFailed extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}
function check(value: unknown, code: string): asserts value {
  if (!value) throw new CheckFailed(code);
}
const delay = (milliseconds: number) => new Promise<void>((wake) => setTimeout(wake, milliseconds));
const child = spawn(process.execPath, ["apps/ios/scripts/simulator/entry.ts", fixture], {
  cwd: repository,
  detached: true,
  stdio: ["ignore", "pipe", "pipe"],
});
let fixtureLog = "";
child.stdout?.on("data", (data) => {
  fixtureLog += String(data);
});
child.stderr?.on("data", (data) => {
  fixtureLog += String(data);
});
let fixtureExited = false;
const exited = new Promise<void>((done) =>
  child.once("exit", () => {
    fixtureExited = true;
    done();
  }),
);
let spawnFailed = false;
child.once("error", () => {
  spawnFailed = true;
});
let browser: Browser | undefined;
let stage = "startup";

async function waitFor<T>(read: () => Promise<T | null>, code: string): Promise<T> {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    check(!spawnFailed && !fixtureExited, "fixture-exited");
    const result = await read();
    if (result !== null) return result;
    await delay(100);
  }
  throw new CheckFailed(code);
}

interface Ready {
  apiURL: string;
  agentId: string;
  hostId: string;
}
interface Status {
  pendingPrompts: number;
  pendingBrowserTakeovers: number;
  activeTurnId: string | null;
  confirmAnswers: Array<{ actionId: string | null; sender: string | null; cancelled: boolean; success: boolean }>;
  browserAnswers: Array<{ cancelled: boolean; success: boolean }>;
  rpc: Array<{ kind: string; path?: string }>;
}
interface Reply {
  ok: boolean;
  value?: TeamProtocolV2Json;
  code?: string;
}
type NativeBridgeMessage =
  | { type: "event"; event: TeamProtocolV2Json }
  | { type: "pin"; hostId: string; publicKey: string }
  | { type: "fetch"; url: string; method: string; headers: Record<string, string>; body: string | null };
type NativeBridgeReply = true | { status: number; body: string; headers: Record<string, string> };
declare global {
  interface Window {
    nativeConfirmationBridge: (message: NativeBridgeMessage) => Promise<NativeBridgeReply>;
    confirmationEvents: TeamProtocolV2Json[];
    openbotNative: { execute: (command: Record<string, TeamProtocolV2Json>) => Promise<Reply> };
  }
}
const responseCount = (status: Status, path: string) =>
  status.rpc.filter((event) => event.kind === "request" && event.path === path).length;

async function nativePage(ready: Ready, source: string): Promise<Page> {
  check(browser, "browser-not-started");
  const page = await browser.newPage();
  const origin = new URL(ready.apiURL).origin;
  await page.exposeFunction("nativeConfirmationBridge", async (message: unknown): Promise<NativeBridgeReply> => {
    check(isDynamicRecord(message), "invalid-native-message");
    if (message.type === "event" || message.type === "pin") return true;
    check(message.type === "fetch" && isString(message.url) && isString(message.method), "invalid-native-fetch");
    const url = new URL(message.url);
    check(url.origin === origin, "nonfixture-native-fetch");
    check(isDynamicRecord(message.headers), "invalid-native-headers");
    check(message.body === null || isString(message.body), "invalid-native-body");
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
    window.confirmationEvents = [];
    Object.assign(window, {
      webkit: {
        messageHandlers: {
          openbotNative: {
            postMessage: async (message: NativeBridgeMessage) => {
              if (message.type === "event") {
                window.confirmationEvents.push(message.event);
                if (window.confirmationEvents.length > 256) window.confirmationEvents.shift();
              }
              return window.nativeConfirmationBridge(message);
            },
          },
        },
      },
    });
  });
  await page.addScriptTag({ content: source });
  const linkResponse = await fetch(`${origin}/_control/connect-link`, { signal: AbortSignal.timeout(10_000) });
  check(linkResponse.ok, "connect-link-refused");
  const link = decodeTeamProtocolV2Json(await linkResponse.json());
  check(isDynamicRecord(link) && isString(link.url), "invalid-connect-link");
  const paired = await call(page, {
    type: "pair",
    link: link.url.replace("openbot-native-simulator:", "openbot:"),
    deviceId: randomUUID(),
  });
  check(paired.ok, "pair-refused");
  const hosts = await call(page, { type: "hosts" });
  check(
    hosts.ok &&
      Array.isArray(hosts.value) &&
      hosts.value.some((host) => isDynamicRecord(host) && host.hostId === ready.hostId),
    "host-not-discovered",
  );
  check((await call(page, { type: "connect", hostId: ready.hostId })).ok, "connect-refused");
  return page;
}

async function call(page: Page, command: Record<string, TeamProtocolV2Json>): Promise<Reply> {
  return page.evaluate((value) => window.openbotNative.execute(value), command);
}
async function send(page: Page, ready: Ready, text: string) {
  await page.evaluate(() => {
    window.confirmationEvents = [];
  });
  check(
    (
      await call(page, {
        type: "send",
        agentId: ready.agentId,
        text,
        clientMessageId: randomUUID(),
        timezone: "Europe/Rome",
      })
    ).ok,
    "send-refused",
  );
}
async function prompt(page: Page, ready: Ready, hydrated: boolean) {
  return waitFor(async () => {
    const events = await page.evaluate(() => window.confirmationEvents);
    for (const envelope of events.toReversed()) {
      if (!isDynamicRecord(envelope) || envelope.type !== "team" || envelope.hostId !== ready.hostId) continue;
      const value = envelope.event;
      if (!isDynamicRecord(value) || value.type !== "prompt" || value.agentId !== ready.agentId) continue;
      if (hydrated && value.contextVerified !== true) continue;
      return value;
    }
    return null;
  }, "confirmation-not-recovered");
}

try {
  const ready = await waitFor(async (): Promise<Ready | null> => {
    try {
      const value = decodeTeamProtocolV2Json(JSON.parse(readFileSync(join(fixture, "ready.json"), "utf8")));
      return isDynamicRecord(value) && isString(value.apiURL) && isString(value.agentId) && isString(value.hostId)
        ? { apiURL: value.apiURL, agentId: value.agentId, hostId: value.hostId }
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
  const settled = async (confirmCount: number, browserCount = 0) =>
    waitFor(async () => {
      const value = await status();
      return value.activeTurnId === null &&
        value.pendingPrompts === 0 &&
        value.pendingBrowserTakeovers === 0 &&
        value.confirmAnswers.length === confirmCount &&
        value.browserAnswers.length === browserCount
        ? value
        : null;
    }, "provider-result-not-settled");
  const candidates = [
    process.env.OPENBOT_NATIVE_CHROME,
    join(
      homedir(),
      "Library/Caches/ms-playwright/chromium_headless_shell-1248/chrome-headless-shell-mac-arm64/chrome-headless-shell",
    ),
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  ].filter(isString);
  const executablePath = candidates.find(existsSync);
  check(executablePath, "headless-chrome-unavailable");
  browser = await chromium.launch({ executablePath, headless: true });
  let completed = 0;

  if (baselinePath) {
    stage = "baseline";
    const html = readFileSync(resolve(baselinePath), "utf8");
    const script = html.match(/<script>([\s\S]*)<\/script>/u)?.[1];
    check(script, "baseline-script-missing");
    const page = await nativePage(ready, script);
    try {
      await send(page, ready, "SIM-CONFIRM");
      const shown = await prompt(page, ready, false);
      check(Array.isArray(shown.questions), "baseline-questions-missing");
      const fallback = shown.questions
        .filter(isDynamicRecord)
        .map((question) => (isString(question.question) ? question.question : ""))
        .join("\n");
      check(!fallback.includes("SIM-CONFIRM-TAIL") && shown.uiBlock === undefined, "baseline-did-not-show-regression");
      const before = responseCount(await status(), "/v1/prompts/respond");
      check(
        (
          await call(page, {
            type: "respondPrompt",
            hostId: ready.hostId,
            prompt: decodeTeamProtocolV2Json(shown),
            answers: { action: ["Send synthetic draft"], sender: ["Work"] },
          })
        ).ok,
        "baseline-send-not-accepted",
      );
      const result = await settled(++completed);
      const answer = result.confirmAnswers.at(-1);
      check(
        answer?.success && answer.actionId === "send" && answer.sender === "Work",
        "baseline-real-tool-result-missing",
      );
      check(responseCount(result, "/v1/prompts/respond") === before + 1, "baseline-response-count");
      report.baseline = {
        supplied: true,
        sha256: createHash("sha256").update(html).digest("hex"),
        fullPreviewTailAvailable: false,
        syntheticSendAccepted: true,
        hostResponses: 1,
      };
    } finally {
      await page.close();
    }
  }

  stage = "current-bundle";
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
  check(build.success && build.outputs[0], "current-bundle-failed");
  const page = await nativePage(ready, await build.outputs[0].text());
  try {
    await send(page, ready, "SIM-CONFIRM");
    const shown = await prompt(page, ready, true);
    check(isDynamicRecord(shown.uiBlock) && isDynamicRecord(shown.uiBlock.spec), "full-block-missing");
    const spec = shown.uiBlock.spec;
    check(
      isString(spec.preview) && spec.preview.length > 2_200 && spec.preview.includes("SIM-CONFIRM-TAIL"),
      "full-preview-tail-missing",
    );
    check(
      Array.isArray(spec.fields) &&
        spec.fields.some(
          (field) => isDynamicRecord(field) && field.label === "To" && field.value === "recipient@example.invalid",
        ) &&
        spec.fields.some(
          (field) =>
            isDynamicRecord(field) &&
            field.select === "sender" &&
            Array.isArray(field.options) &&
            field.options.includes("Work"),
        ),
      "full-fields-missing",
    );
    check(
      Array.isArray(spec.actions) &&
        spec.actions.some(
          (action) =>
            isDynamicRecord(action) &&
            action.id === "send" &&
            action.label === "Send synthetic draft" &&
            action.confirm === true,
        ),
      "full-actions-missing",
    );
    report.checks.push({
      name: "full-confirmation-hydration",
      evidence: {
        previewCharacters: spec.preview.length,
        tailAvailable: true,
        destinationAvailable: true,
        senderChoiceAvailable: true,
        namedConfirmAction: true,
      },
    });
    const answers = { action: ["Send synthetic draft"], sender: ["Work"] };
    const incomplete = structuredClone(shown);
    delete incomplete.uiBlock;
    const changedPreview = structuredClone(shown);
    check(
      isDynamicRecord(changedPreview.uiBlock) && isDynamicRecord(changedPreview.uiBlock.spec),
      "copy-preview-missing",
    );
    changedPreview.uiBlock.spec.preview = "A different synthetic preview.";
    const changedDanger = structuredClone(shown);
    check(isDynamicRecord(changedDanger.uiBlock) && isDynamicRecord(changedDanger.uiBlock.spec), "copy-danger-missing");
    changedDanger.uiBlock.spec.danger = true;
    for (const [name, altered] of [
      ["missing-full-block", incomplete],
      ["changed-preview", changedPreview],
      ["changed-danger", changedDanger],
    ] as const) {
      stage = name;
      const before = await status();
      const response = await call(page, {
        type: "respondPrompt",
        hostId: ready.hostId,
        prompt: decodeTeamProtocolV2Json(altered),
        answers,
      });
      check(!response.ok && response.code === "sendFailed", `${name}-not-rejected-by-freshness`);
      const after = await status();
      check(
        responseCount(after, "/v1/prompts/respond") === responseCount(before, "/v1/prompts/respond") &&
          after.pendingPrompts === 1 &&
          after.confirmAnswers.length === completed,
        `${name}-reached-host`,
      );
      report.checks.push({ name, evidence: { rejectedBeforePost: true, originalRequestStillPending: true } });
    }
    stage = "valid-confirmation";
    const before = responseCount(await status(), "/v1/prompts/respond");
    check(
      (
        await call(page, {
          type: "respondPrompt",
          hostId: ready.hostId,
          prompt: decodeTeamProtocolV2Json(shown),
          answers,
        })
      ).ok,
      "valid-confirmation-refused",
    );
    const accepted = await settled(++completed);
    check(
      accepted.confirmAnswers.at(-1)?.actionId === "send" &&
        accepted.confirmAnswers.at(-1)?.sender === "Work" &&
        accepted.confirmAnswers.at(-1)?.success === true &&
        responseCount(accepted, "/v1/prompts/respond") === before + 1,
      "valid-confirmation-tool-result",
    );
    report.checks.push({
      name: "valid-confirmation-once",
      evidence: { hostResponses: 1, actionAccepted: true, selectedSenderAccepted: true },
    });
    stage = "cancel-confirmation";
    await send(page, ready, "SIM-CONFIRM");
    const cancelPrompt = await prompt(page, ready, true);
    const cancelBefore = responseCount(await status(), "/v1/prompts/respond");
    check(
      (
        await call(page, {
          type: "respondPrompt",
          hostId: ready.hostId,
          prompt: decodeTeamProtocolV2Json(cancelPrompt),
          answers: {},
        })
      ).ok,
      "confirmation-cancel-refused",
    );
    const cancelled = await settled(++completed);
    check(
      cancelled.confirmAnswers.at(-1)?.cancelled === true &&
        cancelled.confirmAnswers.at(-1)?.actionId === null &&
        responseCount(cancelled, "/v1/prompts/respond") === cancelBefore + 1,
      "confirmation-cancel-tool-result",
    );
    report.checks.push({ name: "confirmation-cancel", evidence: { hostResponses: 1, actualToolCancelled: true } });
    stage = "browser-handoff";
    await send(page, ready, "SIM-BROWSER");
    const handoff = await waitFor(async () => {
      const events = await page.evaluate(() => window.confirmationEvents);
      for (const envelope of events.toReversed()) {
        if (
          !isDynamicRecord(envelope) ||
          envelope.type !== "team" ||
          envelope.hostId !== ready.hostId ||
          !isDynamicRecord(envelope.event)
        )
          continue;
        const event = envelope.event;
        if (event.type === "browser-takeover-requested" && isDynamicRecord(event.request)) return event.request;
        if (
          event.type === "runtime-snapshot" &&
          isDynamicRecord(event.snapshot) &&
          Array.isArray(event.snapshot.pendingBrowserTakeovers)
        ) {
          const request = event.snapshot.pendingBrowserTakeovers.find(
            (item) => isDynamicRecord(item) && item.agentId === ready.agentId,
          );
          if (isDynamicRecord(request)) return request;
        }
      }
      return null;
    }, "real-browser-handoff-missing");
    const wrong = { ...handoff, requestId: `${String(handoff.requestId)}-stale` };
    const browserBefore = responseCount(await status(), "/v1/browser-takeovers/respond");
    const refused = await call(page, {
      type: "cancelBrowserTakeover",
      hostId: ready.hostId,
      browserTakeover: decodeTeamProtocolV2Json(wrong),
    });
    check(!refused.ok && refused.code === "sendFailed", "stale-browser-request-not-rejected");
    const stillPending = await status();
    check(
      stillPending.pendingBrowserTakeovers === 1 &&
        stillPending.browserAnswers.length === 0 &&
        responseCount(stillPending, "/v1/browser-takeovers/respond") === browserBefore,
      "stale-browser-request-reached-host",
    );
    check(
      (
        await call(page, {
          type: "cancelBrowserTakeover",
          hostId: ready.hostId,
          browserTakeover: decodeTeamProtocolV2Json(handoff),
        })
      ).ok,
      "browser-cancel-refused",
    );
    const browserCancelled = await settled(completed, 1);
    check(
      browserCancelled.browserAnswers[0]?.cancelled === true &&
        responseCount(browserCancelled, "/v1/browser-takeovers/respond") === browserBefore + 1,
      "browser-cancel-tool-result",
    );
    report.checks.push({
      name: "browser-handoff-exact-cancel",
      evidence: { staleRejectedBeforePost: true, hostResponses: 1, actualToolCancelled: true },
    });
  } finally {
    await page.close();
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
  // This process group was made by this script. Do not leave its Signal/browser children behind.
  if (child.pid) {
    try {
      process.kill(-child.pid, "SIGTERM");
    } catch {
      /* The owned group already exited. */
    }
  }
  if (!fixtureExited) {
    child.kill("SIGKILL");
    await Promise.race([exited, delay(2_000)]);
    if (child.pid) {
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch {
        /* The owned group already exited. */
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
  saveReport();
  console.log(
    JSON.stringify({
      passed: report.passed,
      status: report.status,
      report: join(output, "report.json"),
      ...(report.failure ? { failure: report.failure } : {}),
    }),
  );
}
