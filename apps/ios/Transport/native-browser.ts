import {
  type AgentRuntimeSnapshot,
  BROWSER_SECRET_CAPABILITY,
  BROWSER_SECRET_RESPONSE_PATH,
  type BrowserTakeoverRequest,
  isBrowserTakeoverRequest,
  parseBrowserSecretResponse,
} from "@openbot/contracts/ipc";
import { isDynamicRecord } from "@openbot/contracts/runtime-values";
import { TEAM_API_ROUTES } from "@openbot/contracts/team-api-routes";
import {
  type BrowserViewFrame,
  type BrowserViewInput,
  decodeBrowserViewInputValue,
  TEAM_BROWSER_VIEW_CAPABILITY,
  TEAM_BROWSER_VIEW_CLIPBOARD_CAPABILITY,
  TEAM_BROWSER_VIEW_FRAME_POINT_CAPABILITY,
  TEAM_BROWSER_VIEW_VIEWPORT_CAPABILITY,
} from "@openbot/contracts/team-protocol/browser-view-v1";
import { decodeTeamProtocolV2Json, type TeamProtocolV2Json } from "@openbot/contracts/team-protocol/v2";
import { runTeamEffect } from "@openbot/team-client";
import { createRemoteBrowserView, type RemoteBrowserView } from "@openbot/team-client/browser-view";
import { type NativeHostScope, NativeOperationFailure } from "./native-management";

export type NativeBrowserCommand =
  | { type: "browserSessionCapabilities"; hostId: string; browserTakeover: BrowserTakeoverRequest }
  | { type: "browserSessionOpen"; hostId: string; viewId: string; browserTakeover: BrowserTakeoverRequest }
  | { type: "browserSessionInput"; hostId: string; viewId: string; inputs: BrowserViewInput[] }
  | { type: "browserSessionFrameDone"; hostId: string; viewId: string; sequence: number; drawn: boolean }
  | { type: "browserSessionClose"; hostId: string; viewId: string }
  | {
      type: "browserTakeoverRespond";
      hostId: string;
      browserTakeover: BrowserTakeoverRequest;
      decision: "complete" | "cancel";
    }
  | {
      type: "browserSecretRespond";
      hostId: string;
      browserTakeover: BrowserTakeoverRequest;
      decision: "submit" | "takeover" | "cancel";
      secret?: string;
    };

export const BROWSER_COMMANDS = new Set<string>([
  "browserSessionCapabilities",
  "browserSessionOpen",
  "browserSessionInput",
  "browserSessionFrameDone",
  "browserSessionClose",
  "browserTakeoverRespond",
  "browserSecretRespond",
]);

export function isBrowserCommand(value: { type: string }): value is NativeBrowserCommand {
  return BROWSER_COMMANDS.has(value.type);
}

interface BrowserDependencies {
  scope(hostId: string): NativeHostScope;
  attention(): Promise<AgentRuntimeSnapshot>;
  send(data: string | ArrayBuffer): Promise<void>;
  emit(event: TeamProtocolV2Json): Promise<void>;
}

interface PendingOpen {
  hostId: string;
  viewId: string;
  request: BrowserTakeoverRequest;
  scope: NativeHostScope;
  cancelled: boolean;
}

interface OpenView {
  hostId: string;
  viewId: string;
  request: BrowserTakeoverRequest;
  scope: NativeHostScope;
  remote: ReturnType<typeof createRemoteBrowserView>;
  handle: RemoteBrowserView | null;
  drawing: number | null;
  waiting: BrowserViewFrame | null;
  closed: boolean;
}

function identity(request: BrowserTakeoverRequest): string {
  return JSON.stringify([
    request.requestId,
    request.agentId,
    request.threadId,
    request.turnId,
    request.tabId,
    request.reason ?? null,
    request.secret?.method ?? null,
    request.secret?.origin ?? null,
    request.secret?.digits ?? null,
    request.secret?.requiresReload ?? null,
  ]);
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000)
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  return btoa(binary);
}

export function createNativeBrowser(dependencies: BrowserDependencies) {
  let view: OpenView | null = null;
  let pendingOpen: PendingOpen | null = null;

  const current = (target: OpenView) => view === target && !target.closed && target.scope.current();
  const emitEnded = (target: OpenView) =>
    dependencies
      .emit({ type: "native-browser-ended", hostId: target.hostId, viewId: target.viewId })
      .catch(() => undefined);

  function detach(target: OpenView) {
    if (target.closed) return;
    target.closed = true;
    target.waiting = null;
    target.drawing = null;
    if (view === target) view = null;
    void emitEnded(target);
  }

  function cancelPending(target: PendingOpen) {
    target.cancelled = true;
    if (pendingOpen === target) pendingOpen = null;
  }

  async function closeTarget(target: OpenView) {
    detach(target);
    // A pending host POST can finish after local close. Disconnect invalidates its handshake;
    // remote.open deletes a late session, and a late handle is closed again below.
    if (!target.handle) {
      target.remote.disconnect();
      return;
    }
    try {
      await runTeamEffect(target.handle.close());
    } catch {
      target.remote.disconnect();
    }
  }

  async function close() {
    if (pendingOpen) cancelPending(pendingOpen);
    const target = view;
    if (target) await closeTarget(target);
  }

  async function closeRequest(hostId: string, request: BrowserTakeoverRequest) {
    const pending = pendingOpen;
    const target = view;
    if (pending && pending.hostId === hostId && identity(pending.request) === identity(request)) cancelPending(pending);
    if (target && target.hostId === hostId && identity(target.request) === identity(request)) await closeTarget(target);
  }

  async function checkedRequest(scope: NativeHostScope, shown: BrowserTakeoverRequest) {
    if (!isBrowserTakeoverRequest(shown)) throw new NativeOperationFailure("protocolError");
    const snapshot = await dependencies.attention();
    const request = snapshot.pendingBrowserTakeovers.find((item) => identity(item) === identity(shown));
    if (!scope.current() || !request) throw new NativeOperationFailure("sendFailed");
    return request;
  }

  function forward(target: OpenView, frame: BrowserViewFrame) {
    if (!current(target)) return;
    target.drawing = frame.sequence;
    void dependencies
      .emit({
        type: "native-browser-frame",
        hostId: target.hostId,
        viewId: target.viewId,
        sequence: frame.sequence,
        width: frame.width,
        height: frame.height,
        jpeg: base64(frame.image),
      })
      .catch(() => {
        void closeTarget(target);
      });
  }

  function targetFor(command: { hostId: string; viewId: string }): OpenView {
    const target = view;
    if (!target || !current(target) || target.hostId !== command.hostId || target.viewId !== command.viewId)
      throw new NativeOperationFailure("sendFailed");
    return target;
  }

  return {
    close,
    receive(data: string | ArrayBuffer) {
      if (view && current(view)) view.remote.receive(data);
    },
    observe(hostId: string, event: unknown) {
      if (!isDynamicRecord(event)) return;
      const targets = [pendingOpen, view];
      for (const target of targets) {
        if (!target || target.hostId !== hostId) continue;
        const request = target.request;
        let ended = false;
        if (Array.isArray(event.pendingBrowserTakeovers)) {
          const pending = event.pendingBrowserTakeovers.find(
            (item) => isBrowserTakeoverRequest(item) && identity(item) === identity(request),
          );
          ended = !pending && event.attentionComplete === true;
        } else if (event.type === "browser-takeover-requested" && isBrowserTakeoverRequest(event.request)) {
          ended =
            event.request.agentId === request.agentId &&
            event.request.requestId === request.requestId &&
            identity(event.request) !== identity(request);
        } else {
          ended =
            (event.type === "browser-takeover-resolved" &&
              event.agentId === request.agentId &&
              event.requestId === request.requestId) ||
            (event.type === "turn-completed" &&
              event.agentId === request.agentId &&
              event.threadId === request.threadId &&
              event.turnId === request.turnId);
        }
        if (ended) void closeRequest(hostId, request);
      }
    },
    async execute(command: NativeBrowserCommand): Promise<TeamProtocolV2Json> {
      if (command.type === "browserSessionClose") {
        const pending = pendingOpen;
        const target = view;
        if (pending && pending.hostId === command.hostId && pending.viewId === command.viewId) cancelPending(pending);
        if (target && target.hostId === command.hostId && target.viewId === command.viewId) await closeTarget(target);
        return {};
      }
      if (command.type === "browserSessionOpen") {
        if (
          typeof command.viewId !== "string" ||
          !/^[A-Za-z0-9_-]{1,128}$/u.test(command.viewId) ||
          !isBrowserTakeoverRequest(command.browserTakeover)
        )
          throw new NativeOperationFailure("protocolError");
        const scope = dependencies.scope(command.hostId);
        // Register before the first await. A close for this view must also cancel attention reads.
        const opening: PendingOpen = {
          hostId: command.hostId,
          viewId: command.viewId,
          request: command.browserTakeover,
          scope,
          cancelled: false,
        };
        if (pendingOpen) cancelPending(pendingOpen);
        pendingOpen = opening;
        const previous = view;
        const openingCurrent = () => pendingOpen === opening && !opening.cancelled && scope.current();
        let opened: OpenView | null = null;
        try {
          if (previous) await closeTarget(previous);
          const request = await checkedRequest(scope, opening.request);
          if (!openingCurrent()) throw new NativeOperationFailure("sendFailed");
          if (
            !scope.capabilities.includes(TEAM_BROWSER_VIEW_CAPABILITY) ||
            (request.secret && request.secret.requiresReload !== true)
          )
            throw new NativeOperationFailure("incompatible");
          const namesFrames = scope.capabilities.includes(TEAM_BROWSER_VIEW_FRAME_POINT_CAPABILITY);
          const clipboard = scope.capabilities.includes(TEAM_BROWSER_VIEW_CLIPBOARD_CAPABILITY);
          const viewport = scope.capabilities.includes(TEAM_BROWSER_VIEW_VIEWPORT_CAPABILITY);
          const remote = createRemoteBrowserView(
            async (data) => {
              if (!scope.current()) throw new NativeOperationFailure("sendFailed");
              await dependencies.send(data);
            },
            (method, path, body) => {
              if (method !== "DELETE" && (!opened || !current(opened) || !openingCurrent()))
                throw new NativeOperationFailure("sendFailed");
              return scope.request(method, path, body);
            },
            () => namesFrames,
            () => clipboard,
            () => ({ cursor: false, contextMenu: false, viewport: viewport ? { width: 1280, height: 800 } : null }),
          );
          const target: OpenView = {
            hostId: command.hostId,
            viewId: command.viewId,
            request,
            scope,
            remote,
            handle: null,
            drawing: null,
            waiting: null,
            closed: false,
          };
          opened = target;
          view = target;
          target.handle = await runTeamEffect(
            remote.open(
              request.tabId,
              (frame) => {
                if (!current(target)) return;
                if (target.drawing !== null) target.waiting = frame;
                else forward(target, frame);
              },
              () => detach(target),
              () => {},
            ),
          );
          if (!openingCurrent() || !current(target)) {
            await closeTarget(target);
            throw new NativeOperationFailure("sendFailed");
          }
          return { namesFrames, clipboard, cursor: false, contextMenu: false, viewport };
        } catch (error) {
          if (opened) await closeTarget(opened);
          throw error;
        } finally {
          if (pendingOpen === opening) pendingOpen = null;
        }
      }
      if (command.type === "browserSessionInput") {
        const target = targetFor(command);
        if (!Array.isArray(command.inputs) || command.inputs.length > 128 || !target.handle)
          throw new NativeOperationFailure("protocolError");
        for (const input of command.inputs) {
          if (!current(target)) throw new NativeOperationFailure("sendFailed");
          const decoded = decodeBrowserViewInputValue(input);
          await runTeamEffect(target.handle.input(decoded));
        }
        return {};
      }
      if (command.type === "browserSessionFrameDone") {
        const target = targetFor(command);
        if (target.drawing !== command.sequence) return {};
        if (command.drawn && target.handle)
          await runTeamEffect(target.handle.input({ type: "ack", sequence: command.sequence }));
        target.drawing = null;
        const next = target.waiting;
        target.waiting = null;
        if (next) forward(target, next);
        return {};
      }
      const scope = dependencies.scope(command.hostId);
      const request = await checkedRequest(scope, command.browserTakeover);
      const support = {
        view: scope.capabilities.includes(TEAM_BROWSER_VIEW_CAPABILITY),
        secret: scope.capabilities.includes(BROWSER_SECRET_CAPABILITY),
      };
      if (command.type === "browserSessionCapabilities") return support;
      if (command.type === "browserTakeoverRespond") {
        if (command.decision !== "cancel" && command.decision !== "complete")
          throw new NativeOperationFailure("protocolError");
        if (command.decision === "complete" && request.secret && request.secret.requiresReload !== true)
          throw new NativeOperationFailure("sendFailed");
        await scope.request("POST", TEAM_API_ROUTES.respond.browserTakeover, {
          requestId: request.requestId,
          decision: command.decision,
        });
        await closeRequest(command.hostId, request);
        return {};
      }
      if (!support.secret || !request.secret) throw new NativeOperationFailure("incompatible");
      if (command.decision === "submit" && request.secret.requiresReload === true)
        throw new NativeOperationFailure("sendFailed");
      const response = parseBrowserSecretResponse({
        requestId: request.requestId,
        agentId: request.agentId,
        decision: command.decision,
        ...(command.decision === "submit" ? { secret: command.secret } : {}),
      });
      await scope.request("POST", BROWSER_SECRET_RESPONSE_PATH, decodeTeamProtocolV2Json(response));
      await closeRequest(command.hostId, request);
      return {};
    },
  };
}
