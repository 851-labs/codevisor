import { writeFileSync } from "node:fs"

import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client"

const token = process.env.LINEAR_ACCESS_TOKEN
if (token === undefined || token === "") {
  console.error("Set LINEAR_ACCESS_TOKEN to a Linear OAuth token or API key.")
  process.exit(1)
}

const client = new Client({ name: "codevisor-linear-snapshot", version: "1.0.0" })
await client.connect(
  new StreamableHTTPClientTransport(new URL("https://mcp.linear.app/mcp"), {
    requestInit: { headers: { Authorization: `Bearer ${token}` } }
  })
)
const { tools } = await client.listTools()
await client.close()

const snapshot = tools.map(({ name, title, description, inputSchema, annotations }) => ({
  name,
  title,
  description,
  inputSchema,
  annotations
}))
writeFileSync(
  new URL("../src/linear-mcp-tools.json", import.meta.url),
  `${JSON.stringify(snapshot, null, 2)}\n`
)
console.log(`Saved ${snapshot.length} Linear MCP tools. Update server.json's tool digest to match.`)
