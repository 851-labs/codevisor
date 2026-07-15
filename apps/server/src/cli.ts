#!/usr/bin/env node
/// The `codevisor` CLI: control the server from a terminal (start, stop,
/// status, token, update, logs) plus `codevisor serve` for the daemon itself.
/// All command logic lives in cli/support.ts behind the CliDeps seam; this
/// file only wires real Node implementations and the effect/unstable/cli
/// command tree.
import { NodeRuntime, NodeServices } from "@effect/platform-node"
import { Effect, Option } from "effect"
import { Command, Flag, Prompt } from "effect/unstable/cli"
import { execFile, spawn } from "node:child_process"
import { mkdirSync, openSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { hostname } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
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
import { resolveDataDir, resolveLogsDir } from "./data-dir.js"
import { bundledVersion, runServe } from "./serve.js"

const runtimeDir = dirname(fileURLToPath(import.meta.url))

const makeDeps = (): CliDeps => ({
  exec: (command, args) =>
    new Promise((resolve) => {
      execFile(command, [...args], { encoding: "utf8" }, (error, stdout, stderr) => {
        const code =
          error === null ? 0 : typeof error.code === "number" ? error.code : (127 as number)
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
        signal: AbortSignal.timeout(5000)
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

const portFlag = Flag.integer("port").pipe(
  Flag.withDescription("Server port (defaults to CODEVISOR_PORT, the systemd unit, or 49361)"),
  Flag.optional
)

const runCli = (command: (deps: CliDeps) => Promise<number>): Effect.Effect<void> =>
  Effect.promise(async () => {
    process.exitCode = await command(makeDeps())
  })

const optionalString = (name: string, description: string) =>
  Flag.string(name).pipe(Flag.withDescription(description), Flag.optional)

const serve = Command.make(
  "serve",
  {
    host: optionalString("host", "Bind address (default 127.0.0.1)"),
    port: optionalString("port", "Port to listen on (default 49361)"),
    serverId: optionalString("serverId", "Stable server identifier (default local)"),
    auth: optionalString("auth", "Auth mode: none or token (default none on loopback)"),
    kind: optionalString("kind", "Server kind: local or remote"),
    name: optionalString("name", "Display name shown in clients"),
    db: optionalString("db", "SQLite database path (default ~/.codevisor/data)"),
    corsOrigins: optionalString("cors-origins", "Comma-separated browser origins"),
    upgradeStatus: optionalString("upgrade-status", "Data-upgrade progress sidecar path"),
    version: optionalString("version", "Advertised server version")
  },
  (config) =>
    Effect.promise(() => {
      const entries: Array<readonly [string, Option.Option<string>]> = [
        ["host", config.host],
        ["port", config.port],
        ["serverId", config.serverId],
        ["auth", config.auth],
        ["kind", config.kind],
        ["name", config.name],
        ["db", config.db],
        ["cors-origins", config.corsOrigins],
        ["upgrade-status", config.upgradeStatus],
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
      Flag.withDescription("Replace the token; previously paired clients must re-pair")
    )
  },
  ({ port, rotate }) =>
    runCli((deps) => tokenCommand(deps, { port: Option.getOrUndefined(port), rotate }))
).pipe(Command.withDescription("Print this machine's connection token (stable until rotated)"))

const update = Command.make("update", { port: portFlag }, ({ port }) =>
  runCli((deps) => updateCommand(deps, { port: Option.getOrUndefined(port) }))
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

/// Interactive prompts, each provided its own platform services so they can
/// run from inside the Promise-based command seam. Ctrl-C exits like a shell
/// interrupt would.
const runPrompt = async <A>(prompt: Prompt.Prompt<A>): Promise<A> => {
  try {
    return await Effect.runPromise(Prompt.run(prompt).pipe(Effect.provide(NodeServices.layer)))
  } catch {
    console.error("\nCancelled.")
    return process.exit(130)
  }
}

const makeSetupDeps = (): SetupDeps => ({
  ...makeDeps(),
  hostname: hostname(),
  isInteractive: process.stdin.isTTY === true && process.stdout.isTTY === true,
  prompts: {
    select: (message, choices) => runPrompt(Prompt.select({ message, choices })),
    text: (message) => runPrompt(Prompt.text({ message }))
  }
})

const setup = Command.make("setup", { port: portFlag }, ({ port }) =>
  Effect.promise(async () => {
    process.exitCode = await setupCommand(makeSetupDeps(), {
      port: Option.getOrUndefined(port)
    })
  })
).pipe(
  Command.withDescription("Onboard this machine: pick connectivity and issue a connection token")
)

const root = Command.make("codevisor").pipe(
  Command.withDescription("Control the Codevisor server on this machine"),
  Command.withSubcommands([serve, setup, start, stop, restart, status, token, update, logs])
)

const program = Command.run(root, {
  version: bundledVersion() ?? "0.0.0-dev"
})

NodeRuntime.runMain(program.pipe(Effect.provide(NodeServices.layer)))
