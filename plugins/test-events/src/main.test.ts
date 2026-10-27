import assert from "node:assert/strict"

import { serveStdio } from "@codevisor/plugin-kit"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js"
import { Server } from "@modelcontextprotocol/sdk/server/index.js"
import { expect, it, vi } from "vitest"

vi.mock("@codevisor/plugin-kit", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@codevisor/plugin-kit")>()),
  serveStdio: vi.fn()
}))

it("serves the test-events plugin on the process stdio", async () => {
  await import("./main.js")
  const [server, input, output] = vi.mocked(serveStdio).mock.calls[0] ?? []
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair()
  const client = new Client({ name: "test-host", version: "1.0.0" })
  assert(server instanceof Server)

  await server.connect(serverTransport)
  await client.connect(clientTransport)

  expect([input, output]).toEqual([process.stdin, process.stdout])
  expect(client.getServerVersion()?.name).toBe("test-events")
  await client.close()
})
