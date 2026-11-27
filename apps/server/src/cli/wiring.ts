import { hostname } from "node:os"
import { text } from "node:stream/consumers"

import { NodeServices } from "@effect/platform-node"
import { Effect, Option } from "effect"
import { Argument, Command, Flag, Prompt } from "effect/unstable/cli"

import { authLoginCommand, authLogoutCommand, authStatusCommand } from "./cloud-auth.js"
import { screenRemoveCommand, screenSetupCommand } from "./desktop-screen.js"
import {
  type DesktopCliDeps,
  desktopRemoveCommand,
  desktopSetupCommand,
  desktopStatusCommand
} from "./desktop.js"
import { flagsListCommand, flagsSetCommand } from "./feature-flags.js"
import {
  machinesAddCommand,
  machinesInviteCommand,
  machinesListCommand,
  machinesRemoveCommand
} from "./machines.js"
import type { CliDeps } from "./support.js"

export const portFlag = Flag.integer("port").pipe(
  Flag.withDescription(
    "Server port (defaults to CODEVISOR_PORT, the systemd unit, the port the server last used, or 49361)"
  ),
  Flag.optional
)

export const optionalString = (name: string, description: string) =>
  Flag.string(name).pipe(Flag.withDescription(description), Flag.optional)

export const runPrompt = async <A>(prompt: Prompt.Prompt<A>): Promise<A> => {
  try {
    return await Effect.runPromise(Prompt.run(prompt).pipe(Effect.provide(NodeServices.layer)))
  } catch {
    console.error("\nCancelled.")
    return process.exit(130)
  }
}

export const runPromptOr = async <A>(prompt: Prompt.Prompt<A>, whenCancelled: A): Promise<A> => {
  try {
    return await Effect.runPromise(Prompt.run(prompt).pipe(Effect.provide(NodeServices.layer)))
  } catch {
    return whenCancelled
  }
}

type RunCli = (command: (deps: CliDeps) => Promise<number>) => Effect.Effect<void>

const readStdin = async (): Promise<string> => (await text(process.stdin)).trim()

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
        Effect.promise(async () => {
          if (Option.isSome(invite) && invite.value === "-") return readStdin()
          return Option.getOrUndefined(invite)
        }),
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
      desktop: Flag.boolean("desktop").pipe(
        Flag.withDescription(
          "Also set up a desktop on the new machine (Linux), to watch and control from Codevisor"
        )
      ),
      port: portFlag
    },
    ({ ssh, name, sshPort, desktop: withDesktop, port }) =>
      runCli((deps) =>
        machinesAddCommand(deps, {
          ssh,
          port: Option.getOrUndefined(port),
          ...(Option.isSome(name) ? { name: name.value } : {}),
          ...(Option.isSome(sshPort) ? { sshPort: sshPort.value } : {}),
          ...(withDesktop ? { desktop: true } : {})
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

const yes = (description: string) =>
  Flag.boolean("yes").pipe(Flag.withAlias("y"), Flag.withDescription(description))

const screen = (description: string) =>
  Flag.boolean("screen").pipe(Flag.withDescription(description))

export const makeDesktopCommand = (
  runDesktopCli: (command: (deps: DesktopCliDeps) => Promise<number>) => Effect.Effect<void>,
  runInForeground: (dataDir: string | undefined) => Effect.Effect<void>
) => {
  const run = Command.make(
    "run",
    { dataDir: optionalString("data-dir", "The server's data folder (default ~/.codevisor/data)") },
    ({ dataDir }) => runInForeground(Option.getOrUndefined(dataDir))
  ).pipe(Command.withDescription("Run the desktop in the foreground; its boot service uses this"))

  const setup = Command.make(
    "setup",
    {
      port: portFlag,
      yes: yes(
        "Answer yes to setup's questions: replacing an older root desktop, or a desktop config Codevisor didn't write"
      ),
      screen: screen(
        "Share this machine's real screen instead: the session the server's account is logged in to at the monitor"
      )
    },
    ({ port, yes: agreed, screen: real }) =>
      runDesktopCli((deps) => {
        const options = { port: Option.getOrUndefined(port), yes: agreed }
        return real ? screenSetupCommand(deps, options) : desktopSetupCommand(deps, options)
      })
  ).pipe(
    Command.withDescription(
      "Set up a desktop on this Linux machine that runs as the server's account and can be viewed from Codevisor, or share its real screen with --screen"
    )
  )

  const status = Command.make("status", { port: portFlag }, ({ port }) =>
    runDesktopCli((deps) => desktopStatusCommand(deps, { port: Option.getOrUndefined(port) }))
  ).pipe(
    Command.withDescription(
      "Show whether this machine's desktop is set up and running, and whether its real screen is shared"
    )
  )

  const remove = Command.make(
    "remove",
    {
      port: portFlag,
      yes: yes(
        "Don't ask before removing the desktop, or before unsharing one Codevisor didn't set up"
      ),
      screen: screen("Stop sharing this machine's real screen instead; nothing on it closes")
    },
    ({ port, yes: agreed, screen: real }) =>
      runDesktopCli((deps) => {
        const options = { port: Option.getOrUndefined(port), yes: agreed }
        return real ? screenRemoveCommand(deps, options) : desktopRemoveCommand(deps, options)
      })
  ).pipe(
    Command.withDescription(
      "Stop this machine's desktop, closing everything open in it, or stop sharing its real screen with --screen"
    )
  )

  return Command.make("desktop").pipe(
    Command.withDescription("Set up, check, or remove this Linux machine's desktop"),
    Command.withSubcommands([setup, status, remove, run])
  )
}

export const makeFlagsCommand = (runCli: RunCli) => {
  const list = Command.make("list", { port: portFlag }, ({ port }) =>
    runCli((deps) => flagsListCommand(deps, { port: Option.getOrUndefined(port) }))
  ).pipe(Command.withDescription("List experimental features and whether each is on"))

  const flagArgument = Argument.string("flag").pipe(
    Argument.withDescription("The flag's id (see codevisor flags list)")
  )

  const toggle = (name: string, enabled: boolean, description: string) =>
    Command.make(name, { flag: flagArgument, port: portFlag }, ({ flag, port }) =>
      runCli((deps) => flagsSetCommand(deps, { flag, enabled, port: Option.getOrUndefined(port) }))
    ).pipe(Command.withDescription(description))

  return Command.make("flags").pipe(
    Command.withDescription(
      "Turn experimental features on or off; the Codevisor apps sync them to your other machines"
    ),
    Command.withSubcommands([
      list,
      toggle("enable", true, "Turn an experimental feature on"),
      toggle("disable", false, "Turn an experimental feature off")
    ])
  )
}
