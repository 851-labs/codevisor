import { afterEach, describe, expect, it } from "vitest"

import { cleanupMcpManagerTests, executeResultValue, run } from "./mcp-manager-test-support.js"
import type { PluginAccountSource } from "./mcp-plugin-accounts.js"
import { pluginSkillLabel } from "./mcp-plugin-skills.js"
import {
  closeFakePlugins,
  pluginGatewaySession,
  skillFixture,
  type FakePluginOptions,
  type FakeRequest,
  type SkillFixtureEntry
} from "./mcp-plugin-test-support.js"

afterEach(async () => {
  await closeFakePlugins()
  await cleanupMcpManagerTests()
})

const triageDocument =
  "---\nname: alert-triage\ndescription: Triage firing alerts\n---\n\n# Triage\n\nRead references/checklist.md.\n"

const triage = skillFixture("alert-triage", "Triage firing alerts", {
  "SKILL.md": { text: triageDocument, mimeType: "text/markdown" },
  "references/checklist.md": { text: "# Checklist\n" },
  "assets/logo.png": { blob: Buffer.from("png-bytes").toString("base64"), mimeType: "image/png" },
  "assets/data.bin": { blob: Buffer.from("raw").toString("base64") }
})

const plainDocument = "---\nname: plain\n---\nJust do it.\n"
const plain = skillFixture("plain", undefined, { "SKILL.md": { text: plainDocument } })

const staleDocument = "---\nname: stale\ndescription: Was edited\n---\nFresh body.\n"
const stale = skillFixture("stale", "Was edited", { "SKILL.md": { text: staleDocument } })

const drifted = skillFixture("drifted", "Says one thing", {
  "SKILL.md": { text: "---\nname: drifted\ndescription: Says another\n---\nBody.\n" }
})

const shrunk = skillFixture("shrunk", "Lost a file", {
  "SKILL.md": { text: "---\nname: shrunk\ndescription: Lost a file\n---\nBody.\n" },
  "notes.md": { text: "Old notes" }
})

const shrunkListing = {
  ...shrunk.entry,
  resources: shrunk.entry.resources.map((file) =>
    file.uri.endsWith("notes.md") ? { ...file, size: 1 } : file
  )
}

const shrunkFresh = {
  ...shrunk.entry,
  resources: shrunk.entry.resources.filter((file) => !file.uri.endsWith("notes.md"))
}

const outdatedManifest = (entry: SkillFixtureEntry): SkillFixtureEntry => ({
  ...entry,
  resources: [{ uri: entry.uri, digest: "sha256:0", size: 1 }]
})

const skillsPlugin: FakePluginOptions = {
  skills: [
    triage.entry,
    plain.entry,
    outdatedManifest(stale.entry),
    drifted.entry,
    shrunkListing,
    { uri: "skill://live/SKILL.md", frontmatter: { name: "live" }, resources: "dynamic" },
    { uri: "skill://unnamed/SKILL.md", frontmatter: {}, resources: [] },
    { ...triage.entry, uri: "skill://copy/alert-triage/SKILL.md" }
  ],
  freshSkills: {
    [stale.entry.uri]: stale.entry,
    [shrunk.entry.uri]: shrunkFresh
  },
  resources: {
    ...triage.resources,
    ...plain.resources,
    ...stale.resources,
    ...drifted.resources,
    ...shrunk.resources
  }
}

const accountSource = (labels: ReadonlyArray<string>): PluginAccountSource => ({
  list: async () => labels.map((label) => ({ id: `id-${label}`, label })),
  meta: async (_serverId, accountId) => ({ id: accountId })
})

const resourceReads = (requests: ReadonlyArray<FakeRequest>) =>
  requests.filter((request) => request.method === "resources/read")

describe("plugin skills in the gateway", () => {
  it("lists plugin skills by plugin label without reading their files", async () => {
    const { call, client, manager, plugin, project, session } =
      await pluginGatewaySession(skillsPlugin)

    const listed = await call("skills", {})
    const { tools } = await client.listTools()

    expect(listed.text).toContain("- grafana:alert-triage — Triage firing alerts")
    expect(listed.text).toContain("- grafana:plain — plain")
    expect(listed.text).not.toContain("grafana:live")
    expect(tools.find((tool) => tool.name === "skills")?.description).toContain(
      "grafana:alert-triage"
    )
    expect(await manager.composerSkills(project.id, session.id)).toEqual(
      expect.arrayContaining([
        { builtin: false, name: "grafana:alert-triage", description: "Triage firing alerts" },
        { builtin: false, name: "grafana:plain" }
      ])
    )
    expect(resourceReads(plugin.requests)).toEqual([])
    await client.close()
  })

  it("reads SKILL.md on demand and then its supporting files", async () => {
    const { call, client, plugin } = await pluginGatewaySession(skillsPlugin)

    const instructions = await call("skills", { name: "grafana:alert-triage" })
    const checklist = await call("skills", {
      name: "grafana:alert-triage",
      file: "references/checklist.md"
    })
    const logo = await call("skills", { name: "grafana:alert-triage", file: "assets/logo.png" })
    const data = await call("skills", { name: "grafana:alert-triage", file: "assets/data.bin" })
    const missing = await call("skills", { name: "grafana:alert-triage", file: "secrets.txt" })
    const bare = await call("skills", { name: "grafana:plain" })

    expect(instructions).toEqual({
      isError: false,
      text: [
        "# Triage\n\nRead references/checklist.md.",
        "This skill comes from the Grafana plugin.",
        'Supporting files (read one by calling this tool with name "grafana:alert-triage" and file set to its path): references/checklist.md, assets/logo.png, assets/data.bin'
      ].join("\n\n")
    })
    expect(checklist).toEqual({ isError: false, text: "# Checklist\n" })
    expect(logo.text).toBe(
      "assets/logo.png is a binary file (9 bytes, image/png) that can't be shown here."
    )
    expect(data.text).toBe(
      "assets/data.bin is a binary file (3 bytes, unknown type) that can't be shown here."
    )
    expect(missing).toEqual({
      isError: true,
      text: 'The grafana:alert-triage skill has no file "secrets.txt".'
    })
    expect(bare.text).toBe("Just do it.\n\nThis skill comes from the Grafana plugin.")
    expect(resourceReads(plugin.requests).map((request) => request.params.uri)).toEqual([
      "skill://alert-triage/SKILL.md",
      "skill://alert-triage/references/checklist.md",
      "skill://alert-triage/assets/logo.png",
      "skill://alert-triage/assets/data.bin",
      "skill://plain/SKILL.md"
    ])
    await client.close()
  })

  it("refreshes a stale manifest once and refuses content that still doesn't match", async () => {
    const { call, client, plugin } = await pluginGatewaySession(skillsPlugin)

    const refreshed = await call("skills", { name: "grafana:stale" })
    const rejected = await call("skills", { name: "grafana:drifted" })
    const removed = await call("skills", { name: "grafana:shrunk", file: "notes.md" })

    expect(refreshed.text).toContain("Fresh body.")
    expect(rejected).toEqual({
      isError: true,
      text: "Couldn't read grafana:drifted: Grafana served SKILL.md for drifted that doesn't match its manifest"
    })
    expect(
      plugin.requests.filter((request) => request.method === "skills/get").map((r) => r.params)
    ).toEqual([
      { uri: "skill://stale/SKILL.md" },
      { uri: "skill://drifted/SKILL.md" },
      { uri: "skill://shrunk/SKILL.md" }
    ])
    expect(removed.text).toBe(
      "Couldn't read grafana:shrunk: Grafana served notes.md for shrunk that doesn't match its manifest"
    )
    await client.close()
  })

  it("hides a plugin's skills where the plugin is turned off", async () => {
    const { call, client, manager, project, server, session } =
      await pluginGatewaySession(skillsPlugin)

    await manager.setSessionEnabled(session.id, server.id, false, project.id)

    expect((await call("skills", {})).text).not.toContain("grafana:")
    expect(
      (await manager.composerSkills(project.id, session.id)).map((skill) => skill.name)
    ).not.toContain("grafana:alert-triage")
    await client.close()
  })

  it("answers with no skill for listed skills the connection no longer serves", async () => {
    const { call, client, db, server } = await pluginGatewaySession(skillsPlugin)
    await run(
      db.saveMcpServer({
        id: server.id,
        name: server.name,
        transport: "http",
        url: server.url!,
        enabled: true,
        authType: "none",
        connectionState: "connected",
        toolCount: 0,
        capabilities: {
          tools: [],
          events: [],
          skills: [{ name: "ghost" }, { name: "ghost", description: "Duplicate" }],
          panes: [],
          ingress: []
        }
      })
    )

    const listed = await call("skills", {})
    const ghost = await call("skills", { name: "grafana:ghost" })

    expect(listed.text.match(/grafana:ghost/g)).toHaveLength(1)
    expect(ghost.isError).toBe(true)
    expect(ghost.text).toContain('No skill named "grafana:ghost"')
    await client.close()
  })

  it("labels skills with a slug of the plugin name", () => {
    expect(pluginSkillLabel("Google Mail (Work)", "triage")).toBe("google-mail-work:triage")
    expect(pluginSkillLabel("✨", "triage")).toBe("plugin:triage")
  })
})

const accountTools: FakePluginOptions = {
  tools: [
    {
      name: "query",
      inputSchema: { type: "object", properties: { q: { type: "string" } } }
    },
    {
      name: "custom",
      inputSchema: { type: "object", properties: { account: { type: "string" } } }
    },
    { name: "bare", inputSchema: { type: "object" } }
  ]
}

const toolCalls = (
  requests: ReadonlyArray<{ readonly method: string; readonly params: unknown }>
) => requests.filter((request) => request.method === "tools/call").map((request) => request.params)

describe("plugin accounts in the gateway", () => {
  it("offers an account argument and forwards the chosen account's context", async () => {
    const { client, execute, plugin, server } = await pluginGatewaySession(
      accountTools,
      accountSource(["work", "home"])
    )
    const tool = (name: string) => JSON.stringify(`${server.id}.${name}`)

    const described = executeResultValue(
      await execute(`async () => machines.current.tools.describe.tool({ path: ${tool("query")} })`)
    )
    const custom = executeResultValue(
      await execute(`async () => machines.current.tools.describe.tool({ path: ${tool("custom")} })`)
    )
    const bare = executeResultValue(
      await execute(`async () => machines.current.tools.describe.tool({ path: ${tool("bare")} })`)
    )
    await execute(
      `async () => machines.current.tools[${tool("query")}]({ q: "up", account: "home" })`
    )
    await execute(`async () => machines.current.tools[${tool("query")}]({ q: "down" })`)
    await execute(`async () => machines.current.tools[${tool("custom")}]({ account: "mine" })`)
    const unknown = await execute(
      `async () => machines.current.tools[${tool("query")}]({ q: "up", account: "play" })`
    )
    const searched = JSON.stringify(
      executeResultValue(
        await execute(`async () => machines.current.tools.search({ query: "query" })`)
      )
    )

    expect(described).toMatchObject({
      inputSchema: {
        properties: {
          q: { type: "string" },
          account: {
            type: "string",
            enum: ["work", "home"],
            description: "Which Grafana account; defaults to the first"
          }
        }
      }
    })
    expect(custom).toMatchObject({ inputSchema: { properties: { account: { type: "string" } } } })
    expect(custom).not.toHaveProperty("inputSchema.properties.account.enum")
    expect(bare).toMatchObject({
      inputSchema: { properties: { account: { enum: ["work", "home"] } } }
    })
    expect(toolCalls(plugin.requests)).toEqual([
      {
        name: "query",
        arguments: { q: "up" },
        _meta: { "dev.codevisor/account": { id: "id-home" } }
      },
      {
        name: "query",
        arguments: { q: "down" },
        _meta: { "dev.codevisor/account": { id: "id-work" } }
      },
      {
        name: "custom",
        arguments: { account: "mine" },
        _meta: { "dev.codevisor/account": { id: "id-work" } }
      }
    ])
    expect(JSON.stringify(unknown)).toContain(
      'Unknown Grafana account \\"play\\"; use one of \\"work\\", \\"home\\"'
    )
    expect(searched).toContain(`${server.id}.query`)
    await client.close()
  })

  it("always sends a single account's context without offering a choice", async () => {
    const { client, execute, plugin, server } = await pluginGatewaySession(
      accountTools,
      accountSource(["solo"])
    )
    const path = JSON.stringify(`${server.id}.query`)

    const described = executeResultValue(
      await execute(`async () => machines.current.tools.describe.tool({ path: ${path} })`)
    )
    await execute(`async () => machines.current.tools[${path}]({ q: "up", account: "solo" })`)

    expect(described).not.toHaveProperty("inputSchema.properties.account")
    expect(toolCalls(plugin.requests)).toEqual([
      {
        name: "query",
        arguments: { q: "up", account: "solo" },
        _meta: { "dev.codevisor/account": { id: "id-solo" } }
      }
    ])
    await client.close()
  })
})
