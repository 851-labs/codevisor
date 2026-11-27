import { describe, expect, it } from "vitest"

import { CONFIG, EVERY_PROGRAM } from "./desktop-test-support.js"
import { refusal, setUp, workstation } from "./screen-share-test-support.js"

describe("telling the person at the screen that someone is viewing it", () => {
  const notification =
    "env DISPLAY=:0 XAUTHORITY=/home/codevisor/.Xauthority DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus notify-send -a Codevisor Codevisor Someone started viewing this screen."

  it("shows a notification in that session, and not again for every reconnect", async () => {
    const machine = workstation({ files: { [CONFIG]: setUp } })
    machine.logIn()
    const shown = () => machine.commands.filter((line) => line === notification)

    machine.screen.viewerJoined()
    machine.screen.viewerJoined()
    expect(shown()).toHaveLength(1)

    machine.clock.now += 30_000
    machine.screen.viewerJoined()
    expect(shown()).toHaveLength(2)
  })

  it("shows nothing when nobody is logged in", () => {
    const machine = workstation({ files: { [CONFIG]: setUp } })

    machine.screen.viewerJoined()

    expect(machine.commands).toEqual([])
  })
})

describe("installing what sharing the screen needs", () => {
  const install =
    /^sudo -n timeout .* apt-get .* install -y -q --no-install-recommends tigervnc-scraping-server libnotify-bin$/

  it("installs the scraping server and the notifier as root, and says it is busy meanwhile", async () => {
    const installed = Promise.withResolvers<void>()
    const machine = workstation({
      programs: [...EVERY_PROGRAM],
      holds: { prefix: "sudo -n timeout", until: installed.promise }
    })

    expect(await machine.screen.installPackages()).toMatchObject({ busy: "Installing packages" })

    installed.resolve()
    expect(await machine.settled()).not.toHaveProperty("failure")
    expect(machine.commands).toContainEqual(expect.stringMatching(install))
  })

  it("starts one install for two requests that come at once", async () => {
    const installed = Promise.withResolvers<void>()
    const machine = workstation({
      programs: [...EVERY_PROGRAM],
      holds: { prefix: "sudo -n timeout", until: installed.promise }
    })

    await Promise.all([machine.screen.installPackages(), machine.screen.installPackages()])
    installed.resolve()
    await machine.settled()

    expect(machine.commands.filter((line) => install.test(line))).toHaveLength(1)
  })

  it("keeps why an install failed until what was missing is there", async () => {
    const machine = workstation({ programs: [...EVERY_PROGRAM], failing: ["sudo -n timeout"] })

    await machine.screen.installPackages()

    expect(await machine.settled()).toMatchObject({ failure: "Installing packages failed:\n" })
  })

  it("leaves it to an administrator when the server's account needs a password", async () => {
    const machine = workstation({ programs: [...EVERY_PROGRAM, "sudo"], failing: ["sudo -n true"] })

    expect(await refusal(machine.screen.installPackages())).toMatchObject({ status: 403 })
    expect(await machine.screen.status()).toMatchObject({ sudo: "password" })
  })
})
