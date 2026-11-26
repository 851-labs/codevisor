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
  readonly isSetUp: () => boolean
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
  const underSystemd = systemdService(system, runner)
  const asAProcess = processService(system, runner, files)
  const hasUserSystemd = (await system.run("systemctl", ["--user", "show-environment"])).code === 0
  if (hasUserSystemd) return { current: underSystemd, other: asAProcess }

  return { current: asAProcess, other: underSystemd }
}

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

const systemdService = (system: DesktopSystem, runner: RunnerCommand): DesktopService => {
  const systemctl = (...args: string[]) => system.run("systemctl", ["--user", ...args])
  return {
    kind: "systemd-user",
    start: async () => {
      system.writeText(unitPath(system), unitText(runner))
      await systemctl("daemon-reload")
      await systemctl("enable", DESKTOP_UNIT)
      await systemctl("restart", DESKTOP_UNIT)
    },
    stop: async () => {
      await systemctl("disable", "--now", DESKTOP_UNIT)
      system.remove(unitPath(system))
      await systemctl("daemon-reload")
      await systemctl("reset-failed", DESKTOP_UNIT)
    },
    isSetUp: () => system.exists(unitPath(system)),
    recentLog: async () =>
      (
        await system.run("journalctl", [
          "--user",
          "-u",
          DESKTOP_UNIT,
          "-n",
          String(logLines),
          "--no-pager",
          "-o",
          "cat"
        ])
      ).output.trim(),
    logHint: "journalctl --user -u codevisor-desktop",
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
    isSetUp: () => runningPid() !== undefined,
    recentLog: async () =>
      (system.readText(logFile) ?? "").trimEnd().split("\n").slice(-logLines).join("\n"),
    logHint: logFile,
    startsAtBoot: async () => false
  }
}
