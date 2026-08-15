import { describe, expect, it } from "vitest"
import type { ToolGatewayConfig } from "@codevisor/agent-runtime"
import { makeCodexProvider } from "./provider.js"
import { definition, environment, FakeCodexClient, run, setup } from "./test-support.js"

describe("CodexProvider", () => {
  it("routes automation through Codevisor and disables native Codex automation", async () => {
    const toolGateway: ToolGatewayConfig = {
      name: "codevisor",
      url: "http://127.0.0.1:49361/mcp/gateway?gateway=test",
      bearerToken: "secret"
    }
    const expectedConfig = {
      skills: {
        config: [
          { name: "computer-use:computer-use", enabled: false },
          { name: "browser:control-in-app-browser", enabled: false },
          { name: "chrome:control-chrome", enabled: false }
        ]
      },
      features: {
        browser_use: false,
        browser_use_external: false,
        browser_use_full_cdp_access: false,
        computer_use: false,
        in_app_browser: false
      },
      mcp_servers: {
        node_repl: {
          enabled: false
        },
        "computer-use": {
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

  it("omits native automation disables when the codex config does not define those servers", async () => {
    // A machine without the Codex desktop app (typical headless remote) has
    // no node_repl/computer-use entries in config.toml. Sending bare
    // `{ enabled: false }` stubs there creates transport-less servers that
    // the app-server rejects at config load with "invalid transport".
    const toolGateway: ToolGatewayConfig = {
      name: "codevisor",
      url: "http://127.0.0.1:49361/mcp/gateway?gateway=test",
      bearerToken: "secret"
    }
    const { client } = await setup({ toolGateway, codexConfigToml: null })
    const start = client.requests.find((request) => request.method === "thread/start")
    const config = start?.params as { config: { mcp_servers: Record<string, unknown> } }
    expect(config.config.mcp_servers).toEqual({
      codevisor: {
        url: toolGateway.url,
        bearer_token_env_var: "CODEVISOR_MCP_GATEWAY_TOKEN",
        default_tools_approval_mode: "approve"
      }
    })
  })

  it("disables only the native automation servers the codex config defines", async () => {
    const toolGateway: ToolGatewayConfig = {
      name: "codevisor",
      url: "http://127.0.0.1:49361/mcp/gateway?gateway=test",
      bearerToken: "secret"
    }
    const { client } = await setup({
      toolGateway,
      codexConfigToml: '[mcp_servers.node_repl]\ncommand = "node_repl"\n'
    })
    const start = client.requests.find((request) => request.method === "thread/start")
    const config = start?.params as { config: { mcp_servers: Record<string, unknown> } }
    expect(Object.keys(config.config.mcp_servers).sort()).toEqual(["codevisor", "node_repl"])
    expect(config.config.mcp_servers.node_repl).toEqual({ enabled: false })
  })

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

  it("keeps the requested id when resuming, with thread/start fallback", async () => {
    const { client, loaded } = await setup({ resume: "old-thread" })
    expect(loaded?.sessionId).toBe("old-thread")
    expect(loaded?.metadata?.sessionId).toBe("old-thread")
    expect(
      loaded?.metadata?.configOptions.find((option) => option.id === "model")?.options
    ).toEqual(expect.arrayContaining([expect.objectContaining({ value: "gpt-5.5" })]))
    expect(client.requests.map((request) => request.method)).toContain("thread/resume")

    const fallback = await setup({ failResume: true, resume: "not-a-thread" })
    expect(fallback.loaded?.sessionId).toBe("not-a-thread")
    expect(fallback.client.requests.map((request) => request.method)).toContain("thread/start")
  })
})
