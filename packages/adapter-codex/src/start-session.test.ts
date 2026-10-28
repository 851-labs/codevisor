import type { ToolGatewayConfig } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"

import { makeCodexProvider } from "./provider.js"
import { definition, environment, FakeCodexClient, recordOf, run, setup } from "./test-support.js"

const expectedNativeCodexSkills = {
  bundled: { enabled: false },
  config: [
    { name: "browser:control-in-app-browser", enabled: false },
    { name: "chrome:control-chrome", enabled: false },
    { name: "computer-use:computer-use", enabled: false },
    { name: "documents:documents", enabled: false },
    { name: "pdf:pdf", enabled: false },
    { name: "presentations:Presentations", enabled: false },
    { name: "sites:sites-building", enabled: false },
    { name: "sites:sites-hosting", enabled: false },
    { name: "spreadsheets:Spreadsheets", enabled: false },
    { name: "spreadsheets:excel-live-control", enabled: false },
    { name: "template-creator:template-creator", enabled: false },
    { name: "visualize:visualize", enabled: false }
  ]
}

describe("CodexProvider", () => {
  it("routes tools through Codevisor and disables native Codex skills and automation", async () => {
    const toolGateway: ToolGatewayConfig = {
      name: "codevisor",
      url: "http://127.0.0.1:49361/mcp/gateway?gateway=test",
      bearerToken: "secret"
    }
    const expectedConfig = {
      plugins: {
        "unified-computer-use@openai-bundled": { enabled: false }
      },
      skills: expectedNativeCodexSkills,
      "features.browser_use": false,
      "features.browser_use_external": false,
      "features.browser_use_full_cdp_access": false,
      "features.computer_use": false,
      "features.in_app_browser": false,
      "agents.enabled": false,
      "features.multi_agent": false,
      "features.multi_agent_v2": false,
      mcp_servers: {
        node_repl: {
          enabled: false
        },
        "computer-use": {
          enabled: false
        },
        cua_repl: {
          enabled: false
        },
        codevisor: {
          default_tools_approval_mode: "approve"
        }
      }
    }

    const { client } = await setup({ toolGateway })
    const start = client.requests.find((request) => request.method === "thread/start")
    expect(start?.params).toMatchObject({
      config: expectedConfig
    })

    const { client: resumedClient } = await setup({
      resume: "thread-existing",
      toolGateway
    })
    const resume = resumedClient.requests.find((request) => request.method === "thread/resume")
    expect(resume?.params).toMatchObject({
      config: expectedConfig
    })
  })

  it("disables native Codex skills, subagents, and the unified computer use plugin without a tool gateway", async () => {
    const { client } = await setup()
    const start = client.requests.find((request) => request.method === "thread/start")
    const config = recordOf(recordOf(start?.params).config)
    expect(config).toMatchObject({
      plugins: {
        "unified-computer-use@openai-bundled": { enabled: false }
      },
      skills: expectedNativeCodexSkills,
      "agents.enabled": false,
      "features.multi_agent": false,
      "features.multi_agent_v2": false
    })
    expect(config).not.toHaveProperty("mcp_servers")
  })

  it("launches bots' Codex app-server with goals turned off, on new and resumed threads", async () => {
    const { spawns } = await setup({ bot: true })
    const { spawns: resumedSpawns } = await setup({ bot: true, resume: "thread-existing" })
    const { spawns: chatSpawns } = await setup()

    expect(spawns[0]?.disabledFeatures).toEqual(["goals"])
    expect(resumedSpawns[0]?.disabledFeatures).toEqual(["goals"])
    expect(chatSpawns[0]?.disabledFeatures).toEqual([])
  })

  it("omits native automation disables when the codex config does not define those servers", async () => {
    const toolGateway: ToolGatewayConfig = {
      name: "codevisor",
      url: "http://127.0.0.1:49361/mcp/gateway?gateway=test",
      bearerToken: "secret"
    }
    const { client } = await setup({ toolGateway, codexConfigToml: null })
    const start = client.requests.find((request) => request.method === "thread/start")
    expect(recordOf(recordOf(start?.params).config).mcp_servers).toEqual({
      codevisor: {
        url: toolGateway.url,
        bearer_token_env_var: "CODEVISOR_MCP_GATEWAY_TOKEN",
        default_tools_approval_mode: "approve",
        tool_timeout_sec: 660
      }
    })
  })

  it.each(["node_repl", "computer-use", "cua_repl"])(
    "disables only %s when it is the sole configured native automation server",
    async (serverName) => {
      const toolGateway: ToolGatewayConfig = {
        name: "codevisor",
        url: "http://127.0.0.1:49361/mcp/gateway?gateway=test",
        bearerToken: "secret"
      }
      const { client } = await setup({
        toolGateway,
        codexConfigToml: `[mcp_servers."${serverName}"]\ncommand = "native-automation"\n`
      })
      const start = client.requests.find((request) => request.method === "thread/start")
      const servers = recordOf(recordOf(recordOf(start?.params).config).mcp_servers)
      expect(Object.keys(servers).toSorted()).toEqual(["codevisor", serverName].toSorted())
      expect(servers[serverName]).toEqual({ enabled: false })
    }
  )

  it("reads mcp server names from the CODEX_HOME config.toml when set", async () => {
    const toolGateway: ToolGatewayConfig = {
      name: "codevisor",
      url: "http://127.0.0.1:49361/mcp/gateway?gateway=test",
      bearerToken: "secret"
    }
    const reads: Array<string> = []
    const client = new FakeCodexClient()
    client.startModel = "gpt-5.2-codex"
    const provider = makeCodexProvider(
      { ...environment, env: { ...environment.env, CODEX_HOME: "/custom/codex-home" } },
      {
        connector: async () => client,
        configFileReader: (path) => {
          reads.push(path)
          return undefined
        }
      }
    )
    await run(
      provider.createSession(definition, "/tmp/project", async () => {}, undefined, toolGateway)
    )
    expect(reads).toEqual(["/custom/codex-home/config.toml"])
  })

  it("keeps the requested id and surfaces resume failures without creating a new thread", async () => {
    const { client, loaded } = await setup({ resume: "old-thread" })
    expect(loaded?.sessionId).toBe("old-thread")
    expect(loaded?.metadata?.sessionId).toBe("old-thread")
    expect(
      loaded?.metadata?.configOptions.find((option) => option.id === "model")?.options
    ).toEqual(expect.arrayContaining([expect.objectContaining({ value: "gpt-5.5" })]))
    expect(client.requests.map((request) => request.method)).toContain("thread/resume")

    await expect(setup({ failResume: true, resume: "not-a-thread" })).rejects.toThrow()
  })

  it("cancels the pending prompt and reports the error when the app-server exits", async () => {
    const { client, created, events } = await setup()
    const turnRequested = client.nextRequest("turn/start")
    const prompt = run(created!.handle.prompt("hello"))
    await turnRequested
    client.exit(new Error("codex app-server exited with code 1"))
    await expect(prompt).resolves.toMatchObject({ stopReason: "cancelled" })
    expect(events.at(-1)).toEqual({
      kind: "session.error",
      payload: { message: "codex app-server exited with code 1" },
      subjectId: "thread-new"
    })
  })
})
