import { describe, expect, it } from "vitest"

import { ALPINE, DISTROS, READ_ONLY_USR } from "../desktop/distro-test-support.js"
import {
  answers,
  missing,
  running,
  status,
  url,
  withAnOldRootDesktop,
  world
} from "./desktop-test-support.js"
import { desktopSetupCommand } from "./desktop.js"

const everyPost = ["/packages", "/replace-old", "/start"].map((path) => `POST ${url(path)}`)

describe("codevisor desktop setup on systems without apt", () => {
  it.each(DISTROS)(
    "builds the $manager commands itself on $name and runs them with sudo in the terminal",
    async (distro) => {
      const machine = world(
        {
          [`GET ${url()}`]: answers(
            status({ missing, sudo: "password", packageManager: "apt" }),
            status({ sudo: "password" })
          ),
          [`POST ${url("/start")}`]: answers(running)
        },
        { machine: { files: distro.files, programs: [distro.program, "sudo"] } }
      )
      expect(await desktopSetupCommand(machine.deps)).toBe(0)
      expect(machine.logs).toContain(
        `==> Installing Xfce and TigerVNC with ${distro.manager} (about ${distro.megabytes} MB)`
      )
      expect(machine.interactiveCalls).toEqual(distro.installs.map((command) => `sudo ${command}`))
      expect(machine.httpCalls(`POST ${url("/packages")}`)).toBe(0)
    }
  )

  it.each(DISTROS)(
    "has no root step and no sudo question on $name when every program is there",
    async (distro) => {
      const machine = world(
        {
          [`GET ${url()}`]: answers(status({ sudo: "password" })),
          [`POST ${url("/start")}`]: answers(running)
        },
        { machine: { files: distro.files, programs: [distro.program, "sudo"] } }
      )
      expect(await desktopSetupCommand(machine.deps)).toBe(0)
      expect(machine.interactiveCalls).toEqual([])
      expect(machine.questions).toEqual([])
      expect(machine.httpCalls(`POST ${url("/packages")}`)).toBe(0)
      expect(machine.logs).toEqual([
        "==> Checking this machine",
        `    ${distro.name}, no desktop set up`,
        "==> Starting the desktop as codevisor",
        "==> The desktop is ready. Open it from this machine in Codevisor."
      ])
    }
  )

  it("says once what to install and changes nothing on a system with no package manager it knows", async () => {
    const machine = world(
      { [`GET ${url()}`]: answers(status({ missing: ["Xvnc", "startxfce4", "xclip"] })) },
      {
        machine: {
          ...withAnOldRootDesktop,
          files: { ...withAnOldRootDesktop.files, ...ALPINE },
          programs: ["apk", "sudo"]
        }
      }
    )
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([
      [
        "Codevisor can't install what the desktop needs on Alpine Linux v3.22: it only installs with apt on Debian and Ubuntu, dnf on Fedora, pacman on Arch and zypper on openSUSE.",
        "Install these yourself, then run `codevisor desktop setup` again: Xvnc (TigerVNC 1.12 or newer), startxfce4 (Xfce), xclip."
      ].join("\n")
    ])
    expect(machine.questions).toEqual([])
    expect(machine.interactiveCalls).toEqual([])
    expect(everyPost.map((call) => machine.httpCalls(call))).toEqual([0, 0, 0])
  })

  it.each([
    { name: "has no dnf", programs: ["rpm-ostree", "sudo"], files: {} },
    { name: "keeps its system files read-only", programs: ["dnf", "sudo"], files: READ_ONLY_USR }
  ])("says why it can't use dnf on a Fedora that $name, and runs nothing", async (given) => {
    const fedora = DISTROS[0]!
    const machine = world(
      { [`GET ${url()}`]: answers(status({ missing, sudo: "password" })) },
      { machine: { files: { ...fedora.files, ...given.files }, programs: given.programs } }
    )
    expect(await desktopSetupCommand(machine.deps)).toBe(1)
    expect(machine.errors).toEqual([
      [
        "Codevisor can't install what the desktop needs on Fedora Linux 45 (Server Edition): it would use dnf, which is missing here or can't change this system's files.",
        "Install these yourself, then run `codevisor desktop setup` again: Xvnc (TigerVNC 1.12 or newer), startxfce4 (Xfce)."
      ].join("\n")
    ])
    expect(machine.interactiveCalls).toEqual([])
    expect(everyPost.map((call) => machine.httpCalls(call))).toEqual([0, 0, 0])
  })

  it("still sets the desktop up there once the programs were installed by hand", async () => {
    const machine = world(
      { [`GET ${url()}`]: answers(status()), [`POST ${url("/start")}`]: answers(running) },
      { machine: { files: ALPINE, programs: ["apk", "sudo"] } }
    )
    expect(await desktopSetupCommand(machine.deps)).toBe(0)
    expect(machine.errors).toEqual([])
  })
})
