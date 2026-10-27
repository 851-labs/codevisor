#!/usr/bin/env node
import { execFile, type ExecFileException, spawn } from "node:child_process"
import { mkdirSync, openSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { hostname } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import { NodeRuntime, NodeServices } from "@effect/platform-node"
import { Effect, Option } from "effect"
import { Command, Flag } from "effect/unstable/cli"

import { authLoginCommand } from "./cli/cloud-auth.js"
import { setupCommand, type SetupDeps } from "./cli/setup.js"
import {
  logsCommand,
  restartCommand,
  startCommand,
  statusCommand,
  stopCommand,
  tokenCommand,
  updateCommand,
  type CliDeps
} from "./cli/support.js"
import { makeAuthCommand, makeMachinesCommand, optionalString, portFlag } from "./cli/wiring.js"
import { resolveDataDir, resolveLogsDir } from "./infra/data-dir.js"
import { bundledVersion, runServe } from "./serve.js"

const runtimeDir = dirname(fileURLToPath(import.meta.url))

const execExitCode = (error: ExecFileException | null): number => {
  if (error === null) return 0
  if (typeof error.code === "number") return error.code
  return 127
}

const makeDeps = (): CliDeps => ({
  exec: (command, args) =>
    new Promise((resolve) => {
      execFile(command, [...args], { encoding: "utf8" }, (error, stdout, stderr) => {
        const code = execExitCode(error)
        resolve({ code, stdout, stderr })
      })
    }),
  execInteractive: (command, args) =>
    new Promise((resolve) => {
      const child = spawn(command, [...args], { stdio: "inherit" })
      child.once("error", () => resolve(127))
      child.once("exit", (code) => resolve(code ?? 1))
    }),
  spawnDetachedServer: (args, logPath) => {
    mkdirSync(dirname(logPath), { recursive: true })
    const log = openSync(logPath, "a")
    const child = spawn(process.execPath, [join(runtimeDir, "main.js"), ...args], {
      detached: true,
      stdio: ["ignore", log, log]
    })
    child.unref()
    return Promise.resolve(child.pid ?? -1)
  },
  fetchJson: async (url, init) => {
    try {
      const response = await fetch(url, {
        method: init?.method ?? "GET",
        signal: AbortSignal.timeout(init?.timeoutMs ?? 5000),
        ...(init?.body === undefined
          ? {}
          : {
              body: JSON.stringify(init.body),
              headers: { "content-type": "application/json" }
            })
      })
      const body: unknown = await response.json().catch(() => undefined)
      return { status: response.status, body }
    } catch {
      return undefined
    }
  },
  readTextFile: (path) => {
    try {
      return readFileSync(path, "utf8")
    } catch {
      return undefined
    }
  },
  writeTextFile: (path, contents) => {
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, contents, "utf8")
  },
  removeFile: (path) => rmSync(path, { force: true }),
  processAlive: (pid) => {
    try {
      process.kill(pid, 0)
      return true
    } catch {
      return false
    }
  },
  signal: (pid, signal) => {
    try {
      process.kill(pid, signal)
      return true
    } catch {
      return false
    }
  },
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  env: process.env,
  isRoot: process.getuid?.() === 0,
  installedVersion: () => bundledVersion(),
  dataDir: resolveDataDir(),
  logsDir: resolveLogsDir(),
  log: (line) => console.log(line),
  error: (line) => console.error(line)
})

const runCli = (command: (deps: CliDeps) => Promise<number>): Effect.Effect<void> =>
  Effect.promise(async () => {
    process.exitCode = await command(makeDeps())
  })

const serve = Command.make(
  "serve",
  {
    host: optionalString("host", "Bind address (default 127.0.0.1)"),
    port: optionalString(
      "port",
      "Pin the listening port exactly (default: last port used, else 49361, else the next free port up to 49399)"
    ),
    preferredPort: optionalString(
      "preferred-port",
      "First port to try when --port is not given (default 49361)"
    ),
    serverId: optionalString("serverId", "Stable server identifier (default local)"),
    auth: optionalString("auth", "Auth mode: none or token (default none on loopback)"),
    kind: optionalString("kind", "Server kind: local or remote"),
    directPath: optionalString(
      "direct-path",
      "Direct LAN path: enabled or disabled (default enabled)"
    ),
    name: optionalString("name", "Display name shown in clients"),
    db: optionalString("db", "SQLite database path (default ~/.codevisor/data)"),
    upgradeStatus: optionalString("upgrade-status", "Data-upgrade progress sidecar path"),
    bootId: optionalString("boot-id", "Unique identity for this server startup"),
    appOwned: optionalString("app-owned", "Whether a desktop app owns this server (0 or 1)"),
    ownerPid: optionalString("owner-pid", "Owning desktop app process identifier"),
    version: optionalString("version", "Advertised server version")
  },
  (config) =>
    Effect.promise(() => {
      const entries: Array<readonly [string, Option.Option<string>]> = [
        ["host", config.host],
        ["port", config.port],
        ["preferred-port", config.preferredPort],
        ["serverId", config.serverId],
        ["auth", config.auth],
        ["kind", config.kind],
        ["direct-path", config.directPath],
        ["name", config.name],
        ["db", config.db],
        ["upgrade-status", config.upgradeStatus],
        ["boot-id", config.bootId],
        ["app-owned", config.appOwned],
        ["owner-pid", config.ownerPid],
        ["version", config.version]
      ]
      const args: Record<string, string> = {}
      for (const [key, value] of entries) {
        if (Option.isSome(value)) args[key] = value.value
      }
      return runServe(args)
    })
).pipe(Command.withDescription("Run the Codevisor server in the foreground"))

const start = Command.make("start", { port: portFlag }, ({ port }) =>
  runCli((deps) => startCommand(deps, { port: Option.getOrUndefined(port) }))
).pipe(Command.withDescription("Start the Codevisor server (systemd unit or background process)"))

const stop = Command.make("stop", { port: portFlag }, ({ port }) =>
  runCli((deps) => stopCommand(deps, { port: Option.getOrUndefined(port) }))
).pipe(Command.withDescription("Stop the Codevisor server"))

const restart = Command.make("restart", { port: portFlag }, ({ port }) =>
  runCli((deps) => restartCommand(deps, { port: Option.getOrUndefined(port) }))
).pipe(Command.withDescription("Restart the Codevisor server"))

const status = Command.make(
  "status",
  {
    port: portFlag,
    json: Flag.boolean("json").pipe(Flag.withDescription("Print machine-readable JSON"))
  },
  ({ json, port }) =>
    runCli((deps) => statusCommand(deps, { json, port: Option.getOrUndefined(port) }))
).pipe(Command.withDescription("Show server status, machine manifest, and harness readiness"))

const token = Command.make(
  "token",
  {
    port: portFlag,
    rotate: Flag.boolean("rotate").pipe(
      Flag.withDescription("Replace the token; scripts using the old one must be updated")
    )
  },
  ({ port, rotate }) =>
    runCli((deps) => tokenCommand(deps, { port: Option.getOrUndefined(port), rotate }))
).pipe(
  Command.withDescription(
    "Print this machine's API connection token for scripts (stable until rotated)"
  )
)

const update = Command.make(
  "update",
  {
    port: portFlag,
    alpha: Flag.boolean("alpha").pipe(
      Flag.withDescription("Include Alpha releases when checking for updates")
    )
  },
  ({ port, alpha }) =>
    runCli((deps) => updateCommand(deps, { port: Option.getOrUndefined(port), alpha }))
).pipe(Command.withDescription("Update the Codevisor server to the latest release"))

const logs = Command.make(
  "logs",
  {
    follow: Flag.boolean("follow").pipe(
      Flag.withAlias("f"),
      Flag.withDescription("Keep streaming new log lines")
    )
  },
  ({ follow }) => runCli((deps) => logsCommand(deps, { follow }))
).pipe(Command.withDescription("Show server logs (journalctl or the log file)"))

const makeSetupDeps = (): SetupDeps => {
  const deps = makeDeps()
  return {
    ...deps,
    isInteractive: process.stdin.isTTY && process.stdout.isTTY,
    cloudLogin: (port) => authLoginCommand(deps, { port, machineName: hostname() })
  }
}

const setup = Command.make("setup", { port: portFlag }, ({ port }) =>
  Effect.promise(async () => {
    process.exitCode = await setupCommand(makeSetupDeps(), { port: Option.getOrUndefined(port) })
  })
).pipe(
  Command.withDescription("Onboard this machine: start the server and sign it into Codevisor Cloud")
)

const auth = makeAuthCommand(runCli)
const machines = makeMachinesCommand(runCli)

const root = Command.make("codevisor").pipe(
  Command.withDescription("Control the Codevisor server on this machine"),
  Command.withSubcommands([
    serve,
    setup,
    auth,
    machines,
    start,
    stop,
    restart,
    status,
    token,
    update,
    logs
  ])
)

const program = Command.run(root, {
  version: bundledVersion() ?? "0.0.0-dev"
})

NodeRuntime.runMain(program.pipe(Effect.provide(NodeServices.layer)))
