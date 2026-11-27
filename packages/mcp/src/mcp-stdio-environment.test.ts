import { afterEach, describe, expect, it } from "vitest"

import { cleanupMcpManagerTests, testManager } from "./mcp-manager-test-support.js"

afterEach(cleanupMcpManagerTests)

const serverThatReportsWhereWindowsGo = `
const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n")
const answers = {
  initialize: (params) => ({
    protocolVersion: params.protocolVersion,
    capabilities: { tools: {} },
    serverInfo: { name: "display", version: "1" }
  }),
  "tools/list": () => ({
    tools: [{ name: "display", description: process.env.WINDOWS_GO_TO ?? "nowhere", inputSchema: { type: "object" } }]
  })
}
require("node:readline")
  .createInterface({ input: process.stdin })
  .on("line", (line) => {
    const message = JSON.parse(line)
    const answer = answers[message.method]
    if (answer !== undefined) reply(message.id, answer(message.params))
  })
`

const whereWindowsGoFor = async (
  launchEnvironment: (env: NodeJS.ProcessEnv) => NodeJS.ProcessEnv,
  configured?: Record<string, string>
): Promise<string | undefined> => {
  const { manager } = await testManager({ launchEnvironment })
  const server = await manager.create({
    name: "Display",
    transport: "stdio",
    command: process.execPath,
    args: ["-e", serverThatReportsWhereWindowsGo],
    ...(configured === undefined ? {} : { env: configured })
  })
  await manager.connect(server.id)
  return (await manager.tools(server.id))[0]?.description
}

const addADisplay = (env: NodeJS.ProcessEnv): NodeJS.ProcessEnv =>
  env.WINDOWS_GO_TO === undefined ? { ...env, WINDOWS_GO_TO: ":1" } : env

describe("the environment a stdio MCP server is started with", () => {
  it("has the launch environment applied", async () => {
    expect(await whereWindowsGoFor(addADisplay)).toBe(":1")
  })

  it("lets the launch environment see what the server's own configuration sets", async () => {
    expect(await whereWindowsGoFor(addADisplay, { WINDOWS_GO_TO: ":9" })).toBe(":9")
  })
})
