import { Schema } from "effect"
import { randomUUID } from "node:crypto"
import type { IncomingMessage, ServerResponse } from "node:http"
import {
  appendAndPublish,
  HttpFailure,
  readSchema,
  run,
  writeJson,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"

const StressRequest = Schema.Struct({
  action: Schema.Literals(["seed", "chunk", "finish"]),
  sessionId: Schema.optional(Schema.String),
  folderPath: Schema.optional(Schema.String),
  title: Schema.optional(Schema.String),
  messageId: Schema.optional(Schema.String),
  phase: Schema.optional(Schema.Literals(["commentary", "final"])),
  turns: Schema.optional(Schema.Number),
  text: Schema.optional(Schema.String)
})

const driverSessions = new WeakMap<RouteState, Set<string>>()

/** Opt-in local development fixture control. Uses the normal durable event
 * materializer and fanout so clients exercise real paging, hydration, and
 * streaming. No timers or model calls: the driver acknowledges every chunk. */
export const routeTranscriptStress = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  state: RouteState,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (process.env.TRANSCRIPT_STRESS !== "1" || url.pathname !== "/dev/transcript-stress")
    return false
  if (request.method !== "POST" || request.headers.origin !== undefined)
    throw new HttpFailure(403, "Local development driver only")
  const body = await readSchema(request, StressRequest)
  let owned = driverSessions.get(state)
  if (!owned) {
    owned = new Set()
    driverSessions.set(state, owned)
  }
  const emit = (id: string, kind: "session.output" | "session.updated", payload: unknown) =>
    appendAndPublish(services.db, fanout, kind, id, payload)
  if (body.action === "seed") {
    const turns = body.turns ?? 500
    if (!Number.isInteger(turns) || turns < 1 || turns > 10_000 || !body.folderPath)
      throw new HttpFailure(400, "Provide a folder and 1–10000 turns")
    const project = await run(services.db.createProject({ folderPath: body.folderPath }))
    await appendAndPublish(services.db, fanout, "project.created", project.id, project)
    const workspace = await run(
      services.db.upsertWorkspace({
        projectId: project.id,
        name: body.title ?? "Transcript stress",
        hasCustomName: true,
        rootDirectory: body.folderPath
      })
    )
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: `transcript-stress-${randomUUID()}`,
        workspaceId: workspace.id,
        title: body.title ?? "Transcript stress"
      })
    )
    // Register as driver-owned so the stale-agent sweep cannot terminate the
    // explicit live turn between driver operations.
    state.activePromptSessions.add(session.id)
    owned.add(session.id)
    // A turn must be durably ended before the next begins; fanout order matters.
    /* oxlint-disable no-await-in-loop */
    for (let index = 0; index < turns; index++) {
      await run(
        services.db.appendConversationItem(
          session.id,
          "user",
          `stress-user-${index}`,
          `Stress turn ${index + 1}: explain this implementation.`,
          false
        )
      )
      await emit(session.id, "session.updated", { turnState: "started", turnId: `stress-${index}` })
      await emit(session.id, "session.output", {
        messageId: `stress-answer-${index}`,
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: body.text ?? stressMarkdown(index) }
      })
      await emit(session.id, "session.updated", {
        turnState: "ended",
        turnId: `stress-${index}`,
        stopReason: "end_turn"
      })
    }
    /* oxlint-enable no-await-in-loop */
    await run(
      services.db.appendConversationItem(
        session.id,
        "user",
        "stress-live-user",
        "Live stress stream",
        false
      )
    )
    await emit(session.id, "session.updated", { turnState: "started", turnId: "stress-live" })
    await appendAndPublish(
      services.db,
      fanout,
      "session.created",
      session.id,
      await run(services.db.getSessionSummary(session.id))
    )
    const pane = await run(
      services.db.upsertWorkspacePane(workspace.id, {
        providerId: "codevisor",
        paneType: "chat",
        title: session.title,
        resourceKind: "session",
        resourceId: session.id
      })
    )
    await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
    await appendAndPublish(services.db, fanout, "workspace.pane.updated", pane.id, pane)
    writeJson(response, 201, { sessionId: session.id, workspaceId: workspace.id, turns })
  } else {
    const id = body.sessionId
    if (!id || !owned.has(id))
      throw new HttpFailure(400, "Unknown stress session; seed it in this process first")
    if (body.action === "chunk") {
      await emit(id, "session.output", {
        messageId: body.messageId ?? "stress-live-answer",
        ...(body.phase ? { phase: body.phase } : {}),
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: body.text ?? "" }
      })
    } else {
      await emit(id, "session.updated", {
        turnState: "ended",
        turnId: "stress-live",
        stopReason: "end_turn"
      })
      state.activePromptSessions.delete(id)
      owned.delete(id)
    }
    writeJson(response, 200, { sessionId: id })
  }
  return true
}

export const stressMarkdown = (index: number): string =>
  [
    `## Turn ${index + 1}: rendering and layout`,
    Array.from(
      { length: 12 },
      (_, paragraph) =>
        `Paragraph ${paragraph + 1}. ` +
        "Text **with emphasis**, `inline code`, [a link](https://example.com), emoji 👩🏽‍💻 and 日本語. ".repeat(
          18
        )
    ).join("\n\n"),
    "```swift\n" +
      Array.from(
        { length: 120 },
        (_, line) => `let value${line} = "Line ${line} in turn ${index + 1}"`
      ).join("\n") +
      "\n```",
    "| Item | Value | Details |\n| --- | ---: | --- |\n" +
      Array.from(
        { length: 80 },
        (_, row) => `| ${row} | **${row * 7}** | Table text with wrapping content |`
      ).join("\n"),
    Array.from(
      { length: 24 },
      (_, item) =>
        `> ${item + 1}. Nested list item\n>    - Child with **style** and a long explanation.\n>    - Another child.`
    ).join("\n>\n")
  ].join("\n\n")
