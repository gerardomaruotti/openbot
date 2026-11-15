import { Effect } from "effect";
import type { AgentService } from "../../../../src/backend/agent-service";
import { type HostEventsApi, HostEventsFailure } from "../../../../src/main/host-events-api";
import { HostEventsService } from "../../../../src/main/host-events-service";

/** Faults only the host ports. Scheduler records and the route's response remain production-owned. */
export function createRoutineFaults(agents: AgentService) {
  const state: {
    runsReadbackBlocked: boolean;
    failedRunReadbacks: number;
    failSecondaryPlace: boolean;
    secondaryPlaceFailures: number;
    failedPlaceRoutineId: string | null;
    recoveryCreates: Array<{ agentId: string; routineId: string }>;
  } = {
    runsReadbackBlocked: false,
    failedRunReadbacks: 0,
    failSecondaryPlace: false,
    secondaryPlaceFailures: 0,
    failedPlaceRoutineId: null,
    recoveryCreates: [],
  };
  let pendingPlace: { agentId: string; routineId: string } | null = null;
  const unavailable = () => new Error("Synthetic routine readback is unavailable.");
  const listRuns: AgentService["listRoutineRuns"] = (...args) => {
    if (state.runsReadbackBlocked) {
      state.failedRunReadbacks++;
      throw unavailable();
    }
    return agents.listRoutineRuns(...args);
  };
  const update: AgentService["updateRoutine"] = (...args) => {
    const [input, options] = args;
    if (
      pendingPlace?.agentId === input.agentId &&
      pendingPlace.routineId === input.routineId &&
      input.runIn !== undefined &&
      options?.recordConversationEvent === false
    ) {
      pendingPlace = null;
      state.secondaryPlaceFailures++;
      state.failedPlaceRoutineId = input.routineId;
      throw new Error("Synthetic secondary routine place write failed.");
    }
    return agents.updateRoutine(...args);
  };
  function isAgentPortMember(key: PropertyKey): key is keyof AgentService {
    return key in agents;
  }
  // The proxy faults only the Team API port. The actual scheduler and independent status
  // inspection keep the original instance and its real methods.
  const apiAgents = new Proxy(agents, {
    get(target, property) {
      if (property === "listRoutineRuns") return listRuns;
      if (property === "updateRoutine") return update;
      if (!isAgentPortMember(property)) return undefined;
      const value = target[property];
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  const service = new HostEventsService({
    routines: agents.routineRecords,
    // Schedule recovery uses no cipher or relay. Webhook account operations are unavailable.
    cipher: {
      encrypt: () => {
        throw new Error("Webhook secrets are outside this fixture.");
      },
      decrypt: () => {
        throw new Error("Webhook secrets are outside this fixture.");
      },
    },
    relay: {
      connected: () => false,
      setEnabled: () => {},
      setAccountActive: () => {},
      refresh: () => {},
      ensureHost: () => Effect.die(new Error("Webhook registration is outside this fixture.")),
      registerRoute: () => Effect.fail({ cause: new Error("Webhook relay is outside this fixture.") }),
      revokeRoute: () => Effect.fail({ cause: new Error("Webhook relay is outside this fixture.") }),
    },
    accountPrincipal: () => null,
  });
  const events: HostEventsApi = {
    getStatus: () => service.getStatus(),
    listRoutines: (input) => service.listRoutines(input),
    deleteRoutine: (input) => service.deleteRoutine(input),
    testRoutine: (input) => service.testRoutine(input),
    rotateSecret: (input) => service.rotateSecret(input),
    setSecret: (input) => service.setSecret(input),
    sendTestEvent: (input) => service.sendTestEvent(input),
    listActivity: (input) => service.listActivity(input),
    saveRoutine: (input) =>
      service.saveRoutine(input).pipe(
        Effect.tap((saved) =>
          Effect.sync(() => {
            if (input.id !== undefined || input.owner.kind !== "agent" || input.trigger.kind !== "schedule") return;
            const committed = { agentId: input.owner.id, routineId: saved.routine.id };
            state.recoveryCreates.push(committed);
            if (!state.failSecondaryPlace) return;
            state.failSecondaryPlace = false;
            pendingPlace = committed;
          }),
        ),
      ),
    listRoutineRuns: (input) =>
      Effect.suspend(() => {
        if (!state.runsReadbackBlocked) return service.listRoutineRuns(input);
        state.failedRunReadbacks++;
        return Effect.fail(new HostEventsFailure({ cause: unavailable() }));
      }),
  };
  return {
    apiAgents,
    events,
    state,
    armSecondaryPlace(enabled: boolean) {
      state.failSecondaryPlace = enabled;
      pendingPlace = null;
    },
  };
}
