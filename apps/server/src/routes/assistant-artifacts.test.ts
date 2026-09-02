import { randomUUID } from "node:crypto"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { EventEnvelope } from "@codevisor/api"
import { makeEventFanout } from "../server.js"
import type { CodevisorServerServices } from "../server-context.js"
import { makeServices, run, tempDirs } from "../test-support.js"
import { promoteAssistantArtifacts, referencedAttachmentIds } from "./assistant-artifacts.js"
import { sessionEventSink } from "./session-events.js"

afterEach(() => {
  tempDirs.splice(0)
})

describe("assistant artifact promotion", () => {
  it("extracts attachment file ids from Markdown in order, once each", () => {
    expect(
      referencedAttachmentIds(
        "![a](https://attachments.codevisor.invalid/one) then " +
          "[b](https://attachments.codevisor.invalid/two) and " +
          "![again](https://attachments.codevisor.invalid/one) but not ./attachment"
      )
    ).toEqual(["one", "two"])
    expect(referencedAttachmentIds("plain text")).toEqual([])
  })

  it("attaches referenced artifacts to the assistant item before the turn ends", async () => {
    const { services } = await makeServices("server-a")
    const fanout = await run(makeEventFanout)
    const published: Array<EventEnvelope> = []
    fanout.subscribe((event) => published.push(event))
    const folder = mkdtempSync(join(tmpdir(), "codevisor-artifacts-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-artifacts"
      })
    )
    const stored = await services.attachments.put(Buffer.from("fake-png"))
    const file = await run(
      services.db.createDiskFile({
        id: randomUUID(),
        name: "browser-screenshot.png",
        mimeType: "image/png",
        sizeBytes: stored.sizeBytes,
        sha256: stored.sha256,
        kind: "image",
        createdAt: new Date().toISOString()
      })
    )
    const sink = sessionEventSink(
      services as unknown as CodevisorServerServices,
      fanout,
      "server-a",
      session.id
    )
    const markdown = `Here it is:\n\n![House](https://attachments.codevisor.invalid/${file.id})\n\nAlso https://attachments.codevisor.invalid/missing-id is unknown.`
    await sink({
      kind: "session.updated",
      subjectId: "agent-artifacts",
      payload: { initiatedBy: "user", turnId: "turn-1", turnState: "started" }
    })
    await sink({
      kind: "session.output",
      subjectId: "agent-artifacts",
      payload: {
        sessionUpdate: "agent_message_chunk",
        messageId: "msg-1",
        content: { type: "text", text: markdown }
      }
    })
    await sink({
      kind: "session.updated",
      subjectId: "agent-artifacts",
      payload: { initiatedBy: "user", turnId: "turn-1", turnState: "ended", stopReason: "end_turn" }
    })

    const finalized = published.find(
      (event) =>
        event.kind === "session.output" &&
        (event.payload as { sessionUpdate?: string }).sessionUpdate ===
          "assistant_message_finalized"
    )
    expect(finalized?.payload).toMatchObject({
      markdown,
      messageId: "msg-1",
      attachments: [
        {
          fileId: file.id,
          name: "browser-screenshot.png",
          mimeType: "image/png",
          sizeBytes: stored.sizeBytes,
          kind: "image"
        }
      ]
    })
    const ended = published.findIndex(
      (event) => (event.payload as { turnState?: string }).turnState === "ended"
    )
    expect(published.indexOf(finalized!)).toBeLessThan(ended)

    const page = await run(services.db.getTranscriptPage(session.id, undefined, 8))
    const item = page.items.find((candidate) => candidate.role === "assistant")
    expect(item).toMatchObject({
      text: markdown,
      isGenerating: false,
      attachments: [{ fileId: file.id, kind: "image" }]
    })
  })

  it("skips promotion when every referenced id is unknown", async () => {
    const { services } = await makeServices("server-c")
    const fanout = await run(makeEventFanout)
    const folder = mkdtempSync(join(tmpdir(), "codevisor-artifacts-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    const sink = sessionEventSink(
      services as unknown as CodevisorServerServices,
      fanout,
      "server-c",
      session.id
    )
    await sink({
      kind: "session.updated",
      subjectId: "agent",
      payload: { initiatedBy: "user", turnId: "turn-1", turnState: "started" }
    })
    await sink({
      kind: "session.output",
      subjectId: "agent",
      payload: {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "![x](https://attachments.codevisor.invalid/nope)" }
      }
    })
    await expect(
      promoteAssistantArtifacts(
        services as unknown as CodevisorServerServices,
        fanout,
        "server-c",
        session.id
      )
    ).resolves.toBe(false)
  })

  it("still ends the turn when promotion fails", async () => {
    const { services } = await makeServices("server-d")
    const fanout = await run(makeEventFanout)
    const published: Array<EventEnvelope> = []
    fanout.subscribe((event) => published.push(event))
    const errors = vi.spyOn(console, "error").mockImplementation(() => undefined)
    const folder = mkdtempSync(join(tmpdir(), "codevisor-artifacts-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    // Both an Error and a raw thrown value are reported without blocking the turn end.
    for (const failure of [new Error("transcript unavailable"), "transcript unavailable"]) {
      const failing = {
        ...services,
        db: {
          ...services.db,
          getTranscriptPage: () => {
            throw failure
          }
        }
      } as unknown as CodevisorServerServices
      const sink = sessionEventSink(failing, fanout, "server-d", session.id)
      await sink({
        kind: "session.updated",
        subjectId: "agent",
        payload: {
          initiatedBy: "user",
          turnId: "turn-1",
          turnState: "ended",
          stopReason: "end_turn"
        }
      })
    }
    expect(errors).toHaveBeenCalledTimes(2)
    expect(errors).toHaveBeenCalledWith(
      expect.stringContaining("Assistant artifact promotion failed")
    )
    expect(
      published.filter((event) => (event.payload as { turnState?: string }).turnState === "ended")
    ).toHaveLength(2)
    errors.mockRestore()
  })

  it("promotes a reply that streamed without a provider message id", async () => {
    const { services } = await makeServices("server-e")
    const fanout = await run(makeEventFanout)
    const published: Array<EventEnvelope> = []
    fanout.subscribe((event) => published.push(event))
    const folder = mkdtempSync(join(tmpdir(), "codevisor-artifacts-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    const stored = await services.attachments.put(Buffer.from("png"))
    const file = await run(
      services.db.createDiskFile({
        id: randomUUID(),
        name: "shot.png",
        mimeType: "image/png",
        sizeBytes: stored.sizeBytes,
        sha256: stored.sha256,
        kind: "image",
        createdAt: new Date().toISOString()
      })
    )
    const sink = sessionEventSink(
      services as unknown as CodevisorServerServices,
      fanout,
      "server-e",
      session.id
    )
    await sink({
      kind: "session.updated",
      subjectId: "agent",
      payload: { initiatedBy: "user", turnId: "turn-1", turnState: "started" }
    })
    await sink({
      kind: "session.output",
      subjectId: "agent",
      payload: {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: `![x](https://attachments.codevisor.invalid/${file.id})` }
      }
    })
    await sink({
      kind: "session.updated",
      subjectId: "agent",
      payload: { initiatedBy: "user", turnId: "turn-1", turnState: "ended", stopReason: "end_turn" }
    })
    const finalized = published.find(
      (event) =>
        (event.payload as { sessionUpdate?: string }).sessionUpdate ===
        "assistant_message_finalized"
    )
    expect(finalized?.payload).toMatchObject({ attachments: [{ fileId: file.id }] })
    expect(finalized?.payload).not.toHaveProperty("messageId")
  })

  it("does nothing for replies without attachment references", async () => {
    const { services } = await makeServices("server-b")
    const fanout = await run(makeEventFanout)
    const folder = mkdtempSync(join(tmpdir(), "codevisor-artifacts-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    await expect(
      promoteAssistantArtifacts(
        services as unknown as CodevisorServerServices,
        fanout,
        "server-b",
        session.id
      )
    ).resolves.toBe(false)
  })
})
