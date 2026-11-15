import { INPUT_LIMITS } from "@openbot/contracts/input-limits";
import type { AgentApproval, AgentRuntimeSnapshot } from "@openbot/contracts/ipc";
import {
  isAgentApproval,
  isAgentEvent,
  isAttachmentSummary,
  isBrowserTakeoverRequest,
  isQueuedMessageReceipt,
} from "@openbot/contracts/ipc";
import { parseMobileConnectUrl, validateMobileConnectHostBinding } from "@openbot/contracts/mobile-connect";
import { isDynamicRecord, isString } from "@openbot/contracts/runtime-values";
import { TEAM_API_ROUTES } from "@openbot/contracts/team-api-routes";
import {
  TEAM_ANY_FILE_ATTACHMENTS_CAPABILITY,
  TEAM_MESSAGE_CLIENT_ID_CAPABILITY,
} from "@openbot/contracts/team-protocol/current";
import {
  PUSH_NOTIFICATION_THREADS_CAPABILITY,
  PUSH_NOTIFICATION_THREADS_ROUTES,
} from "@openbot/contracts/team-protocol/push-notification-threads-v1";
import {
  PUSH_NOTIFICATIONS_CAPABILITY,
  PUSH_NOTIFICATIONS_ROUTES,
  type PushNotificationRegistration,
} from "@openbot/contracts/team-protocol/push-notifications-v1";
import { decodeTeamProtocolV2Json, type TeamProtocolV2Json } from "@openbot/contracts/team-protocol/v2";
import { decodeTeamProtocolSupportV9 } from "@openbot/contracts/team-protocol/v9";
import {
  type ConversationUiBlock,
  normalizeConversationUiBlock,
  UI_BLOCK_TEXT_ACTION_ID,
  UI_CHOICE_QUESTION_ID,
  UI_CONFIRM_ACTION_QUESTION_ID,
  UI_QUICK_REPLIES_QUESTION_ID,
  uiBlockAnswersFromResponse,
  uiBlockFallbackQuestions,
  uiBlockResponseFromAnswers,
} from "@openbot/contracts/ui-blocks";
import { runTeamEffect } from "@openbot/team-client";
import { verifyEd25519Base64Url } from "@openbot/team-client/ed25519";
import {
  RemoteDirectoryError,
  RemoteTeamDirectoryClient,
  type RemoteTeamHost,
} from "@openbot/team-client/remote-directory";
import { createRemoteTeamPeer, type RemoteTeamPeerActions } from "@openbot/team-client/remote-peer";
import { createNativeBrowser, isBrowserCommand, type NativeBrowserCommand } from "./native-browser";
import {
  executeManagement,
  isManagementCommand,
  type NativeHostScope,
  type NativeManagementCommand,
  NativeOperationFailure,
} from "./native-management";

interface Session {
  apiUrl: string;
  sessionToken: string;
  userName: string;
  email: string;
  host?: { hostId: string; fingerprint: string };
  hostKeys: Record<string, string>;
}

type NativePrompt = AgentRuntimeSnapshot["pendingPrompts"][number] & {
  contextVerified?: true;
  uiBlock?: ConversationUiBlock;
};

interface PromptRecovery {
  hostId: string;
  session: Session | null;
  version: number;
  prompts: NativePrompt[];
}

type NativeFileUpload = { name: string; mimeType: string; base64: string };
const NATIVE_ATTACHMENT_BYTES = 10 * 1024 * 1024;

type Command =
  | NativeManagementCommand
  | NativeBrowserCommand
  | { type: "restore"; session: Session }
  | { type: "emailStart"; apiUrl: string; email: string; requestId: string }
  | { type: "emailVerify"; apiUrl: string; challengeId: string; code: string; deviceId: string }
  | { type: "pair"; link: string; deviceId: string }
  | { type: "hosts" }
  | { type: "connect"; hostId: string }
  | { type: "history"; agentId: string; before?: string }
  | {
      type: "send";
      agentId: string;
      text: string;
      clientMessageId: string;
      timezone: string;
      attachmentDraftIds?: string[];
      replyToMessageId?: string | null;
    }
  | { type: "uploadAttachment"; hostId: string; upload: NativeFileUpload }
  | { type: "discardAttachment"; hostId: string; attachmentId: string }
  | { type: "downloadAttachment"; hostId: string; attachmentId: string }
  | { type: "respondApproval"; hostId: string; approval: AgentApproval; decision: "accept" | "decline" }
  | { type: "respondPrompt"; hostId: string; prompt: NativePrompt; answers: Record<string, string[]> }
  | {
      type: "cancelBrowserTakeover";
      hostId: string;
      browserTakeover: AgentRuntimeSnapshot["pendingBrowserTakeovers"][number];
    }
  | { type: "interrupt"; hostId: string; agentId: string; turnId: string }
  | { type: "pushRegister"; hostId: string; registration: PushNotificationRegistration }
  | { type: "pushRemove"; hostId: string }
  | { type: "active"; value: boolean }
  | { type: "disconnect" }
  | { type: "signOut" };

type NativeCode =
  | "network"
  | "invalidLink"
  | "auth"
  | "invalidCode"
  | "incompatible"
  | "protocolError"
  | "hostMissing"
  | "unconfirmed"
  | "sendFailed";
class ClientFailure extends Error {
  constructor(readonly code: NativeCode) {
    super(code);
  }
}

type NativeMessage =
  | { type: "fetch"; url: string; method: string; headers: Record<string, string>; body: string | null }
  | { type: "event"; event: unknown }
  | { type: "pin"; hostId: string; publicKey: string };

interface NativeFetchReply {
  status: number;
  body: string;
  headers: Record<string, string>;
}

type CommandValue = Session | RemoteTeamHost[] | TeamProtocolV2Json;
type CommandReply = { ok: true; value: CommandValue } | { ok: false; code: NativeCode };

declare global {
  interface Window {
    webkit?: { messageHandlers?: { openbotNative?: { postMessage(value: NativeMessage): Promise<unknown> } } };
    openbotNative?: { execute(command: Command): Promise<CommandReply> };
  }
}

async function post<T>(message: NativeMessage, decode: (value: unknown) => T): Promise<T> {
  const handler = window.webkit?.messageHandlers?.openbotNative;
  if (!handler) throw new ClientFailure("network");
  return decode(await handler.postMessage(message));
}

async function notify(event: unknown): Promise<void> {
  await post({ type: "event", event }, decodeAcknowledgement);
}

function decodeAcknowledgement(value: unknown): void {
  if (value !== true) throw new ClientFailure("network");
}

function decodeFetchReply(answer: unknown): NativeFetchReply {
  if (
    !isDynamicRecord(answer) ||
    typeof answer.status !== "number" ||
    !isString(answer.body) ||
    !isDynamicRecord(answer.headers)
  )
    throw new ClientFailure("network");
  const headers: Record<string, string> = {};
  for (const [name, value] of Object.entries(answer.headers)) if (isString(value)) headers[name] = value;
  return { status: answer.status, body: answer.body, headers };
}

const nativeFetch: typeof fetch = async (input, init) => {
  const headers: Record<string, string> = {};
  new Headers(init?.headers).forEach((value, name) => {
    headers[name] = value;
  });
  if (init?.signal?.aborted) throw new ClientFailure("network");
  const body = init?.body;
  if (body !== undefined && body !== null && typeof body !== "string") throw new ClientFailure("network");
  const request = post(
    {
      type: "fetch",
      url: input instanceof Request ? input.url : String(input),
      method: init?.method ?? "GET",
      headers,
      body: body ?? null,
    },
    decodeFetchReply,
  );
  const answer = await new Promise<NativeFetchReply>((resolve, reject) => {
    const abort = () => reject(new ClientFailure("network"));
    init?.signal?.addEventListener("abort", abort, { once: true });
    request.then(resolve, reject).finally(() => init?.signal?.removeEventListener("abort", abort));
  });
  return new Response(answer.status === 204 || answer.status === 304 ? null : answer.body, {
    status: answer.status,
    headers: answer.headers,
  });
};

let session: Session | null = null;
let directory: RemoteTeamDirectoryClient | null = null;
let peer: ReturnType<typeof createRemoteTeamPeer> | null = null;
let capabilities: readonly string[] = [];
let commandNumber = 0;
let selectedHost: string | null = null;
let selectedRole: RemoteTeamHost["role"] | null = null;
let selectedMembership: string | null = null;
let clientActive = true;
let nativeBrowser: ReturnType<typeof createNativeBrowser> | null = null;
let listedHosts: RemoteTeamHost[] | null = null;
let cachedAgents: TeamProtocolV2Json | null = null;
let attentionVersion = 0;
let nextPromptRecovery: PromptRecovery | null = null;
let recoveringPrompts: Promise<void> | null = null;

function getSession(): Session {
  if (!session) throw new ClientFailure("auth");
  return session;
}

async function account(
  apiUrl: string,
  path: string,
  body?: Record<string, string>,
  extraHeaders?: Record<string, string>,
  method = "POST",
) {
  const response = await nativeFetch(new URL(path, apiUrl), {
    method,
    headers: { "content-type": "application/json", ...extraHeaders },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(35_000),
  });
  if (response.status === 401) {
    await notify({ type: "expired" });
    throw new ClientFailure("auth");
  }
  if (!response.ok) throw new ClientFailure(path.includes("verify") ? "invalidCode" : "network");
  if (response.status === 204) return {};
  return decodeTeamProtocolV2Json(await response.json());
}

function decodeSession(value: unknown, apiUrl: string): Session {
  if (
    !isDynamicRecord(value) ||
    !isString(value.sessionToken) ||
    value.sessionToken.length < 16 ||
    value.sessionToken.length > 512 ||
    !isDynamicRecord(value.user) ||
    !isString(value.user.email)
  )
    throw new ClientFailure("auth");
  return {
    apiUrl,
    sessionToken: value.sessionToken,
    userName: isString(value.user.name) ? value.user.name : value.user.email,
    email: value.user.email,
    hostKeys: {},
  };
}

async function installSession(value: Session) {
  invalidatePromptRecovery();
  await nativeBrowser?.close();
  if (peer) await peer.dispose();
  peer = null;
  selectedHost = null;
  selectedRole = null;
  selectedMembership = null;
  capabilities = [];
  listedHosts = null;
  cachedAgents = null;
  session = value;
  directory = new RemoteTeamDirectoryClient({
    apiUrl: value.apiUrl,
    token: value.sessionToken,
    fetch: nativeFetch,
    pairedHost: value.host,
    inviteLinks: { allowLocalDevelopmentApiUrl: new URL(value.apiUrl).protocol === "http:" },
    verifyHostKeySignature: verifyEd25519Base64Url,
    hostKeys: {
      get: async (hostId) => value.hostKeys[hostId] ?? null,
      set: async (hostId, publicKey) => {
        await post({ type: "pin", hostId, publicKey }, decodeAcknowledgement);
        value.hostKeys[hostId] = publicKey;
      },
    },
  });
}

function getDirectory(): RemoteTeamDirectoryClient {
  if (!directory) throw new ClientFailure("auth");
  return directory;
}

function getPeer() {
  if (peer) return peer;
  const actions: { current: RemoteTeamPeerActions } = {
    current: {
      getBootstrap: (hostId, key, retainedSession) =>
        runTeamEffect(getDirectory().createBootstrap(hostId, key, retainedSession)),
      endSession: (id) => runTeamEffect(getDirectory().endSession(id)),
      onConnectionUpdate: async (update) => {
        if (update.state !== "online") void nativeBrowser?.close();
        await notify({
          type: "connection",
          hostId: update.hostId,
          state: update.state,
          code: update.code ?? null,
          resync: update.resync ?? false,
        });
      },
      onHostStreamData: (data) => nativeBrowser?.receive(data),
      onTeamEvent: async (hostId, event) => {
        if (hostId === selectedHost && event.type === "agents-changed")
          cachedAgents = decodeTeamProtocolV2Json(event.agents);
        if (hostId === selectedHost) {
          nativeBrowser?.observe(hostId, event.type === "runtime-snapshot" ? event.snapshot : event);
          if (event.type === "prompt" || event.type === "agent-input-resolved" || event.type === "turn-completed")
            invalidatePromptRecovery();
          if (event.type === "prompt") {
            // A prompt event has only the fallback questions, not an ask_ui confirmation's full preview.
            await notify({ type: "team", hostId, event: { ...event, type: "prompt-context-pending" } });
            recoverPrompts(hostId, [event]);
            // Recover all pending requests as well if several agents asked at the same time.
            void currentAttention().catch(() => undefined);
            return;
          }
          await notify({ type: "team", hostId, event });
          if (event.type === "runtime-snapshot") {
            snapshotWaiter?.resolve(event.snapshot);
            // The native model first prunes from the compact snapshot, then accepts full questions.
            recoverPrompts(hostId, event.snapshot.pendingPrompts);
          }
        }
      },
    },
  };
  peer = createRemoteTeamPeer(actions);
  return peer;
}

let snapshotWaiter: { resolve: (snapshot: AgentRuntimeSnapshot) => void } | null = null;
let refreshing: Promise<AgentRuntimeSnapshot> | null = null;
let nextAttentionRequestAt = 0;

async function currentAttention(): Promise<AgentRuntimeSnapshot> {
  if (!capabilities.includes("agent-runtime-snapshots")) throw new ClientFailure("incompatible");
  if (refreshing) return refreshing;
  const ownerSession = session;
  const ownerHost = selectedHost;
  const ownerPeer = getPeer();
  const current = () => session === ownerSession && selectedHost === ownerHost && peer === ownerPeer;
  refreshing = (async () => {
    // The released host silently drops explicit snapshot requests within one second.
    // Wait from the prior response, so a change in network latency cannot shorten the host's interval.
    const delay = nextAttentionRequestAt - Date.now();
    if (delay > 0) await new Promise<void>((resolveDelay) => setTimeout(resolveDelay, delay));
    if (!current()) throw new ClientFailure("network");
    let timer: ReturnType<typeof setTimeout> | undefined;
    const received = new Promise<AgentRuntimeSnapshot>((resolveSnapshot, reject) => {
      snapshotWaiter = { resolve: resolveSnapshot };
      timer = setTimeout(() => reject(new ClientFailure("network")), 10_000);
    });
    try {
      const [, snapshot] = await Promise.all([ownerPeer.refreshRuntimeSnapshot(), received]);
      if (!current()) throw new ClientFailure("network");
      nextAttentionRequestAt = Date.now() + 1_000;
      return snapshot;
    } finally {
      clearTimeout(timer);
      snapshotWaiter = null;
    }
  })();
  try {
    return await refreshing;
  } finally {
    refreshing = null;
  }
}

function approvalIdentity(approval: AgentApproval) {
  return JSON.stringify([
    approval.requestId,
    approval.agentId,
    approval.threadId,
    approval.turnId,
    approval.kind,
    approval.command,
    approval.cwd,
    approval.reason,
    approval.grantRoot,
    approval.permissions?.fileSystem.read ?? null,
    approval.permissions?.fileSystem.write ?? null,
    approval.permissions?.network ?? null,
  ]);
}

function decodePrompt(value: unknown): NativePrompt | null {
  if (!isDynamicRecord(value)) return null;
  const event = { ...value, type: "prompt" };
  if (!isAgentEvent(event) || event.type !== "prompt" || event.questions.length === 0) return null;
  if (new Set(event.questions.map((question) => question.id)).size !== event.questions.length) return null;
  const block = value.uiBlock === undefined ? undefined : normalizeConversationUiBlock(value.uiBlock);
  if (block === null || (block && block.state.status !== "pending")) return null;
  return {
    ...event,
    ...(value.contextVerified === true ? { contextVerified: true } : {}),
    ...(block ? { uiBlock: block } : {}),
  };
}

function promptIdentity(prompt: NativePrompt): string {
  return JSON.stringify([prompt.requestId, prompt.agentId, prompt.threadId, prompt.turnId]);
}

function promptQuestions(prompt: NativePrompt): string {
  return JSON.stringify(
    prompt.questions.map((question) => [
      question.id,
      question.header,
      question.question,
      question.isSecret,
      question.options?.map((option) => [option.label, option.description]) ?? null,
      question.multiSelect === true,
    ]),
  );
}

function promptContext(prompt: NativePrompt): string {
  return JSON.stringify(prompt.uiBlock ?? null);
}

function hasCompletePlainPromptContext(prompt: NativePrompt): boolean {
  const fallbackIds = new Set([UI_CONFIRM_ACTION_QUESTION_ID, UI_CHOICE_QUESTION_ID, UI_QUICK_REPLIES_QUESTION_ID]);
  return prompt.questions.every(
    (question) =>
      // These frozen IDs can identify a block whose full spec was omitted from a bounded page.
      // Exact-limit plain questions can also be clipped fallbacks; require the Mac in either case.
      !fallbackIds.has(question.id) &&
      question.header.length < INPUT_LIMITS.promptHeader &&
      question.question.length < INPUT_LIMITS.promptQuestion &&
      (question.options ?? []).every(
        (option) =>
          option.label.length < INPUT_LIMITS.promptOptionLabel &&
          option.description.length < INPUT_LIMITS.promptOptionDescription,
      ),
  );
}

function browserTakeoverIdentity(request: AgentRuntimeSnapshot["pendingBrowserTakeovers"][number]): string {
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

function checkedPromptAnswers(prompt: NativePrompt, value: unknown): Record<string, string[]> {
  if (!isDynamicRecord(value)) throw new ClientFailure("protocolError");
  const entries = Object.entries(value);
  if (entries.length > INPUT_LIMITS.promptQuestions) throw new ClientFailure("protocolError");
  let total = 0;
  const answers: Array<[string, string[]]> = [];
  for (const [id, values] of entries) {
    const question = prompt.questions.find((item) => item.id === id);
    if (
      !question ||
      !Array.isArray(values) ||
      values.length > (question.multiSelect ? INPUT_LIMITS.promptAnswersPerQuestion : 1) ||
      // Released Team codecs cap each answer at 20,000 characters.
      !values.every((answer) => isString(answer) && answer.length <= 20_000)
    )
      throw new ClientFailure("protocolError");
    const text = values.filter(isString);
    total += text.reduce((length, answer) => length + answer.length, 0);
    if (total > INPUT_LIMITS.promptAnswersTotalText) throw new ClientFailure("protocolError");
    answers.push([id, text]);
  }
  return Object.fromEntries(answers);
}

async function historyPage(agentId: string, before?: string, limit = 50) {
  const query = new URLSearchParams({ limit: String(limit) });
  if (before !== undefined) query.set("before", before);
  return request("GET", `${TEAM_API_ROUTES.agent.conversationPage(agentId)}?${query}`);
}

/** Runtime questions can be silently shortened. Only conversation messages carry the full form. */
async function fullPrompt(expected: NativePrompt, hostId: string): Promise<NativePrompt | null> {
  let before: string | undefined;
  const seen = new Set<string>();
  // A pending main-chat form is normally on the latest page. Bound recovery of an older one.
  for (let pageNumber = 0; pageNumber < 20; pageNumber++) {
    if (selectedHost !== hostId) return null;
    const page = await historyPage(expected.agentId, before, 100);
    if (
      !isDynamicRecord(page) ||
      page.agentId !== expected.agentId ||
      page.threadId !== expected.threadId ||
      page.activeTurnId !== expected.turnId ||
      !Array.isArray(page.messages)
    )
      return null;
    for (let message of page.messages) {
      if (!isDynamicRecord(message) || message.turnId !== expected.turnId) continue;
      let form = message.questionPrompt;
      if (!isDynamicRecord(form) || form.requestId !== expected.requestId || form.resolution !== null) continue;
      if (message.uiBlock === undefined && capabilities.includes("ui-blocks-v1") && isString(message.id)) {
        // A large page can omit an older block under the aggregate wire budget. Ask for its narrowest frozen page.
        const messageId = message.id;
        const query = new URLSearchParams({ around: messageId, limit: "1" });
        const narrow = await request("GET", `${TEAM_API_ROUTES.agent.conversationPage(expected.agentId)}?${query}`);
        if (
          selectedHost !== hostId ||
          !isDynamicRecord(narrow) ||
          narrow.agentId !== expected.agentId ||
          narrow.threadId !== expected.threadId ||
          narrow.activeTurnId !== expected.turnId ||
          !Array.isArray(narrow.messages)
        )
          return null;
        const found = narrow.messages.find((item) => isDynamicRecord(item) && item.id === messageId);
        if (!isDynamicRecord(found) || found.turnId !== expected.turnId) return null;
        message = found;
        form = message.questionPrompt;
        if (!isDynamicRecord(form) || form.requestId !== expected.requestId || form.resolution !== null) return null;
      }
      const prompt = decodePrompt({
        ...expected,
        questions: form.questions,
        contextVerified: true,
        uiBlock: message.uiBlock,
      });
      if (prompt?.uiBlock) {
        // Other block types can carry custom submit, field validation or Vault semantics.
        // Until this client renders those semantics, their generic fallback must not approve an action.
        if (
          prompt.uiBlock.spec.type !== "confirm" ||
          promptQuestions(prompt) !==
            promptQuestions({ ...prompt, questions: uiBlockFallbackQuestions(prompt.uiBlock.spec) })
        )
          return null;
      } else if (prompt && !hasCompletePlainPromptContext(prompt)) return null;
      return prompt;
    }
    const info = page.pageInfo;
    if (!isDynamicRecord(info) || !info.hasOlder || !isString(info.olderCursor) || seen.has(info.olderCursor))
      return null;
    before = info.olderCursor;
    seen.add(before);
  }
  return null;
}

function invalidatePromptRecovery() {
  attentionVersion++;
  nextPromptRecovery = null;
}

function recoverPrompts(hostId: string, prompts: NativePrompt[]) {
  const version = ++attentionVersion;
  nextPromptRecovery = { hostId, session, version, prompts };
  if (recoveringPrompts) return;
  recoveringPrompts = (async () => {
    while (nextPromptRecovery) {
      const recovery = nextPromptRecovery;
      nextPromptRecovery = null;
      const current = () =>
        recovery.version === attentionVersion && recovery.hostId === selectedHost && recovery.session === session;
      for (const pending of recovery.prompts) {
        if (!current()) break;
        try {
          const prompt = await fullPrompt(pending, recovery.hostId);
          if (!current()) break;
          if (prompt) await notify({ type: "team", hostId: recovery.hostId, event: { type: "prompt", ...prompt } });
        } catch {
          // Keep the native pending notice. A compact or unavailable form must not be answered.
        }
      }
    }
  })().finally(() => {
    recoveringPrompts = null;
  });
}

async function request(
  method: string,
  path: string,
  body: TeamProtocolV2Json = {},
  timeoutMs?: number,
  upload?: NativeFileUpload,
) {
  const mutates = method !== "GET" && method !== "HEAD";
  const result = await getPeer().execute({
    id: `native-${++commandNumber}`,
    type: "request",
    method,
    path,
    body,
    ...(upload ? { upload } : {}),
    timeoutMs: timeoutMs ?? 15_000,
  });
  const status = result.ok ? result.status : result.requestStatus;
  // A host refusal has a confirmed outcome even when RPC wraps it as an error.
  if (status === 401) throw new ClientFailure("auth");
  if (status === 403) throw new ClientFailure(mutates ? "sendFailed" : "network");
  if (!result.ok) throw new ClientFailure(mutates ? "unconfirmed" : "network");
  if (status !== undefined && status >= 400) {
    if (mutates && status >= 500) throw new ClientFailure("unconfirmed");
    throw new ClientFailure(mutates ? "sendFailed" : "network");
  }
  if (status === 204) return {};
  if (result.body === undefined) throw new ClientFailure(mutates ? "unconfirmed" : "network");
  return result.body;
}

function hostScope(hostId: string): NativeHostScope {
  const ownerSession = session;
  const ownerPeer = peer;
  const ownerMembership = selectedMembership;
  if (!ownerSession || !ownerPeer || hostId !== selectedHost || !selectedRole || !ownerMembership || !clientActive)
    throw new ClientFailure("sendFailed");
  const ownerRole = selectedRole;
  const current = () =>
    session === ownerSession &&
    peer === ownerPeer &&
    selectedHost === hostId &&
    selectedMembership === ownerMembership &&
    selectedRole === ownerRole &&
    clientActive;
  return {
    role: selectedRole,
    capabilities: [...capabilities],
    current,
    request: async (method, path, body) => {
      if (!current()) throw new NativeOperationFailure("sendFailed");
      const value = await request(method, path, body);
      if (!current()) throw new NativeOperationFailure(method === "GET" ? "sendFailed" : "unconfirmed");
      return value;
    },
  };
}

function browserController() {
  nativeBrowser ??= createNativeBrowser({
    scope: hostScope,
    attention: currentAttention,
    send: (data) => getPeer().sendHostStreamData(data),
    emit: (event) => notify({ type: "team", hostId: isDynamicRecord(event) ? event.hostId : selectedHost, event }),
  });
  return nativeBrowser;
}

async function execute(command: Command): Promise<CommandValue> {
  if (isManagementCommand(command)) {
    const scope = hostScope(command.hostId);
    const value = await executeManagement(scope, command);
    if (["createAgent", "updateAgent", "deleteAgent"].includes(command.type) && scope.current()) {
      // The mutation is already confirmed. A lost follow-up read must not invite a second create.
      let agents = await scope.request("GET", TEAM_API_ROUTES.agents.all).catch(() => null);
      if (agents === null && Array.isArray(cachedAgents)) {
        if (command.type === "deleteAgent") {
          agents = cachedAgents.filter((item) => !isDynamicRecord(item) || item.id !== command.agentId);
        } else if (isDynamicRecord(value) && isString(value.id)) {
          agents = [...cachedAgents.filter((item) => !isDynamicRecord(item) || item.id !== value.id), value];
        }
      }
      if (agents !== null && scope.current()) {
        cachedAgents = agents;
        await notify({ type: "team", hostId: command.hostId, event: { type: "agents-changed", agents } });
      }
    }
    return value;
  }
  if (isBrowserCommand(command)) return browserController().execute(command);
  switch (command.type) {
    case "emailStart": {
      const value = await account(
        command.apiUrl,
        "/v1/auth/email/start",
        { email: command.email.trim() },
        { "Idempotency-Key": command.requestId },
      );
      if (!isDynamicRecord(value) || !isString(value.challengeId)) throw new ClientFailure("network");
      return {
        challengeId: value.challengeId,
        developmentCode: isString(value.developmentCode) ? value.developmentCode : null,
      };
    }
    case "emailVerify": {
      const value = await account(command.apiUrl, "/v1/mobile-auth/email/verify", {
        challengeId: command.challengeId,
        code: command.code.trim(),
        deviceId: command.deviceId,
        deviceName: "OpenBot Native iPhone",
        platform: "ios",
      });
      const authenticated = decodeSession(value, command.apiUrl);
      await installSession(authenticated);
      return authenticated;
    }
    case "pair": {
      const payload = parseMobileConnectUrl(command.link);
      if (!payload?.host) throw new ClientFailure("invalidLink");
      const value = await account(payload.apiUrl, "/v1/mobile-auth/redeem", {
        ticket: payload.ticket,
        deviceId: command.deviceId,
        deviceName: "OpenBot Native iPhone",
        platform: "ios",
      });
      const authenticated = decodeSession(value, payload.apiUrl);
      try {
        authenticated.host = validateMobileConnectHostBinding(
          payload.host,
          isDynamicRecord(value) ? value.host : undefined,
        );
      } catch {
        throw new ClientFailure("invalidLink");
      }
      await installSession(authenticated);
      return authenticated;
    }
    case "restore":
      await installSession(command.session);
      await account(
        command.session.apiUrl,
        "/v1/mobile-auth/session",
        undefined,
        { authorization: `Bearer ${command.session.sessionToken}` },
        "GET",
      );
      return {};
    case "hosts": {
      listedHosts = await runTeamEffect(getDirectory().listHosts());
      return listedHosts;
    }
    case "connect": {
      const host = (listedHosts ?? (await runTeamEffect(getDirectory().listHosts()))).find(
        (candidate) => candidate.hostId === command.hostId,
      );
      listedHosts = null;
      if (!host) throw new ClientFailure("hostMissing");
      if (selectedHost !== host.hostId) {
        await nativeBrowser?.close();
        invalidatePromptRecovery();
        cachedAgents = null;
        capabilities = [];
      }
      selectedHost = host.hostId;
      selectedRole = host.role;
      selectedMembership = host.membershipId;
      clientActive = true;
      const current = getPeer();
      current.setActive(true);
      const connected = await current.execute({
        id: `native-${++commandNumber}`,
        type: "connect",
        hostId: host.hostId,
        hostPublicKey: host.devicePublicKey,
      });
      if (!connected.ok)
        throw new ClientFailure(connected.reference?.endsWith("/protocol_error") ? "protocolError" : "network");
      if (!connected.kept || cachedAgents === null) {
        const compatibility = decodeTeamProtocolSupportV9(await request("GET", TEAM_API_ROUTES.compatibility));
        capabilities = compatibility.capabilities;
        cachedAgents = await request("GET", TEAM_API_ROUTES.agents.all);
      }
      if (capabilities.includes("agent-runtime-snapshots")) await currentAttention();
      return {
        agents: cachedAgents,
        kept: connected.kept ?? false,
        deduplicatesMessages: capabilities.includes(TEAM_MESSAGE_CLIENT_ID_CAPABILITY),
        supportsPush: capabilities.includes(PUSH_NOTIFICATIONS_CAPABILITY),
        supportsAttachments: capabilities.includes(TEAM_ANY_FILE_ATTACHMENTS_CAPABILITY),
        capabilities: [...capabilities],
        role: host.role,
        features: {
          agents: true,
          agentCreate: true,
          agentDelete: host.role !== "member",
          routines: true,
          routineHistory: true,
          reactions: true,
          notificationPreferences: capabilities.includes("agent-notification-levels-v1"),
          browserView: capabilities.includes("browser-view"),
          browserSecretHandoff: capabilities.includes("browser-secret-handoff"),
        },
        hostName: host.name,
      };
    }
    case "history": {
      const ownerHost = selectedHost;
      const ownerSession = session;
      const page = await historyPage(command.agentId, command.before);
      if (
        command.before === undefined &&
        ownerHost !== null &&
        selectedHost === ownerHost &&
        session === ownerSession
      ) {
        try {
          const queue = await request("GET", TEAM_API_ROUTES.agent.queue(command.agentId));
          if (selectedHost === ownerHost && session === ownerSession)
            await notify({ type: "team", hostId: ownerHost, event: { type: "queue-changed", snapshot: queue } });
        } catch {
          // A queue read must not discard successfully loaded conversation history.
        }
      }
      return page;
    }
    case "send": {
      const { agentId, text, clientMessageId, timezone } = command;
      const replyToMessageId = command.replyToMessageId ?? null;
      const drafts = command.attachmentDraftIds ?? [];
      if (
        !Array.isArray(drafts) ||
        drafts.length > INPUT_LIMITS.attachments ||
        drafts.some((id) => !isString(id) || id.length === 0 || id.length > INPUT_LIMITS.identifier) ||
        new Set(drafts).size !== drafts.length ||
        (replyToMessageId !== null &&
          (!isString(replyToMessageId) ||
            replyToMessageId.length === 0 ||
            replyToMessageId.length > INPUT_LIMITS.identifier))
      )
        throw new ClientFailure("protocolError");
      const attachmentDraftIds = [...drafts];
      if (!selectedHost) throw new ClientFailure("sendFailed");
      const scope = hostScope(selectedHost);
      if (attachmentDraftIds.length && !scope.capabilities.includes(TEAM_ANY_FILE_ATTACHMENTS_CAPABILITY))
        throw new ClientFailure("incompatible");
      if (replyToMessageId !== null) {
        // The released send accepts a reference, but does not establish that it is in this chat.
        // An authoritative around page finds an older target without depending on the native cache.
        const query = new URLSearchParams({ around: replyToMessageId, limit: "1" });
        const target = await scope.request("GET", `${TEAM_API_ROUTES.agent.conversationPage(agentId)}?${query}`);
        if (
          !isDynamicRecord(target) ||
          target.agentId !== agentId ||
          !Array.isArray(target.messages) ||
          !target.messages.some((message) => isDynamicRecord(message) && message.id === replyToMessageId)
        )
          throw new ClientFailure("sendFailed");
      }
      if (!scope.current()) throw new ClientFailure("sendFailed");
      const receipt = await request(
        "POST",
        TEAM_API_ROUTES.agent.messages(agentId),
        {
          text,
          attachmentDraftIds,
          replyToMessageId,
          timezone,
          ...(scope.capabilities.includes(TEAM_MESSAGE_CLIENT_ID_CAPABILITY) ? { clientMessageId } : {}),
        },
        30_000,
      );
      if (!scope.current()) throw new ClientFailure("unconfirmed");
      if (!isQueuedMessageReceipt(receipt)) throw new ClientFailure("unconfirmed");
      const delivery = receipt.deliveries.find((item) => item.recipientAgentId === agentId);
      if (!delivery) throw new ClientFailure("unconfirmed");
      return { conversationMessageId: delivery.id };
    }
    case "uploadAttachment": {
      if (command.hostId !== selectedHost) throw new ClientFailure("sendFailed");
      if (!capabilities.includes(TEAM_ANY_FILE_ATTACHMENTS_CAPABILITY)) throw new ClientFailure("incompatible");
      const upload = command.upload;
      if (
        !isDynamicRecord(upload) ||
        !isString(upload.name) ||
        !upload.name.length ||
        upload.name.length > INPUT_LIMITS.attachmentName ||
        /[\\/\p{Cc}]/u.test(upload.name) ||
        !isString(upload.mimeType) ||
        upload.mimeType.length > INPUT_LIMITS.mimeType ||
        !isString(upload.base64) ||
        upload.base64.length > Math.ceil(NATIVE_ATTACHMENT_BYTES / 3) * 4
      )
        throw new ClientFailure("protocolError");
      const query = new URLSearchParams({ name: upload.name, mime: upload.mimeType });
      const attachment = await request("POST", `${TEAM_API_ROUTES.attachments}?${query}`, {}, 75_000, upload);
      if (
        command.hostId !== selectedHost ||
        !isAttachmentSummary(attachment) ||
        !Number.isSafeInteger(attachment.size) ||
        attachment.size > NATIVE_ATTACHMENT_BYTES
      )
        throw new ClientFailure("network");
      return attachment;
    }
    case "discardAttachment": {
      if (command.hostId !== selectedHost) throw new ClientFailure("sendFailed");
      await request("DELETE", TEAM_API_ROUTES.attachment(command.attachmentId));
      return {};
    }
    case "downloadAttachment": {
      if (command.hostId !== selectedHost) throw new ClientFailure("sendFailed");
      // The shared peer verifies the file digest and its 10 MiB native transfer limit.
      const value = await request("GET", TEAM_API_ROUTES.attachment(command.attachmentId), {}, 75_000);
      if (
        command.hostId !== selectedHost ||
        !isDynamicRecord(value) ||
        !isString(value.name) ||
        !isString(value.mimeType) ||
        !isString(value.base64) ||
        value.base64.length > Math.ceil(NATIVE_ATTACHMENT_BYTES / 3) * 4
      )
        throw new ClientFailure("network");
      return value;
    }
    case "respondApproval": {
      if (command.hostId !== selectedHost || !isAgentApproval(command.approval))
        throw new ClientFailure("protocolError");
      const snapshot = await currentAttention();
      const pending = snapshot.pendingApprovals.find(
        (approval) => approvalIdentity(approval) === approvalIdentity(command.approval),
      );
      if (command.hostId !== selectedHost || !pending || (pending.truncated && command.decision === "accept"))
        throw new ClientFailure("sendFailed");
      await request("POST", TEAM_API_ROUTES.respond.approval, {
        requestId: pending.requestId,
        decision: command.decision,
      });
      await currentAttention();
      return {};
    }
    case "respondPrompt": {
      const ownerSession = session;
      const shown = decodePrompt(command.prompt);
      if (command.hostId !== selectedHost || !shown || shown.contextVerified !== true)
        throw new ClientFailure("protocolError");
      const snapshot = await currentAttention();
      const pending = snapshot.pendingPrompts.find((prompt) => promptIdentity(prompt) === promptIdentity(shown));
      if (!pending || command.hostId !== selectedHost) throw new ClientFailure("sendFailed");
      const full = await fullPrompt(pending, command.hostId);
      if (!full || promptQuestions(full) !== promptQuestions(shown) || promptContext(full) !== promptContext(shown))
        throw new ClientFailure("sendFailed");
      let answers = checkedPromptAnswers(full, command.answers);
      if (full.uiBlock?.spec.type === "confirm" && Object.keys(answers).length > 0) {
        const response = uiBlockResponseFromAnswers(full.uiBlock.spec, answers);
        if (!response || response.actionId === UI_BLOCK_TEXT_ACTION_ID) throw new ClientFailure("protocolError");
        answers = checkedPromptAnswers(full, uiBlockAnswersFromResponse(full.uiBlock.spec, response));
      }
      const latest = await currentAttention();
      if (
        command.hostId !== selectedHost ||
        session !== ownerSession ||
        !latest.pendingPrompts.some((prompt) => promptIdentity(prompt) === promptIdentity(full))
      )
        throw new ClientFailure("sendFailed");
      const confirmed = await fullPrompt(full, command.hostId);
      if (
        !confirmed ||
        command.hostId !== selectedHost ||
        session !== ownerSession ||
        promptQuestions(confirmed) !== promptQuestions(shown) ||
        promptContext(confirmed) !== promptContext(shown)
      )
        throw new ClientFailure("sendFailed");
      await request("POST", TEAM_API_ROUTES.respond.prompt, { requestId: full.requestId, answers });
      // A confirmed answer stays confirmed when the later attention refresh fails.
      await currentAttention().catch(() => undefined);
      return {};
    }
    case "cancelBrowserTakeover": {
      const ownerSession = session;
      if (command.hostId !== selectedHost) throw new ClientFailure("sendFailed");
      const shown = command.browserTakeover;
      if (!isBrowserTakeoverRequest(shown)) throw new ClientFailure("protocolError");
      const snapshot = await currentAttention();
      const pending = snapshot.pendingBrowserTakeovers.find(
        (item) => browserTakeoverIdentity(item) === browserTakeoverIdentity(shown),
      );
      if (!pending || selectedHost !== command.hostId || session !== ownerSession)
        throw new ClientFailure("sendFailed");
      await request("POST", TEAM_API_ROUTES.respond.browserTakeover, {
        requestId: pending.requestId,
        decision: "cancel",
      });
      await currentAttention().catch(() => undefined);
      return {};
    }
    case "interrupt": {
      if (command.hostId !== selectedHost) throw new ClientFailure("sendFailed");
      const page = await historyPage(command.agentId);
      if (
        command.hostId !== selectedHost ||
        !isDynamicRecord(page) ||
        page.agentId !== command.agentId ||
        page.activeTurnId !== command.turnId
      )
        throw new ClientFailure("sendFailed");
      await request("POST", TEAM_API_ROUTES.agent.interrupt(command.agentId), { turnId: command.turnId });
      await currentAttention().catch(() => undefined);
      return {};
    }
    case "pushRegister": {
      if (command.hostId !== selectedHost || !capabilities.includes(PUSH_NOTIFICATIONS_CAPABILITY))
        throw new ClientFailure("incompatible");
      await request("POST", PUSH_NOTIFICATIONS_ROUTES.register, decodeTeamProtocolV2Json(command.registration));
      if (capabilities.includes(PUSH_NOTIFICATION_THREADS_CAPABILITY))
        await request("POST", PUSH_NOTIFICATION_THREADS_ROUTES.set, { replies: false });
      return {};
    }
    case "pushRemove": {
      if (command.hostId !== selectedHost || !capabilities.includes(PUSH_NOTIFICATIONS_CAPABILITY))
        throw new ClientFailure("incompatible");
      await request("POST", PUSH_NOTIFICATIONS_ROUTES.remove);
      return {};
    }
    case "active":
      if (!command.value) await nativeBrowser?.close();
      clientActive = command.value;
      peer?.setActive(command.value);
      return {};
    case "disconnect":
      invalidatePromptRecovery();
      await nativeBrowser?.close();
      if (peer) await peer.dispose();
      peer = null;
      selectedHost = null;
      selectedRole = null;
      selectedMembership = null;
      return {};
    case "signOut": {
      invalidatePromptRecovery();
      await nativeBrowser?.close();
      const credential = getSession();
      if (capabilities.includes(PUSH_NOTIFICATIONS_CAPABILITY)) {
        await request("POST", PUSH_NOTIFICATIONS_ROUTES.remove).catch(() => undefined);
      }
      const response = await nativeFetch(new URL("/v1/mobile-auth/session", credential.apiUrl), {
        method: "DELETE",
        headers: { authorization: `Bearer ${credential.sessionToken}` },
        signal: AbortSignal.timeout(10_000),
      });
      if (!response.ok && response.status !== 401) throw new ClientFailure("network");
      if (peer) await peer.dispose();
      peer = null;
      directory = null;
      session = null;
      selectedHost = null;
      selectedRole = null;
      selectedMembership = null;
      return {};
    }
  }
}

window.openbotNative = {
  async execute(command) {
    try {
      return { ok: true, value: await execute(command) };
    } catch (error) {
      const code =
        error instanceof ClientFailure || error instanceof NativeOperationFailure
          ? error.code
          : error instanceof RemoteDirectoryError && error.status === 401
            ? "auth"
            : "network";
      return { ok: false, code };
    }
  },
};
