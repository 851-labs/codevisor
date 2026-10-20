import { execFile } from "node:child_process"
import { randomUUID } from "node:crypto"
import { mkdtemp, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import {
  WorkspaceLinkPage,
  WorkspaceMediaPage,
  WorkspacePhotoPage,
  type AttachmentKind,
  type EventEnvelope,
  type FileMetadata
} from "@codevisor/api"
import { Schema } from "effect"
import ffmpeg from "ffmpeg-static"
import { describe, expect, it, onTestFinished, vi } from "vitest"

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
    return Object.assign(output, { say, sessionId: session.id })
  }
  const server = await startWithApp(services, fanout)
  const get = (path: string) => jsonRequest(server, `/v1/workspaces/${workspace.id}/${path}`)
  return { services, server, workspace, published, chat, get }
}

const photoPage = (body: unknown) => Schema.decodeUnknownSync(WorkspacePhotoPage)(body)
const mediaPage = (body: unknown) => Schema.decodeUnknownSync(WorkspaceMediaPage)(body)

const ref = (file: FileMetadata) => ({
  fileId: file.id,
  name: file.name,
  mimeType: file.mimeType,
  sizeBytes: file.sizeBytes,
  kind: file.kind
})

const videoClip = async (seconds: number): Promise<Buffer> => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-media-"))
  onTestFinished(() => rm(root, { recursive: true, force: true }))
  const path = join(root, "clip.mp4")
  if (typeof ffmpeg !== "string") throw new Error("Missing ffmpeg binary")
  await promisify(execFile)(ffmpeg, [
    "-nostdin",
    "-loglevel",
    "error",
    "-f",
    "lavfi",
    "-i",
    "color=blue:s=64x48:r=10",
    "-t",
    String(seconds),
    "-y",
    path
  ])
  return readFile(path)
}
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

  it("lists videos among images newest first, probing each video's duration once", async () => {
    const f = await fixture()
    const output = await f.chat()
    const store = async (name: string, mimeType: string, kind: AttachmentKind, data: Buffer) => {
      const stored = await f.services.attachments.put(data)
      return run(
        f.services.db.createDiskFile({
          id: randomUUID(),
          name,
          mimeType,
          sizeBytes: stored.sizeBytes,
          sha256: stored.sha256,
          kind,
          createdAt: new Date().toISOString()
        })
      )
    }
    const shot = await store("shot.png", "image/png", "image", Buffer.from("screenshot"))
    const clip = await store("clip.mp4", "video/mp4", "file", await videoClip(2.5))
    const broken = await store("broken.mov", "video/quicktime", "file", Buffer.from("not video"))
    const recording = await store("recording.mp4", "video/mp4", "file", await videoClip(1))
    const lost = await store("lost.mp4", "video/mp4", "file", Buffer.from("lost video"))
    await rm(f.services.attachments.objectPath(lost.sha256))
    const attach = (minute: number, file: FileMetadata) => {
      vi.setSystemTime(new Date(Date.UTC(2026, 9, 15, 12, minute)))
      return run(
        f.services.db.appendEvent("session.output", output.sessionId, {
          role: "user",
          text: "",
          attachments: [ref(file)]
        })
      )
    }
    vi.useFakeTimers({ toFake: ["Date"] })
    try {
      await attach(1, shot)
      await attach(2, clip)
      await attach(3, broken)
      await attach(4, lost)
      vi.setSystemTime(new Date(Date.UTC(2026, 9, 15, 12, 5)))
      await output({
        sessionUpdate: "tool_call_update",
        toolCallId: "execute",
        status: "completed",
        _meta: {
          codevisorExecution: {
            state: "completed",
            calls: [{ path: "computer.record", ok: true, ms: 9, files: [{ fileId: recording.id }] }]
          }
        }
      })
    } finally {
      vi.useRealTimers()
    }

    const all = mediaPage((await f.get("media")).body)
    expect(
      all.media.map((item) => [
        item.attachment.name,
        item.attachment.kind,
        item.source,
        item.durationSeconds
      ])
    ).toEqual([
      ["recording.mp4", "file", "tool", 1],
      ["lost.mp4", "file", "message", undefined],
      ["broken.mov", "file", "message", undefined],
      ["clip.mp4", "file", "message", 2.5],
      ["shot.png", "image", "message", undefined]
    ])
    expect(all.media.at(-1)).toEqual({
      attachment: ref(shot),
      sessionId: output.sessionId,
      itemId: expect.any(String),
      createdAt: "2026-10-15T12:01:00.000Z",
      source: "message"
    })
    expect((await f.get("photos")).body).toEqual({ photos: [all.media.at(-1)] })

    const first = mediaPage((await f.get("media?limit=4")).body)
    expect(first.media).toEqual(all.media.slice(0, 4))
    expect(mediaPage((await f.get(`media?before=${first.nextBefore!}`)).body)).toEqual({
      media: all.media.slice(4)
    })

    await rm(f.services.attachments.objectPath(clip.sha256))
    expect(mediaPage((await f.get("media")).body).media[3]?.durationSeconds).toBe(2.5)
    expect((await jsonRequest(f.server, "/v1/workspaces/missing-workspace/media")).status).toBe(404)
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
