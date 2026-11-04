import type { Readable, Writable } from "node:stream"

import type { Server } from "@modelcontextprotocol/server"
import { StdioServerTransport } from "@modelcontextprotocol/server/stdio"

export const serveStdio = async (
  server: Server,
  input: Readable,
  output: Writable
): Promise<void> => {
  input.once("end", () => void server.close())
  await server.connect(new StdioServerTransport(input, output))
}
