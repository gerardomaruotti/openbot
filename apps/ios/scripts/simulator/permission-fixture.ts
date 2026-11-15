import { execFile } from "node:child_process";
import { readdir, readFile, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { isDynamicRecord, isString } from "@openbot/contracts/runtime-values";
import { TEAM_APP_VERSION_HEADER, TEAM_PROTOCOL_VERSION_HEADER } from "@openbot/contracts/team-protocol/v1";
import { TEAM_PROTOCOL_V9 } from "@openbot/contracts/team-protocol/v9";
import { registerSecretValue } from "@openbot/logging";
import { Effect } from "effect";
import type { RemoteControlPlane } from "../../../../apps/auth-api/src/server/remote-control-plane";
import type { AuthUser } from "../../../../apps/auth-api/src/server/types";
import type { AgentService } from "../../../../src/backend/agent-service";
import type { AgentAccessStore } from "../../../../src/main/agent-access-store";
import type { TeamStore } from "../../../../src/main/team-store";

/** A real invited member and real per-agent levels, confined to the owned fixture. */
export function createPermissionFixture(input: {
  root: string;
  agents: AgentService;
  access: AgentAccessStore;
  team: TeamStore;
  plane: RemoteControlPlane;
  owner: AuthUser;
  hostID: string;
  deniedAgentID: string;
  teamPort: number;
  revokeSession: (id: string) => Promise<unknown>;
}) {
  const email = "native-permission@example.invalid";
  let invitation: string | null = null;
  let member: AuthUser | null = null;
  let memberID: string | null = null;
  let allowed: { id: string; name: string } | null = null;
  let preparing: Promise<{ email: string; deniedAgentID: string; allowedAgentID: string }> | null = null;

  async function synchronize() {
    const members = await Effect.runPromise(input.plane.listMembers(input.owner.id, input.hostID));
    const closed = await Effect.runPromise(input.team.syncRemoteDirectory(input.hostID, members, { keepOwner: true }));
    for (const id of closed) await input.revokeSession(id);
    return members;
  }

  async function prepare() {
    allowed = await Effect.runPromise(
      input.agents.createAgentProfile({
        name: "Permission Queue Agent",
        description: "Synthetic permission recovery check.",
        avatarSeed: "permission-fixture",
        avatarHue: null,
      }),
    );
    const invite = await Effect.runPromise(
      input.plane.createInvite(input.owner, {
        hostId: input.hostID,
        role: "member",
        email,
      }),
    );
    invitation = invite.token;
    registerSecretValue(invitation);
    return { email, deniedAgentID: input.deniedAgentID, allowedAgentID: allowed.id };
  }

  function setup() {
    preparing ??= prepare();
    return preparing;
  }

  async function accept(user: AuthUser) {
    if (user.email !== email || !invitation || member) return;
    await Effect.runPromise(input.plane.acceptInvite(user, invitation));
    member = user;
    const members = await synchronize();
    memberID = members.find((candidate) => candidate.email === email)?.membershipId ?? null;
    if (!memberID) throw new Error("Synthetic permission member was not created.");
  }

  async function restrict() {
    if (!member || !memberID || !allowed) throw new Error("Synthetic member is not signed in.");
    const before = input.access.get(input.hostID);
    const ids = new Set(input.agents.listAgents().map((agent) => agent.id));
    await Effect.runPromise(
      input.access.set(
        input.hostID,
        {
          ...before,
          everyone: { ...before.everyone, [input.deniedAgentID]: "view", [allowed.id]: "chat" },
        },
        ids,
        ids,
        null,
      ),
    );
    // Independently verify the real host status for the same member. This request
    // is refused before any input/provider execution; it supplies no mock reply.
    const sessionID = crypto.randomUUID();
    const session = input.team.openRemoteSession({
      sessionId: sessionID,
      membershipId: memberID,
      userId: member.id,
      role: "member",
    });
    registerSecretValue(session.sessionToken);
    try {
      const response = await fetch(`http://127.0.0.1:${input.teamPort}/v1/agents/${input.deniedAgentID}/messages`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${session.sessionToken}`,
          "content-type": "application/json",
          [TEAM_PROTOCOL_VERSION_HEADER]: String(TEAM_PROTOCOL_V9),
          [TEAM_APP_VERSION_HEADER]: "native-permission-e2e",
        },
        body: JSON.stringify({ text: "SIM-ACCESS-DENIAL-PROBE", attachmentDraftIds: [], replyToMessageId: null }),
      });
      return { deniedStatus: response.status };
    } finally {
      input.team.closeRemoteSession(sessionID);
    }
  }

  async function revoke() {
    if (!memberID) throw new Error("No synthetic member to revoke.");
    await Effect.runPromise(
      input.plane.changeMembership(input.owner.id, {
        hostId: input.hostID,
        membershipId: memberID,
        revoke: true,
      }),
    );
    await synchronize();
    return { revoked: true };
  }

  async function status() {
    if (!allowed || !member || !memberID) throw new Error("Synthetic permission case is not ready.");
    const denied = await Effect.runPromise(input.agents.readConversation(input.deniedAgentID));
    const permitted = await Effect.runPromise(input.agents.readConversation(allowed.id));
    const members = await Effect.runPromise(input.plane.listMembers(input.owner.id, input.hostID));
    const current = members.find((candidate) => candidate.membershipId === memberID);
    const rows = (page: typeof denied) =>
      page.messages.map(({ id, author, text, status, turnId }) => ({ id, author, text, status, turnId }));
    return {
      email,
      memberRole: current?.role ?? null,
      memberActive: current?.status === "active",
      availableHosts: (await Effect.runPromise(input.plane.listHosts(member.id))).length,
      deniedMessages: rows(denied),
      allowedMessages: rows(permitted),
      sealedFileCount: await sealedFileCount(input.root),
    };
  }

  return { setup, accept, restrict, revoke, status };
}

/** Read metadata only for the runner's exact UUID app; never inspect another app. */
async function sealedFileCount(root: string) {
  const registration = JSON.parse(await readFile(join(root, "native-container.json"), "utf8"));
  if (
    !isDynamicRecord(registration) ||
    !isString(registration.bundleID) ||
    !/^com\.gerardomaruotti\.openbot\.native\.simulator\.run[0-9a-f]{32}$/.test(registration.bundleID) ||
    !isString(registration.deviceID) ||
    !/^[0-9A-F-]{36}$/.test(registration.deviceID)
  )
    throw new Error("No owned native permission container.");
  const { stdout } = await promisify(execFile)(
    "xcrun",
    ["simctl", "get_app_container", registration.deviceID, registration.bundleID, "data"],
    { maxBuffer: 16 * 1024 },
  );
  const container = await realpath(stdout.trim());
  const parent = join(
    homedir(),
    "Library/Developer/CoreSimulator/Devices",
    registration.deviceID,
    "data/Containers/Data/Application",
  );
  if (
    container !== resolve(stdout.trim()) ||
    !container.startsWith(`${parent}/`) ||
    !/^[0-9A-F-]{36}$/.test(container.slice(parent.length + 1))
  )
    throw new Error("Unexpected native permission container.");
  const files = await readdir(join(container, "Library/Application Support/NativeWorkspace")).catch(
    (error: unknown) => {
      if (error instanceof Error && "code" in error && error.code === "ENOENT") return [];
      throw error;
    },
  );
  return files.filter((name) => /^[0-9a-f]{64}\.sealed$/.test(name)).length;
}
