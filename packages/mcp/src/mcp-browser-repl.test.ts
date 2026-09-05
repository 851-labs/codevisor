import { afterEach, expect, it } from "vitest"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import { createServer } from "node:http"
import { mkdtemp, mkdir, writeFile, readFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { makeBrowserUseProvider } from "@codevisor/automation"
import { cleanupMcpManagerTests, listen, run, testManager } from "./mcp-manager-test-support.js"

afterEach(cleanupMcpManagerTests)
it("preserves browser cells and applies gateway upload validation and attachment persistence to nested operations", async () => {
  const root = await mkdtemp(join(tmpdir(), "browser-repl-gateway-"))
  const provider = makeBrowserUseProvider(root)
  const nested: string[] = []
  const { db, manager, directory } = await testManager(undefined, {
    makeBrowserProvider: () => ({
      ...provider,
      invoke: async (context, name, args) => {
        if (name === "content.export") {
          nested.push(name)
          return {
            content: [
              {
                type: "resource",
                resource: {
                  uri: "browser-export:fixture.md",
                  mimeType: "text/markdown",
                  blob: Buffer.from("Exported page").toString("base64")
                }
              }
            ]
          }
        }
        if (name === "upload_files") {
          nested.push(name)
          throw new Error("Upload validation was bypassed")
        }
        return provider.invoke(context, name, args)
      }
    })
  })
  await manager.setBrowserPreference("managed")
  await mkdir(join(directory, "workspace"))
  await writeFile(join(directory, "outside.txt"), "outside")
  const project = await run(db.createProject({ folderPath: join(directory, "workspace") }))
  const session = await run(db.createSession({ harnessId: "codex", projectId: project.id }))
  manager.setBaseUrl(await listen(createServer(manager.handleGatewayRequest)))
  const gateway = await manager.issueGateway(session.id, project.id)
  const client = new Client({ name: "browser-repl-test", version: "1" })
  await client.connect(
    new StreamableHTTPClientTransport(new URL(gateway.url), {
      requestInit: { headers: { authorization: `Bearer ${gateway.bearerToken}` } }
    }) as unknown as Transport
  )
  const execute = (code: string) =>
    client.callTool({
      name: "execute",
      arguments: { code: `async () => tools["browser.js"]({code: ${JSON.stringify(code)}})` }
    })
  try {
    expect((await execute("var retained = 41; retained")).isError).not.toBe(true)
    expect(JSON.stringify((await execute("retained + 1")).content)).toContain("42")
    const exported = await execute("await browser.content.export({format:'markdown'})")
    expect(exported.isError, JSON.stringify(exported)).not.toBe(true)
    const content = exported.content as Array<{ type: string; text?: string }>
    const output = JSON.parse(content.find((block) => block.type === "text")!.text!) as {
      result: { artifacts: Array<{ fileId: string; path: string }> }
    }
    const artifact = output.result.artifacts[0]!
    expect(await run(db.getFileMetadata(artifact.fileId))).toMatchObject({
      mimeType: "text/markdown"
    })
    expect(await readFile(artifact.path, "utf8")).toBe("Exported page")
    const rejected = await execute("await browser.upload_files({paths:['../outside.txt']})")
    expect(JSON.stringify(rejected)).toContain("workspace")
    expect(nested).toEqual(["content.export"])
    await manager.finishTurn(session.id)
  } finally {
    await client.close()
    await manager.close()
    await rm(root, { recursive: true, force: true })
  }
})
