import { afterEach, describe, expect, it } from "vitest"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import { createServer } from "node:http"
import { computerUseTools, textToolResult } from "@codevisor/automation"
import { cleanupMcpManagerTests, listen, run, testManager } from "./mcp-manager-test-support.js"
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import type { FileMetadata } from "@codevisor/api"
import { makeAttachmentStore } from "@codevisor/db"
import { makeRecordingPublisher } from "./mcp-recording-artifacts.js"

afterEach(cleanupMcpManagerTests)

describe("recording attachment persistence", () => {
  it("provides the native provider a publisher and returns an embeddable local video through MCP execute", async () => {
    let path = ""
    const { db, manager, directory } = await testManager(undefined, {
      makeComputerProvider: () => ({
        id: "computer",
        tools: computerUseTools,
        status: () => ({ available: true }),
        ensureSetup: async () => {},
        close: async () => {},
        closeSession: async () => {},
        invoke: async (context) => {
          const file = await context.publishRecording!({ path, name: "fix.mp4" })
          return textToolResult(
            JSON.stringify({ status: "stopped", file, markdown: `![Fix](<${file.path}>)` })
          )
        }
      })
    })
    await mkdir(join(directory, "computer-use-recordings"))
    path = join(directory, "computer-use-recordings", "fix.mp4")
    await writeFile(path, "native video fixture")
    manager.setBaseUrl(await listen(createServer(manager.handleGatewayRequest)))
    const project = await run(db.createProject({ folderPath: directory }))
    const session = await run(
      db.createSession({ harnessId: "codex", title: "Recording test", projectId: project.id })
    )
    const issued = await manager.issueGateway(session.id)
    const client = new Client({ name: "recording-test", version: "1" })
    await client.connect(
      new StreamableHTTPClientTransport(new URL(issued.url), {
        requestInit: { headers: { authorization: `Bearer ${issued.bearerToken}` } }
      }) as unknown as Transport
    )
    try {
      const result = await client.callTool({
        name: "execute",
        arguments: { code: 'async () => tools["computer.stop_recording"]({recording_id:"r"})' }
      })
      expect(result.isError).not.toBe(true)
      const rendered = JSON.stringify(result.content)
      const content = result.content as Array<{ type: string; text?: string }>
      const output = JSON.parse(content.find((block) => block.type === "text")!.text!) as {
        result: { file: { fileId: string; path: string }; markdown: string }
      }
      expect(await readFile(output.result.file.path, "utf8")).toBe("native video fixture")
      expect(output.result.markdown).toBe(`![Fix](<${output.result.file.path}>)`)
      expect(await run(db.getFileMetadata(output.result.file.fileId))).toMatchObject({
        name: "fix.mp4",
        mimeType: "video/mp4",
        kind: "file"
      })
      expect(rendered).not.toContain(Buffer.from("native video fixture").toString("base64"))
    } finally {
      await client.close()
    }
  })

  it("streams a native MP4 into durable storage and returns a materialized file", async () => {
    const root = await mkdtemp(join(tmpdir(), "codevisor-recording-"))
    try {
      const directory = join(root, "computer-use-recordings")
      await mkdir(directory)
      const path = join(directory, "fix.mp4")
      const bytes = Buffer.from("recorded video fixture")
      await writeFile(path, bytes)
      let metadata: FileMetadata | undefined
      const publish = makeRecordingPublisher(root, async (file) => {
        metadata = file
      })
      const artifact = await publish({ path, name: "fix.mp4" })
      expect(metadata).toMatchObject({
        id: artifact.fileId,
        name: "fix.mp4",
        mimeType: "video/mp4",
        kind: "file",
        sizeBytes: bytes.length
      })
      expect(await readFile(artifact.path)).toEqual(bytes)
      expect(await makeAttachmentStore(root).read(metadata!)).toEqual(bytes)
      expect(await readFile(path)).toEqual(bytes)
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it("rejects unrelated paths, symlink escapes, empty files and directories", async () => {
    const root = await mkdtemp(join(tmpdir(), "codevisor-recording-"))
    try {
      const directory = join(root, "computer-use-recordings")
      await mkdir(directory)
      const outside = join(root, "private.mp4")
      await writeFile(outside, "private")
      const escape = join(directory, "escape.mp4")
      await symlink(outside, escape)
      const empty = join(directory, "empty.mp4")
      await writeFile(empty, "")
      const other = join(directory, "notes.txt")
      await writeFile(other, "notes")
      const folder = join(directory, "folder.mp4")
      await mkdir(folder)
      const publish = makeRecordingPublisher(root, async () => {
        throw new Error("must not persist")
      })
      for (const path of [outside, escape, empty, other, folder])
        await expect(publish({ path, name: "fix.mp4" })).rejects.toThrow(
          "Only completed Computer Use MP4"
        )
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })
})
