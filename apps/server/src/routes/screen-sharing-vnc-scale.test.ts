import { describe, expect, it } from "vitest"

import {
  type ScalerCommands,
  systemScalerCommands,
  xfceScaler
} from "./screen-sharing-vnc-scale.js"
import { vncScreenSharing } from "./screen-sharing-vnc.js"

/// A desktop session in memory: xfconf values, and every command run, in order.
const fakeSession = (
  options: {
    panel?: string
    bus?: string
    scale?: string
    theme?: string
    /// xfconf reads fail (a key that was never set) and `xfdesktop --quit` fails (not running).
    failReads?: boolean
  } = {}
) => {
  const values = new Map<string, string>([
    ["xsettings /Gdk/WindowScalingFactor", options.scale ?? "1"],
    ["xfwm4 /general/theme", options.theme ?? "Default"]
  ])
  const log: string[] = []
  const commands: ScalerCommands = {
    run: async (command, args, env) => {
      log.push(
        `${command} ${args.join(" ")}${env.DISPLAY ? ` [${env.DISPLAY} ${env.DBUS_SESSION_BUS_ADDRESS}]` : ""}`
      )
      if (command === "pgrep") {
        if (options.panel === "") throw new Error("exit 1")
        return `${options.panel ?? "4242"}\n`
      }
      if (command === "xfdesktop" && options.failReads) throw new Error("not running")
      if (command === "xfconf-query") {
        const key = `${args[1]} ${args[3]}`
        const set = args.indexOf("-s")
        if (set < 0 && options.failReads) throw new Error("Property does not exist")
        if (set >= 0) values.set(key, args[set + 1] ?? "")
        return set >= 0 ? "" : `${values.get(key) ?? ""}\n`
      }
      return ""
    },
    spawnDetached: (command, args, env) =>
      log.push(
        `spawn ${command} ${args.join(" ")}[${env.DISPLAY} ${env.DBUS_SESSION_BUS_ADDRESS}]`
      ),
    environ: (pid) =>
      pid === (options.panel ?? "4242")
        ? `HOME=/root\0DBUS_SESSION_BUS_ADDRESS=${options.bus ?? "unix:path=/tmp/dbus-session"}\0`
        : ""
  }
  return { commands, values, log }
}

describe("Xfce desktop scale (851-2339)", () => {
  it("sets 2× through the session's own D-Bus, with the 2× borders, and restarts the desktop once", async () => {
    const session = fakeSession()
    await xfceScaler(1, session.commands)(2)
    expect(session.values.get("xsettings /Gdk/WindowScalingFactor")).toBe("2")
    expect(session.values.get("xfwm4 /general/theme")).toBe("Default-xhdpi")
    // Every desktop command carries the session's display and bus, never this process's.
    for (const line of session.log.filter((entry) => !entry.startsWith("pgrep")))
      expect(line).toContain("[:1 unix:path=/tmp/dbus-session]")
    expect(session.log.filter((entry) => entry.startsWith("spawn xfdesktop"))).toHaveLength(1)
    // Already 2×: nothing restarts.
    session.log.length = 0
    await xfceScaler(1, session.commands)(2)
    expect(session.log.some((entry) => entry.includes("xfdesktop"))).toBe(false)
  })

  it("goes back to 1× and undoes only its own theme, never one the user picked", async () => {
    const own = fakeSession({ scale: "2", theme: "Default-xhdpi" })
    await xfceScaler(1, own.commands)(1)
    expect(own.values.get("xsettings /Gdk/WindowScalingFactor")).toBe("1")
    expect(own.values.get("xfwm4 /general/theme")).toBe("Default")
    const picked = fakeSession({ scale: "2", theme: "Greybird" })
    await xfceScaler(1, picked.commands)(1)
    expect(picked.values.get("xfwm4 /general/theme")).toBe("Greybird")
  })

  it("treats unset properties as 1× and the default theme, and a desktop that isn't running as fine", async () => {
    const session = fakeSession({ failReads: true })
    await xfceScaler(1, session.commands)(2)
    expect(session.values.get("xsettings /Gdk/WindowScalingFactor")).toBe("2")
    expect(session.values.get("xfwm4 /general/theme")).toBe("Default-xhdpi")
    expect(session.log.filter((entry) => entry.startsWith("spawn xfdesktop"))).toHaveLength(1)
  })

  it("runs real commands with the session's environment", async () => {
    expect(
      await systemScalerCommands.run("sh", ["-c", 'printf "%s" "$CODEVISOR_SCALE_TEST"'], {
        CODEVISOR_SCALE_TEST: "yes"
      })
    ).toBe("yes")
    await expect(systemScalerCommands.run("sh", ["-c", "exit 3"], {})).rejects.toThrow()
    expect(() => systemScalerCommands.spawnDetached("true", [], {})).not.toThrow()
    expect(() => systemScalerCommands.environ("999999999")).toThrow()
  })

  it("fails clearly when the session isn't running or has no bus", async () => {
    await expect(xfceScaler(1, fakeSession({ panel: "" }).commands)(2)).rejects.toThrow(
      "The desktop session isn't running"
    )
    await expect(xfceScaler(1, fakeSession({ bus: "" }).commands)(2)).rejects.toThrow(
      "no D-Bus address"
    )
  })

  it("advertises the scales and default size, and answers setScale only with a scaler", async () => {
    const config = {
      port: 5901,
      name: "Desktop",
      desktop: "xfce" as const,
      defaultWidth: 1440,
      defaultHeight: 900
    }
    const request = {
      version: 1 as const,
      workspaceId: "w",
      paneId: "p",
      viewerId: "v",
      displayId: "vnc:5901"
    }
    const scales: (1 | 2)[] = []
    const provider = vncScreenSharing(config, async (scale) => {
      scales.push(scale)
    })
    const capabilities = await provider({ ...request, operation: "capabilities" })
    expect(capabilities.displays[0]).toMatchObject({
      scales: [1, 2],
      defaultWidth: 1440,
      defaultHeight: 900
    })
    expect((await provider({ ...request, operation: "setScale", scale: 2 })).status).toBe("ok")
    expect(scales).toEqual([2])
    expect(
      (await provider({ ...request, operation: "setScale", displayId: "vnc:1", scale: 2 })).status
    ).toBe("error")
    expect((await provider({ ...request, operation: "setScale" })).status).toBe("error")
    const failing = vncScreenSharing(config, async () => {
      throw new Error("The desktop session isn't running")
    })
    expect(await failing({ ...request, operation: "setScale", scale: 1 })).toMatchObject({
      status: "error",
      message: "The desktop session isn't running"
    })
    const odd = vncScreenSharing(config, async () => {
      throw "not an Error"
    })
    expect(await odd({ ...request, operation: "setScale", scale: 2 })).toMatchObject({
      status: "error",
      message: "The desktop's scale couldn't be set"
    })
    const plain = vncScreenSharing({ port: 5901, name: "Desktop" })
    expect(
      (await plain({ ...request, operation: "capabilities" })).displays[0]?.scales
    ).toBeUndefined()
    expect((await plain({ ...request, operation: "setScale", scale: 2 })).status).toBe(
      "unsupported"
    )
  })
})
