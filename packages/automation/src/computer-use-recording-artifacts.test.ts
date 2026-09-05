import { describe, expect, it, vi } from "vitest"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { makeRecordingArtifacts } from "./computer-use-recording-artifacts.js"

const reply = (value: unknown): CallToolResult => ({
  content: [{ type: "text", text: JSON.stringify(value) }]
})
const value = (result: CallToolResult) => JSON.parse((result.content[0] as { text: string }).text)
const stopped = {
  recordingId: "r",
  status: "stopped",
  file: { path: "/recordings/fix.mp4", name: "fix.mp4", mimeType: "video/mp4" }
}
const attachment = {
  fileId: "f",
  path: "/attachments/fix (demo).mp4",
  sizeBytes: 123
}

describe("recording artifacts", () => {
  it("publishes only finalized files, returns embed Markdown and deduplicates repeated status/stop calls", async () => {
    const publisher = makeRecordingArtifacts()
    const publishRecording = vi.fn(async () => attachment)
    const context = { sessionId: "a", publishRecording }
    expect(value(await publisher.enrich(reply({ status: "recording" }), context))).toEqual({
      status: "recording"
    })
    expect(publishRecording).not.toHaveBeenCalled()
    const first = value(await publisher.enrich(reply(stopped), context))
    expect(first.file).toEqual({ ...stopped.file, ...attachment })
    expect(first.markdown).toBe("![Recording of the fix](</attachments/fix (demo).mp4>)")
    expect(publishRecording).toHaveBeenCalledWith({ path: stopped.file.path, name: "fix.mp4" })
    const list = value(await publisher.enrich(reply({ recordings: [stopped] }), context))
    expect(list.recordings[0]).toEqual(first)
    expect(publishRecording).toHaveBeenCalledTimes(1)
    await publisher.enrich(reply(stopped), { ...context, sessionId: "b" })
    publisher.closeSession("a")
    await publisher.enrich(reply(stopped), context)
    expect(publishRecording).toHaveBeenCalledTimes(3)
    publisher.clear()
    await publisher.enrich(reply(stopped), context)
    expect(publishRecording).toHaveBeenCalledTimes(4)
  })

  it("preserves local files on publication failure and retries without repeating native recording", async () => {
    const publisher = makeRecordingArtifacts()
    const publishRecording = vi
      .fn()
      .mockRejectedValueOnce(new Error("disk full"))
      .mockResolvedValue(attachment)
    const context = { sessionId: "a", publishRecording }
    const failed = value(await publisher.enrich(reply(stopped), context))
    expect(failed.file).toEqual(stopped.file)
    expect(failed.attachmentError).toContain("disk full")
    expect(value(await publisher.enrich(reply(stopped), context)).file.path).toBe(attachment.path)
  })

  it("keeps native errors, standalone files and nontext content intact", async () => {
    const publisher = makeRecordingArtifacts()
    const result = reply(stopped)
    expect(await publisher.enrich(result, { sessionId: "a" })).toBe(result)
    const publishRecording = vi.fn(async () => attachment)
    const error = { ...result, isError: true }
    expect(await publisher.enrich(error, { sessionId: "a", publishRecording })).toBe(error)
    const image: CallToolResult = {
      content: [{ type: "image", data: "AA==", mimeType: "image/png" }]
    }
    expect(await publisher.enrich(image, { sessionId: "a", publishRecording })).toEqual(image)
    for (const file of [undefined, { path: 1 }, { path: "p", name: 1 }])
      expect(
        value(
          await publisher.enrich(reply({ status: "stopped", file }), {
            sessionId: "a",
            publishRecording
          })
        ).file
      ).toEqual(file)
    expect(publishRecording).not.toHaveBeenCalled()
  })
})
