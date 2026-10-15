import { WorkspaceLinkPage, WorkspacePhotoPage, type EventEnvelope } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it, vi } from "vitest"

import { makeEventFanout } from "../server.js"
import { jsonRequest, makeServices, run, startWithApp } from "../test-support.js"
import { isRecord } from "../unknown-values.js"
import { markdownLinks } from "./markdown-links.js"
import { sessionEventSink } from "./session-events.js"
import { toolImageCandidates } from "./tool-images.js"

const fixture = async () => {
  const { services } = await makeServices("workspace-media")
  const project = await run(services.db.createProject({ folderPath: "/tmp/workspace-media" }))
  const workspace = await run(
    services.db.upsertWorkspace({ projectId: project.id, name: "Work", hasCustomName: false })
  )
  const fanout = await run(makeEventFanout)
  const published: Array<EventEnvelope> = []
  fanout.subscribe((event) => published.push(event))
  const chat = async () => {
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    await run(services.db.setSessionWorkspace(session.id, workspace.id))
    const sink = sessionEventSink(services, fanout, "workspace-media", session.id)
    await sink({
      kind: "session.updated",
      subjectId: session.id,
      payload: { turnState: "started" }
    })
    const output = (payload: Record<string, unknown>) =>
      sink({ kind: "session.output", subjectId: session.id, payload })
    const say = (minute: number, text: string) => {
      vi.setSystemTime(new Date(Date.UTC(2026, 9, 15, 12, minute)))
      return run(services.db.appendEvent("session.output", session.id, { role: "user", text }))
    }
    return Object.assign(output, { say })
  }
  const server = await startWithApp(services, fanout)
  const get = (path: string) => jsonRequest(server, `/v1/workspaces/${workspace.id}/${path}`)
  return { services, server, workspace, published, chat, get }
}

const photoPage = (body: unknown) => Schema.decodeUnknownSync(WorkspacePhotoPage)(body)
const linkPage = (body: unknown) => Schema.decodeUnknownSync(WorkspaceLinkPage)(body)

describe("workspace media routes", () => {
  it("stores inline tool images as files once and lists them as workspace photos", async () => {
    const f = await fixture()
    const output = await f.chat()
    const claude = Buffer.from("claude screenshot").toString("base64")
    const mcp = Buffer.from("mcp screenshot").toString("base64")
    const claudeRead = {
      sessionUpdate: "tool_call_update",
      toolCallId: "read",
      status: "completed",
      rawOutput: [
        { type: "image", source: { type: "base64", media_type: "image/png", data: claude } },
        { type: "image", source: { type: "base64", media_type: "text/plain", data: claude } }
      ]
    }
    vi.useFakeTimers({ toFake: ["Date"] })
    try {
      vi.setSystemTime(new Date(Date.UTC(2026, 9, 15, 12, 1)))
      await output(claudeRead)
      await output(claudeRead)
      vi.setSystemTime(new Date(Date.UTC(2026, 9, 15, 12, 2)))
      await output({
        sessionUpdate: "tool_call_update",
        toolCallId: "browser",
        status: "completed",
        rawOutput: { content: [{ type: "image", data: mcp, mimeType: "image/jpeg" }] }
      })
    } finally {
      vi.useRealTimers()
    }

    const published = JSON.stringify(f.published)
    expect(published).not.toContain(mcp)
    expect(published.split(claude)).toHaveLength(3)
    const update = (toolCallId: string) =>
      f.published.findLast(
        (event) => isRecord(event.payload) && event.payload.toolCallId === toolCallId
      )?.payload
    expect(update("browser")).toMatchObject({
      rawOutput: {
        content: [
          {
            type: "image",
            data: "",
            mimeType: "image/jpeg",
            attachment: { mimeType: "image/jpeg" }
          }
        ]
      }
    })
    expect(update("read")).toMatchObject({
      rawOutput: [
        {
          type: "image",
          source: { type: "base64", media_type: "image/png", data: "" },
          attachment: { mimeType: "image/png" }
        },
        { type: "image", source: { media_type: "text/plain", data: claude } }
      ]
    })

    const all = photoPage((await f.get("photos")).body)
    expect(all.photos.map((photo) => [photo.attachment.mimeType, photo.source])).toEqual([
      ["image/jpeg", "tool"],
      ["image/png", "tool"]
    ])
    const [jpeg, png] = all.photos
    expect(
      await f.services.attachments.read(
        (await run(f.services.db.getFileMetadata(png!.attachment.fileId)))!
      )
    ).toEqual(Buffer.from("claude screenshot"))

    const first = photoPage((await f.get("photos?limit=1")).body)
    expect(first.photos).toEqual([jpeg])
    expect(photoPage((await f.get(`photos?limit=1&before=${first.nextBefore!}`)).body)).toEqual({
      photos: [png]
    })

    expect(photoPage((await f.get("photos?limit=many")).body).photos).toHaveLength(2)
    expect((await f.get("photos?before=not-a-cursor")).status).toBe(400)
    expect(
      (
        await jsonRequest(f.server, `/v1/workspaces/${f.workspace.id}/photos`, {
          method: "POST",
          body: "{}"
        })
      ).status
    ).toBe(404)
    expect((await jsonRequest(f.server, "/v1/workspaces/missing-workspace/photos")).status).toBe(
      404
    )
  })

  it("leaves a tool update untouched when its image can't be stored", async () => {
    const f = await fixture()
    const output = await f.chat()
    const data = Buffer.from("unstorable").toString("base64")
    vi.spyOn(f.services.attachments, "put").mockRejectedValueOnce(new Error("disk full"))
    vi.spyOn(console, "error").mockImplementationOnce(() => undefined)
    await output({
      sessionUpdate: "tool_call_update",
      toolCallId: "browser",
      status: "completed",
      content: [{ type: "content", content: { type: "image", data, mimeType: "image/png" } }]
    })
    expect(JSON.stringify(f.published)).toContain(data)
    expect(photoPage((await f.get("photos")).body).photos).toEqual([])
  })

  it("lists each chat link once, newest first, a page at a time", async () => {
    const f = await fixture()
    const older = await f.chat()
    const newer = await f.chat()
    vi.useFakeTimers({ toFake: ["Date"] })
    try {
      await older.say(1, "Compare https://example.com/a with https://example.com/b")
      await newer.say(2, "No links here")
      await newer.say(3, "Revisit [B](https://example.com/b) and https://example.com/c")
    } finally {
      vi.useRealTimers()
    }

    expect(
      linkPage((await f.get("links")).body).links.map((link) => [link.url, link.title])
    ).toEqual([
      ["https://example.com/b", "B"],
      ["https://example.com/c", undefined],
      ["https://example.com/a", undefined]
    ])

    const first = linkPage((await f.get("links?limit=1")).body)
    expect(first.links.map((link) => link.url)).toEqual([
      "https://example.com/b",
      "https://example.com/c"
    ])
    expect(
      linkPage((await f.get(`links?limit=1&before=${first.nextBefore!}`)).body).links.map(
        (link) => link.url
      )
    ).toEqual(["https://example.com/a", "https://example.com/b"])
  })
})

const toolImage = (data = "aW1hZ2U=") => ({ type: "image", data, mimeType: "image/png" })
const toolUpdate = (rawOutput: unknown, sessionUpdate = "tool_call_update") => ({
  sessionUpdate,
  rawOutput
})

describe("toolImageCandidates", () => {
  it.each([
    ["a tool image", toolUpdate(toolImage()), 1],
    ["a non-tool update", toolUpdate(toolImage(), "agent_message_chunk"), 0],
    ["an image nested too deeply", toolUpdate({ a: { b: { c: { d: { e: toolImage() } } } } }), 0],
    [
      "more images than one event keeps",
      toolUpdate(Array.from({ length: 9 }, (_, i) => toolImage(`aW1n${i}`))),
      8
    ],
    ["an oversized image", toolUpdate(toolImage("A".repeat(28_000_000))), 0],
    ["an image without a mime type", toolUpdate({ type: "image", data: "aW1hZ2U=" }), 0],
    [
      "a linked rather than embedded image",
      toolUpdate({ type: "image", source: { type: "url", url: "https://example.com/a.png" } }),
      0
    ]
  ])("finds %s", (_label, payload, expected) => {
    expect(toolImageCandidates(payload).size).toBe(expected)
  })
})

describe("markdownLinks", () => {
  it.each([
    ["[docs](https://example.com/docs)", [{ url: "https://example.com/docs", title: "docs" }]],
    ["[https://example.com](https://example.com)", [{ url: "https://example.com/" }]],
    ["<https://example.com/auto>", [{ url: "https://example.com/auto" }]],
    ["See https://example.com/a, then stop.", [{ url: "https://example.com/a" }]],
    ["(see https://example.com/wiki/A_(B))", [{ url: "https://example.com/wiki/A_(B)" }]],
    ["Run `http://localhost:3000`", [{ url: "http://localhost:3000/" }]],
    ["Run `curl https://example.com`", []],
    ["```\nhttps://example.com/fenced\n```", []],
    ["    https://example.com/indented", []],
    ["![shot](https://example.com/shot.png)", []],
    ["[file](./notes.md) mailto:a@b.co ftp://example.com", []],
    ["[att](https://attachments.codevisor.invalid/abc)", []],
    ["```\n[in code](https://example.com/in-code)\n```", []],
    ["\\[escaped](https://example.com/escaped)", [{ url: "https://example.com/escaped" }]],
    ["`<https://example.com/code>`", []],
    [
      "[![CI](https://img.shields.io/badge.svg)](https://github.com/o/r/actions)",
      [{ url: "https://github.com/o/r/actions", title: "CI" }]
    ],
    [
      "[Foo](https://en.wikipedia.org/wiki/Foo_(bar))",
      [{ url: "https://en.wikipedia.org/wiki/Foo_(bar)", title: "Foo" }]
    ],
    [
      "[<https://a.example>](https://b.example)",
      [{ url: "https://b.example/", title: "<https://a.example>" }]
    ],
    ["https://example.com/x and https://example.com/x", [{ url: "https://example.com/x" }]]
  ])("extracts %j", (source, expected) => {
    expect(markdownLinks(source)).toEqual(expected)
  })
})
