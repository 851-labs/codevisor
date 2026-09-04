import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { EventEnvelope } from "@codevisor/api"
import { makeEventFanout } from "../server.js"
import type { CodevisorServerServices } from "../server-context.js"
import { makeServices, run, tempDirs } from "../test-support.js"
import { sessionEventSink } from "./session-events.js"
import { localArtifactPath, markdownFileReferences } from "./markdown-artifacts.js"

afterEach(() => vi.restoreAllMocks())

const fixture = async () => {
  const { services } = await makeServices("file-delivery")
  const folder = mkdtempSync(join(tmpdir(), "codevisor-file-delivery-"))
  tempDirs.push(folder)
  const project = await run(services.db.createProject({ folderPath: folder }))
  const session = await run(
    services.db.createSession({ projectId: project.id, harnessId: "codex" })
  )
  const fanout = await run(makeEventFanout)
  const published: Array<EventEnvelope> = []
  fanout.subscribe((event) => published.push(event))
  const sink = sessionEventSink(
    services as unknown as CodevisorServerServices,
    fanout,
    "file-delivery",
    session.id
  )
  const output = (payload: Record<string, unknown>) =>
    sink({ kind: "session.output", subjectId: session.id, payload })
  const end = () =>
    sink({
      kind: "session.updated",
      subjectId: session.id,
      payload: { turnId: "turn-1", turnState: "ended", stopReason: "end_turn" }
    })
  await sink({
    kind: "session.updated",
    subjectId: session.id,
    payload: { turnId: "turn-1", turnState: "started" }
  })
  const item = async () =>
    (await run(services.db.getTranscriptPage(session.id, undefined, 8))).items.find(
      (candidate) => candidate.role === "assistant"
    )!
  return { services, folder, session, published, output, end, item }
}

describe("file delivery", () => {
  it("keeps existing generated attachments when their canonical link is repeated", async () => {
    const f = await fixture()
    await f.output({
      sessionUpdate: "tool_call_update",
      kind: "image_generation",
      toolCallId: "image-1",
      status: "completed",
      generatedImage: { result: Buffer.from("image").toString("base64") }
    })
    const attachment = (await f.item()).attachments![0]!
    const link = `![Image](https://attachments.codevisor.invalid/${attachment.fileId})`
    await f.output({
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: `${link}\n${link}` }
    })
    await f.end()
    expect((await f.item()).attachments).toEqual([attachment])
  })

  it("keeps valid deliverables when other links are missing or point to directories", async () => {
    const f = await fixture()
    const errors = vi.spyOn(console, "error").mockImplementation(() => {})
    writeFileSync(join(f.folder, "valid.png"), "valid")
    await f.output({
      sessionUpdate: "agent_message_chunk",
      content: {
        type: "text",
        text: "![Valid](./valid.png)\n![Missing](./missing.png)\n![Directory](./)"
      }
    })
    await f.end()
    expect((await f.item()).attachments).toMatchObject([{ name: "valid.png" }])
    expect((await f.item()).text).toContain("![Missing](./missing.png)")
    expect(errors).toHaveBeenCalledWith(expect.stringContaining("not a regular file"))
    expect(errors).toHaveBeenCalledWith(expect.stringContaining("ENOENT"))
  })

  it("reports missing generated image data without leaving the turn streaming", async () => {
    const f = await fixture()
    const errors = vi.spyOn(console, "error").mockImplementation(() => {})
    for (const generatedImage of [undefined, {}]) {
      await f.output({
        sessionUpdate: "tool_call_update",
        kind: "image_generation",
        toolCallId: "missing-image",
        status: "completed",
        generatedImage
      })
    }
    await f.end()
    expect((await f.item()).isGenerating).toBe(false)
    expect((await f.item()).attachments ?? []).toEqual([])
    expect(errors).toHaveBeenCalledWith(expect.stringContaining("returned no image"))
    expect(f.published).toContainEqual(
      expect.objectContaining({
        payload: expect.objectContaining({
          status: "failed",
          title: "Could not save generated image"
        })
      })
    )
  })

  it("handles storage failures even when the storage provider rejects without an Error", async () => {
    const f = await fixture()
    const errors = vi.spyOn(console, "error").mockImplementation(() => {})
    vi.spyOn(f.services.attachments, "put").mockRejectedValueOnce("image storage unavailable")
    await f.output({
      sessionUpdate: "tool_call_update",
      kind: "image_generation",
      toolCallId: "failed-image",
      status: "completed",
      generatedImage: { result: Buffer.from("image").toString("base64") }
    })
    writeFileSync(join(f.folder, "recording.mp4"), "recording")
    vi.spyOn(f.services.attachments, "putStream").mockImplementationOnce(async (source) => {
      const chunks: Uint8Array[] = []
      for await (const chunk of source) chunks.push(chunk)
      expect(Buffer.concat(chunks).toString()).toBe("recording")
      return Promise.reject("file storage unavailable")
    })
    await f.output({
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: "[View recording](./recording.mp4)" }
    })
    await f.end()
    expect(await f.item()).toMatchObject({
      isGenerating: false,
      text: "[View recording](./recording.mp4)"
    })
    expect(errors).toHaveBeenCalledWith(expect.stringContaining("image storage unavailable"))
    expect(errors).toHaveBeenCalledWith(expect.stringContaining("file storage unavailable"))
  })

  it("preserves relative image embeds and recording links, leaving source links and code literal", async () => {
    const f = await fixture()
    writeFileSync(join(f.folder, "screen shot.png"), "screenshot")
    writeFileSync(join(f.folder, "demo.mp4"), "recording")
    writeFileSync(join(f.folder, "main.ts"), "source")
    const literal = "`![example](./screen%20shot.png)`\n\n```markdown\n![example](./demo.mp4)\n```"
    await f.output({
      sessionUpdate: "agent_message_chunk",
      messageId: "message",
      content: {
        type: "text",
        text: `![Screenshot](<./screen shot.png>)\n[View recording](./demo.mp4)\n[Source](./main.ts:12)\n${literal}`
      }
    })
    await f.end()
    const item = await f.item()
    expect(item.attachments).toHaveLength(2)
    expect(item.text).toContain(literal)
    expect(item.text).toContain("[Source](./main.ts:12)")
    expect(item.text).toContain("[View recording](https://attachments.codevisor.invalid/")
    rmSync(join(f.folder, "screen shot.png"))
    rmSync(join(f.folder, "demo.mp4"))
    for (const ref of item.attachments!) {
      const metadata = await run(f.services.db.getFileMetadata(ref.fileId))
      expect((await f.services.attachments.read(metadata!)).toString()).toBe(
        ref.mimeType === "image/png" ? "screenshot" : "recording"
      )
    }
  })

  it("publishes generated images immediately, survives replay and deduplicates a later embed", async () => {
    const f = await fixture()
    const bytes = Buffer.from("generated image bytes")
    const path = join(f.folder, "generated.png")
    writeFileSync(path, bytes)
    await f.output({
      sessionUpdate: "tool_call",
      kind: "image_generation",
      toolCallId: "image-1",
      status: "in_progress",
      title: "Generating image"
    })
    const completed = {
      sessionUpdate: "tool_call_update",
      kind: "image_generation",
      toolCallId: "image-1",
      status: "completed",
      title: "Generated image",
      generatedImage: { result: bytes.toString("base64"), savedPath: path }
    }
    await f.output(completed)
    await f.output(completed)
    expect((await f.item()).attachments).toHaveLength(1)
    expect(JSON.stringify(f.published)).not.toContain(bytes.toString("base64"))
    expect(JSON.stringify(f.published)).not.toContain('"generatedImage":')
    await f.output({
      sessionUpdate: "agent_message_chunk",
      messageId: "message",
      content: { type: "text", text: "![Generated image](./generated.png)" }
    })
    await f.end()
    const item = await f.item()
    expect(item.attachments).toHaveLength(1)
    expect(item.text).toContain(item.attachments![0]!.fileId)
    rmSync(path)
    const metadata = await run(f.services.db.getFileMetadata(item.attachments![0]!.fileId))
    expect(await f.services.attachments.read(metadata!)).toEqual(bytes)
  })

  it("retains a generated image when the model sends no final response", async () => {
    const f = await fixture()
    const path = join(f.folder, "generated.png")
    writeFileSync(path, "image")
    await f.output({
      sessionUpdate: "tool_call_update",
      kind: "image_generation",
      toolCallId: "image-1",
      status: "completed",
      generatedImage: { savedPath: path }
    })
    await f.end()
    expect(await f.item()).toMatchObject({
      isGenerating: false,
      attachments: [{ mimeType: "image/png" }]
    })
  })

  it("keeps subagent images out of the parent's attachments and preserves failure details", async () => {
    const f = await fixture()
    await f.output({
      sessionUpdate: "tool_call_update",
      kind: "image_generation",
      toolCallId: "child-image",
      parentToolCallId: "child",
      status: "completed",
      generatedImage: { result: Buffer.from("child image").toString("base64") }
    })
    await f.output({
      sessionUpdate: "tool_call_update",
      kind: "image_generation",
      toolCallId: "failed-image",
      status: "failed",
      rawOutput: { message: "Image generation failed", failure: { type: "usageLimitExceeded" } }
    })
    await f.end()
    expect((await f.item()).attachments ?? []).toEqual([])
    expect(f.published).toContainEqual(
      expect.objectContaining({
        payload: expect.objectContaining({
          status: "failed",
          rawOutput: { message: "Image generation failed", failure: { type: "usageLimitExceeded" } }
        })
      })
    )
  })

  it("ignores fenced, quoted, escaped and inline code links", () => {
    const source =
      "```md\n![a](./one.png)\n```\n> ~~~\n> ![b](./two.png)\n> ~~~\n    ![c](./three.png)\n`![d](./four.png)` \\![e](./five.png)\n![View](</tmp/six image.png>)"
    expect(markdownFileReferences(source).map((ref) => ref.target)).toEqual(["/tmp/six image.png"])
    expect(localArtifactPath("https://example.com/image.png", "/work")).toBeUndefined()
    expect(localArtifactPath("//example.com/image.png", "/work")).toBeUndefined()
    expect(localArtifactPath("#figure", "/work")).toBeUndefined()
    expect(localArtifactPath("./image%20one.png", "/work")).toBe("/work/image one.png")
  })
})
