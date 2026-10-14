import { randomUUID } from "node:crypto"

import type { RuntimeEvent } from "./types.js"

const record = (value: unknown): Record<string, unknown> | undefined =>
  typeof value === "object" && value !== null ? (value as Record<string, unknown>) : undefined

const chunkText = (payload: Record<string, unknown>): string => {
  const content = record(payload.content)
  return content?.type === "text" && typeof content.text === "string" ? content.text : ""
}

const phaseCorrection = (subjectId: string, messageId: string): RuntimeEvent => ({
  kind: "session.output",
  subjectId,
  payload: {
    content: { text: "", type: "text" },
    messageId,
    phase: "commentary",
    sessionUpdate: "agent_message_chunk"
  }
})

export interface MessagePhases {
  readonly label: (event: RuntimeEvent) => ReadonlyArray<RuntimeEvent>
}

export const makeMessagePhases = (newId: () => string = randomUUID): MessagePhases => {
  let run: string | undefined
  let latest: { readonly id: string; commentary: boolean } | undefined
  const labeled = new Set<string>()

  const reset = () => {
    run = undefined
    latest = undefined
    labeled.clear()
  }

  const text = (event: RuntimeEvent, payload: Record<string, unknown>): RuntimeEvent => {
    const content = chunkText(payload)
    const given = typeof payload.messageId === "string" ? payload.messageId : undefined
    if (given === undefined && content === "") return event
    run = given === undefined ? (run ?? newId()) : undefined
    const id = given ?? run!
    const withId =
      given === undefined ? { ...event, payload: { ...payload, messageId: id } } : event
    if (payload.phase !== undefined) {
      labeled.add(id)
      if (latest?.id === id) latest = undefined
      return withId
    }
    if (labeled.has(id) || content === "") return withId
    if (latest?.id === id && latest.commentary) {
      latest.commentary = false
      return { ...withId, payload: { ...(withId.payload as object), phase: "final" } }
    }
    latest = { id, commentary: false }
    return withId
  }

  return {
    label: (event) => {
      const payload = record(event.payload)
      if (payload === undefined) return [event]
      if (event.kind === "session.updated") {
        if (payload.turnState !== undefined) reset()
        return [event]
      }
      if (event.kind !== "session.output" || typeof payload.parentToolCallId === "string")
        return [event]
      if (payload.sessionUpdate === "agent_message_chunk") return [text(event, payload)]
      run = undefined
      if (payload.sessionUpdate !== "tool_call" || latest === undefined || latest.commentary)
        return [event]
      latest.commentary = true
      return [phaseCorrection(event.subjectId, latest.id), event]
    }
  }
}
