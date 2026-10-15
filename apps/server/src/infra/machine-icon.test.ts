import { describe, expect, it } from "vitest"

import { guessMachineIcon, macIconForModel } from "./machine-icon.js"

const hardware = (machineName: string) =>
  JSON.stringify({ SPHardwareDataType: [{ machine_name: machineName }] })

const missingDirectory = () => Promise.reject(new Error("ENOENT"))

describe("macIconForModel", () => {
  it.each([
    ["MacBook Pro", "laptopcomputer"],
    ["MacBook Air", "laptopcomputer"],
    ["Mac mini", "macmini"],
    ["Mac Studio", "macstudio"],
    ["Mac Pro", "macpro.gen3"],
    ["iMac", "desktopcomputer"],
    ["", "desktopcomputer"]
  ])("guesses %j as %s", (model, icon) => {
    expect(macIconForModel(model)).toBe(icon)
  })
})

describe("guessMachineIcon", () => {
  it("reads the Mac model from system_profiler", async () => {
    const calls: Array<readonly [string, ReadonlyArray<string>]> = []
    const icon = await guessMachineIcon({
      platform: "darwin",
      run: async (file, args) => {
        calls.push([file, args])
        return hardware("Mac Studio")
      }
    })
    expect(icon).toBe("macstudio")
    expect(calls).toEqual([["/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"]]])
  })

  it.each([
    ["the command fails", () => Promise.reject(new Error("no system_profiler"))],
    ["the output is not JSON", () => Promise.resolve("not json")],
    ["the output has no hardware overview", () => Promise.resolve("{}")]
  ])("falls back to a desktop Mac when %s", async (_case, run) => {
    expect(await guessMachineIcon({ platform: "darwin", run })).toBe("desktopcomputer")
  })

  it.each([
    [["AC", "BAT0"], "laptopcomputer"],
    [["AC"], "server.rack"]
  ])("guesses Linux with power supplies %j as %s", async (supplies, icon) => {
    expect(await guessMachineIcon({ platform: "linux", listDirectory: async () => supplies })).toBe(
      icon
    )
  })

  it("treats Linux without a power supply directory as a server", async () => {
    expect(await guessMachineIcon({ platform: "linux", listDirectory: missingDirectory })).toBe(
      "server.rack"
    )
  })

  it("guesses a PC on Windows and nothing elsewhere", async () => {
    expect(await guessMachineIcon({ platform: "win32" })).toBe("pc")
    expect(await guessMachineIcon({ platform: "freebsd" })).toBeUndefined()
  })
})
