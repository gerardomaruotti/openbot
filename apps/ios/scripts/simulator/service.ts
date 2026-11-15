import { type ChildProcess, spawn } from "node:child_process";
import { createHash, generateKeyPairSync, randomBytes } from "node:crypto";
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { AGENT_PROVIDERS, type ConversationMessage } from "@openbot/contracts/ipc";
import { createMobileConnectUrl } from "@openbot/contracts/mobile-connect";
import { isDynamicRecord, isString } from "@openbot/contracts/runtime-values";
import {
  TEAM_APP_VERSION_HEADER,
  TEAM_CAPABILITIES_HEADER,
  TEAM_CURRENT_CAPABILITIES,
  TEAM_PROTOCOL_VERSION_HEADER,
} from "@openbot/contracts/team-protocol";
import {
  PUSH_NOTIFICATIONS_ROUTES,
  type PushNotificationRegistration,
} from "@openbot/contracts/team-protocol/push-notifications-v1";
import { createOpenBotLogger, registerSecretValue } from "@openbot/logging";
import { Effect } from "effect";
import { sqliteD1 } from "../../../../apps/auth-api/scripts/sqlite-d1";
import { AuthService, AuthServiceError } from "../../../../apps/auth-api/src/server/auth-service";
import { sha256 } from "../../../../apps/auth-api/src/server/crypto";
import { D1AuthRepository } from "../../../../apps/auth-api/src/server/d1-auth-repository";
import {
  RemoteControlPlane,
  RemoteControlPlaneError,
  verifyRemoteServiceSignature,
} from "../../../../apps/auth-api/src/server/remote-control-plane";
import { NO_APPROVAL_AUTOMATION } from "../../../../src/backend/agent/approval-automation";
import { AgentService } from "../../../../src/backend/agent-service";
import { AgentStore } from "../../../../src/backend/agent-store";
import { CodexAppServerClient } from "../../../../src/backend/app-server-client";
import { MailboxStore } from "../../../../src/backend/mailbox-store";
import { OpenBotDatabase } from "../../../../src/backend/openbot-database";
import { NO_PROVIDER_CREDENTIALS } from "../../../../src/backend/provider-drivers";
import { SidebarLayoutStore } from "../../../../src/backend/sidebar-layout-store";
import { AgentAccessStore } from "../../../../src/main/agent-access-store";
import { AgentNotificationLevelStore } from "../../../../src/main/agent-notification-level-store";
import { CentralAuthManager } from "../../../../src/main/central-auth-manager";
import { PushNotificationStore } from "../../../../src/main/push-notification-store";
import {
  type NotificationRelayRequest,
  PushNotificationSendFailure,
  PushNotificationService,
} from "../../../../src/main/push-notifications";
import { RemoteWorkflowError } from "../../../../src/main/remote-service-effects";
import { TeamApiServer } from "../../../../src/main/team-api-server";
import { TeamStore } from "../../../../src/main/team-store";
import { TeamWebRtcHostGateway } from "../../../../src/main/team-webrtc-host-gateway";
import { HeadlessHostBridge } from "./bridge";
import { createSimulatorBrowserSurface } from "./browser-surface";
import { createNativeStorageFaults } from "./native-storage-faults";
import { createPermissionFixture } from "./permission-fixture";
import { writeProvider } from "./provider";
import { createQuietFixture } from "./quiet-fixture";
import { createRoutineFaults } from "./routine-faults";

const repository = resolve(import.meta.dirname, "../../../..");
class FixtureActionError extends Error {
  constructor(readonly stage: string) {
    super(stage);
  }
}
const logger = createOpenBotLogger("native-simulator-fixture");
const run = Effect.runPromise;
async function freePort(): Promise<number> {
  return new Promise((resolvePort, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const a = server.address();
      if (!a || typeof a === "string") return reject(new Error("No loopback port."));
      server.close(() => resolvePort(a.port));
    });
  });
}
async function bodyOf(request: IncomingMessage) {
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(Buffer.from(chunk));
  const raw = Buffer.concat(chunks).toString("utf8");
  const value = raw ? JSON.parse(raw) : {};
  return { raw, body: isDynamicRecord(value) ? value : {} };
}
function send(response: ServerResponse, status: number, body?: unknown) {
  response.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
  response.end(body === undefined ? undefined : JSON.stringify(body));
}

export async function startFixture(root: string) {
  const cleanup: Array<() => Promise<unknown> | undefined> = [];
  const nativeStorage = createNativeStorageFaults(root);
  cleanup.push(nativeStorage.restoreWrites);
  let closing = false;
  async function close() {
    if (closing) return;
    closing = true;
    for (const release of cleanup.reverse()) {
      try {
        await release();
      } catch {
        /* Release the other isolated resources too. */
      }
    }
  }
  const terminate = () => {
    void close().finally(() => process.exit(0));
  };
  process.once("SIGINT", terminate);
  process.once("SIGTERM", terminate);
  try {
    await mkdir(root, { recursive: true });
    const provider = await writeProvider(root);
    // Supported discovery override, confined to this fixture process; never changes HOME/CODEX_HOME.
    process.env.OPENBOT_CODEX_PATH = provider;
    const userData = join(root, "host-profile"),
      home = join(root, "host-home");
    const database = new OpenBotDatabase(userData);
    cleanup.push(() => {
      database.close();
    });
    const store = new AgentStore(userData, home, database);
    const mailbox = new MailboxStore(userData, store.sharedRoot, store.database);
    const sidebar = new SidebarLayoutStore(join(userData, "sidebar-layout.json"));
    const team = new TeamStore(join(userData, "team.json"));
    const access = new AgentAccessStore(join(userData, "access.json"));
    const notificationLevels = new AgentNotificationLevelStore(join(userData, "notification-levels.json"));
    await run(notificationLevels.load());
    const syntheticBrowser = createSimulatorBrowserSurface({
      authenticate: (token) => team.authenticate(token),
      getBrowser: () => bridge.browser,
    });
    const agents = new AgentService({
      store,
      mailbox,
      sidebarLayout: sidebar,
      browser: syntheticBrowser.agentBrowser,
      approvalAutomation: NO_APPROVAL_AUTOMATION,
      preferredProvider: "codex",
      preferredModel: "gpt-6-luna",
      busyMessageMode: () => "queue",
      offProviders: AGENT_PROVIDERS.filter((id) => id !== "codex"),
      installedCliProviders: [],
      bundledExecutables: { codex: provider },
      prepareAgentWorkspace: () => Effect.void,
      computerUseMcpServer: () => null,
      credentials: {
        ...NO_PROVIDER_CREDENTIALS,
        providerStateDirectory: join(root, "provider-state"),
        providerTempDirectory: join(root, "provider-temp"),
      },
      clientFactory: (kind) => {
        if (kind !== "codex") throw new Error("Only the synthetic provider is allowed.");
        return new CodexAppServerClient(provider, 10000);
      },
    });
    cleanup.push(() => run(agents.stop()));
    const routineFaults = createRoutineFaults(agents);
    await run(sidebar.initialize());
    await run(team.initialize());
    const identity = await run(
      team.configure("Simulator Mac", "simulator-owner", randomBytes(24).toString("base64url")),
    );
    await run(agents.initialize());
    const agent = await run(
      agents.createAgentProfile({
        name: "Simulator Agent",
        description: "Synthetic native app checks.",
        avatarSeed: "native-fixture",
        avatarHue: null,
      }),
    );
    const browserEvents: Array<{
      type: "requested" | "resolved";
      requestId: string | number;
      agentId: string;
      turnId?: string;
    }> = [];
    agents.on("event", (event) => {
      if (event.type === "browser-takeover-requested") {
        browserEvents.push({
          type: "requested",
          requestId: event.request.requestId,
          agentId: event.request.agentId,
          turnId: event.request.turnId,
        });
      } else if (event.type === "browser-takeover-resolved") {
        browserEvents.push({ type: "resolved", requestId: event.requestId, agentId: event.agentId });
      }
    });
    const pushStore = new PushNotificationStore(join(root, "push-registrations.json"));
    await run(pushStore.load());
    const deliveredPushes: NotificationRelayRequest[] = [];
    let deniedPushes = 0;
    let api: TeamApiServer;
    const pushes = new PushNotificationService({
      agents,
      store: pushStore,
      send: (request) =>
        plane.sessionOpen(identity.serverId, request.push.sessionId).pipe(
          Effect.map((open) => {
            if (!open) {
              deniedPushes++;
              return "gone" as const;
            }
            deliveredPushes.push(request);
            return "sent" as const;
          }),
          Effect.mapError((cause) => new PushNotificationSendFailure({ cause })),
        ),
      hiddenAgentIds: (protocol, capabilities, memberId) => api.hiddenAgentIds(protocol, capabilities, memberId),
      memberActive: (memberId) => team.getMember(memberId)?.disabled === false,
      lastUseElsewhere: () => null,
      atHostComputer: () => false,
      liveActivityShows: () => false,
      randomBytes: (size) => new Uint8Array(randomBytes(size)),
    });
    cleanup.push(() => run(pushes.dispose()));
    api = new TeamApiServer({
      store: team,
      agents: routineFaults.apiAgents,
      mailbox,
      browser: syntheticBrowser.browser,
      browserView: syntheticBrowser.browserView,
      sidebarLayout: sidebar,
      agentAccess: access,
      agentNotificationLevels: notificationLevels,
      appVersion: "0.0.0-native-fixture",
      pushNotifications: pushes,
      events: routineFaults.events,
      routineRunPlaces: agents.routineRecords,
    });
    cleanup.push(() => run(api.stop()));
    const teamPort = await run(api.start());
    pushes.start();

    const accountDB = new DatabaseSync(join(root, "account.db"));
    cleanup.push(() => {
      accountDB.close();
    });
    accountDB.exec("PRAGMA foreign_keys=ON");
    for (const file of (await readdir(join(repository, "apps/auth-api/migrations"))).sort())
      accountDB.exec(await readFile(join(repository, "apps/auth-api/migrations", file), "utf8"));
    const binding = sqliteD1(accountDB);
    // The existing owner signed in earlier; phone sign-in still uses the real cooldown.
    let bootstrapClock = Date.now() - 120_000;
    const auth = new AuthService({
      now: () => (bootstrapClock === 0 ? Date.now() : bootstrapClock),
      repository: new D1AuthRepository(binding),
      delivery: null,
      exposeDevelopmentCode: true,
    });
    const signalPort = await freePort(),
      healthPort = await freePort();
    const signalURL = `ws://127.0.0.1:${signalPort}/v1/signal`;
    const signing = generateKeyPairSync("ec", { namedCurve: "P-256" });
    const keyID = "native-simulator-key";
    const publicJwk = { ...signing.publicKey.export({ format: "jwk" }), kid: keyID, alg: "ES256", use: "sig" };
    const privateJwk = { ...signing.privateKey.export({ format: "jwk" }), kid: keyID, alg: "ES256", use: "sig" };
    const webhookSecret = randomBytes(32).toString("base64url");
    const plane = new RemoteControlPlane({
      DB: binding,
      REMOTE_TICKET_PRIVATE_JWK: JSON.stringify(privateJwk),
      REMOTE_TICKET_PUBLIC_JWKS: JSON.stringify({ keys: [publicJwk] }),
      REMOTE_TICKET_KEY_ID: keyID,
      REMOTE_SIGNAL_URL: signalURL,
      REMOTE_SIGNAL_HOMES: undefined,
      REMOTE_SIGNAL_HOME_LOCATIONS: undefined,
      REMOTE_AUTH_WEBHOOK_URL: `http://127.0.0.1:${signalPort}/v1/auth/events`,
      REMOTE_AUTH_WEBHOOK_URLS: undefined,
      REMOTE_AUTH_WEBHOOK_SECRET: webhookSecret,
      SLACK_ROUTE_PRIVATE_JWK: undefined,
      SLACK_ROUTE_KEY_ID: undefined,
      DISCORD_ROUTE_PRIVATE_JWK: undefined,
      DISCORD_ROUTE_KEY_ID: undefined,
      TELEGRAM_BOT_ID: undefined,
      TELEGRAM_BOT_USERNAME: undefined,
    });
    const challenge = await run(auth.startEmailSignIn("native-simulator@example.invalid", "127.0.0.1"));
    if (!challenge.developmentCode) throw new Error("Fixture development code unavailable.");
    const ownerSession = await run(
      auth.verifyEmailCode({
        challengeId: challenge.challengeId,
        code: challenge.developmentCode,
        sourceIp: "127.0.0.1",
        surface: "desktop",
      }),
    );
    bootstrapClock = 0;
    registerSecretValue(ownerSession.sessionToken);
    const owner = ownerSession.user;
    const ownerMemberId = team.getOwnerMemberId();
    if (!ownerMemberId) throw new Error("No fixture owner membership.");
    const quiet = createQuietFixture(agents, agent.id, ownerMemberId);
    const registration = await run(
      plane.registerHost(owner, {
        hostId: identity.serverId,
        name: "Simulator Mac",
        ownerMembershipId: ownerMemberId,
        devicePublicKey: identity.publicKey,
      }),
    );
    if (!registration.machineToken) throw new Error("Fixture host credential unavailable.");
    const machineToken = registration.machineToken;
    registerSecretValue(machineToken);
    const bridge = new HeadlessHostBridge();
    bridge.onRoutineRunResponseDropped = () => {
      routineFaults.state.runsReadbackBlocked = true;
    };
    cleanup.push(() => run(bridge.stop()));
    cleanup.push(() => run(syntheticBrowser.close));
    let accountOrigin = "";
    let gateway: TeamWebRtcHostGateway;
    let online = true;
    const hostBinding = {
      hostId: identity.serverId,
      fingerprint: createHash("sha256").update(identity.publicKey).digest("base64url"),
    };
    const permissions = createPermissionFixture({
      root,
      agents,
      access,
      team,
      plane,
      owner,
      hostID: identity.serverId,
      deniedAgentID: agent.id,
      teamPort,
      revokeSession: (id) => run(gateway.revokeSession(id)),
    });
    const control = { messages: 0, providerTurns: 0 };
    let historySeed: Promise<void> | null = null;
    let attachmentSeed: Promise<void> | null = null;
    let browserSeed: Promise<void> | null = null;
    let signoutRevokeUnavailable = false;
    let signoutRevokeAttempts = 0;
    let signoutRevokeFailures = 0;
    let signoutRejectedSessionStillActive = false;
    const historyMarkers = Array.from(
      { length: 60 },
      (_, index) => `SIM-HISTORY-${String(index + 1).padStart(2, "0")}`,
    );
    const attachmentMarker = "SIM-FILE";
    const attachmentName = "simulator-note.txt";
    const attachmentBytes = Buffer.from(
      "SIMULATOR ATTACHMENT\nThis harmless file came from the real host attachment store.\n",
    );

    const seedHistory = async () => {
      const current = await run(agents.readConversation(agent.id));
      const existing = current.messages.filter((message) => historyMarkers.includes(message.text));
      if (existing.length === historyMarkers.length && new Set(existing.map((message) => message.text)).size === 60)
        return;
      if (existing.length > 0 || current.activeTurnId !== null)
        throw new FixtureActionError(
          `history-not-idle-${existing.length}-${current.activeTurnId === null ? "idle" : "active"}`,
        );
      // Import immutable history through its real owner. No send receipt or provider completion is supplied here.
      const oldest = Math.min(Date.now(), ...current.messages.map((message) => Date.parse(message.createdAt)));
      const messages: ConversationMessage[] = historyMarkers.map((text, index) => ({
        id: crypto.randomUUID(),
        author: "assistant",
        source: "assistant",
        itemType: "agent_message",
        text,
        createdAt: new Date(oldest - (historyMarkers.length - index) * 60_000).toISOString(),
        status: "completed",
      }));
      await run(
        agents.importTransferHistory(
          {
            agentId: agent.id,
            thread: {
              main: true,
              title: "",
              titleSource: "auto",
              origin: "user",
              archived: false,
              routineId: null,
              messages,
            },
            files: new Map(),
            agentIds: new Map(),
            routineIds: new Map(),
            runIds: new Map(),
          },
          ownerMemberId,
        ),
      );
      // Refresh the ordinary live projection after the import, before another fixture action sends a turn.
      await run(agents.readConversation(agent.id));
    };

    async function seedAttachment() {
      const current = await run(agents.readConversation(agent.id));
      if (
        current.messages.some(
          (message) => message.author === "user" && message.text === attachmentMarker && message.attachments?.length,
        )
      )
        return;
      const drafts = await run(
        agents.prepareImportedAttachments(
          [],
          [{ name: attachmentName, mimeType: "text/plain", bytes: attachmentBytes }],
        ),
      );
      await run(
        agents.sendMessage({
          agentId: agent.id,
          text: attachmentMarker,
          attachmentDraftIds: drafts.map((draft) => draft.id),
          replyToMessageId: null,
          clientMessageId: "native-simulator-file-seed",
        }),
      );
    }

    async function seedBrowserHandoff() {
      const page = await run(agents.readConversation(agent.id));
      if (page.activeTurnId !== null) throw new FixtureActionError("browser-not-idle");
      // The provider opens its owned synthetic tab and calls submit_secret. The real
      // attention domain creates the request that the frozen cancel route must resolve.
      await run(
        agents.sendMessage({
          agentId: agent.id,
          text: "SIM-BROWSER",
          attachmentDraftIds: [],
          replyToMessageId: null,
          clientMessageId: "native-simulator-browser-seed",
        }),
      );
    }
    let pushPhone: { token: string; sessionId: string; secret: string } | null = null;
    const pushScope = "synthetic-account-host-membership";
    async function pushRequest(path: string, body: PushNotificationRegistration | Record<string, never>) {
      if (!pushPhone) throw new Error("No synthetic notification phone.");
      const response = await fetch(`http://127.0.0.1:${teamPort}${path}`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${pushPhone.token}`,
          "content-type": "application/json",
          [TEAM_PROTOCOL_VERSION_HEADER]: "9",
          [TEAM_APP_VERSION_HEADER]: "0.69.0",
          [TEAM_CAPABILITIES_HEADER]: TEAM_CURRENT_CAPABILITIES.join(","),
        },
        body: JSON.stringify(body),
      });
      if (!response.ok) throw new FixtureActionError(`push-http-${response.status}`);
    }
    async function registerPushPhone(away: boolean) {
      if (!pushPhone) throw new Error("No synthetic notification phone.");
      await pushRequest(PUSH_NOTIFICATIONS_ROUTES.register, {
        serverId: pushScope,
        token: "ab".repeat(32),
        environment: "development",
        secret: pushPhone.secret,
        locale: "en",
        away,
        level: "all",
        mutedUntil: null,
        preview: true,
        sound: "default",
        liveActivityStartedAt: null,
      });
    }

    const server = createServer((request, response) => {
      void (async () => {
        const url = new URL(request.url ?? "/", "http://127.0.0.1");
        if (url.pathname === "/_fixture/host") {
          response.writeHead(200, { "content-type": "text/html" });
          response.end("<!doctype html><title>Native simulator fixture</title>");
          return;
        }
        const { raw, body } = await bodyOf(request);
        const key = `${request.method} ${url.pathname}`;
        if (key === "POST /_control/quiet/setup") {
          send(response, 200, await quiet.setup());
          return;
        }
        if (key === "POST /_control/quiet/run-background") {
          send(response, 200, await quiet.runBackgroundRoutine());
          return;
        }
        if (key === "GET /_control/quiet/status") {
          send(response, 200, await quiet.status());
          return;
        }
        if (key === "POST /_control/permissions/setup") {
          send(response, 200, await permissions.setup());
          return;
        }
        if (key === "POST /_control/permissions/restrict") {
          send(response, 200, await permissions.restrict());
          return;
        }
        if (key === "POST /_control/permissions/revoke") {
          send(response, 200, await permissions.revoke());
          return;
        }
        if (key === "GET /_control/permissions/status") {
          send(response, 200, {
            ...(await permissions.status()),
            rpc: bridge.trace,
            bridgeLifecycle: { ...bridge.lifecycle },
          });
          return;
        }
        if (key === "POST /_control/storage/fail-writes") {
          send(response, 200, await nativeStorage.failWrites());
          return;
        }
        if (key === "POST /_control/storage/restore-writes") {
          send(response, 200, await nativeStorage.restoreWrites());
          return;
        }
        if (key === "POST /_control/routines/drop-manual-response") {
          bridge.dropNextRoutineRunResponse = body.enabled !== false;
          if (bridge.dropNextRoutineRunResponse) routineFaults.state.runsReadbackBlocked = false;
          send(response, 200, { armed: bridge.dropNextRoutineRunResponse });
          return;
        }
        if (key === "POST /_control/routines/runs-readback") {
          // An empty POST clears the fault for native UI checks that send no JSON body.
          routineFaults.state.runsReadbackBlocked = body.enabled === true;
          send(response, 200, { blocked: routineFaults.state.runsReadbackBlocked });
          return;
        }
        if (key === "POST /_control/routines/fail-secondary-place") {
          routineFaults.armSecondaryPlace(body.enabled !== false);
          send(response, 200, { armed: routineFaults.state.failSecondaryPlace });
          return;
        }
        if (key === "POST /_control/signout-revoke-unavailable") {
          signoutRevokeUnavailable = body.enabled !== false;
          send(response, 200, { enabled: signoutRevokeUnavailable });
          return;
        }
        if (key === "POST /_control/seed-browser-handoff") {
          browserSeed ??= seedBrowserHandoff().catch((cause) => {
            browserSeed = null;
            throw cause;
          });
          await browserSeed;
          send(response, 200, { marker: "SIM-BROWSER", agentId: agent.id });
          return;
        }
        if (key === "POST /_control/seed-history") {
          historySeed ??= seedHistory().catch((cause) => {
            historySeed = null;
            throw cause;
          });
          await historySeed;
          const current = await run(agents.readConversation(agent.id));
          const messages = current.messages.filter((message) => historyMarkers.includes(message.text));
          const latest = await run(agents.readConversationPageFor(agent.id, ownerMemberId, { type: "latest" }, 50));
          send(response, 200, {
            count: messages.length,
            firstMarker: historyMarkers[0],
            lastMarker: historyMarkers.at(-1),
            firstMessageId: messages.find((message) => message.text === historyMarkers[0])?.id ?? null,
            lastMessageId: messages.find((message) => message.text === historyMarkers.at(-1))?.id ?? null,
            pageInfo: latest.pageInfo,
          });
          return;
        }
        if (key === "POST /_control/seed-attachment") {
          attachmentSeed ??= seedAttachment().catch((cause) => {
            attachmentSeed = null;
            throw cause;
          });
          await attachmentSeed;
          const current = await run(agents.readConversation(agent.id));
          const message = current.messages.find(
            (candidate) => candidate.author === "user" && candidate.text === attachmentMarker,
          );
          send(response, 200, {
            messageId: message?.id ?? null,
            attachments:
              message?.attachments?.map(({ id, name, mimeType, size }) => ({ id, name, mimeType, size })) ?? [],
          });
          return;
        }
        if (key === "POST /_control/push/setup") {
          const ticket = await run(auth.issueMobileAuthTicket(ownerSession.sessionToken, "127.0.0.1", hostBinding));
          const mobile = await run(
            auth.redeemMobileAuthTicket(
              ticket.ticket,
              { id: crypto.randomUUID(), name: "Synthetic notification phone", platform: "ios" },
              "127.0.0.1",
            ),
          );
          if (!mobile) throw new Error("No synthetic notification account session.");
          registerSecretValue(mobile.sessionToken);
          const session = await run(
            plane.startSession(owner.id, identity.serverId, await run(sha256(mobile.sessionToken))),
          );
          const local = team.openRemoteSession({
            sessionId: session.sessionId,
            membershipId: ownerMemberId,
            userId: owner.id,
            role: "owner",
          });
          registerSecretValue(local.sessionToken);
          const secret = randomBytes(32);
          pushPhone = { token: local.sessionToken, sessionId: session.sessionId, secret: secret.toString("base64url") };
          registerSecretValue(pushPhone.secret);
          await writeFile(
            join(root, "notification-secret.json"),
            JSON.stringify({
              scope: pushScope,
              hostID: identity.serverId,
              name: "Simulator Mac",
              secret: secret.toString("base64"),
            }),
            { mode: 0o600 },
          );
          await registerPushPhone(true);
          send(response, 204);
          return;
        }
        if (key === "POST /_control/push/foreground") {
          await registerPushPhone(false);
          send(response, 204);
          return;
        }
        if (key === "POST /_control/push/remove") {
          await pushRequest(PUSH_NOTIFICATIONS_ROUTES.remove, {});
          send(response, 204);
          return;
        }
        if (key === "POST /_control/push/away") {
          await registerPushPhone(true);
          send(response, 204);
          return;
        }
        if (key === "POST /_control/push/revoke") {
          if (!pushPhone) throw new Error("No synthetic notification phone.");
          await run(plane.endSession(owner.id, pushPhone.sessionId));
          send(response, 204);
          return;
        }
        if (key === "POST /_control/push/send") {
          const marker = isString(body.text) ? body.text : "SIM-PUSH-1";
          // Owner action on this isolated host, even after the synthetic phone was revoked.
          await run(
            agents.sendMessage({
              agentId: agent.id,
              text: marker,
              attachmentDraftIds: [],
              replyToMessageId: null,
              clientMessageId: crypto.randomUUID(),
            }),
          );
          send(response, 204);
          return;
        }
        if (key === "GET /_control/push/status") {
          const page = await run(agents.readConversation(agent.id));
          await writeFile(join(root, "notification-deliveries.json"), JSON.stringify(deliveredPushes));
          send(response, 200, {
            delivered: deliveredPushes.length,
            denied: deniedPushes,
            registrations: pushStore.list().length,
            activeTurn: page.activeTurnId,
            threadID: page.threadId,
            replies: page.messages.filter((m) => m.author === "assistant").map((m) => m.text),
          });
          return;
        }
        if (key === "GET /_control/status") {
          const page = await run(agents.readConversation(agent.id));
          const runtime = agents.getRuntimeSnapshot();
          await writeFile(join(root, "host-status.json"), JSON.stringify({ runtime, rpc: bridge.trace }, null, 2));
          control.messages = page.messages.filter((m) => m.author === "user").length;
          control.providerTurns = (await readFile(join(root, "provider-turns.jsonl"), "utf8").catch(() => ""))
            .trim()
            .split("\n")
            .filter(Boolean).length;
          const promptAnswers = (await readFile(join(root, "provider-prompt-answers.jsonl"), "utf8").catch(() => ""))
            .split("\n")
            .filter(Boolean)
            .map((line) => JSON.parse(line));
          const readMetadata = async (name: string) =>
            (await readFile(join(root, name), "utf8").catch(() => ""))
              .split("\n")
              .filter(Boolean)
              .map((line) => JSON.parse(line));
          const queue = agents.listQueue(agent.id);
          send(response, 200, {
            ...control,
            droppedReceipts: bridge.droppedReceipts,
            receiptOnlyFault: {
              armed: bridge.dropNextReceiptOnly,
              drops: bridge.receiptOnlyDrops,
              lifecycle: bridge.lifecycle,
            },
            nativeStorage: nativeStorage.state,
            routineFaults: {
              ...routineFaults.state,
              dropManualResponseArmed: bridge.dropNextRoutineRunResponse,
              droppedManualResponses: bridge.droppedManualRuns.length,
              droppedManualRuns: bridge.droppedManualRuns,
            },
            paths: bridge.paths,
            online,
            messages: page.messages
              .filter((m) => m.author === "user")
              .map((m) => ({ id: m.id, text: m.text, replyToMessageId: m.replyToMessageId, turnId: m.turnId })),
            chatMessages: page.messages.map(({ id, text, author, turnId, replyToMessageId, itemType, status }) => ({
              id,
              text,
              author,
              turnId,
              replyToMessageId,
              itemType,
              status,
            })),
            pendingApprovals: runtime.pendingApprovals.length,
            pendingPrompts: runtime.pendingPrompts.length,
            pendingBrowserTakeovers: runtime.pendingBrowserTakeovers.length,
            browserRequests: runtime.pendingBrowserTakeovers.map((handoff) => ({
              requestId: handoff.requestId,
              agentId: handoff.agentId,
              threadId: handoff.threadId,
              turnId: handoff.turnId,
              tabId: handoff.tabId,
              site: handoff.secret ? new URL(handoff.secret.origin).hostname : null,
              method: handoff.secret?.method ?? null,
            })),
            browserEvents,
            browserSurface: syntheticBrowser.state,
            features: {
              agents: agents.listAgents().map(({ id, name, title, description, notifications, updatedAt }) => ({
                id,
                name,
                title,
                instructionsLength: description.length,
                notifications,
                updatedAt,
              })),
              routines: agents.listAgents().flatMap((item) =>
                agents.listRoutines(item.id).map((routine) => ({
                  id: routine.id,
                  agentId: item.id,
                  name: routine.name,
                  active: routine.active,
                  schedule: routine.trigger.schedule,
                  runIn: routine.runIn ?? "chat",
                  limitPolicy: routine.limitPolicy ?? "wait",
                  missedPolicy: routine.missedPolicy ?? "skip",
                  updatedAt: routine.updatedAt,
                  runs: agents
                    .listRoutineRuns({ agentId: item.id, routineId: routine.id, limit: 20 })
                    .map(({ id, status, kind }) => ({ id, status, kind })),
                })),
              ),
              preferences: notificationLevels.snapshot(ownerMemberId),
              reactions: page.messages
                .filter((item) => item.reaction || item.reactions?.length)
                .map(({ id, reaction, reactions }) => ({ id, reaction, reactions })),
            },
            browserAnswers: await readMetadata("provider-browser-answers.jsonl"),
            confirmAnswers: await readMetadata("provider-confirm-answers.jsonl"),
            failedTurns: runtime.failedTurns,
            work: runtime.work.map(({ id, agentId, turnId, status, error }) => ({
              id,
              agentId,
              turnId,
              status,
              errorPresent: error !== null,
            })),
            queue: {
              queued: queue.deliveries.filter((delivery) => delivery.status === "queued").length,
              starting: queue.deliveries.filter((delivery) => delivery.status === "starting").length,
              running: queue.deliveries.filter((delivery) => delivery.status === "running").length,
              failed: queue.deliveries.filter((delivery) => delivery.status === "failed").length,
            },
            signout: {
              revokeUnavailable: signoutRevokeUnavailable,
              revokeAttempts: signoutRevokeAttempts,
              revokeFailures: signoutRevokeFailures,
              rejectedSessionStillActive: signoutRejectedSessionStillActive,
            },
            activeTurnId: page.activeTurnId,
            interruptedTurns: new Set(
              page.messages
                .filter((message) => message.delivery?.status === "interrupted")
                .map((message) => message.turnId ?? message.delivery?.id),
            ).size,
            attachments: page.messages.flatMap((message) =>
              (message.attachments ?? []).map(({ id, name, mimeType, size }) => ({
                messageId: message.id,
                id,
                name,
                mimeType,
                size,
              })),
            ),
            promptAnswers,
            rpc: bridge.trace,
          });
          return;
        }
        if (key === "GET /_control/connect-link") {
          const ticket = await run(auth.issueMobileAuthTicket(ownerSession.sessionToken, "127.0.0.1", hostBinding));
          const link = createMobileConnectUrl({ apiUrl: accountOrigin, ticket: ticket.ticket, host: hostBinding });
          send(response, 200, { url: link.replace("openbot:", "openbot-native-simulator:") });
          return;
        }
        if (key === "POST /_control/finish-stream") {
          await writeFile(join(root, "release-stream"), "");
          send(response, 204);
          return;
        }
        if (key === "POST /_control/drop-receipt") {
          bridge.dropNextReceipt = true;
          send(response, 204);
          return;
        }
        if (key === "POST /_control/drop-receipt-only") {
          bridge.dropNextReceiptOnly = true;
          send(response, 204);
          return;
        }
        if (key === "POST /_control/offline") {
          online = false;
          await run(gateway.stop());
          send(response, 204);
          return;
        }
        if (key === "POST /_control/online") {
          if (!online) {
            online = true;
            await startGateway();
          }
          send(response, 204);
          return;
        }
        if (key === "POST /v1/auth/email/start") {
          send(
            response,
            200,
            await run(
              auth.startEmailSignIn(
                String(body.email),
                "127.0.0.1",
                isString(request.headers["idempotency-key"]) ? request.headers["idempotency-key"] : undefined,
              ),
            ),
          );
          return;
        }
        if (key === "POST /v1/mobile-auth/email/verify") {
          const session = await run(
            auth.verifyMobileEmailCode({
              challengeId: String(body.challengeId),
              code: String(body.code),
              sourceIp: "127.0.0.1",
              device: { id: String(body.deviceId), name: String(body.deviceName), platform: "ios" },
            }),
          );
          registerSecretValue(session.sessionToken);
          await permissions.accept(session.user);
          send(response, 200, session);
          return;
        }
        if (key === "POST /v1/mobile-auth/redeem") {
          const session = await run(
            auth.redeemMobileAuthTicket(
              String(body.ticket),
              { id: String(body.deviceId), name: String(body.deviceName), platform: "ios" },
              "127.0.0.1",
            ),
          );
          if (!session) {
            send(response, 401);
            return;
          }
          registerSecretValue(session.sessionToken);
          send(response, 200, session);
          return;
        }
        if (key === "GET /.well-known/jwks.json") {
          send(response, 200, plane.publicJwks());
          return;
        }
        if (key === "POST /v2/remote/resume/validate") {
          const valid = await run(
            verifyRemoteServiceSignature(
              webhookSecret,
              raw,
              String(request.headers["openbot-timestamp"]),
              String(request.headers["openbot-signature"]),
            ),
          );
          if (!valid) {
            send(response, 401);
            return;
          }
          if (
            !isString(body.sessionId) ||
            !isString(body.hostId) ||
            !isString(body.userId) ||
            !isString(body.membershipId) ||
            !(body.role === "host" || body.role === "owner" || body.role === "admin" || body.role === "member") ||
            typeof body.authEpoch !== "number" ||
            typeof body.sessionExpiresAt !== "number"
          ) {
            send(response, 400);
            return;
          }
          send(response, 200, {
            valid: await run(
              plane.validateResumeClaims({
                sessionId: body.sessionId,
                hostId: body.hostId,
                userId: body.userId,
                membershipId: body.membershipId,
                role: body.role,
                authEpoch: body.authEpoch,
                sessionExpiresAt: body.sessionExpiresAt,
              }),
            ),
          });
          return;
        }
        const token = /^Bearer (\S+)$/u.exec(request.headers.authorization ?? "")?.[1];
        if (!token) {
          send(response, 401);
          return;
        }
        if (key === "GET /v1/mobile-auth/session") {
          const session = await run(auth.authenticateMobileSession(token));
          send(response, session ? 200 : 401, session ?? undefined);
          return;
        }
        if (key === "DELETE /v1/mobile-auth/session") {
          signoutRevokeAttempts++;
          if (signoutRevokeUnavailable) {
            signoutRejectedSessionStillActive = (await run(auth.authenticateMobileSession(token))) !== null;
            if (!signoutRejectedSessionStillActive) {
              send(response, 401);
              return;
            }
            signoutRevokeFailures++;
            send(response, 503, {
              error: { code: "fixture_unavailable", message: "Synthetic account revocation unavailable." },
            });
            return;
          }
          await run(auth.logoutMobileSession(token));
          send(response, 204);
          return;
        }
        const user = await run(auth.authenticate(token));
        if (!user) {
          send(response, 401);
          return;
        }
        if (key === "GET /v2/remote/hosts/") {
          send(response, 200, { hosts: await run(plane.listHosts(user.id)) });
          return;
        }
        if (key === "POST /v2/remote/sessions/") {
          send(response, 201, await run(plane.startSession(user.id, String(body.hostId), await run(sha256(token)))));
          return;
        }
        const ticket = /^\/v2\/remote\/sessions\/([^/]+)\/ticket$/u.exec(url.pathname);
        if (request.method === "POST" && ticket?.[1]) {
          send(response, 200, await run(plane.issueSessionTicket(user.id, ticket[1], String(body.clientPublicKey))));
          return;
        }
        const end = /^\/v2\/remote\/sessions\/([^/]+)\/end$/u.exec(url.pathname);
        if (request.method === "POST" && end?.[1]) {
          await run(plane.endSession(user.id, end[1]));
          send(response, 204);
          return;
        }
        send(response, 404);
      })().catch((error) => {
        const status =
          error instanceof AuthServiceError || error instanceof RemoteControlPlaneError ? error.status : 500;
        logger.warn("Fixture request failed.", {
          path: request.url?.split("?")[0],
          status,
          kind: error instanceof Error ? error.name : "unknown",
          ...(error instanceof FixtureActionError ? { stage: error.stage } : {}),
        });
        send(response, status, { error: { code: "fixture_failure", message: "Local fixture request failed." } });
      });
    });
    cleanup.push(() => {
      server.closeAllConnections();
      server.close();
    });
    await new Promise<void>((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("No fixture account port.");
    accountOrigin = `http://127.0.0.1:${address.port}`;
    bridge.pageOrigin = accountOrigin;
    const signal: ChildProcess = spawn(process.execPath, [join(repository, "remote/api/src/index.ts")], {
      cwd: join(repository, "remote/api"),
      env: {
        PATH: process.env.PATH ?? "",
        HOME: process.env.HOME ?? "",
        REMOTE_SIGNAL_HOST: "127.0.0.1",
        REMOTE_SIGNAL_PORT: String(signalPort),
        REMOTE_HEALTH_PORT: String(healthPort),
        REMOTE_TLS_DISABLED: "true",
        REMOTE_TICKET_PUBLIC_KEYS: JSON.stringify({ keys: [publicJwk] }),
        REMOTE_CONTROL_PLANE_URL: accountOrigin,
        REMOTE_SESSION_SECRET: randomBytes(32).toString("base64url"),
        REMOTE_AUTH_WEBHOOK_SECRET: webhookSecret,
        TURN_SHARED_SECRET: randomBytes(32).toString("base64url"),
        TURN_HOST: "127.0.0.1",
        TURN_PORT: "9",
        REMOTE_METRICS_TOKEN: randomBytes(32).toString("base64url"),
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const signalLog: string[] = [];
    cleanup.push(async () => {
      signal.kill("SIGTERM");
      await writeFile(join(root, "signal.log"), signalLog.join(""));
    });
    signal.stdout?.on("data", (chunk) => signalLog.push(String(chunk)));
    signal.stderr?.on("data", (chunk) => signalLog.push(String(chunk)));
    const deadline = Date.now() + 15000;
    while (true) {
      if (signal.exitCode !== null) throw new Error("Local Signal exited.");
      if (
        await fetch(`http://127.0.0.1:${healthPort}/health/live`).then(
          (r) => r.ok,
          () => false,
        )
      )
        break;
      if (Date.now() > deadline) throw new Error("Local Signal did not become healthy.");
      await new Promise((wake) => setTimeout(wake, 100));
    }
    const central = new CentralAuthManager({
      apiUrl: accountOrigin,
      storagePath: join(root, "central-session.json"),
      encrypt: (value) => Buffer.from(value),
      decrypt: (value) => value.toString(),
    });
    gateway = new TeamWebRtcHostGateway({
      bridge,
      store: team,
      appVersion: "0.0.0-native-fixture",
      transferDirectory: join(root, "transfers"),
      verifyClientTicket: (ticket) =>
        central.verifyRemoteSessionTicket(ticket).pipe(Effect.mapError((cause) => new RemoteWorkflowError({ cause }))),
      closeSession: (id) =>
        plane.endSession(owner.id, id).pipe(Effect.mapError((cause) => new RemoteWorkflowError({ cause }))),
      renewSignal: (hostId) =>
        plane
          .issueHostTicket(hostId, machineToken)
          .pipe(Effect.mapError((cause) => new RemoteWorkflowError({ cause }))),
    });
    cleanup.push(() => run(gateway.stop()));
    async function startGateway() {
      const ticket = await run(plane.issueHostTicket(identity.serverId, machineToken));
      await run(
        gateway.start({
          hostId: identity.serverId,
          signalUrl: ticket.signalUrl,
          ticket: ticket.ticket,
          localApiPort: teamPort,
        }),
      );
    }
    await startGateway();
    await writeFile(
      join(root, "ready.json"),
      `${JSON.stringify(
        {
          apiURL: accountOrigin,
          agentId: agent.id,
          hostId: identity.serverId,
          provider: "deterministic local app-server",
          limits: ["No model service, production account, TURN or APNs."],
        },
        null,
        2,
      )}\n`,
    );
    logger.info("Native simulator fixture ready.", { apiURL: accountOrigin, root });
  } catch (error) {
    await close();
    throw error;
  }
}
