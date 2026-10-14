import { execFile, spawn } from "node:child_process"
import { readFileSync } from "node:fs"

export type VNCDesktopScaler = (scale: 1 | 2) => Promise<void>

export interface ScalerCommands {
  readonly run: (
    command: string,
    args: readonly string[],
    env: Record<string, string>
  ) => Promise<string>
  readonly spawnDetached: (
    command: string,
    args: readonly string[],
    env: Record<string, string>
  ) => Promise<void>
  readonly environ: (pid: string) => string
}

export const systemScalerCommands: ScalerCommands = {
  run: (command, args, env) =>
    new Promise((resolve, reject) =>
      execFile(
        command,
        [...args],
        { env: { ...process.env, ...env }, timeout: 10_000 },
        (error, stdout) => (error ? reject(error) : resolve(String(stdout)))
      )
    ),
  spawnDetached: (command, args, env) =>
    new Promise((resolve, reject) => {
      const child = spawn(command, [...args], {
        env: { ...process.env, ...env },
        detached: true,
        stdio: "ignore"
      })
      child.unref()
      child.on("error", reject)
      child.once("spawn", () => resolve())
    }),
  environ: (pid) => readFileSync(`/proc/${pid}/environ`, "utf8")
}

export const xfceScaler =
  (display: number, commands: ScalerCommands): VNCDesktopScaler =>
  async (scale) => {
    const panel = (await commands.run("pgrep", ["-o", "xfce4-panel"], {}).catch(() => "")).trim()
    if (panel === "") throw new Error("The desktop session isn't running")
    const bus = commands
      .environ(panel)
      .split("\0")
      .find((entry) => entry.startsWith("DBUS_SESSION_BUS_ADDRESS="))
      ?.slice("DBUS_SESSION_BUS_ADDRESS=".length)
    if (bus === undefined || bus === "") throw new Error("The desktop session has no D-Bus address")
    const env = { DISPLAY: `:${display}`, DBUS_SESSION_BUS_ADDRESS: bus }
    const xfconf = (...args: string[]) => commands.run("xfconf-query", args, env)
    const previous = (
      await xfconf("-c", "xsettings", "-p", "/Gdk/WindowScalingFactor").catch(() => "1")
    ).trim()
    await xfconf(
      "-c",
      "xsettings",
      "-p",
      "/Gdk/WindowScalingFactor",
      "-n",
      "-t",
      "int",
      "-s",
      String(scale)
    )
    const theme = (await xfconf("-c", "xfwm4", "-p", "/general/theme").catch(() => "")).trim()
    if (scale === 2 && theme !== "Default-xhdpi")
      await xfconf(
        "-c",
        "xfwm4",
        "-p",
        "/general/theme",
        "-n",
        "-t",
        "string",
        "-s",
        "Default-xhdpi"
      )
    if (scale === 1 && theme === "Default-xhdpi")
      await xfconf("-c", "xfwm4", "-p", "/general/theme", "-n", "-t", "string", "-s", "Default")
    if (previous !== String(scale)) {
      await commands.run("xfdesktop", ["--quit"], env).catch(() => "")
      await commands.spawnDetached("xfdesktop", [], env)
    }
  }
