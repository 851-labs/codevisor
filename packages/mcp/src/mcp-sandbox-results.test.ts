import { describe, expect, it } from "vitest"
import {
  sandboxSuccessfulToolResult,
  type SandboxArtifactCollector
} from "./mcp-sandbox-results.js"

const png = Buffer.from("fake-png-bytes").toString("base64")

const screenshotResult = () => ({
  content: [
    { type: "text" as const, text: JSON.stringify({ value: "Page URL: https://example.com/" }) },
    { type: "image" as const, data: png, mimeType: "image/png" }
  ]
})

describe("sandboxSuccessfulToolResult", () => {
  it("persists emitted artifacts and hands the sandbox a local file path", async () => {
    const persisted: Array<{ mimeType: string; toolPath: string; bytes: number }> = []
    const collector: SandboxArtifactCollector = {
      content: [],
      maxItems: 4,
      maxBytes: 1024,
      persistence: {
        persist: async ({ data, mimeType, toolPath }) => {
          persisted.push({ mimeType, toolPath, bytes: data.byteLength })
          return {
            fileId: "file-1",
            path: "/files/browser-screenshot.png",
            name: "browser-screenshot.png",
            mimeType,
            sizeBytes: data.byteLength,
            kind: "image"
          }
        }
      }
    }
    const result = await sandboxSuccessfulToolResult(
      screenshotResult(),
      collector,
      "browser.screenshot"
    )
    expect(persisted).toEqual([
      { mimeType: "image/png", toolPath: "browser.screenshot", bytes: "fake-png-bytes".length }
    ])
    expect(result).toEqual({
      value: "Page URL: https://example.com/",
      artifacts: [
        {
          type: "artifact_ref",
          artifactId: "file-1",
          fileId: "file-1",
          path: "/files/browser-screenshot.png",
          name: "browser-screenshot.png",
          mediaType: "image/png",
          sizeBytes: "fake-png-bytes".length,
          emitted: true
        }
      ]
    })
    // The bytes still reach the model as content.
    expect(collector.content).toEqual([{ type: "image", data: png, mimeType: "image/png" }])
  })

  it("falls back to an in-memory reference when persistence is unavailable or fails", async () => {
    for (const collector of [
      { content: [], maxItems: 4, maxBytes: 1024 },
      {
        content: [],
        maxItems: 4,
        maxBytes: 1024,
        persistence: {
          persist: async () => {
            throw new Error("disk full")
          }
        }
      }
    ] satisfies ReadonlyArray<SandboxArtifactCollector>) {
      const result = (await sandboxSuccessfulToolResult(screenshotResult(), collector)) as {
        artifacts: Array<Record<string, unknown>>
        showToUser?: string
      }
      expect(result.artifacts).toEqual([
        expect.objectContaining({ type: "artifact_ref", mediaType: "image/png", emitted: true })
      ])
      expect(result.artifacts[0]).not.toHaveProperty("path")
      expect(result.showToUser).toBeUndefined()
      expect(collector.content).toHaveLength(1)
    }
  })

  it("leaves text-only results untouched and rejects failed tool results", async () => {
    const collector: SandboxArtifactCollector = { content: [], maxItems: 4, maxBytes: 1024 }
    await expect(
      sandboxSuccessfulToolResult({ content: [{ type: "text", text: '{"ok":true}' }] }, collector)
    ).resolves.toEqual({ ok: true })
    await expect(
      sandboxSuccessfulToolResult(
        { isError: true, content: [{ type: "text", text: "boom" }] },
        collector
      )
    ).rejects.toThrow("boom")
  })
})
