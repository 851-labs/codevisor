import type { NativeMcpScan, SkillsScan } from "@codevisor/api"
import { PluginsError } from "@codevisor/plugins"
import type { PluginsManager, PluginStateEvent } from "@codevisor/plugins"

/// Scan fixtures and stub managers for the native MCP, skills, and plugin
/// routes.

export const nativeMcpScan: NativeMcpScan = {
  candidates: [
    {
      alreadyManaged: false,
      args: ["-y", "docs-mcp"],
      command: "npx",
      foundIn: ["claude-code"],
      identity: "docs-mcp",
      name: "docs",
      transport: "stdio"
    }
  ],
  harnesses: [
    {
      configPath: "/home/u/.claude.json",
      exists: true,
      harnessId: "claude-code",
      harnessName: "Claude Code",
      harnessSymbol: "sparkle",
      servers: []
    }
  ]
}

export const skillsScan: SkillsScan = {
  canonicalDir: "/home/u/.agents/skills",
  global: [
    {
      directoryName: "deploy",
      installs: [{ harnessId: "claude-code", state: "linked" }],
      name: "Deploy",
      path: "/home/u/.agents/skills/deploy"
    }
  ],
  harnesses: [
    {
      harnessId: "claude-code",
      harnessName: "Claude Code",
      harnessSymbol: "sparkle",
      skills: [],
      skillsDir: "/home/u/.claude/skills"
    }
  ]
}

export const nativeMcpRemoval = {
  configPath: "/home/u/.claude.json",
  harnessId: "claude-code",
  id: "removal-1",
  removedAt: "2026-07-20T00:00:00.000Z",
  serverName: "docs"
}

/// Shared plugins-manager stub for the plugin route suites (same role as
/// nativeMcpStub/skillsStub below): records calls and mirrors the real
/// manager's typed failures.
export const pluginSummary = {
  canRestore: false,
  enabled: true,
  id: "owner.example",
  name: "Example",
  panes: [{ path: "/panes/main/", title: "Main", type: "main" }],
  path: "/tmp/example",
  source: "linked",
  state: "stopped",
  version: "0.1.0"
} as const

export const pluginsStub = (
  calls: Array<Array<unknown>>,
  listeners: Array<(event: PluginStateEvent) => void> = []
): PluginsManager => ({
  close: () => calls.push(["close"]),
  startAll: async () => {
    calls.push(["startAll"])
  },
  discoverRemote: async (request) => {
    calls.push(["discoverRemote", request])
    if (request.source === "ghost/missing") {
      throw new PluginsError("invalid", "No codevisor-plugin.json found in ghost/missing")
    }
    return {
      alreadyInstalled: false,
      description: "Example plugin",
      id: "owner.example",
      installCommand: "bun install",
      name: "Example",
      panes: pluginSummary.panes,
      runCommand: "bun run start",
      version: "0.1.0"
    }
  },
  importRemote: async (request) => {
    calls.push(["importRemote", request])
    if (request.source === "other/taken") {
      throw new PluginsError("conflict", "already provided by dev-checkout")
    }
    return { ...pluginSummary, source: "managed" }
  },
  listUpdates: async () => {
    calls.push(["listUpdates"])
    return {
      updates: [
        {
          checkedAt: "2026-08-23T00:00:00.000Z",
          installedVersion: "0.1.0",
          pluginId: "owner.example",
          registryVersion: "0.2.0",
          state: "available"
        }
      ]
    }
  },
  prepareUpdate: async (pluginId) => {
    calls.push(["prepareUpdate", pluginId])
    return {
      candidate: {
        panes: pluginSummary.panes,
        runCommand: "node server.js",
        setupCommands: ["npm ci"],
        version: "0.2.0"
      },
      current: {
        panes: pluginSummary.panes,
        runCommand: "bun run start",
        setupCommands: ["bun install"],
        version: "0.1.0"
      },
      expiresAt: "2026-08-23T00:15:00.000Z",
      name: "Example",
      paneChanges: { added: [], changed: [], removed: [] },
      planId: "plan-1",
      pluginId,
      resolvedCommit: "b".repeat(40),
      toolChanges: { added: [], changed: [], removed: [] }
    }
  },
  applyUpdate: async (pluginId, planId) => {
    calls.push(["applyUpdate", pluginId, planId])
    return { ...pluginSummary, source: "managed", version: "0.2.0" }
  },
  fetchIcon: async (pluginId, paneType) => {
    calls.push(["fetchIcon", pluginId, paneType])
    return { contentType: "image/png", data: new Uint8Array([1, 2, 3]) }
  },
  link: async (request) => {
    calls.push(["link", request])
    if (request.path === "relative/path") {
      throw new PluginsError("invalid", "Plugin link path must be absolute")
    }
    return pluginSummary
  },
  remove: async (pluginId) => {
    calls.push(["remove", pluginId])
    if (pluginId !== "owner.example") {
      throw new PluginsError("notFound", `Plugin not installed: ${pluginId}`)
    }
    return { plugins: [] }
  },
  get: async (pluginId) => {
    calls.push(["get", pluginId])
    if (pluginId === "owner.conflict") {
      throw new PluginsError("conflict", "conflicting install")
    }
    if (pluginId === "owner.invalid") {
      throw new PluginsError("invalid", "broken manifest")
    }
    if (pluginId === "owner.unavailable") {
      throw new PluginsError("unavailable", "circuit breaker is open")
    }
    if (pluginId !== "owner.example") {
      throw new PluginsError("notFound", `Plugin not installed: ${pluginId}`)
    }
    return pluginSummary
  },
  handleProxyRequest: async (_request, response, url) => {
    // Mirror the real manager: only proxy-shaped paths are handled here.
    if (!url.pathname.includes("/app/") || url.pathname.endsWith("/unhandled/")) {
      return false
    }
    calls.push(["proxy", url.pathname])
    response.writeHead(200, { "Content-Type": "text/html" })
    response.end("<html>pane</html>")
    return true
  },
  handleUpgrade: async (request, socket) => {
    const url = new URL(request.url ?? "/", "http://127.0.0.1")
    if (url.pathname.endsWith("/unhandled")) {
      return false
    }
    calls.push(["upgrade", url.pathname])
    socket.write("HTTP/1.1 418 Plugin Socket\r\nConnection: close\r\n\r\n")
    socket.destroy()
    return true
  },
  invokeTool: async (pluginId, toolName, args, context) => {
    calls.push(["invokeTool", pluginId, toolName, args, context])
    if (pluginId !== "owner.example") {
      throw new PluginsError("notFound", `Plugin not installed: ${pluginId}`)
    }
    if (toolName !== "notes_add") {
      throw new PluginsError("notFound", `Plugin ${pluginId} has no tool: ${toolName}`)
    }
    return { added: true, received: args }
  },
  listTools: async () => {
    calls.push(["listTools"])
    return [{ description: "Append a note", name: "notes_add", pluginId: "owner.example" }]
  },
  subscribeInstalled: (listener) => {
    calls.push(["subscribeInstalled", listener])
    return () => calls.push(["unsubscribeInstalled"])
  },
  issuePaneToken: async (pluginId, paneId, request) => {
    calls.push(["issuePaneToken", pluginId, paneId, request])
    return {
      expiresAt: new Date().toISOString(),
      path: `/v1/plugins/${pluginId}/app/panes/${request.paneType}/?paneId=${paneId}&codevisorPaneToken=tok`,
      token: "tok"
    }
  },
  list: async () => {
    calls.push(["list"])
    return { plugins: [pluginSummary] }
  },
  restart: async (pluginId) => {
    calls.push(["restart", pluginId])
    if (pluginId !== "owner.example") {
      throw new PluginsError("notFound", `Plugin not installed: ${pluginId}`)
    }
    return pluginSummary
  },
  restore: async (pluginId) => {
    calls.push(["restore", pluginId])
    return { ...pluginSummary, canRestore: true, source: "managed", version: "0.0.9" }
  },
  setEnabled: async (pluginId, enabled) => {
    calls.push(["setEnabled", pluginId, enabled])
    return { ...pluginSummary, enabled }
  },
  subscribe: (listener) => {
    listeners.push(listener)
    return () => calls.push(["unsubscribe"])
  }
})

export const nativeMcpStub = (calls: Array<unknown[]>) => ({
  importServers: async (request: { identities: ReadonlyArray<string> }) => ({
    outcomes: request.identities.map((identity) => ({
      identity,
      status: "imported" as const,
      warnings: []
    })),
    scan: nativeMcpScan
  }),
  listRemovals: async () => [nativeMcpRemoval],
  removeServer: async (harnessId: string, serverName: string) => {
    calls.push(["removeServer", harnessId, serverName])
    return { removal: nativeMcpRemoval, scan: nativeMcpScan }
  },
  restoreRemoval: async (id: string) => {
    calls.push(["restoreRemoval", id])
    return nativeMcpScan
  },
  scan: async () => nativeMcpScan,
  setNativeEnabled: async (harnessId: string, serverName: string, enabled: boolean) => {
    calls.push(["setNativeEnabled", harnessId, serverName, enabled])
    return nativeMcpScan
  }
})

export const skillsStub = (calls: Array<unknown[]>) => ({
  create: async (request: unknown) => {
    calls.push(["create", request])
    return skillsScan
  },
  importLocal: async (request: unknown) => {
    calls.push(["importLocal", request])
    return skillsScan
  },
  importRemote: async (request: unknown) => {
    calls.push(["importRemote", request])
    return skillsScan
  },
  sync: async (request?: unknown) => {
    calls.push(["sync", request])
    return skillsScan
  },
  discoverRemote: async (request: unknown) => {
    calls.push(["discoverRemote", request])
    return {
      skills: [{ alreadyExists: false, directoryName: "deploy", name: "Deploy" } as const]
    }
  },
  list: async () => skillsScan,
  makeGlobal: async (harnessId: string, directoryName: string) => {
    calls.push(["makeGlobal", harnessId, directoryName])
    return skillsScan
  },
  remove: async (directoryName: string) => {
    calls.push(["remove", directoryName])
    return skillsScan
  },
  setInstalled: async (directoryName: string, harnessId: string, installed: boolean) => {
    calls.push(["setInstalled", directoryName, harnessId, installed])
    return skillsScan
  },
  syncManaged: async () => {}
})
