import { decode } from "@codevisor/api"
import { makeCodevisorProvider } from "@codevisor/automation"
import type { Tool } from "@modelcontextprotocol/sdk/types.js"
import type { JsonSchemaType } from "@modelcontextprotocol/sdk/validation"
import { AjvJsonSchemaValidator } from "@modelcontextprotocol/sdk/validation/ajv"
import { Schema } from "effect"
import { expect, it } from "vitest"

import { jsonRequest, run } from "../test-support.js"
import { setUpWorkspace, createFirstSession } from "./session-test-support.js"

const TranscriptToolPage = Schema.Struct({
  items: Schema.Array(Schema.Struct({ itemId: Schema.String, text: Schema.String })),
  next: Schema.optional(Schema.String)
})

const SearchToolPage = Schema.Struct({
  items: Schema.Array(
    Schema.Struct({ itemId: Schema.String, kind: Schema.String, snippet: Schema.String })
  ),
  next: Schema.optional(Schema.String)
})

const jsonSchemaOf = ({ properties, required, ...rest }: Tool["inputSchema"]): JsonSchemaType => ({
  ...rest,
  ...(properties === undefined ? {} : { properties }),
  ...(required === undefined ? {} : { required })
})

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

it("pages, searches, and reads an agent's transcript through the agent tools", async () => {
  const { server, services, workspace } = await setUpWorkspace()
  const session = await createFirstSession(server, workspace)
  for (const text of ["first", "second", "third"])
    await run(services.db.appendConversationItem(session.id, "user", text, text, false))
  const provider = makeCodevisorProvider(
    () => server.url,
    async () => "unused"
  )
  const validator = new AjvJsonSchemaValidator()
  const call = async (name: string, args: Record<string, unknown>) => {
    const tool = provider.tools.find((candidate) => candidate.name === name)!
    expect(validator.getValidator(jsonSchemaOf(tool.inputSchema))(args)).toMatchObject({
      valid: true
    })
    const result = await provider.invoke({ sessionId: session.id }, name, args)
    const content = result.content[0]
    if (content?.type !== "text") throw new Error("Expected text tool content")
    const parsed: unknown = JSON.parse(content.text)
    return parsed
  }
  const agentId = session.id
  const transcript = async (args: Record<string, unknown>) =>
    decode(TranscriptToolPage)(await call("agents.debug.transcript", { agentId, ...args }))
  const search = async (args: Record<string, unknown>) =>
    decode(SearchToolPage)(await call("agents.debug.search", { agentId, ...args }))

  const newest = await transcript({ limit: 2 })
  expect(newest.items.map((item) => item.text)).toEqual(["second", "third"])
  const older = await transcript({ next: newest.next, limit: 2 })
  expect(older.items.map((item) => item.text)).toEqual(["first"])
  expect(older.next).toBeUndefined()

  const hits = await search({ query: "SEC" })
  expect(hits.items).toEqual([expect.objectContaining({ kind: "user", snippet: "second" })])
  const newestTwo = await search({ last: 2 })
  expect(newestTwo.items.map((hit) => hit.snippet)).toEqual(["third", "second"])
  const rest = await search({ last: 2, next: newestTwo.next })
  expect(rest.items.map((hit) => hit.snippet)).toEqual(["first"])
  expect(rest.next).toBeUndefined()
  expect(await call("agents.debug.item", { agentId, itemId: hits.items[0]!.itemId })).toMatchObject(
    {
      kind: "user",
      text: "second"
    }
  )
  expect(await call("agents.status", { agentId })).toMatchObject({ agentId, state: "idle" })
})

it("rejects unknown agents, kinds, and limits on the agent routes", async () => {
  const { server, workspace } = await setUpWorkspace()
  const session = await createFirstSession(server, workspace)
  const missing = "00000000-0000-4000-8000-000000000000"

  expect((await jsonRequest(server, `/v1/agents/${missing}`)).status).toBe(404)
  expect((await jsonRequest(server, `/v1/agents/${missing}/search`)).status).toBe(404)
  expect((await jsonRequest(server, `/v1/agents/${missing}/items/item-1`)).status).toBe(404)
  expect(
    (await jsonRequest(server, `/v1/agents/${session.id}/search?kinds=user,thought`)).status
  ).toBe(400)
  expect((await jsonRequest(server, `/v1/agents/${session.id}/search?last=0`)).status).toBe(400)
  expect(
    await jsonRequest(server, `/v1/agents/${session.id}/search?last=500&kinds=user`)
  ).toMatchObject({
    status: 200,
    body: { items: [] }
  })
})
