import { join } from "node:path"

import { DESKTOP_UNIT, unitPath } from "./desktop-layout.js"
import type { DesktopSystem } from "./desktop-system.js"

export type ServiceKind = "systemd-user" | "process"

export interface RunnerCommand {
  readonly program: string
  readonly args: ReadonlyArray<string>
}

export interface DesktopService {
  readonly kind: ServiceKind
  readonly start: () => Promise<void>
  readonly stop: () => Promise<void>
  readonly refresh: () => Promise<void>
  readonly isSetUp: () => boolean
  readonly belongsToAnother: () => boolean
  readonly recentLog: () => Promise<string>
  readonly logHint: string
  readonly startsAtBoot: () => Promise<boolean>
}

export interface ServiceFiles {
  readonly dataDir: string
  readonly logsDir: string
}

export interface DesktopServices {
  readonly current: DesktopService
  readonly other: DesktopService
}

export const desktopServices = async (
  system: DesktopSystem,
  runner: RunnerCommand,
  files: ServiceFiles
): Promise<DesktopServices> => {
  const asAProcess = processService(system, runner, files)
  const reach = await userSystemd(system)
  if (reach !== undefined)
    return { current: systemdService(system, runner, files, reach), other: asAProcess }

  return { current: asAProcess, other: systemdService(system, runner, files, []) }
}

const userSystemd = async (system: DesktopSystem): Promise<ReadonlyArray<string> | undefined> => {
  const answers = async (through: ReadonlyArray<string>): Promise<boolean> =>
    (await asUser(system, through, "systemctl", ["show-environment"])).code === 0
  if (await answers([])) return []

  const runtime = `/run/user/${system.uid}`
  const through = [`XDG_RUNTIME_DIR=${runtime}`]
  const mayBeThere = system.env["XDG_RUNTIME_DIR"] !== runtime && system.exists(runtime)
  return mayBeThere && (await answers(through)) ? through : undefined
}

const asUser = (
  system: DesktopSystem,
  through: ReadonlyArray<string>,
  program: "systemctl" | "journalctl",
  args: ReadonlyArray<string>
) =>
  through.length === 0
    ? system.run(program, ["--user", ...args])
    : system.run("env", [...through, program, "--user", ...args])

export const unitText = (runner: RunnerCommand): string =>
  [
    "[Unit]",
    "Description=Codevisor desktop",
    "",
    "[Service]",
    `ExecStart=${[runner.program, ...runner.args].map(quotedForSystemd).join(" ")}`,
    "Restart=on-failure",
    "RestartSec=2",
    "",
    "[Install]",
    "WantedBy=default.target",
    ""
  ].join("\n")

const logLines = 15
const stopPollMs = 100
const stopPolls = 50

const runnerWords = "desktop\0run"

const isTheRunner = (commandLine: string | undefined): boolean =>
  commandLine?.includes(runnerWords) === true

const quotedForSystemd = (value: string): string =>
  `"${value.replaceAll("\\", "\\\\").replaceAll('"', '\\"').replaceAll("%", "%%").replaceAll("$", "$$$$")}"`

const systemdService = (
  system: DesktopSystem,
  runner: RunnerCommand,
  files: ServiceFiles,
  through: ReadonlyArray<string>
): DesktopService => {
  const systemctl = (...args: string[]) => asUser(system, through, "systemctl", args)
  const ourDataFolder = `"--data-dir" ${quotedForSystemd(files.dataDir)}`
  const written = (): string | undefined => system.readText(unitPath(system))
  const isOurs = (): boolean => written()?.includes(ourDataFolder) === true
  const belongsToAnother = (): boolean => written() !== undefined && !isOurs()
  return {
    kind: "systemd-user",
    start: async () => {
      system.writeText(unitPath(system), unitText(runner))
      await systemctl("daemon-reload")
      await systemctl("enable", DESKTOP_UNIT)
      await systemctl("restart", DESKTOP_UNIT)
    },
    refresh: async () => {
      if (!isOurs() || written() === unitText(runner)) return

      system.writeText(unitPath(system), unitText(runner))
      await systemctl("daemon-reload")
    },
    stop: async () => {
      if (belongsToAnother()) return

      await systemctl("disable", "--now", DESKTOP_UNIT)
      system.remove(unitPath(system))
      await systemctl("daemon-reload")
      await systemctl("reset-failed", DESKTOP_UNIT)
    },
    isSetUp: isOurs,
    belongsToAnother,
    recentLog: async () =>
      (
        await asUser(system, through, "journalctl", [
          "-u",
          DESKTOP_UNIT,
          "-n",
          String(logLines),
          "--no-pager",
          "-o",
          "cat"
        ])
      ).output.trim(),
    logHint: [...through, "journalctl --user -u codevisor-desktop"].join(" "),
    startsAtBoot: async () =>
      (
        await system.run("loginctl", ["show-user", system.account, "--property=Linger", "--value"])
      ).output.trim() === "yes"
  }
}

const processService = (
  system: DesktopSystem,
  runner: RunnerCommand,
  files: ServiceFiles
): DesktopService => {
  const pidFile = join(files.dataDir, "desktop.pid")
  const logFile = join(files.logsDir, "desktop.log")
  const runningPid = (): number | undefined => {
    const pid = Number(system.readText(pidFile)?.trim() ?? "")
    if (!Number.isInteger(pid) || pid <= 0 || !system.processAlive(pid)) return undefined

    return isTheRunner(system.readText(`/proc/${pid}/cmdline`)) ? pid : undefined
  }
  const stop = async (): Promise<void> => {
    const pid = runningPid()
    system.remove(pidFile)
    if (pid === undefined) return

    system.terminate(pid)
    for (let poll = 0; poll < stopPolls && system.processAlive(pid); poll += 1)
      await system.sleep(stopPollMs)
  }
  return {
    kind: "process",
    start: async () => {
      await stop()
      const pid = system.spawnDetached(runner.program, runner.args, logFile)
      if (pid !== undefined) system.writeText(pidFile, `${pid}\n`)
    },
    stop,
    refresh: async () => undefined,
    isSetUp: () => runningPid() !== undefined,
    belongsToAnother: () => false,
    recentLog: async () =>
      (system.readText(logFile) ?? "").trimEnd().split("\n").slice(-logLines).join("\n"),
    logHint: logFile,
    startsAtBoot: async () => false
  }
}
