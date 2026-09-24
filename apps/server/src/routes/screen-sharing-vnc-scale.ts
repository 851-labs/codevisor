import { execFile, spawn } from "node:child_process"
import { readFileSync } from "node:fs"

/// Sets a VNC desktop's UI scale (851-2339), for a viewer whose remote desktop
/// has a pixel per device pixel (Dynamic Resolution, 851-2340): at 2× the UI
/// stays its usual size and turns sharp.
export type VNCDesktopScaler = (scale: 1 | 2) => Promise<void>

/// What the scaler runs; the tests supply a fake.
export interface ScalerCommands {
  /// Runs a command to completion; rejects when it exits non-zero.
  readonly run: (
    command: string,
    args: readonly string[],
    env: Record<string, string>
  ) => Promise<string>
  /// Starts a command detached from the server (it outlives the request).
  readonly spawnDetached: (
    command: string,
    args: readonly string[],
    env: Record<string, string>
  ) => void
  /// A process's environment, NUL-separated (`/proc/<pid>/environ`).
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
  spawnDetached: (command, args, env) => {
    spawn(command, [...args], {
      env: { ...process.env, ...env },
      detached: true,
      stdio: "ignore"
    }).unref()
  },
  environ: (pid) => readFileSync(`/proc/${pid}/environ`, "utf8")
}

/// Xfce on X display `display`, as scripts/vnc-desktop.sh sets it up (851-2330):
/// settings go through the session's own D-Bus (the panel's), never a second
/// xfconfd; window borders follow (Default-xhdpi at 2×; back to Default only
/// if it was the 2× theme); xfdesktop restarts when the scale changed, since it
/// reads the scale at start. Apps already open keep theirs until reopened.
export const xfceScaler =
  (display: number, commands: ScalerCommands = systemScalerCommands): VNCDesktopScaler =>
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
      commands.spawnDetached("xfdesktop", [], env)
    }
  }
