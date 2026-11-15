import { randomUUID } from "node:crypto";
import type { ConversationMessage } from "@openbot/contracts/ipc";
import { Effect } from "effect";
import type { AgentService } from "../../../../src/backend/agent-service";

/** Real history import and routine execution on the fixture's private host profile. */
export function createQuietFixture(agents: AgentService, agentId: string, ownerMemberId: string) {
  const content = "Example HTTP 503 at /private/tmp/user-requested-example.log";
  const routineName = "Quiet background routine";
  let routineId: string | null = null;
  let runId: string | null = null;

  async function setup() {
    if (routineId) return { content, routineName, routineId };
    const page = await Effect.runPromise(agents.readConversation(agentId));
    if (page.activeTurnId !== null) throw new Error("The owned quiet fixture is not idle.");
    // This is ordinary saved assistant content, not a failure notice. Its technical
    // words must survive the presentation policy without a content-based censor.
    const message: ConversationMessage = {
      id: randomUUID(),
      author: "assistant",
      source: "assistant",
      itemType: "agent_message",
      text: content,
      createdAt: new Date().toISOString(),
      status: "completed",
    };
    await Effect.runPromise(
      agents.importTransferHistory(
        {
          agentId,
          thread: {
            main: true,
            title: "",
            titleSource: "auto",
            origin: "user",
            archived: false,
            routineId: null,
            messages: [message],
          },
          files: new Map(),
          agentIds: new Map(),
          routineIds: new Map(),
          runIds: new Map(),
        },
        ownerMemberId,
      ),
    );
    const routine = agents.createRoutine({
      agentId,
      name: routineName,
      instruction: "SIM-FAIL",
      active: false,
      timezone: "UTC",
      schedule: { kind: "daily", time: "09:00" },
      runIn: "chat",
      limitPolicy: "wait",
      missedPolicy: "skip",
    });
    routineId = routine.id;
    return { content, routineName, routineId };
  }

  async function runBackgroundRoutine() {
    if (!routineId || runId) throw new Error("The owned quiet routine is not ready for its one run.");
    const run = await Effect.runPromise(agents.testRoutine({ agentId, routineId }));
    runId = run.id;
    return { routineId, runId };
  }

  async function status() {
    const page = await Effect.runPromise(agents.readConversation(agentId));
    const runs = routineId ? agents.listRoutineRuns({ agentId, routineId, limit: 10 }) : [];
    return {
      content,
      routineName,
      routineId,
      runId,
      activeTurnId: page.activeTurnId,
      routineRuns: runs.map(({ id, status, kind, deliveryId }) => ({ id, status, kind, deliveryId })),
      failedTurns: agents.getRuntimeSnapshot().failedTurns.filter((item) => item.agentId === agentId),
      messages: page.messages.map(({ id, author, text, status, turnId }) => ({ id, author, text, status, turnId })),
      limits:
        "Private profile, real routine/provider/SQLite/RTC path. Provider replies are synthetic; no real model or external action.",
    };
  }
  return { setup, runBackgroundRoutine, status };
}
