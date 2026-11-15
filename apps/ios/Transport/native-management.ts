import {
  type ClientAgentSummary,
  type CreateAgentInput,
  type CreateRoutineInput,
  decodeAgentAccessSnapshot,
  decodeEventRoutineRuns,
  decodeEventRoutines,
  isAgentNotificationLevelsSnapshot,
  isClientAgentModelOption,
  isClientAgentSummary,
  isMessageReaction,
  type Routine,
  type ServerNotificationLevel,
  type UpdateAgentInput,
  type UpdateRoutineInput,
} from "@openbot/contracts/ipc";
import { isDynamicRecord } from "@openbot/contracts/runtime-values";
import { TEAM_API_ROUTES } from "@openbot/contracts/team-api-routes";
import { AGENT_ACCESS_CAPABILITY, AGENT_ACCESS_ROUTES } from "@openbot/contracts/team-protocol/agent-access-v1";
import {
  AGENT_NOTIFICATION_LEVELS_CAPABILITY,
  AGENT_NOTIFICATION_LEVELS_ROUTES,
} from "@openbot/contracts/team-protocol/agent-notification-levels-v1";
import { TEAM_AGENT_CREATE_MODEL_CAPABILITY } from "@openbot/contracts/team-protocol/current";
import {
  ROUTINE_RECOVERY_CAPABILITY,
  ROUTINE_RECOVERY_ROUTES,
} from "@openbot/contracts/team-protocol/routine-recovery-v1";
import {
  ROUTINE_RUN_PLACE_CAPABILITY,
  ROUTINE_RUN_PLACE_ROUTES,
} from "@openbot/contracts/team-protocol/routine-run-place-v1";
import { ROUTINES_ONCE_CAPABILITY } from "@openbot/contracts/team-protocol/routines-once-v1";
import { decodeTeamProtocolV2Json, type TeamProtocolV2Json } from "@openbot/contracts/team-protocol/v2";
import { type TeamApiRequest, teamAgentRoutinesApi } from "@openbot/team-client/team-api-requests";

export class NativeOperationFailure extends Error {
  constructor(readonly code: "sendFailed" | "protocolError" | "incompatible" | "unconfirmed") {
    super(code);
  }
}

/** Captured by the app peer. Every read and dispatch verifies this same host/session/peer owner. */
export interface NativeHostScope {
  role: "owner" | "admin" | "member";
  capabilities: readonly string[];
  current(): boolean;
  request(method: string, path: string, body?: TeamProtocolV2Json): Promise<TeamProtocolV2Json>;
}

type AgentCreate = Pick<
  CreateAgentInput,
  "name" | "description" | "avatarSeed" | "avatarHue" | "initialMessage" | "provider" | "model" | "reasoningEffort"
>;
type AgentPatch = Pick<
  UpdateAgentInput,
  | "name"
  | "title"
  | "description"
  | "notifications"
  | "provider"
  | "model"
  | "reasoningEffort"
  | "avatarSeed"
  | "avatarHue"
>;
export type NativeManagementCommand =
  | { type: "agents"; hostId: string }
  | { type: "agentModels"; hostId: string }
  | { type: "createAgent"; hostId: string; input: AgentCreate }
  | { type: "updateAgent"; hostId: string; agentId: string; patch: AgentPatch; expectedUpdatedAt: string | null }
  | { type: "deleteAgent"; hostId: string; agentId: string; expectedUpdatedAt: string | null }
  | { type: "setReaction"; hostId: string; agentId: string; messageId: string; emoji: string | null }
  | { type: "notificationPreferences"; hostId: string }
  | { type: "setAgentNotificationLevel"; hostId: string; agentId: string; level: ServerNotificationLevel | null }
  | { type: "setServerNotificationLevel"; hostId: string; level: ServerNotificationLevel | null }
  | { type: "routinesList"; hostId: string; agentId: string }
  | { type: "routineCreate"; hostId: string; agentId: string; input: Omit<CreateRoutineInput, "agentId"> }
  | {
      type: "routineUpdate";
      hostId: string;
      agentId: string;
      routineId: string;
      changes: Omit<UpdateRoutineInput, "agentId" | "routineId">;
      expectedUpdatedAt: string;
    }
  | { type: "routineDelete"; hostId: string; agentId: string; routineId: string; expectedUpdatedAt: string }
  | { type: "routineTest"; hostId: string; agentId: string; routineId: string; expectedUpdatedAt: string }
  | { type: "routineRuns"; hostId: string; agentId: string; routineId: string; limit?: number };

export const MANAGEMENT_COMMANDS = new Set<string>([
  "agents",
  "agentModels",
  "createAgent",
  "updateAgent",
  "deleteAgent",
  "setReaction",
  "notificationPreferences",
  "setAgentNotificationLevel",
  "setServerNotificationLevel",
  "routinesList",
  "routineCreate",
  "routineUpdate",
  "routineDelete",
  "routineTest",
  "routineRuns",
]);

export function isManagementCommand(value: { type: string }): value is NativeManagementCommand {
  return MANAGEMENT_COMMANDS.has(value.type);
}

const requireCapability = (scope: NativeHostScope, capability: string) => {
  if (!scope.capabilities.includes(capability)) throw new NativeOperationFailure("incompatible");
};
const administrator = (scope: NativeHostScope) => scope.role === "owner" || scope.role === "admin";

function decodeAgent(value: unknown, dispatched = false): ClientAgentSummary {
  if (!isClientAgentSummary(value)) throw new NativeOperationFailure(dispatched ? "unconfirmed" : "protocolError");
  return value;
}

async function roster(scope: NativeHostScope): Promise<ClientAgentSummary[]> {
  const value = await scope.request("GET", TEAM_API_ROUTES.agents.all);
  if (!Array.isArray(value)) throw new NativeOperationFailure("protocolError");
  return value.map((agent) => decodeAgent(agent));
}

async function managementLevels(scope: NativeHostScope): Promise<ReadonlySet<string> | null> {
  if (administrator(scope) || !scope.capabilities.includes(AGENT_ACCESS_CAPABILITY)) return null;
  const value = decodeAgentAccessSnapshot(await scope.request("POST", AGENT_ACCESS_ROUTES.read, {}));
  return new Set(
    Object.entries(value.mine)
      .filter(([, level]) => level === "manage")
      .map(([id]) => id),
  );
}

async function existingAgent(scope: NativeHostScope, agentId: string, manage: boolean): Promise<ClientAgentSummary> {
  const agent = (await roster(scope)).find((item) => item.id === agentId);
  if (!agent) throw new NativeOperationFailure("sendFailed");
  if (manage) {
    const allowed = await managementLevels(scope);
    if (allowed && !allowed.has(agentId)) throw new NativeOperationFailure("sendFailed");
  }
  return agent;
}

async function notificationSnapshot(scope: NativeHostScope, path: string, body: TeamProtocolV2Json) {
  requireCapability(scope, AGENT_NOTIFICATION_LEVELS_CAPABILITY);
  const value = await scope.request("POST", path, body);
  if (!isAgentNotificationLevelsSnapshot(value)) throw new NativeOperationFailure("protocolError");
  return value;
}

function routineApi(scope: NativeHostScope) {
  const request: TeamApiRequest = async (method, path, decode, body) => {
    const value = await scope.request(method, path, body);
    try {
      return decode(value);
    } catch {
      throw new NativeOperationFailure(method === "GET" ? "protocolError" : "unconfirmed");
    }
  };
  return teamAgentRoutinesApi(
    request,
    () => scope.capabilities.includes(ROUTINE_RUN_PLACE_CAPABILITY),
    () => scope.capabilities.includes(ROUTINES_ONCE_CAPABILITY),
  );
}

const recoverySupported = (scope: NativeHostScope) =>
  administrator(scope) && scope.capabilities.includes(ROUTINE_RECOVERY_CAPABILITY);

async function routines(scope: NativeHostScope, agentId: string): Promise<Routine[]> {
  const list = await routineApi(scope).listRoutines(agentId);
  if (!recoverySupported(scope)) return list;
  const recovery = decodeEventRoutines(
    await scope.request("POST", ROUTINE_RECOVERY_ROUTES.listRoutines, { owner: { kind: "agent", id: agentId } }),
  );
  return list.map((routine) => {
    const full = recovery.find(
      (item) => item.id === routine.id && item.owner.kind === "agent" && item.owner.id === agentId,
    );
    return full
      ? {
          ...routine,
          ...(full.limitPolicy === undefined ? {} : { limitPolicy: full.limitPolicy }),
          ...(full.missedPolicy === undefined ? {} : { missedPolicy: full.missedPolicy }),
        }
      : routine;
  });
}

async function readSavedRoutine(scope: NativeHostScope, agentId: string, routineId: string): Promise<Routine> {
  // A second place/policy write can advance updatedAt. Return the host's final saved revision.
  try {
    const saved = (await routines(scope, agentId)).find((item) => item.id === routineId);
    if (saved) return saved;
  } catch {
    /* The write already succeeded; require review instead of inviting a replay. */
  }
  throw new NativeOperationFailure("unconfirmed");
}

function checkRoutineOptions(
  scope: NativeHostScope,
  input: {
    schedule?: CreateRoutineInput["schedule"];
    runIn?: CreateRoutineInput["runIn"];
    limitPolicy?: CreateRoutineInput["limitPolicy"];
    missedPolicy?: CreateRoutineInput["missedPolicy"];
  },
) {
  if (input.schedule?.kind === "once") requireCapability(scope, ROUTINES_ONCE_CAPABILITY);
  if (input.runIn !== undefined) requireCapability(scope, ROUTINE_RUN_PLACE_CAPABILITY);
  if ((input.limitPolicy !== undefined || input.missedPolicy !== undefined) && !recoverySupported(scope))
    throw new NativeOperationFailure("incompatible");
}

async function saveRecoveryRoutine(
  scope: NativeHostScope,
  agentId: string,
  input: Omit<CreateRoutineInput, "agentId">,
  id?: string,
): Promise<Routine> {
  const value = await scope.request(
    "POST",
    ROUTINE_RECOVERY_ROUTES.saveRoutine,
    decodeTeamProtocolV2Json({
      owner: { kind: "agent", id: agentId },
      ...(id ? { id } : {}),
      name: input.name,
      instruction: input.instruction,
      active: input.active,
      timezone: input.timezone,
      trigger: { kind: "schedule", schedule: input.schedule },
      ...(input.limitPolicy === undefined ? {} : { limitPolicy: input.limitPolicy }),
      ...(input.missedPolicy === undefined ? {} : { missedPolicy: input.missedPolicy }),
    }),
  );
  if (!isDynamicRecord(value) || !isDynamicRecord(value.routine) || typeof value.routine.id !== "string")
    throw new NativeOperationFailure("unconfirmed");
  const savedID = value.routine.id;
  let placeUnconfirmed = false;
  if (input.runIn !== undefined) {
    // The routine is already committed. Read it back for review, without rollback or another create.
    await scope
      .request("POST", ROUTINE_RUN_PLACE_ROUTES.set, { agentId, routineId: savedID, runIn: input.runIn })
      .catch(() => {
        placeUnconfirmed = true;
      });
  }
  const saved = await readSavedRoutine(scope, agentId, savedID);
  if (placeUnconfirmed || (input.runIn !== undefined && (saved.runIn ?? "chat") !== input.runIn))
    throw new NativeOperationFailure("unconfirmed");
  return saved;
}

export async function executeManagement(
  scope: NativeHostScope,
  command: NativeManagementCommand,
): Promise<TeamProtocolV2Json> {
  switch (command.type) {
    case "agents": {
      const agents = await roster(scope);
      const allowed = await managementLevels(scope);
      return decodeTeamProtocolV2Json({
        agents: agents.map((agent) => ({
          ...agent,
          canManage: !allowed || allowed.has(agent.id),
          canDelete: administrator(scope),
        })),
        canCreate: true,
        canChooseModel: scope.capabilities.includes(TEAM_AGENT_CREATE_MODEL_CAPABILITY),
      });
    }
    case "agentModels": {
      requireCapability(scope, TEAM_AGENT_CREATE_MODEL_CAPABILITY);
      const models = await scope.request("GET", TEAM_API_ROUTES.agents.models);
      if (!Array.isArray(models) || !models.every(isClientAgentModelOption))
        throw new NativeOperationFailure("protocolError");
      return models;
    }
    case "createAgent": {
      if (
        command.input.provider !== undefined ||
        command.input.model !== undefined ||
        command.input.reasoningEffort !== undefined
      )
        requireCapability(scope, TEAM_AGENT_CREATE_MODEL_CAPABILITY);
      const value = decodeAgent(
        await scope.request("POST", TEAM_API_ROUTES.agents.all, decodeTeamProtocolV2Json(command.input)),
        true,
      );
      return decodeTeamProtocolV2Json({ ...value, canManage: true, canDelete: administrator(scope) });
    }
    case "updateAgent":
    case "deleteAgent": {
      const agent = await existingAgent(scope, command.agentId, true);
      if (agent.updatedAt !== command.expectedUpdatedAt) throw new NativeOperationFailure("sendFailed");
      if (command.type === "deleteAgent") {
        if (!administrator(scope)) throw new NativeOperationFailure("sendFailed");
        return scope.request("DELETE", TEAM_API_ROUTES.agent.one(command.agentId));
      }
      const value = decodeAgent(
        await scope.request(
          "PATCH",
          TEAM_API_ROUTES.agent.one(command.agentId),
          decodeTeamProtocolV2Json(command.patch),
        ),
        true,
      );
      return decodeTeamProtocolV2Json({ ...value, canManage: true, canDelete: administrator(scope) });
    }
    case "setReaction": {
      if (command.emoji !== null && !isMessageReaction(command.emoji))
        throw new NativeOperationFailure("protocolError");
      await existingAgent(scope, command.agentId, false);
      const query = new URLSearchParams({ around: command.messageId, limit: "1" });
      const page = await scope.request("GET", `${TEAM_API_ROUTES.agent.conversationPage(command.agentId)}?${query}`);
      if (
        !isDynamicRecord(page) ||
        !Array.isArray(page.messages) ||
        !page.messages.some((item) => isDynamicRecord(item) && item.id === command.messageId)
      )
        throw new NativeOperationFailure("sendFailed");
      return scope.request("POST", TEAM_API_ROUTES.agent.reactions(command.agentId), {
        messageId: command.messageId,
        emoji: command.emoji,
      });
    }
    case "notificationPreferences":
      return decodeTeamProtocolV2Json(await notificationSnapshot(scope, AGENT_NOTIFICATION_LEVELS_ROUTES.read, {}));
    case "setAgentNotificationLevel":
      await existingAgent(scope, command.agentId, false);
      return decodeTeamProtocolV2Json(
        await notificationSnapshot(scope, AGENT_NOTIFICATION_LEVELS_ROUTES.set, {
          agentId: command.agentId,
          level: command.level,
        }),
      );
    case "setServerNotificationLevel":
      return decodeTeamProtocolV2Json(
        await notificationSnapshot(scope, AGENT_NOTIFICATION_LEVELS_ROUTES.server, { level: command.level }),
      );
    case "routinesList": {
      await existingAgent(scope, command.agentId, false);
      const allowed = await managementLevels(scope);
      return decodeTeamProtocolV2Json({
        routines: await routines(scope, command.agentId),
        once: scope.capabilities.includes(ROUTINES_ONCE_CAPABILITY),
        runPlaces: scope.capabilities.includes(ROUTINE_RUN_PLACE_CAPABILITY),
        recovery: recoverySupported(scope),
        canManage: !allowed || allowed.has(command.agentId),
      });
    }
    case "routineCreate": {
      await existingAgent(scope, command.agentId, true);
      checkRoutineOptions(scope, command.input);
      const input = { ...command.input, agentId: command.agentId };
      const policies = input.limitPolicy !== undefined || input.missedPolicy !== undefined;
      const created =
        policies && input.schedule.kind !== "once"
          ? await saveRecoveryRoutine(scope, command.agentId, command.input)
          : await routineApi(scope).createRoutine(input);
      return decodeTeamProtocolV2Json(await readSavedRoutine(scope, command.agentId, created.id));
    }
    case "routineRuns": {
      await existingAgent(scope, command.agentId, false);
      const limit = command.limit ?? 50;
      if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new NativeOperationFailure("protocolError");
      if (recoverySupported(scope)) {
        const runs = decodeEventRoutineRuns(
          await scope.request("POST", ROUTINE_RECOVERY_ROUTES.listRuns, {
            owner: { kind: "agent", id: command.agentId },
            routineId: command.routineId,
            limit,
          }),
        );
        return decodeTeamProtocolV2Json(
          runs.map((run) => ({ ...run, agentId: command.agentId, deliveryId: run.deliveryId ?? null })),
        );
      }
      return decodeTeamProtocolV2Json(
        await routineApi(scope).listRoutineRuns({ agentId: command.agentId, routineId: command.routineId, limit }),
      );
    }
    case "routineUpdate":
    case "routineDelete":
    case "routineTest": {
      await existingAgent(scope, command.agentId, true);
      const original = (await routines(scope, command.agentId)).find((item) => item.id === command.routineId);
      if (!original || original.updatedAt !== command.expectedUpdatedAt) throw new NativeOperationFailure("sendFailed");
      const api = routineApi(scope);
      const identity = { agentId: command.agentId, routineId: command.routineId };
      if (command.type === "routineDelete") {
        await api.deleteRoutine(identity);
        return {};
      }
      if (command.type === "routineTest") return decodeTeamProtocolV2Json(await api.testRoutine(identity));
      checkRoutineOptions(scope, command.changes);
      const policies = command.changes.limitPolicy !== undefined || command.changes.missedPolicy !== undefined;
      if (policies && !scope.capabilities.includes(ROUTINES_ONCE_CAPABILITY)) {
        return decodeTeamProtocolV2Json(
          await saveRecoveryRoutine(
            scope,
            command.agentId,
            {
              name: original.name,
              instruction: original.instruction,
              active: original.active,
              timezone: original.timezone,
              schedule: original.trigger.schedule,
              ...(original.limitPolicy === undefined ? {} : { limitPolicy: original.limitPolicy }),
              ...(original.missedPolicy === undefined ? {} : { missedPolicy: original.missedPolicy }),
              ...command.changes,
            },
            command.routineId,
          ),
        );
      }
      await api.updateRoutine({ ...identity, ...command.changes });
      return decodeTeamProtocolV2Json(await readSavedRoutine(scope, command.agentId, command.routineId));
    }
  }
}
