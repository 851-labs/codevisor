import type { Harness, NativeMcpScan, SkillsList } from "@codevisor/api"
import { SkillsError } from "@codevisor/skills"

import type { RestartCoordinator } from "./restart-drain.js"
import type { UpdateRun } from "./update-run.js"

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

export const skillsList: SkillsList = {
  dir: "/data/skills",
  skills: [{ directoryName: "deploy", name: "Deploy", path: "/data/skills/deploy" }]
}

export const nativeMcpRemoval = {
  configPath: "/home/u/.claude.json",
  harnessId: "claude-code",
  id: "removal-1",
  removedAt: "2026-07-20T00:00:00.000Z",
  serverName: "docs"
}

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

export const skillsStub = (calls: Array<unknown[]>) => {
  const known = (directoryName: string): void => {
    if (!skillsList.skills.some((skill) => skill.directoryName === directoryName)) {
      throw new SkillsError(`No skill named ${directoryName}`, "notFound")
    }
  }
  return {
    dir: skillsList.dir,
    read: async (directoryName: string) => {
      calls.push(["read", directoryName])
      known(directoryName)
      return { content: "---\nname: Deploy\ndescription: Deploy checklist\n---\nShip it.\n" }
    },
    update: async (directoryName: string, request: unknown) => {
      calls.push(["update", directoryName, request])
      known(directoryName)
      return skillsList
    },
    create: async (request: unknown) => {
      calls.push(["create", request])
      return skillsList
    },
    importRemote: async (request: unknown) => {
      calls.push(["importRemote", request])
      return skillsList
    },
    discoverRemote: async (request: unknown) => {
      calls.push(["discoverRemote", request])
      return {
        skills: [{ alreadyExists: false, directoryName: "deploy", name: "Deploy" } as const]
      }
    },
    list: async () => skillsList,
    remove: async (directoryName: string) => {
      calls.push(["remove", directoryName])
      return skillsList
    },
    replace: async () => undefined,
    rename: async () => undefined,
    document: async () => undefined,
    subscribe: () => () => undefined
  }
}

export const idleRestartCoordinator = (): RestartCoordinator => {
  const startedAt = "2026-06-30T00:00:00.000Z"
  return {
    state: () => ({ state: "idle", remaining: 0, startedAt, pausedSessionIds: [] }),
    isActive: () => false,
    gates: () => false,
    gateFor: () => ({ harnessId: "codevisor-server", harnessName: "Codevisor" }),
    begin: async () => ({ state: "drained", remaining: 0, startedAt, pausedSessionIds: [] }),
    cancel: async () => ({ state: "idle", remaining: 0, startedAt, pausedSessionIds: [] }),
    extendGrace: () => {},
    close: () => {}
  }
}

export const idleUpdateRun = (): UpdateRun => {
  const idle = {
    state: "idle" as const,
    harnessIds: [],
    pausing: 0,
    startedAt: "2026-06-30T00:00:00.000Z"
  }
  return {
    state: () => idle,
    start: async () => ({ run: idle }),
    startServerUpdate: async () => ({ accepted: false, targetVersion: "0.0.0" }),
    cancel: async () => idle,
    noteChatsChanged: () => {}
  }
}

export const harnesses: ReadonlyArray<Harness> = [
  {
    id: "codex",
    name: "Codex",
    symbolName: "chevron.left.forwardslash.chevron.right",
    source: "registry",
    launchKind: "npx",
    enabled: true,
    readiness: { state: "ready" },
    installHint: "npm install -g @openai/codex"
  }
]
