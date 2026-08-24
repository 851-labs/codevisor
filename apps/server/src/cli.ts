#!/usr/bin/env node
/// The `codevisor` CLI: control the server from a terminal (start, stop,
/// status, token, update, logs) plus `codevisor serve` for the daemon itself.
/// All command logic lives in cli/support.ts behind the CliDeps seam; this
/// file only wires real Node implementations and the effect/unstable/cli
/// command tree.
import { NodeRuntime, NodeServices } from "@effect/platform-node"
import { Effect, Option } from "effect"
import { Argument, Command, Flag, Prompt } from "effect/unstable/cli"
import { execFile, spawn } from "node:child_process"
import { mkdirSync, openSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { hostname } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { authLoginCommand } from "./cli/cloud-auth.js"
import {
  makeAuthCommand,
  makeSyncCommand,
  optionalString,
  portFlag,
  runPrompt,
  syncConfigPrompt
} from "./cli/wiring.js"
import {
  pluginInstallCommand,
  pluginLinkCommand,
  pluginListCommand,
  pluginRemoveCommand,
  pluginRestoreCommand,
  pluginSetEnabledCommand,
  pluginUpdateCommand,
  pluginUpdatesCommand,
  type PluginsCliDeps
} from "./cli/plugins.js"
import { qrCommand, setupCommand, type SetupDeps } from "./cli/setup.js"
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
import { resolveDataDir, resolveLogsDir } from "./infra/data-dir.js"
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
    port: optionalString("port", "Port to listen on (default 49361)"),
    serverId: optionalString("serverId", "Stable server identifier (default local)"),
    auth: optionalString("auth", "Auth mode: none or token (default none on loopback)"),
    kind: optionalString("kind", "Server kind: local or remote"),
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
        ["serverId", config.serverId],
        ["auth", config.auth],
        ["kind", config.kind],
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
      Flag.withDescription("Replace the token; previously paired clients must re-pair")
    )
  },
  ({ port, rotate }) =>
    runCli((deps) => tokenCommand(deps, { port: Option.getOrUndefined(port), rotate }))
).pipe(Command.withDescription("Print this machine's connection token (stable until rotated)"))

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
      port: Option.getOrUndefined(port),
      // The optional cloud step: device-code login, then a server restart so
      // the machine connects to the hub immediately (the cloud bridge reads
      // its credentials at boot).
      cloudLogin: async () => {
        const deps = makeDeps()
        const result = await authLoginCommand(deps, {
          machineName: hostname(),
          promptSyncConfig: syncConfigPrompt
        })
        if (result === 0) {
          await restartCommand(deps, { port: Option.getOrUndefined(port) })
        }
        return result
      }
    })
  })
).pipe(
  Command.withDescription("Onboard this machine: pick connectivity and issue a connection token")
)

const qr = Command.make(
  "qr",
  {
    port: portFlag,
    host: optionalString(
      "host",
      "Address clients should use to reach this machine (defaults to Tailscale detection)"
    )
  },
  ({ port, host }) =>
    runCli((deps) =>
      qrCommand(
        { ...deps, hostname: hostname() },
        { port: Option.getOrUndefined(port), host: Option.getOrUndefined(host) }
      )
    )
).pipe(Command.withDescription("Print the pairing QR code for the Codevisor phone app"))

/// Plugin commands talk to the running server over the loopback API; the
/// consent prompt is the only interactive piece.
const makePluginsDeps = (): PluginsCliDeps => ({
  ...makeDeps(),
  confirm: (message) => runPrompt(Prompt.confirm({ message }))
})

const pluginInstall = Command.make(
  "install",
  {
    source: Argument.string("source").pipe(
      Argument.withDescription("owner/repo, owner/repo/path, a git URL, or a local path")
    ),
    port: portFlag,
    yes: Flag.boolean("yes").pipe(
      Flag.withAlias("y"),
      Flag.withDescription("Skip the install confirmation prompt")
    )
  },
  ({ port, source, yes }) =>
    Effect.promise(async () => {
      process.exitCode = await pluginInstallCommand(makePluginsDeps(), {
        port: Option.getOrUndefined(port),
        source,
        yes
      })
    })
).pipe(Command.withDescription("Install a plugin after showing the commands it will run"))

const pluginLink = Command.make(
  "link",
  {
    path: Argument.string("path").pipe(
      Argument.withDescription("Local plugin directory to symlink into the plugins root")
    ),
    port: portFlag
  },
  ({ path, port }) =>
    runCli((deps) =>
      pluginLinkCommand(
        { ...deps, confirm: async () => true },
        { path, port: Option.getOrUndefined(port) }
      )
    )
).pipe(Command.withDescription("Link a local plugin directory for development"))

const pluginList = Command.make("list", { port: portFlag }, ({ port }) =>
  runCli((deps) =>
    pluginListCommand({ ...deps, confirm: async () => true }, { port: Option.getOrUndefined(port) })
  )
).pipe(Command.withDescription("List installed plugins with their runtime state"))

const pluginRemove = Command.make(
  "remove",
  {
    pluginId: Argument.string("id").pipe(
      Argument.withDescription("Plugin id to uninstall (managed installs only)")
    ),
    port: portFlag
  },
  ({ pluginId, port }) =>
    runCli((deps) =>
      pluginRemoveCommand(
        { ...deps, confirm: async () => true },
        { pluginId, port: Option.getOrUndefined(port) }
      )
    )
).pipe(Command.withDescription("Uninstall a managed plugin"))

const pluginUpdates = Command.make("updates", { port: portFlag }, ({ port }) =>
  runCli((deps) =>
    pluginUpdatesCommand(
      { ...deps, confirm: async () => true },
      { port: Option.getOrUndefined(port) }
    )
  )
).pipe(Command.withDescription("Show update state for installed plugins"))

const pluginUpdate = Command.make(
  "update",
  {
    pluginId: Argument.string("id").pipe(Argument.withDescription("Plugin id to update")),
    port: portFlag,
    yes: Flag.boolean("yes").pipe(
      Flag.withAlias("y"),
      Flag.withDescription("Skip the update confirmation prompt")
    )
  },
  ({ pluginId, port, yes }) =>
    Effect.promise(async () => {
      process.exitCode = await pluginUpdateCommand(makePluginsDeps(), {
        pluginId,
        port: Option.getOrUndefined(port),
        yes
      })
    })
).pipe(Command.withDescription("Review and apply an available plugin update"))

const pluginRestore = Command.make(
  "restore",
  {
    pluginId: Argument.string("id").pipe(Argument.withDescription("Plugin id to restore")),
    port: portFlag
  },
  ({ pluginId, port }) =>
    runCli((deps) =>
      pluginRestoreCommand(
        { ...deps, confirm: async () => true },
        { pluginId, port: Option.getOrUndefined(port) }
      )
    )
).pipe(Command.withDescription("Restore a plugin's verified pre-update version"))

const pluginEnabledCommand = (name: "enable" | "disable", enabled: boolean) =>
  Command.make(
    name,
    {
      pluginId: Argument.string("id").pipe(Argument.withDescription(`Plugin id to ${name}`)),
      port: portFlag
    },
    ({ pluginId, port }) =>
      runCli((deps) =>
        pluginSetEnabledCommand(
          { ...deps, confirm: async () => true },
          { enabled, pluginId, port: Option.getOrUndefined(port) }
        )
      )
  ).pipe(Command.withDescription(`${name === "enable" ? "Enable" : "Disable"} an installed plugin`))

const pluginEnable = pluginEnabledCommand("enable", true)
const pluginDisable = pluginEnabledCommand("disable", false)

const plugin = Command.make("plugin").pipe(
  Command.withDescription("Manage this machine's Codevisor plugins"),
  Command.withSubcommands([
    pluginInstall,
    pluginLink,
    pluginList,
    pluginRemove,
    pluginUpdates,
    pluginUpdate,
    pluginRestore,
    pluginEnable,
    pluginDisable
  ])
)

const auth = makeAuthCommand(runCli)
const sync = makeSyncCommand(runCli)

const root = Command.make("codevisor").pipe(
  Command.withDescription("Control the Codevisor server on this machine"),
  Command.withSubcommands([
    serve,
    setup,
    qr,
    auth,
    plugin,
    start,
    stop,
    restart,
    status,
    token,
    update,
    sync,
    logs
  ])
)

const program = Command.run(root, {
  version: bundledVersion() ?? "0.0.0-dev"
})

NodeRuntime.runMain(program.pipe(Effect.provide(NodeServices.layer)))
