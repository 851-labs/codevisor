import type { Readable, Writable } from "node:stream"

import type { Server } from "@modelcontextprotocol/sdk/server/index.js"
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js"

export const serveStdio = async (
  server: Server,
  input: Readable,
  output: Writable
): Promise<void> => {
  input.once("end", () => void server.close())
  await server.connect(new StdioServerTransport(input, output))
}
