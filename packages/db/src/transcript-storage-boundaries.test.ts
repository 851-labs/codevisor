import type { TranscriptBodyPage } from "@codevisor/api"
import { expect, it } from "vitest"

import type { JsonRecord } from "./event-payloads.js"
import { projectSetupState, sessionSetupState } from "./setup-state.js"
import { memoryDatabase, run } from "./test-support.js"
import {
  mergeTranscriptFields,
  readToolSnapshot,
  transcriptTextResource,
  inlineTranscriptFields
} from "./transcript-bodies.js"
import {
  projectTranscriptState,
  readTranscriptText,
  textPatchForEvent
} from "./transcript-state.js"

it("retains setup metadata and all Unicode log pages with session authorization", async () => {
  const { sqlite, db, project, session } = await memoryDatabase()
  const put = (subject: string, kind: string, payload: unknown) =>
    projectSetupState(sqlite, subject, kind, 1, "2026-09-16", payload)
  put(session.id, "unrelated", {})
  put(session.id, "project.setup", null)
  expect(sessionSetupState(sqlite, session.id)).toEqual([])
  put(project.id, "project.setup", { state: "running" })
  expect(sessionSetupState(sqlite, session.id)).toMatchObject([{ state: "running" }])
  const text = "a".repeat(8182) + "😀" + "z".repeat(9000)
  put(project.id, "project.setup", { state: "log", line: text })
  put(project.id, "project.setup", { state: "log", stream: "stderr", line: "done" })
  expect(sessionSetupState(sqlite, session.id)).toMatchObject([
    { state: "running", resource: { itemId: `setup:${project.id}` } }
  ])
  let result = ""
  let position: number | undefined = 0
  while (position !== undefined) {
    const page: TranscriptBodyPage = (await run(
      db.getTranscriptBodyPage(session.id, `setup:${project.id}`, "project.setup", "text", position)
    ))!
    result += page.text
    position = page.nextPosition
  }
  expect(result).toBe(`[stdout] ${text}\n[stderr] done\n`)
  expect(
    await run(
      db.getTranscriptBodyPage(session.id, `setup:${project.id}`, "project.setup", "text", 999)
    )
  ).toBeUndefined()
  expect(
    await run(
      db.getTranscriptBodyPage("unknown", `setup:${project.id}`, "project.setup", "text", 0)
    )
  ).toBeUndefined()
})

it("pages large tool fields losslessly and replaces them without retaining stale blocks", async () => {
  const { sqlite, db, session } = await memoryDatabase()
  await run(
    db.appendEvent("session.output", session.id, { sessionUpdate: "tool_call", toolCallId: "t" })
  )
  const item = (await run(db.getTranscriptPage(session.id, undefined, 1))).items[0]!
  const large = "a".repeat(8191) + "😀" + "z".repeat(10000)
  const payload = mergeTranscriptFields(
    sqlite,
    item.id,
    "tool:t",
    7,
    {},
    {
      omitted: undefined,
      first: "a".repeat(16000),
      second: "b".repeat(16000),
      overflow: "c".repeat(1000),
      small: true,
      output: large,
      json: { data: large },
      nil: null
    }
  )
  expect(inlineTranscriptFields(payload)).toMatchObject({
    small: true,
    nil: null,
    output: large.slice(0, 512)
  })
  expect(inlineTranscriptFields(payload)).not.toHaveProperty("json")
  for (const [field, expected] of [
    ["output", large],
    ["json", JSON.stringify({ data: large })]
  ] as const) {
    let position: number | undefined = 0
    let result = ""
    while (position !== undefined) {
      const page: TranscriptBodyPage = (await run(
        db.getTranscriptBodyPage(session.id, item.id, "tool:t", field, position)
      ))!
      result += page.text
      position = page.nextPosition
    }
    expect(result).toBe(expected)
    expect(
      await run(db.getTranscriptBodyPage(session.id, item.id, "tool:t", field, 999))
    ).toBeUndefined()
  }
  expect(
    await run(db.getTranscriptBodyPage("other", item.id, "tool:t", "output", 0))
  ).toBeUndefined()
  expect(readToolSnapshot(sqlite, item.id, "missing")).toBeUndefined()
  expect(transcriptTextResource(sqlite, item.id, "missing")).toBeUndefined()
  const replaced = mergeTranscriptFields(sqlite, item.id, "tool:t", 8, payload, { output: "done" })
  expect(replaced.output).toBe("done")
  expect(
    await run(db.getTranscriptBodyPage(session.id, item.id, "tool:t", "output", 0))
  ).toBeUndefined()
})

it("folds final answers, metadata, compaction and parented text into current state", async () => {
  const { sqlite, db, session } = await memoryDatabase()
  await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
  const item = (await run(db.getTranscriptPage(session.id, undefined, 1))).items[0]!
  let revision = 10
  const put = (
    payload: JsonRecord,
    kind = "session.output",
    itemId: string | undefined = item.id
  ) => {
    const event = {
      session_id: session.id,
      revision: revision++,
      server_id: "local",
      global_event_id: null,
      kind,
      created_at: "2026-09-16",
      payload: JSON.stringify(payload),
      chat_item_id: itemId ?? null
    }
    projectTranscriptState(sqlite, event as never, itemId)
    return textPatchForEvent(sqlite, item.id, event.revision, payload)
  }
  expect(put({ sessionUpdate: "agent_message_chunk" })).toBeUndefined()
  expect(put({ role: "assistant", text: "first", phase: "commentary" })).toMatchObject({
    text: "first"
  })
  expect(put({ sessionUpdate: "assistant_message_finalized", markdown: "final" })).toMatchObject({
    text: "final",
    isFinalized: true
  })
  put({ sessionUpdate: "tool_call" })
  put({ sessionUpdate: "tool_call", toolCallId: "break" })
  expect(put({ sessionUpdate: "agent_message_chunk", messageId: "empty" })).toMatchObject({
    text: ""
  })
  expect(
    put({
      sessionUpdate: "agent_message_chunk",
      parentToolCallId: "break",
      messageId: "child",
      text: "child"
    })
  ).toMatchObject({ parentToolCallId: "break" })
  expect(
    put({ sessionUpdate: "assistant_message_finalized", parentToolCallId: "other" })
  ).toMatchObject({ text: "" })
  put({ sessionUpdate: "context_compaction", status: "started" })
  put({ sessionUpdate: "context_compaction", status: "completed" })
  put({ sessionUpdate: "context_compaction", status: "failed" })
  put({ sessionUpdate: "context_compaction", compactionId: "keep", status: "completed" })
  put({ sessionUpdate: "large_custom", value: { data: "z".repeat(40000) } })
  put({ sessionUpdate: "plan_document", markdown: "p".repeat(25000) })
  put({ goal: { status: "active" } }, "session.updated")
  put({ goalCleared: true, configOptions: [] }, "session.updated")
  expect(readTranscriptText(sqlite, item.id, "plan")).toHaveLength(25000)
  expect(readTranscriptText(sqlite, item.id, "plan", 8192)).toHaveLength(8192)
  expect(
    await run(db.getTranscriptBodyPage(session.id, item.id, "missing", "text", 0))
  ).toBeUndefined()
  expect(
    await run(db.getTranscriptBodyPage(session.id, item.id, "message::empty", "text", 0))
  ).toBeUndefined()
  expect(await run(db.getTranscriptItemDetails(session.id, item.id))).toMatchObject({
    entries: expect.arrayContaining([
      expect.objectContaining({
        key: "plan",
        payload: expect.objectContaining({ detailResource: expect.any(Object) })
      })
    ])
  })
  await expect(run(db.getTranscriptPage(session.id, "missing", 8))).rejects.toThrow("cursor item")
  for (const cursor of [
    { position: 0.5, key: "" },
    { position: 0, key: false }
  ])
    await expect(
      run(
        db.getTranscriptItemDetails(
          session.id,
          item.id,
          Buffer.from(JSON.stringify(cursor)).toString("base64url")
        )
      )
    ).rejects.toThrow("Invalid transcript state cursor")
})
