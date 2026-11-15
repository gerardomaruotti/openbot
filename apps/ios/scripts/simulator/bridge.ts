import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { isDynamicRecord, isString } from "@openbot/contracts/runtime-values";
import { decodeTeamProtocolV2RpcFrame } from "@openbot/contracts/team-protocol/v2";
import { Effect } from "effect";
import { type Browser, chromium, type Page } from "playwright-core";
import { RemoteWorkflowError } from "../../../../src/main/remote-service-effects";
import { TeamWebRtcBridge, type TeamWebRtcChannel } from "../../../../src/main/team-webrtc-bridge";

import type { BridgeCommand } from "../../../../src/renderer/src/features/team/team-webrtc";

type HostCommand = Omit<BridgeCommand, "commandId" | "data"> & { data?: string | { binary: number[] } };
interface ReceiptFaultLifecycle {
  connections: number;
  disconnections: number;
  pathLosses: number;
  signalOpens: number;
  signalCloses: number;
}
interface RpcTraceEntry {
  kind: string;
  operation?: string;
  method?: string;
  path?: string;
  peerId: string;
  requestId: string;
  status?: number;
  code?: string;
  snapshots?: boolean;
  lifecycle?: ReceiptFaultLifecycle;
}
declare global {
  interface Window {
    nativeHostPort: MessagePort;
    nativeHostEvent: (value: unknown) => void;
  }
}

const repository = resolve(import.meta.dirname, "../../../..");
function call<A>(run: () => Promise<A>) {
  return Effect.tryPromise({ try: run, catch: (cause) => new RemoteWorkflowError({ cause }) });
}

/** Replaces only Electron's MessagePort/window adapter. RTC, Signal, framing and DTLS stay real. */
export class HeadlessHostBridge extends TeamWebRtcBridge {
  browser: Browser | null = null;
  page: Page | null = null;
  pageOrigin = "";
  dropNextReceipt = false;
  droppedReceipts = 0;
  dropNextReceiptOnly = false;
  readonly receiptOnlyDrops: Array<{
    peerId: string;
    mailboxId: string;
    droppedAt: string;
    lifecycle: ReceiptFaultLifecycle;
  }> = [];
  readonly lifecycle = { connections: 0, disconnections: 0, pathLosses: 0, signalOpens: 0, signalCloses: 0 };
  private readonly connectedPeers = new Set<string>();
  dropNextRoutineRunResponse = false;
  readonly droppedManualRuns: Array<{ agentId: string; routineId: string; runId: string }> = [];
  onRoutineRunResponseDropped: (() => void) | null = null;
  private readonly requests = new Map<string, { method: string; path: string }>();
  readonly paths: string[] = [];
  readonly trace: RpcTraceEntry[] = [];
  private observe(data: string, peerId: string) {
    try {
      const frame = decodeTeamProtocolV2RpcFrame(data);
      if (frame.type === "request") {
        if (isDynamicRecord(frame.payload) && isString(frame.payload.path) && isString(frame.payload.method)) {
          this.requests.set(`${peerId}:${frame.requestId}`, { method: frame.payload.method, path: frame.payload.path });
        }
        this.trace.push({
          kind: "request",
          operation: frame.operation,
          peerId,
          requestId: frame.requestId,
          ...(isDynamicRecord(frame.payload) && isString(frame.payload.method) ? { method: frame.payload.method } : {}),
          ...(isDynamicRecord(frame.payload) && isString(frame.payload.path) ? { path: frame.payload.path } : {}),
        });
      } else {
        const request = this.requests.get(`${peerId}:${frame.requestId}`);
        if ("error" in frame)
          this.trace.push({
            kind: "error",
            peerId,
            requestId: frame.requestId,
            ...request,
            ...(frame.error.status === undefined ? {} : { status: frame.error.status }),
            code: frame.error.code,
            lifecycle: { ...this.lifecycle },
          });
        else if (isDynamicRecord(frame.result))
          this.trace.push({
            kind: "response",
            peerId,
            requestId: frame.requestId,
            ...request,
            ...(typeof frame.result.status === "number" ? { status: frame.result.status } : {}),
            ...(isDynamicRecord(frame.result.body) && Array.isArray(frame.result.body.capabilities)
              ? { snapshots: frame.result.body.capabilities.includes("agent-runtime-snapshots") }
              : {}),
          });
      }
    } catch {
      /* Authentication frames are intentionally not recorded. */
    }
  }
  private sequence = 0;
  private pending = new Map<string, { resolve: () => void; reject: (error: Error) => void }>();
  private ready: Promise<void> | null = null;
  private readyResolve: (() => void) | null = null;

  override readonly start = () =>
    call(async () => {
      if (this.page) {
        await this.ready;
        return;
      }
      const candidates = [
        process.env.OPENBOT_NATIVE_CHROME,
        join(
          homedir(),
          "Library/Caches/ms-playwright/chromium_headless_shell-1248/chrome-headless-shell-mac-arm64/chrome-headless-shell",
        ),
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      ].filter(isString);
      const executablePath = candidates.find(existsSync);
      if (!executablePath) throw new Error("No installed headless Chrome. Set OPENBOT_NATIVE_CHROME.");
      this.ready = new Promise((resolveReady) => {
        this.readyResolve = resolveReady;
      });
      this.browser = await chromium.launch({ executablePath, headless: true });
      this.page = await this.browser.newPage();
      await this.page.exposeFunction("nativeHostEvent", (event: unknown) => this.receive(event));
      const built = await Bun.build({
        entrypoints: [join(repository, "src/renderer/src/features/team/team-webrtc.ts")],
        target: "browser",
        format: "iife",
        minify: true,
        define: { "process.env.NODE_ENV": JSON.stringify("production") },
        plugins: [
          {
            name: "fixture-no-translations",
            setup(build) {
              build.onLoad({ filter: /packages[\\/]i18n[\\/]src[\\/]source-catalogs\.ts$/ }, () => ({
                contents: "export function sourceTranslation(){ return undefined; }",
                loader: "ts",
              }));
            },
          },
        ],
      });
      if (!built.success || !built.outputs[0]) throw new Error("Could not bundle the real host WebRTC renderer.");
      await this.page.goto(`${this.pageOrigin}/_fixture/host`);
      await this.page.setContent("<!doctype html><title>Native simulator host fixture</title>");
      await this.page.addScriptTag({ content: await built.outputs[0].text() });
      await this.page.evaluate(() => {
        const channel = new MessageChannel();
        Object.assign(window, { nativeHostPort: channel.port1 });
        channel.port1.onmessage = (event) => {
          const data = { ...event.data };
          if (data.data instanceof ArrayBuffer) data.data = { binary: Array.from(new Uint8Array(data.data)) };
          window.nativeHostEvent(data);
        };
        channel.port1.start();
        window.postMessage("openbot-team-webrtc-port", "*", [channel.port2]);
      });
      await Promise.race([
        this.ready,
        new Promise((_, reject) => setTimeout(() => reject(new Error("Host renderer did not become ready.")), 10000)),
      ]);
    });

  private async command(value: HostCommand): Promise<void> {
    if (!this.page) throw new Error("Host renderer is not running.");
    const commandId = `native-host-${++this.sequence}`;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const done = new Promise<void>((resolveDone, reject) => {
      timer = setTimeout(() => {
        this.pending.delete(commandId);
        reject(new Error("Host renderer command timed out."));
      }, 15000);
      this.pending.set(commandId, { resolve: resolveDone, reject });
    });
    try {
      await this.page.evaluate(
        (payload) => {
          window.nativeHostPort.postMessage({
            ...payload,
            data: typeof payload.data === "object" ? new Uint8Array(payload.data.binary).buffer : payload.data,
          });
        },
        { ...value, commandId },
      );
      await done;
    } finally {
      clearTimeout(timer);
      this.pending.delete(commandId);
    }
  }

  private receive(value: unknown) {
    if (!isDynamicRecord(value)) return;
    const type = value.type,
      peer = isString(value.peerId) ? value.peerId : "";
    if (type === "bridge-ready") {
      this.readyResolve?.();
      return;
    }
    if ((type === "command-complete" || type === "command-error") && isString(value.commandId)) {
      const pending = this.pending.get(value.commandId);
      if (type === "command-complete") pending?.resolve();
      else pending?.reject(new Error("Host renderer rejected a command."));
      return;
    }
    if (!peer) return;
    if (type === "incoming-peer")
      this.emit("incoming", peer, {
        hostId: String(value.hostId),
        connectionId: String(value.connectionId),
        sessionId: String(value.sessionId),
        userId: String(value.userId),
        membershipId: String(value.membershipId),
        role: value.role === "owner" ? "owner" : value.role === "admin" ? "admin" : "member",
        sessionExpiresAt: Number(value.sessionExpiresAt),
      });
    else if (type === "peer-connected" && isString(value.localFingerprint) && isString(value.remoteFingerprint)) {
      if (!this.connectedPeers.has(peer)) {
        this.connectedPeers.add(peer);
        this.lifecycle.connections++;
      }
      this.emit("connected", peer, {
        localFingerprint: value.localFingerprint,
        remoteFingerprint: value.remoteFingerprint,
      });
    } else if (type === "signal-ready") this.emit("signalReady", peer);
    else if (type === "signal-open") {
      this.lifecycle.signalOpens++;
      this.emit("signalOpen", peer);
    } else if (type === "signal-closed") {
      this.lifecycle.signalCloses++;
      this.emit("signalClosed", peer, String(value.code), value.terminal === true);
    } else if (type === "peer-disconnected") {
      if (this.connectedPeers.delete(peer)) this.lifecycle.disconnections++;
      this.emit("disconnected", peer);
    } else if (type === "peer-path-lost") {
      this.lifecycle.pathLosses++;
      this.emit("pathLost", peer);
    } else if (type === "peer-path-restored") this.emit("pathRestored", peer);
    else if (type === "ice-path" && (value.path === "p2p" || value.path === "relay")) {
      this.paths.push(value.path);
      this.emit("path", peer, value.path);
    } else if (type === "peer-error")
      this.emit("error", peer, String(value.code), "Synthetic host renderer error", value.terminal === true);
    else if (
      type === "data" &&
      (value.channel === "rpc" ||
        value.channel === "events" ||
        value.channel === "files" ||
        value.channel === "desktop")
    ) {
      if (isString(value.data)) {
        if (value.channel === "rpc") this.observe(value.data, peer);
        this.emit("data", peer, value.channel, value.data);
      } else if (isDynamicRecord(value.data) && Array.isArray(value.data.binary))
        this.emit("data", peer, value.channel, new Uint8Array(value.data.binary.map(Number)).buffer);
    }
  }

  override readonly connect = (input: Parameters<TeamWebRtcBridge["connect"]>[0]) =>
    call(async () => {
      await Effect.runPromise(this.start());
      await this.command({ type: "connect", ...input, iceTransportPolicy: "all" });
    });
  override readonly send = (peerId: string, channel: TeamWebRtcChannel, data: string | ArrayBuffer) =>
    call(async () => {
      if (channel === "rpc" && typeof data === "string") {
        this.observe(data, peerId);
        let committed: { agentId: string; routineId: string; runId: string } | null = null;
        try {
          const frame = decodeTeamProtocolV2RpcFrame(data);
          if (frame.type === "response") {
            const requestKey = `${peerId}:${frame.requestId}`;
            const request = this.requests.get(requestKey);
            this.requests.delete(requestKey);
            const match =
              request?.method === "POST"
                ? /^\/v1\/agents\/([^/]+)\/routines\/([^/]+)\/test$/u.exec(request.path)
                : null;
            if (
              this.dropNextRoutineRunResponse &&
              match?.[1] &&
              match[2] &&
              "result" in frame &&
              isDynamicRecord(frame.result) &&
              frame.result.status === 201 &&
              isDynamicRecord(frame.result.body) &&
              frame.result.body.kind === "manual" &&
              isString(frame.result.body.id)
            )
              committed = { agentId: match[1], routineId: match[2], runId: frame.result.body.id };
          }
        } catch {
          /* Auth and control frames are not routine responses. */
        }
        if (committed) {
          this.dropNextRoutineRunResponse = false;
          this.droppedManualRuns.push(committed);
          this.onRoutineRunResponseDropped?.();
          await this.command({ type: "disconnect-peer", peerId });
          return;
        }
      }
      if (this.dropNextReceipt && channel === "rpc" && typeof data === "string") {
        let receipt = false;
        try {
          const frame = decodeTeamProtocolV2RpcFrame(data);
          receipt =
            frame.type === "response" &&
            "result" in frame &&
            isDynamicRecord(frame.result) &&
            isDynamicRecord(frame.result.body) &&
            isString(frame.result.body.messageId);
        } catch {
          /* Auth/control frames are not receipts. */
        }
        if (receipt) {
          this.dropNextReceipt = false;
          this.droppedReceipts++;
          await this.command({ type: "disconnect-peer", peerId });
          return;
        }
      }
      if (this.dropNextReceiptOnly && channel === "rpc" && typeof data === "string") {
        try {
          const frame = decodeTeamProtocolV2RpcFrame(data);
          if (
            frame.type === "response" &&
            "result" in frame &&
            isDynamicRecord(frame.result) &&
            frame.result.status === 202 &&
            isDynamicRecord(frame.result.body) &&
            isString(frame.result.body.messageId) &&
            Array.isArray(frame.result.body.deliveries)
          ) {
            this.dropNextReceiptOnly = false;
            this.receiptOnlyDrops.push({
              peerId,
              mailboxId: frame.result.body.messageId,
              droppedAt: new Date().toISOString(),
              lifecycle: { ...this.lifecycle },
            });
            // The real host already committed this send. Lose only its response:
            // RTC, Signal, event delivery and every later response remain intact.
            return;
          }
        } catch {
          /* Authentication and other responses are never selected as this fault. */
        }
      }
      await this.command({
        type: "send",
        peerId,
        channel,
        data: typeof data === "string" ? data : { binary: Array.from(new Uint8Array(data)) },
      });
    });
  override readonly disconnect = (peerId: string) => call(() => this.command({ type: "disconnect", peerId }));
  override readonly disconnectPeer = (peerId: string) => call(() => this.command({ type: "disconnect-peer", peerId }));
  override readonly setPrivateNetwork = (peerId: string, privateNetwork: boolean) =>
    call(() => this.command({ type: "set-private-network", peerId, privateNetwork }));
  override readonly stop = () =>
    call(async () => {
      await this.browser?.close();
      this.page = null;
      this.browser = null;
    });
}
