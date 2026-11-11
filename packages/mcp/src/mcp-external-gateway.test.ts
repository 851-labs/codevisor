import { createServer } from "node:http"

import {
  Client,
  StreamableHTTPClientTransport,
  type CallToolResult
} from "@modelcontextprotocol/client"
import { afterEach, describe, expect, it, onTestFinished } from "vitest"

import { connectClient, studioGateway } from "./mcp-gateway-machines-test-support.js"
import { cleanupMcpManagerTests, listen, testManager } from "./mcp-manager-test-support.js"
import { serveGatewayOverStdio, type IssuedGateway } from "./mcp-stdio-bridge.js"
import { stdioPipes } from "./mcp-stdio-test-support.js"

afterEach(cleanupMcpManagerTests)

const whereAmI = {
  name: "execute",
  arguments: {
    description: "Where am I",
    code: "async () => context.current()"
  }
}

const resultText = (result: CallToolResult): string => {
  const block = result.content[0]
  if (block?.type !== "text") throw new Error("Expected a text result")
  return block.text
}

const executeResult = (result: CallToolResult): unknown => {
  const parsed: unknown = JSON.parse(resultText(result))
  if (typeof parsed !== "object" || parsed === null || !("result" in parsed)) {
    throw new Error(`Expected an execute result, got ${resultText(result)}`)
  }
  return parsed.result
}

const gatewayId = (issued: IssuedGateway): string =>
  new URL(issued.url).searchParams.get("gateway") ?? ""

const externalGatewayServer = async () => {
  const { manager } = await testManager()
  const forgotten = new Set<string>()
  const base = await listen(
    createServer((request, response) => {
      const id = new URL(request.url ?? "/", "http://gateway").searchParams.get("gateway")
      if (id !== null && forgotten.has(id)) {
        response.writeHead(404).end()
        return
      }
      void manager.handleGatewayRequest(request, response)
    })
  )
  manager.setBaseUrl(base)
  return { manager, forget: (issued: IssuedGateway) => forgotten.add(gatewayId(issued)) }
}

const bridgedClient = async (
  issueGateway: (name: string | undefined) => Promise<IssuedGateway>
) => {
  const pipes = stdioPipes()
  const bridge = serveGatewayOverStdio({ version: "1", issueGateway, ...pipes.bridge })
  const client = new Client({ name: "Grok", version: "1" })
  await client.connect(pipes.client)
  onTestFinished(() => bridge.close())
  return { bridge, client }
}

describe("MCP clients outside Codevisor", () => {
  it("get a gateway with no chat that closes when they disconnect", async () => {
    const { manager } = await externalGatewayServer()
    const issued = await manager.issueExternalGateway({ client: { name: "Grok" } })
    const transport = new StreamableHTTPClientTransport(new URL(issued.url), {
      requestInit: { headers: { authorization: `Bearer ${issued.bearerToken}` } }
    })
    const client = new Client({ name: "Grok", version: "1" })
    await client.connect(transport)

    const { tools } = await client.listTools()
    expect(tools.find((tool) => tool.name === "execute")?.description).toContain(
      "You reach Codevisor from Grok, outside Codevisor"
    )
    expect(executeResult(await client.callTool(whereAmI))).toEqual({
      externalClient: { name: "Grok" },
      machine: expect.anything()
    })

    await transport.terminateSession()
    await client.close()
    await expect(connectClient(issued)).rejects.toThrow("Codevisor tool gateway session not found")
  })

  it("reach it over stdio, which reconnects when the server forgets the gateway", async () => {
    const { manager, forget } = await externalGatewayServer()
    const issued: Array<{
      readonly clientName: string | undefined
      readonly gateway: IssuedGateway
    }> = []
    const { bridge, client } = await bridgedClient(async (clientName) => {
      const gateway = await manager.issueExternalGateway({ client: { name: clientName ?? "?" } })
      issued.push({ clientName, gateway })
      return gateway
    })

    expect(executeResult(await client.callTool(whereAmI))).toMatchObject({
      externalClient: { name: "Grok" }
    })
    forget(issued[0]!.gateway)
    expect(executeResult(await client.callTool(whereAmI))).toMatchObject({
      externalClient: { name: "Grok" }
    })
    expect(issued.map(({ clientName }) => clientName)).toEqual(["Grok", "Grok"])

    await bridge.close()
    await expect(connectClient(issued[1]!.gateway)).rejects.toThrow(
      "Codevisor tool gateway session not found"
    )
  })

  it("show their own name when they use Computer Use, with no chat to ask for permissions in", async () => {
    const { computerContexts, manager } = await studioGateway()
    const client = await connectClient(
      await manager.issueExternalGateway({ client: { name: "Grok" } })
    )
    onTestFinished(() => client.close())

    await client.callTool({
      name: "execute",
      arguments: {
        description: "List apps",
        code: "async () => machines.current.tools.computer.list_apps({})"
      }
    })

    expect(computerContexts.at(-1)).toMatchObject({ agentLabel: "Grok" })
    expect(computerContexts.at(-1)).not.toHaveProperty("requestPermissions")
  })

  it("see why a tool call couldn't reach Codevisor", async () => {
    const { client } = await bridgedClient(async () => {
      throw new Error("Codevisor isn't running on this machine")
    })

    const result = await client.callTool(whereAmI)

    expect(result.isError).toBe(true)
    expect(resultText(result)).toBe("Codevisor isn't running on this machine")
  })
})
