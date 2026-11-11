import { createInterface } from "node:readline"
import { PassThrough } from "node:stream"

import { describe, expect, it } from "vitest"

import { mcpCommand } from "./mcp.js"
import { makeWorld, type FakeOptions } from "./support-test-support.js"

const port = 49555
const openGateway = `POST http://127.0.0.1:${port}/v1/mcp-gateways`

const handshake = [
  {
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2025-11-25",
      capabilities: {},
      clientInfo: { name: "Grok", version: "1" }
    }
  },
  { jsonrpc: "2.0", method: "notifications/initialized" }
]

const toolCall = {
  jsonrpc: "2.0",
  id: 2,
  method: "tools/call",
  params: { name: "execute", arguments: { description: "Where am I", code: "async () => 1" } }
}

const answerToToolCall = async (http: NonNullable<FakeOptions["http"]>): Promise<unknown> => {
  const input = new PassThrough()
  const output = new PassThrough()
  const disconnected = Promise.withResolvers<void>()
  const command = mcpCommand(
    makeWorld({ http }).deps,
    { input, output, disconnected: disconnected.promise },
    { port }
  )
  for (const message of [...handshake, toolCall]) input.write(`${JSON.stringify(message)}\n`)

  for await (const line of createInterface({ input: output })) {
    const message: unknown = JSON.parse(line)
    if (typeof message !== "object" || message === null || !("id" in message)) continue
    if (message.id !== toolCall.id) continue
    disconnected.resolve()
    expect(await command).toBe(0)
    return message
  }
  throw new Error("codevisor mcp closed without answering the tool call")
}

describe("codevisor mcp", () => {
  it("answers a tool call over stdio with why Codevisor couldn't be reached", async () => {
    const notRunning = await answerToToolCall({ [openGateway]: [undefined] })
    const refused = await answerToToolCall({
      [openGateway]: [{ status: 404, body: { error: "No project named gadget. Projects: Widget" } }]
    })

    expect(notRunning).toMatchObject({
      result: {
        isError: true,
        content: [
          {
            text: "Codevisor isn't running on this machine (nothing answered on port 49555). Open the Codevisor app or run codevisor start, then try again."
          }
        ]
      }
    })
    expect(refused).toMatchObject({
      result: {
        isError: true,
        content: [
          {
            text: "Codevisor couldn't open a connection: No project named gadget. Projects: Widget"
          }
        ]
      }
    })
  })
})
