import type { AgentRuntimeService, HarnessDefinition } from "@codevisor/agent-runtime"
import type { Harness } from "@codevisor/api"
import { makeDatabase } from "@codevisor/db"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import { Effect } from "effect"
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import type { LifecycleProcess } from "./harness-lifecycle.js"

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

export const agentsStub = (
  definitions: ReadonlyArray<HarnessDefinition>,
  harnesses: ReadonlyArray<Harness>
): AgentRuntimeService =>
  ({
    catalog: definitions,
    discoverHarnesses: Effect.succeed(harnesses)
  }) as unknown as AgentRuntimeService

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

/// A PATH directory with executable stubs, for install-method availability.
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
  const terminal = {
    registerExternalTerminal: () => ({
      exit: (code?: number) => exits.push(code),
      output: (data: string) => outputs.push(data),
      remove: () => {},
      response: {} as never,
      terminalId: "terminal-1"
    })
  } as unknown as TerminalManagerService
  return { exits, outputs, terminal }
}

/// Manually-settled fake process so tests control exit timing.
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

export const waitForLifecycleSettle = (
  lifecycle: import("./harness-lifecycle-types.js").HarnessLifecycleManager
) =>
  new Promise<void>((resolve) => {
    const unsubscribe = lifecycle.subscribe((event) => {
      const phase = (event.payload as { lifecycle?: { phase?: string } }).lifecycle?.phase
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
