import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import {
  harnessCatalog,
  type AgentRuntimeService,
  type HarnessDefinition
} from "@codevisor/agent-runtime"
import type { Harness } from "@codevisor/api"
import { makeDatabase } from "@codevisor/db"
import type {
  CodevisorDatabaseService,
  HarnessAccountRecord,
  SaveHarnessAccountRequest
} from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import type { Provider } from "@earendil-works/pi-ai"
import { Effect } from "effect"

import type { HarnessLifecycleManager, LifecycleProcess } from "./harness-lifecycle.js"
import type { SharedAccountIntegration } from "./shared-account-integration.js"

export const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

export const directories: string[] = []
export const databases: CodevisorDatabaseService[] = []

export const cleanupLifecycleTests = async (): Promise<void> => {
  await Promise.all(databases.splice(0).map((database) => run(database.close)))
  for (const directory of directories.splice(0)) {
    rmSync(directory, { force: true, recursive: true })
  }
}

export const makeDb = async (): Promise<CodevisorDatabaseService> => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-lifecycle-"))
  directories.push(directory)
  const db = await run(
    makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
  )
  databases.push(db)
  return db
}

export const harness = (id: string, path: string, version?: string): Harness => ({
  id,
  name: id,
  symbolName: "terminal",
  source: "registry",
  launchKind: "executable",
  enabled: true,
  readiness: { state: "ready", path, ...(version === undefined ? {} : { version }) }
})

export const installMethodsFor = async (lifecycle: HarnessLifecycleManager, id: string) => {
  const [decorated] = await lifecycle.decorateHarnesses([
    { ...harness(id, ""), readiness: { state: "unavailable" } }
  ])
  return decorated?.installMethods ?? []
}

const unstubbed = (name: string) => (): never => {
  throw new Error(`${name} is not stubbed`)
}
const unstubbedEffect = (name: string) => () => Effect.die(new Error(`${name} is not stubbed`))

export const fakeAgentRuntime = (
  overrides: Partial<AgentRuntimeService> = {}
): AgentRuntimeService => ({
  catalog: harnessCatalog,
  discoverHarnesses: Effect.die(new Error("discoverHarnesses is not stubbed")),
  refreshEnvironment: Effect.die(new Error("refreshEnvironment is not stubbed")),
  refreshHarnessVersions: () => Effect.void,
  listAgentSessions: unstubbedEffect("listAgentSessions"),
  reconcileConfigValue: unstubbed("reconcileConfigValue"),
  readHarnessUsageLimits: unstubbedEffect("readHarnessUsageLimits"),
  createAgentSession: unstubbedEffect("createAgentSession"),
  inspectHarness: unstubbedEffect("inspectHarness"),
  loadAgentSession: unstubbedEffect("loadAgentSession"),
  prompt: unstubbedEffect("prompt"),
  cancel: unstubbedEffect("cancel"),
  loadedAgentSessionIds: unstubbed("loadedAgentSessionIds"),
  closeAgentSession: unstubbedEffect("closeAgentSession"),
  setMode: unstubbedEffect("setMode"),
  setConfigOption: unstubbedEffect("setConfigOption"),
  setGoal: unstubbedEffect("setGoal"),
  clearGoal: unstubbedEffect("clearGoal"),
  answerQuestion: unstubbedEffect("answerQuestion"),
  readSessionContext: unstubbedEffect("readSessionContext"),
  probeHarnessAuth: unstubbedEffect("probeHarnessAuth"),
  authenticateHarness: unstubbedEffect("authenticateHarness"),
  logoutHarness: unstubbedEffect("logoutHarness"),
  ...overrides
})

export const fakeTerminalManager = (
  overrides: Partial<TerminalManagerService> = {}
): TerminalManagerService => ({
  createTerminal: unstubbedEffect("createTerminal"),
  connectTerminal: unstubbedEffect("connectTerminal"),
  handleClientFrame: unstubbedEffect("handleClientFrame"),
  closeTerminal: unstubbedEffect("closeTerminal"),
  closeTerminalForSession: unstubbedEffect("closeTerminalForSession"),
  closeTerminalsForSessionPrefix: unstubbedEffect("closeTerminalsForSessionPrefix"),
  registerExternalTerminal: unstubbed("registerExternalTerminal"),
  snapshotTerminals: unstubbed("snapshotTerminals"),
  restoreTerminals: unstubbed("restoreTerminals"),
  readScreen: unstubbedEffect("readScreen"),
  outputRevision: unstubbed("outputRevision"),
  subscribeTitles: unstubbed("subscribeTitles"),
  releaseClient: unstubbed("releaseClient"),
  ...overrides
})

export const harnessAccountRecord = (
  fields: Partial<HarnessAccountRecord> = {}
): HarnessAccountRecord => ({
  id: "acct-1",
  harnessId: "codex",
  profileKind: "default",
  label: "Account",
  authState: "unauthenticated",
  isActive: false,
  canLogin: true,
  canLogout: false,
  createdAt: "2026-01-01T00:00:00.000Z",
  updatedAt: "2026-01-01T00:00:00.000Z",
  ...fields
})

export const savedHarnessAccount = (request: SaveHarnessAccountRequest): HarnessAccountRecord =>
  harnessAccountRecord(request)

export const fakeSharedAccounts = (
  overrides: Partial<SharedAccountIntegration> = {}
): SharedAccountIntegration => ({
  reconcile: unstubbed("reconcile"),
  probe: unstubbed("probe"),
  context: unstubbed("context"),
  activate: unstubbed("activate"),
  accounts: unstubbed("accounts"),
  captureLogin: unstubbed("captureLogin"),
  prepareLogin: unstubbed("prepareLogin"),
  logout: unstubbed("logout"),
  loginFailed: unstubbed("loginFailed"),
  saveApiKey: unstubbed("saveApiKey"),
  ...overrides
})

export const fakeProvider = (provider: Pick<Provider, "id" | "name" | "auth">): Provider => ({
  getModels: () => [],
  stream: unstubbed("stream"),
  streamSimple: unstubbed("streamSimple"),
  ...provider
})

export const agentsStub = (
  definitions: ReadonlyArray<HarnessDefinition>,
  harnesses: ReadonlyArray<Harness>
): AgentRuntimeService =>
  fakeAgentRuntime({ catalog: definitions, discoverHarnesses: Effect.succeed(harnesses) })

export const npmDefinition: HarnessDefinition = {
  detectBinaries: ["fake-cli"],
  id: "fake-cli",
  launch: { args: ["acp"], command: "fake-cli", kind: "executable" },
  name: "Fake CLI",
  provider: "acp",
  symbolName: "terminal",
  update: {
    sources: [
      {
        apply: { args: ["update"], kind: "selfUpdate" },
        check: { kind: "npm", packageName: "fake-cli" },
        when: "any"
      }
    ]
  }
}

export const jsonResponse = (body: unknown, status = 200) => ({
  ok: status >= 200 && status < 300,
  status,
  json: async () => body,
  text: async () => (typeof body === "string" ? body : JSON.stringify(body))
})

export const makeBinDir = (names: ReadonlyArray<string>): string => {
  const dir = mkdtempSync(join(tmpdir(), "codevisor-bin-"))
  directories.push(dir)
  for (const name of names) {
    const path = join(dir, name)
    writeFileSync(path, "#!/bin/sh\n")
    chmodSync(path, 0o755)
  }
  return dir
}

export const fakeTerminal = () => {
  const outputs: Array<string> = []
  const exits: Array<number | undefined> = []
  const terminal = fakeTerminalManager({
    registerExternalTerminal: () => ({
      exit: (code?: number) => {
        exits.push(code)
      },
      output: (data: string) => {
        outputs.push(data)
      },
      remove: () => {},
      response: { terminalId: "terminal-1", websocketPath: "", nextOutputSeq: 0 },
      terminalId: "terminal-1"
    })
  })
  return { exits, outputs, terminal }
}

export const fakeSpawner = () => {
  const spawned = Promise.withResolvers<void>()
  const spawns: Array<{ command: string; env: NodeJS.ProcessEnv }> = []
  const processes: Array<{
    emitOutput: (data: string) => void
    emitExit: (code: number | undefined) => void
    killed: boolean
  }> = []
  const spawnShell = (command: string, env: NodeJS.ProcessEnv): LifecycleProcess => {
    spawns.push({ command, env })
    const outputListeners: Array<(data: string) => void> = []
    const exitListeners: Array<(code: number | undefined) => void> = []
    const record = {
      emitExit: (code: number | undefined) => {
        for (const listener of exitListeners) listener(code)
      },
      emitOutput: (data: string) => {
        for (const listener of outputListeners) listener(data)
      },
      killed: false
    }
    processes.push(record)
    return {
      kill: () => {
        record.killed = true
      },
      onExit: (listener) => {
        exitListeners.push(listener)
        spawned.resolve()
      },
      onOutput: (listener) => outputListeners.push(listener)
    }
  }
  return { processes, spawnShell, spawns, spawned: spawned.promise }
}

export const installableDefinition: HarnessDefinition = {
  detectBinaries: ["fake-cli"],
  id: "fake-cli",
  installMethods: [
    { formula: "fake-cli", kind: "brew" },
    { kind: "npm", packageName: "fake-cli" }
  ],
  launch: { args: ["acp"], command: "fake-cli", kind: "executable" },
  name: "Fake CLI",
  provider: "acp",
  symbolName: "terminal",
  update: {
    sources: [
      {
        apply: { args: ["update"], env: { FAKE_UPDATE_OPTIN: "1" }, kind: "selfUpdate" },
        check: { kind: "npm", packageName: "fake-cli" },
        when: "any"
      }
    ]
  }
}

export const waitForLifecycleSettle = (lifecycle: HarnessLifecycleManager) =>
  new Promise<void>((resolve) => {
    const unsubscribe = lifecycle.subscribe((event) => {
      const phase = event.payload.lifecycle?.phase
      if (phase !== "idle" && phase !== "failed") return
      unsubscribe()
      resolve()
    })
  })

export const appBundleDefinition: HarnessDefinition = {
  ...installableDefinition,
  update: {
    sources: [
      {
        apply: { kind: "appBundleSwap" },
        check: { appcastUrl: "https://example.com/appcast.xml", kind: "sparkle" },
        when: "appBundle"
      }
    ]
  }
}
