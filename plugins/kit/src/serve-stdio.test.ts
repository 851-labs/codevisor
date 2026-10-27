import { once } from "node:events"
import { PassThrough } from "node:stream"

import { Server } from "@modelcontextprotocol/sdk/server/index.js"
import { expect, it } from "vitest"
import { z } from "zod"

import { serveStdio } from "./serve-stdio.js"

const initialize = {
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "host", version: "1" }
  }
}

it("answers over stdio and closes the server when the host ends stdin", async () => {
  const input = new PassThrough()
  const output = new PassThrough()
  const server = new Server({ name: "stdio-test", version: "1.0.0" }, { capabilities: {} })
  output.setEncoding("utf8")
  await serveStdio(server, input, output)

  input.write(`${JSON.stringify(initialize)}\n`)
  const [line] = await once(output, "data")
  expect(server.transport).toBeDefined()
  input.end()
  await once(input, "end")

  expect(JSON.parse(z.string().parse(line))).toMatchObject({
    id: 1,
    result: { serverInfo: { name: "stdio-test" } }
  })
  expect(server.transport).toBeUndefined()
})
