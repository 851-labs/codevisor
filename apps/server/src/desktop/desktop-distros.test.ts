import { describe, expect, it } from "vitest"

import { AS_ROOT, EVERY_PROGRAM, fakeMachine, settled } from "./desktop-test-support.js"
import { DISTROS, UNSERVED } from "./distro-test-support.js"

const sixPrograms = EVERY_PROGRAM.filter((program) => program !== "apt-get" && program !== "sudo")

describe("installing the desktop's packages with each system's own package manager", () => {
  it("leaves no system's root step without a time limit that stops everything the step started", async () => {
    const machine = fakeMachine({ programs: ["dnf"], files: DISTROS[0]!.files, uid: 0 })
    await machine.manager.installPackages()
    await settled(machine.manager)
    expect(machine.commands.filter((line) => line.includes("dnf install"))).toEqual(
      DISTROS[0]!.installs.map((command) => `timeout --kill-after=30 1200 ${command}`)
    )
  })

  it.each(DISTROS)("uses $manager on $name", async (distro) => {
    const machine = fakeMachine({ programs: [distro.program, "sudo"], files: distro.files })
    expect(await machine.manager.status()).toMatchObject({
      system: distro.name,
      packageManager: distro.manager,
      sudo: "passwordless"
    })

    await machine.manager.installPackages()
    expect(await settled(machine.manager)).not.toHaveProperty("failure")
    const asRoot = machine.commands.filter((line) => line.startsWith("sudo -n "))
    expect(asRoot.filter((line) => line !== "sudo -n true")).toEqual(
      distro.installs.map((command) => `${AS_ROOT} ${command}`)
    )
  })

  it.each(UNSERVED)("names no package manager on $name", async ({ files, programs }) => {
    const machine = fakeMachine({ programs, files })
    const status = await machine.manager.status()
    expect(status.missing).toHaveLength(6)
    expect(status).not.toHaveProperty("packageManager")
    await expect(machine.manager.installPackages()).rejects.toMatchObject({ status: 501 })
    expect(machine.commands.filter((line) => line.startsWith(AS_ROOT))).toEqual([])
  })

  it.each(DISTROS)(
    "has no root step on $name when every program is already there",
    async (distro) => {
      const machine = fakeMachine({
        programs: [...sixPrograms, distro.program, "sudo"],
        files: distro.files
      })
      expect(await machine.manager.status()).toMatchObject({ missing: [] })
      expect(await machine.manager.start()).toMatchObject({ state: "running", missing: [] })
      expect(await machine.manager.status()).not.toHaveProperty("sudo")
      expect(machine.commands.filter((line) => line.startsWith("sudo"))).toEqual([])
      expect(machine.commands.filter((line) => line.includes(distro.program))).toEqual([])
    }
  )
})
