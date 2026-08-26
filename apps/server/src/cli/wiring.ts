import { NodeServices } from "@effect/platform-node"
import { Effect, Option } from "effect"
import { Command, Flag, Prompt } from "effect/unstable/cli"
import { hostname } from "node:os"
import { authLoginCommand, authLogoutCommand, authStatusCommand } from "./cloud-auth.js"
import type { CliDeps } from "./support.js"
import { syncCommand } from "./sync.js"

/// CLI wiring split from cli.ts to keep the entry point within size
/// limits: shared flag helpers, the interactive prompt runner, and the
/// `auth`/`sync` command groups. Wiring only — the testable logic lives in
/// cloud-auth.ts and sync.ts.

export const portFlag = Flag.integer("port").pipe(
  Flag.withDescription("Server port (defaults to CODEVISOR_PORT, the systemd unit, or 49361)"),
  Flag.optional
)

export const optionalString = (name: string, description: string) =>
  Flag.string(name).pipe(Flag.withDescription(description), Flag.optional)

/// Interactive prompts, each provided its own platform services so they can
/// run from inside the Promise-based command seam. Ctrl-C exits like a shell
/// interrupt would.
export const runPrompt = async <A>(prompt: Prompt.Prompt<A>): Promise<A> => {
  try {
    return await Effect.runPromise(Prompt.run(prompt).pipe(Effect.provide(NodeServices.layer)))
  } catch {
    console.error("\nCancelled.")
    return process.exit(130)
  }
}

/// The onboarding sync opt-in, asked after a cloud login connects this
/// machine to an account that may already have a fleet. Default yes; the
/// honest limitation is that the CLI cannot see the account's other
/// machines, so the question shows on a first machine too (where either
/// answer is harmless until a second machine exists).
export const syncConfigPrompt = (): Promise<boolean> =>
  runPrompt(
    Prompt.select({
      message: "Sync your Codevisor configuration to this machine?",
      choices: [
        {
          title: "Sync (recommended)",
          value: true,
          description: "Skills, MCP servers, and settings from your other machines apply here too"
        },
        {
          title: "Keep this machine separate",
          value: false,
          description: "Stay out of config sync; change later with `codevisor sync on`"
        }
      ]
    })
  )

type RunCli = (command: (deps: CliDeps) => Promise<number>) => Effect.Effect<void>

export const makeAuthCommand = (runCli: RunCli) => {
  const login = Command.make(
    "login",
    {
      server: optionalString(
        "server",
        "Cloud instance base URL (self-hosted or dev; defaults to Codevisor Cloud)"
      ),
      name: optionalString("name", "Display name for this machine (defaults to the hostname)"),
      noSync: Flag.boolean("no-sync").pipe(
        Flag.withDescription("Keep this machine out of config sync (skills, MCP servers, settings)")
      )
    },
    ({ server, name, noSync }) =>
      runCli((deps) =>
        authLoginCommand(deps, {
          ...(Option.isSome(server) ? { server: server.value } : {}),
          machineName: Option.getOrElse(name, () => hostname()),
          ...(noSync ? { syncConfig: false } : {}),
          // Interactive logins ask — but only when joining an existing
          // fleet (the command checks the account's machine list); piped
          // installs stay silent and keep the server default
          // (participating).
          ...(!noSync && process.stdin.isTTY === true && process.stdout.isTTY === true
            ? { promptSyncConfig: syncConfigPrompt }
            : {})
        })
      )
  ).pipe(
    Command.withDescription("Connect this machine to your Codevisor Cloud account (device code)")
  )

  const status = Command.make("status", {}, () => runCli((deps) => authStatusCommand(deps))).pipe(
    Command.withDescription("Show this machine's cloud account connection")
  )

  const logout = Command.make("logout", {}, () => runCli((deps) => authLogoutCommand(deps))).pipe(
    Command.withDescription("Disconnect this machine from its cloud account")
  )

  return Command.make("auth").pipe(
    Command.withDescription("Connect this machine to a Codevisor Cloud account"),
    Command.withSubcommands([login, status, logout])
  )
}

export const makeSyncCommand = (runCli: RunCli) => {
  const status = Command.make("status", { port: portFlag }, ({ port }) =>
    runCli((deps) => syncCommand(deps, { port: Option.getOrUndefined(port) }))
  ).pipe(Command.withDescription("Show whether this machine participates in config sync"))

  const set = (name: "on" | "off", enabled: boolean) =>
    Command.make(name, { port: portFlag }, ({ port }) =>
      runCli((deps) => syncCommand(deps, { port: Option.getOrUndefined(port), enabled }))
    ).pipe(
      Command.withDescription(
        enabled
          ? "Join config sync: skills, MCP servers, and settings follow you here"
          : "Leave config sync: nothing is replicated to or from this machine"
      )
    )

  return Command.make("sync").pipe(
    Command.withDescription("This machine's config sync participation"),
    Command.withSubcommands([status, set("on", true), set("off", false)])
  )
}
