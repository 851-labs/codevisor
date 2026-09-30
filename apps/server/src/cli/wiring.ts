import { hostname } from "node:os"

import { NodeServices } from "@effect/platform-node"
import { Effect, Option } from "effect"
import { Argument, Command, Flag, Prompt } from "effect/unstable/cli"

import { authLoginCommand, authLogoutCommand, authStatusCommand } from "./cloud-auth.js"
import {
  machinesAddCommand,
  machinesInviteCommand,
  machinesListCommand,
  machinesRemoveCommand
} from "./machines.js"
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

/// All of stdin, trimmed: secrets like invite codes arrive this way so they
/// stay out of argv (and so `ps` and shell history).
const readStdin = async (): Promise<string> => {
  const chunks: Buffer[] = []
  for await (const chunk of process.stdin) chunks.push(chunk as Buffer)
  return Buffer.concat(chunks).toString("utf8").trim()
}

export const makeAuthCommand = (runCli: RunCli) => {
  const login = Command.make(
    "login",
    {
      server: optionalString(
        "server",
        "Cloud instance base URL (self-hosted or dev; defaults to Codevisor Cloud)"
      ),
      name: optionalString("name", "Display name for this machine (defaults to the hostname)"),
      invite: optionalString(
        "invite",
        "Join with a one-time invite from another machine (`codevisor machines invite`) instead of approving a code; pass - to read it from stdin"
      ),
      port: portFlag
    },
    ({ server, name, invite, port }) =>
      Effect.flatMap(
        Effect.promise(async () =>
          Option.isSome(invite) && invite.value === "-"
            ? readStdin()
            : Option.getOrUndefined(invite)
        ),
        (inviteCode) =>
          runCli((deps) =>
            authLoginCommand(deps, {
              port: Option.getOrUndefined(port),
              ...(Option.isSome(server) ? { server: server.value } : {}),
              machineName: Option.getOrElse(name, () => hostname()),
              ...(inviteCode === undefined ? {} : { inviteCode })
            })
          )
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

export const makeMachinesCommand = (runCli: RunCli) => {
  const list = Command.make("list", { port: portFlag }, ({ port }) =>
    runCli((deps) => machinesListCommand(deps, { port: Option.getOrUndefined(port) }))
  ).pipe(Command.withDescription("List every machine on your account"))

  const invite = Command.make("invite", { port: portFlag }, ({ port }) =>
    runCli((deps) => machinesInviteCommand(deps, { port: Option.getOrUndefined(port) }))
  ).pipe(
    Command.withDescription(
      "Print a one-time code that adds a new machine to your account (codevisor auth login --invite)"
    )
  )

  const add = Command.make(
    "add",
    {
      ssh: Argument.string("destination").pipe(
        Argument.withDescription("SSH destination: user@host, host, or a Host alias")
      ),
      name: optionalString("name", "Display name for the new machine (defaults to its hostname)"),
      sshPort: Flag.integer("ssh-port").pipe(
        Flag.withDescription("SSH port, when not 22 or set in ~/.ssh/config"),
        Flag.optional
      ),
      port: portFlag
    },
    ({ ssh, name, sshPort, port }) =>
      runCli((deps) =>
        machinesAddCommand(deps, {
          ssh,
          port: Option.getOrUndefined(port),
          ...(Option.isSome(name) ? { name: name.value } : {}),
          ...(Option.isSome(sshPort) ? { sshPort: sshPort.value } : {})
        })
      )
  ).pipe(Command.withDescription("Install Codevisor on a host over SSH and add it to your account"))

  const remove = Command.make(
    "remove",
    {
      machine: Argument.string("machine").pipe(
        Argument.withDescription("The machine's name or id (see codevisor machines list)")
      ),
      port: portFlag
    },
    ({ machine, port }) =>
      runCli((deps) => machinesRemoveCommand(deps, { machine, port: Option.getOrUndefined(port) }))
  ).pipe(Command.withDescription("Remove another machine from your account"))

  return Command.make("machines").pipe(
    Command.withDescription("Add, list, and remove the machines on your Codevisor account"),
    Command.withSubcommands([list, invite, add, remove])
  )
}
