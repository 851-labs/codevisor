import { mkdtemp } from "node:fs/promises"
import { createServer } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { makeBrowserUseProvider } from "@codevisor/automation"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import { afterEach, expect, it } from "vitest"

import { isRecord } from "./mcp-guards.js"
import {
  cleanupMcpManagerTests,
  directories,
  executeResultValue,
  listen,
  run,
  testManager
} from "./mcp-manager-test-support.js"
import { sdkTransport } from "./mcp-support.js"

afterEach(cleanupMcpManagerTests)

it("blocks the model's install request on the composer card and returns the user's answer", async () => {
  const root = await mkdtemp(join(tmpdir(), "gateway-install-prompt-"))
  directories.push(root)
  const provider = makeBrowserUseProvider(root, "http://127.0.0.1:43210")
  const { db, manager } = await testManager({
    makeBrowserProvider: () => ({
      ...provider,
      status: () => ({
        ...provider.status(),
        chromeAvailable: true,
        extensionConnected: false,
        extensionNeedsUpdate: false,
        extensionSetupMode: "development"
      })
    })
  })
  manager.setBaseUrl(await listen(createServer(manager.handleGatewayRequest)))
  const project = await run(db.createProject({ folderPath: "/tmp/mcp-install-prompt" }))
  const session = await run(db.createSession({ harnessId: "codex", projectId: project.id }))
  const { promise: asked, resolve } = Promise.withResolvers<Record<string, unknown>>()
  const issued = await manager.issueGateway(session.id, project.id, (event: RuntimeEvent) => {
    if (isRecord(event.payload) && event.payload.sessionUpdate === "question")
      resolve(event.payload)
  })
  const client = new Client({ name: "install-prompt-test", version: "1" })
  await client.connect(
    sdkTransport(
      new StreamableHTTPClientTransport(new URL(issued.url), {
        requestInit: { headers: { authorization: `Bearer ${issued.bearerToken}` } }
      })
    )
  )
  try {
    const executed = client.callTool({
      name: "execute",
      arguments: {
        description: "Ask to add the Chrome extension",
        timeout_ms: 600_000,
        code: `async () => machines.current.tools.browser.request_extension_install()`
      }
    })
    const question = await asked
    expect(question.questions).toMatchObject([
      { header: "Connect Chrome", presentation: "browserExtensionSetup" }
    ])
    expect(
      await manager.answerQuestion(session.id, String(question.questionId), {
        outcome: "cancelled"
      })
    ).toBe(true)
    expect(executeResultValue(await executed)).toEqual({ outcome: "dismissed" })
  } finally {
    await client.close()
    await provider.close()
  }
})

it("asks for an extension update before using an outdated Chrome extension", async () => {
  const root = await mkdtemp(join(tmpdir(), "gateway-extension-update-"))
  directories.push(root)
  const provider = makeBrowserUseProvider(root, "http://127.0.0.1:43210")
  const { db, manager } = await testManager({
    makeBrowserProvider: () => ({
      ...provider,
      status: () => ({ ...provider.status(), chromeAvailable: true, extensionNeedsUpdate: true })
    })
  })
  manager.setBaseUrl(await listen(createServer(manager.handleGatewayRequest)))
  const project = await run(db.createProject({ folderPath: "/tmp/mcp-extension-update" }))
  const session = await run(db.createSession({ harnessId: "codex", projectId: project.id }))
  const { promise: asked, resolve } = Promise.withResolvers<Record<string, unknown>>()
  const issued = await manager.issueGateway(session.id, project.id, (event: RuntimeEvent) => {
    if (isRecord(event.payload) && event.payload.sessionUpdate === "question")
      resolve(event.payload)
  })
  const client = new Client({ name: "extension-update-test", version: "1" })
  await client.connect(
    sdkTransport(
      new StreamableHTTPClientTransport(new URL(issued.url), {
        requestInit: { headers: { authorization: `Bearer ${issued.bearerToken}` } }
      })
    )
  )
  try {
    const executed = client.callTool({
      name: "execute",
      arguments: {
        description: "Use the user's Chrome",
        timeout_ms: 600_000,
        code: `async () => machines.current.tools.browser.use_backend({ backend: "extension" })`
      }
    })
    const question = await asked
    expect(question.questions).toMatchObject([
      { header: "Update Chrome Extension", presentation: "browserExtensionUpdate" }
    ])

    await manager.answerQuestion(session.id, String(question.questionId), { outcome: "cancelled" })

    expect(JSON.stringify((await executed).content)).toContain(
      "The user chose not to update the Codevisor Chrome extension"
    )
  } finally {
    await client.close()
    await provider.close()
  }
})
