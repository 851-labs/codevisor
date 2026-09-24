import { codevisorTools, makeCodevisorProvider } from "@codevisor/automation"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import type { JsonSchemaType } from "@modelcontextprotocol/sdk/validation"
import { AjvJsonSchemaValidator } from "@modelcontextprotocol/sdk/validation/ajv"
import { expect, it } from "vitest"

import { jsonRequest, run } from "../test-support.js"
import { setUpWorkspace, createFirstSession } from "./session-test-support.js"

it("serves a navigation snapshot and validates bidirectional transcript and body cursors", async () => {
  const { server, services, workspace } = await setUpWorkspace()
  const session = await createFirstSession(server, workspace)
  await run(services.db.appendConversationItem(session.id, "user", "message", "hello", false))
  const item = (await run(services.db.getTranscriptPage(session.id, undefined, 1))).items[0]!
  const root = `/v1/sessions/${session.id}/transcript`
  const navigation = await jsonRequest(server, "/v1/navigation")
  expect(navigation.status).toBe(200)
  expect(navigation.body).toMatchObject({
    sessions: expect.arrayContaining([expect.objectContaining({ id: session.id })]),
    eventCursor: expect.any(Number)
  })
  for (const before of [`before-id:${item.id}`, `after-id:${item.id}`, "after:0"])
    expect((await jsonRequest(server, `${root}?before=${before}`)).status).toBe(200)
  for (const before of ["after-id:bad", "before-id:bad"])
    expect((await jsonRequest(server, `${root}?before=${before}`)).status).toBe(400)
  const body = `${root}/${item.id}/body`
  const latest = await jsonRequest(server, `${root}/${item.id}/details?after=latest`)
  expect(latest.status).toBe(200)
  expect(latest.body).toMatchObject({
    itemId: item.id,
    entries: [expect.objectContaining({ key: "message::message" })]
  })
  expect((await jsonRequest(server, `${body}?key=message::message&field=text`)).body).toMatchObject(
    { text: "hello", position: 0 }
  )
  expect(
    (await jsonRequest(server, `${body}?key=message::message&field=text&position=99`)).status
  ).toBe(404)
  for (const query of [
    "",
    "key=x",
    "field=text",
    "key=x&field=text&position=-1",
    "key=x&field=text&position=0.1"
  ])
    expect((await jsonRequest(server, `${body}?${query}`)).status).toBe(400)
  for (const cursor of [
    { position: 0.1, key: "" },
    { position: 0, key: 1 },
    { position: 0, key: "", reverse: 1 }
  ])
    expect(
      (
        await jsonRequest(
          server,
          `${root}/${item.id}/details?after=${Buffer.from(JSON.stringify(cursor)).toString("base64url")}`
        )
      ).status
    ).toBe(400)
  for (const reverse of [undefined, false, true])
    expect(
      (
        await jsonRequest(
          server,
          `${root}/${item.id}/details?after=${Buffer.from(JSON.stringify({ position: 0, key: "", reverse })).toString("base64url")}`
        )
      ).status
    ).toBe(200)
})

it("pages the agent transcript tools with the cursors the route returns", async () => {
  const { server, services, workspace } = await setUpWorkspace()
  const session = await createFirstSession(server, workspace)
  for (const text of ["first", "second", "third"])
    await run(services.db.appendConversationItem(session.id, "user", text, text, false))
  const provider = makeCodevisorProvider(
    () => server.url,
    async () => "unused"
  )
  const validator = new AjvJsonSchemaValidator()
  // Agents build arguments from the published input schema (and the gateway
  // rejects unknown ones), so every call must satisfy that schema first.
  const call = async (name: string, args: Record<string, unknown>) => {
    const tool = codevisorTools.find((candidate) => candidate.name === name)!
    expect(validator.getValidator(tool.inputSchema as JsonSchemaType)(args)).toMatchObject({
      valid: true
    })
    const result = (await provider.invoke({ sessionId: session.id }, name, args)) as CallToolResult
    const content = result.content[0]
    if (content?.type !== "text") throw new Error("Expected text tool content")
    return JSON.parse(content.text) as Record<string, unknown> & {
      readonly items: ReadonlyArray<{ readonly id: string; readonly text: string }>
    }
  }

  const newest = await call("sessions.transcript", { limit: 2 })
  expect(newest.items.map((item) => item.text)).toEqual(["second", "third"])
  expect(newest).toMatchObject({ hasMore: true, nextBefore: expect.any(String) })
  const older = await call("sessions.transcript", { before: newest.nextBefore, limit: 2 })
  expect(older.items.map((item) => item.text)).toEqual(["first"])
  expect(older.hasMore).toBe(false)
  const newer = await call("sessions.transcript", { before: older.nextAfter, limit: 2 })
  expect(newer.items.map((item) => item.text)).toEqual(["second", "third"])

  const details = await call("sessions.transcript_details", {
    itemId: older.items[0]!.id,
    after: "latest"
  })
  expect(details).toMatchObject({ entries: [expect.objectContaining({ key: "message::first" })] })
})
