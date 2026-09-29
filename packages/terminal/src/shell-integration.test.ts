import { homedir } from "node:os"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { makeTerminalManager, type TerminalManagerConfig } from "./index.js"
import { BUNDLED_GHOSTTY_RESOURCES_DIRECTORY } from "./shell-integration.js"
import { makeSpawner, run } from "./test-support.js"

const resources = BUNDLED_GHOSTTY_RESOURCES_DIRECTORY
const integration = join(resources, "shell-integration")

/// The shell launch the manager hands its spawner for `shell` and `args`.
const launch = async (
  shell: string,
  args?: ReadonlyArray<string>,
  env: NodeJS.ProcessEnv = {},
  config: TerminalManagerConfig = {}
) => {
  const spawner = makeSpawner()
  const manager = makeTerminalManager({ env, platform: "linux", spawner, ...config })
  await run(
    manager.createTerminal({
      sessionId: "session",
      cwd: "/tmp",
      cols: 80,
      rows: 24,
      shell,
      ...(args === undefined ? {} : { args })
    })
  )
  const request = spawner.requests[0]!
  return { args: request.args, env: request.env }
}

describe("@codevisor/terminal Ghostty shell integration", () => {
  it("gives macOS shells started without a locale UTF-8, and leaves a chosen one alone", async () => {
    const mac = { platform: "darwin" } as const
    expect((await launch("/bin/zsh", [], {}, mac)).env.LANG).toBe("en_US.UTF-8")
    expect((await launch("/bin/zsh", [], { LANG: "de_DE.UTF-8" }, mac)).env.LANG).toBe(
      "de_DE.UTF-8"
    )
    expect((await launch("/bin/zsh", [], { LC_ALL: "C" }, mac)).env.LANG).toBeUndefined()
    expect((await launch("/bin/zsh", [], { LC_CTYPE: "UTF-8" }, mac)).env.LANG).toBeUndefined()
    // Linux installs differ in which locales exist: nothing is assumed.
    expect((await launch("/bin/zsh")).env.LANG).toBeUndefined()
  })

  it("points zsh at the integration through ZDOTDIR, keeping the user's", async () => {
    const plain = await launch("/bin/zsh", ["-l"])
    expect(plain.args).toEqual(["-l"])
    expect(plain.env).toMatchObject({
      ZDOTDIR: join(integration, "zsh"),
      GHOSTTY_RESOURCES_DIR: resources,
      GHOSTTY_SHELL_FEATURES: "cursor:blink,title"
    })
    expect(plain.env.GHOSTTY_ZSH_ZDOTDIR).toBeUndefined()

    const custom = await launch("/usr/bin/zsh", [], { ZDOTDIR: "/home/me/.config/zsh" })
    expect(custom.env).toMatchObject({
      ZDOTDIR: join(integration, "zsh"),
      GHOSTTY_ZSH_ZDOTDIR: "/home/me/.config/zsh"
    })
  })

  it("starts bash in POSIX mode with ENV loading the integration", async () => {
    const { args, env } = await launch(
      "/usr/bin/bash",
      ["--login", "--norc", "--rcfile", "/home/me/rc", "--noprofile", "-i", "--", "-c", "x"],
      { ENV: "/home/me/env.sh", HOME: "/home/me" }
    )
    // Interpreted flags move into the environment; everything after "--"
    // passes through untouched.
    expect(args).toEqual(["--posix", "--login", "-i", "--", "-c", "x"])
    expect(env).toMatchObject({
      ENV: join(integration, "bash", "ghostty.bash"),
      GHOSTTY_BASH_ENV: "/home/me/env.sh",
      GHOSTTY_BASH_INJECT: "1 --norc --noprofile",
      GHOSTTY_BASH_RCFILE: "/home/me/rc",
      HISTFILE: "/home/me/.bash_history",
      GHOSTTY_BASH_UNEXPORT_HISTFILE: "1"
    })
  })

  it("keeps bash's own history file settings", async () => {
    const custom = await launch("bash", undefined, { HISTFILE: "/tmp/history" })
    expect(custom.args).toEqual(["--posix"])
    expect(custom.env).toMatchObject({ HISTFILE: "/tmp/history", GHOSTTY_BASH_INJECT: "1" })
    expect(custom.env.GHOSTTY_BASH_UNEXPORT_HISTFILE).toBeUndefined()
    expect(custom.env.GHOSTTY_BASH_ENV).toBeUndefined()
    expect(custom.env.GHOSTTY_BASH_RCFILE).toBeUndefined()

    // Without HOME in the environment, the account's home directory.
    expect((await launch("bash")).env.HISTFILE).toBe(join(homedir(), ".bash_history"))
  })

  it.each([
    ["a command", "/usr/bin/bash", ["-lc", "make"]],
    ["POSIX mode", "/usr/bin/bash", ["--posix"]],
    ["macOS's Bash 3.2", "/bin/bash", []]
  ])("launches bash unchanged for %s", async (_case, shell, args) => {
    const { args: launched, env } = await launch(shell, args, {}, { platform: "darwin" })
    expect(launched).toEqual(args)
    expect(env.ENV).toBeUndefined()
    expect(env.GHOSTTY_BASH_INJECT).toBeUndefined()
  })

  it.each([
    ["fish", undefined, `${integration}:/usr/local/share:/usr/share`],
    ["elvish", "", integration],
    ["fish", "/opt/share", `${integration}:/opt/share`]
  ])("prepends the integration to %s's XDG_DATA_DIRS", async (shell, current, expected) => {
    const { args, env } = await launch(
      `/usr/bin/${shell}`,
      ["-l"],
      current === undefined ? {} : { XDG_DATA_DIRS: current }
    )
    expect(args).toEqual(["-l"])
    expect(env).toMatchObject({
      XDG_DATA_DIRS: expected,
      GHOSTTY_SHELL_INTEGRATION_XDG_DIR: integration
    })
  })

  it("has nushell use the integration module", async () => {
    const { args, env } = await launch("/usr/bin/nu", ["--login", "-l", "--", "-c", "x"])
    expect(args).toEqual(["--execute", "use ghostty *", "--login", "-l", "--", "-c", "x"])
    expect(env.GHOSTTY_SHELL_INTEGRATION_XDG_DIR).toBe(integration)

    // Commands and the language server keep their arguments; the module
    // stays importable by hand.
    for (const flags of [["-c", "ls"], ["--command", "ls"], ["--lsp"]]) {
      const unchanged = await launch("nu", flags)
      expect(unchanged.args).toEqual(flags)
      expect(unchanged.env.GHOSTTY_SHELL_INTEGRATION_XDG_DIR).toBe(integration)
    }
  })

  it("launches other shells, and shells whose scripts are missing, unchanged", async () => {
    const other = await launch("/bin/sh", ["-l"])
    expect(other.args).toEqual(["-l"])
    expect(other.env.ZDOTDIR).toBeUndefined()

    const missing = { ghosttyResourcesDirectory: "/codevisor-test/missing" }
    for (const shell of ["zsh", "bash", "fish", "nu"]) {
      const { args, env } = await launch(shell, ["-l"], { ZDOTDIR: "/home/me" }, missing)
      expect(args, shell).toEqual(["-l"])
      expect(env, shell).toMatchObject({ ZDOTDIR: "/home/me" })
      expect(env.ENV ?? env.XDG_DATA_DIRS, shell).toBeUndefined()
    }
  })
})
