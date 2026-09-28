import { hostname } from "node:os"

import { NodeServices } from "@effect/platform-node"
import { Effect, Option } from "effect"
import { Command, Flag, Prompt } from "effect/unstable/cli"

import { authLoginCommand, authLogoutCommand, authStatusCommand } from "./cloud-auth.js"
import type { CliDeps } from "./support.js"

/// CLI wiring split from cli.ts to keep the entry point within size
/// limits: shared flag helpers, the interactive prompt runner, and the
/// `auth` command group. Wiring only — the testable logic lives in
/// cloud-auth.ts.

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
      port: portFlag
    },
    ({ server, name, port }) =>
      runCli((deps) =>
        authLoginCommand(deps, {
          port: Option.getOrUndefined(port),
          ...(Option.isSome(server) ? { server: server.value } : {}),
          machineName: Option.getOrElse(name, () => hostname())
        })
      )
  ).pipe(
    Command.withDescription("Connect this machine to your Codevisor Cloud account (device code)")
  )

  const status = Command.make("status", { port: portFlag }, ({ port }) =>
    runCli((deps) => authStatusCommand(deps, { port: Option.getOrUndefined(port) }))
  ).pipe(Command.withDescription("Show this machine's cloud account connection"))

  const logout = Command.make("logout", { port: portFlag }, ({ port }) =>
    runCli((deps) => authLogoutCommand(deps, { port: Option.getOrUndefined(port) }))
  ).pipe(Command.withDescription("Disconnect this machine and remove it from its cloud account"))

  return Command.make("auth").pipe(
    Command.withDescription("Connect this machine to a Codevisor Cloud account"),
    Command.withSubcommands([login, status, logout])
  )
}
