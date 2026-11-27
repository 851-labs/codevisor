import { describe, expect, it } from "vitest"

import { ALPINE } from "../desktop/distro-test-support.js"
import { offerDesktop } from "./desktop-offer.js"
import { answers, missing, running, status, url, world } from "./desktop-test-support.js"

const question = "Set up a desktop?"
const everyPost = ["/packages", "/replace-old", "/start"].map((path) => `POST ${url(path)}`)
const posts = (machine: ReturnType<typeof world>) =>
  everyPost.map((call) => machine.httpCalls(call))

const dataFolder = "/home/user/.codevisor/data"

const answering = (machine: ReturnType<typeof world>, said: boolean | undefined) => ({
  ...machine.deps,
  answer: (asked: string) => {
    machine.questions.push(asked)
    return Promise.resolve(said)
  }
})

describe("the desktop question in codevisor setup", () => {
  it("is asked on a Linux machine without a desktop, and No leaves everything alone", async () => {
    const machine = world({ [`GET ${url()}`]: answers(status({ missing })) })
    await offerDesktop(answering(machine, false))
    expect(machine.questions).toEqual([question])
    expect(machine.logs).toEqual([
      "",
      "This machine can have a desktop that you watch and control from Codevisor.",
      "No desktop set up. Add one any time with: codevisor desktop setup"
    ])
    expect(machine.errors).toEqual([])
    expect(posts(machine)).toEqual([0, 0, 0])
  })

  it("runs the same setup as codevisor desktop setup on Yes", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(status({ missing }), status({ missing }), status()),
      [`POST ${url("/packages")}`]: answers(status()),
      [`POST ${url("/start")}`]: answers(running)
    })
    await offerDesktop(answering(machine, true))
    expect(machine.questions).toEqual([question])
    expect(machine.logs.slice(2)).toEqual([
      "==> Checking this machine",
      "    Ubuntu 24.04.5 LTS, no desktop set up",
      "==> Installing Xfce and TigerVNC with apt (about 640 MB)",
      "==> Starting the desktop as codevisor",
      "==> The desktop is ready. Open it from this machine in Codevisor."
    ])
    expect(machine.errors).toEqual([])
    expect(posts(machine)).toEqual([1, 0, 1])
  })

  it("says in one more line how to try again when the setup it ran fails, and doesn't fail itself", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(status()),
      [`POST ${url("/start")}`]: [{ status: 500, body: { error: "The desktop didn't start." } }]
    })
    await expect(offerDesktop(answering(machine, true))).resolves.toBeUndefined()
    expect(machine.errors.at(-1)).toBe(
      "The desktop wasn't set up. Try again with: codevisor desktop setup"
    )
    expect(machine.errors).toHaveLength(2)
  })

  it("survives a setup that breaks instead of answering", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(status({ missing, sudo: "password" }))
    })
    const deps = {
      ...answering(machine, true),
      execInteractive: () => Promise.reject(new Error("the terminal went away"))
    }
    await expect(offerDesktop(deps)).resolves.toBeUndefined()
    expect(machine.errors).toEqual([
      "The desktop wasn't set up. Try again with: codevisor desktop setup"
    ])
  })

  it.each([
    { name: "nobody is at a terminal", http: answers(status()), terminal: { interactive: false } },
    { name: "a desktop is already running", http: answers(running), terminal: {} },
    {
      name: "a desktop is set up but down",
      http: answers(status({ state: "stopped", problem: "the desktop's session isn't up" })),
      terminal: {}
    },
    { name: "the server doesn't answer about desktops", http: [undefined], terminal: {} },
    {
      name: "a root step is needed and the account has no sudo",
      http: answers(status({ missing, sudo: "none" })),
      terminal: {}
    },
    {
      name: "setup couldn't install what is missing on this system",
      http: answers(status({ missing })),
      terminal: { machine: { files: ALPINE, programs: ["apk", "sudo"] } }
    }
  ])("isn't asked, and says nothing, when $name", async ({ http, terminal }) => {
    const machine = world({ [`GET ${url()}`]: http }, terminal)
    await offerDesktop(answering(machine, true))
    expect(machine.questions).toEqual([])
    expect(machine.logs).toEqual([])
    expect(machine.errors).toEqual([])
    expect(posts(machine)).toEqual([0, 0, 0])
  })

  it("isn't asked again after a No, on later runs of setup", async () => {
    const machine = world({ [`GET ${url()}`]: answers(status({ missing })) })
    await offerDesktop(answering(machine, false))
    expect(machine.files.has(`${dataFolder}/desktop-declined`)).toBe(true)
    await offerDesktop(answering(machine, false))
    expect(machine.questions).toEqual([question])
    expect(machine.logs).toHaveLength(3)
  })

  it("leaves nothing behind and says nothing more when the question is cancelled or can't be read", async () => {
    const machine = world({ [`GET ${url()}`]: answers(status({ missing })) })
    await offerDesktop(answering(machine, undefined))
    await offerDesktop(answering(machine, undefined))
    expect(machine.questions).toEqual([question, question])
    expect(machine.files.size).toBe(0)
    expect(machine.logs.filter((line) => line.includes("No desktop"))).toEqual([])
    expect(machine.errors).toEqual([])
    expect(posts(machine)).toEqual([0, 0, 0])
  })

  it("notes a Yes whose setup failed, for the installer that ran it, without remembering a No", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(status()),
      [`POST ${url("/start")}`]: [{ status: 500, body: { error: "The desktop didn't start." } }]
    })
    await offerDesktop(answering(machine, true))
    expect([...machine.files.keys()]).toEqual([`${dataFolder}/desktop-setup-failed`])
  })

  it("is asked again after a Yes whose setup failed", async () => {
    const machine = world({
      [`GET ${url()}`]: answers(status()),
      [`POST ${url("/start")}`]: [{ status: 500, body: { error: "The desktop didn't start." } }]
    })
    await offerDesktop(answering(machine, true))
    await offerDesktop(answering(machine, true))
    expect(machine.questions).toEqual([question, question])
  })

  it("still says No was heard when the answer can't be written down", async () => {
    const machine = world({ [`GET ${url()}`]: answers(status()) })
    const deps = {
      ...answering(machine, false),
      writeTextFile: () => {
        throw new Error("read-only data folder")
      }
    }
    await expect(offerDesktop(deps)).resolves.toBeUndefined()
    expect(machine.logs.at(-1)).toBe(
      "No desktop set up. Add one any time with: codevisor desktop setup"
    )
  })

  it("is asked when the desktop that is shared wasn't set up by Codevisor, which setup offers to replace", async () => {
    const theirs = status({ state: "running", display: 1, unmanaged: true })
    const machine = world({ [`GET ${url()}`]: answers(theirs) })
    await offerDesktop(answering(machine, false))
    expect(machine.questions).toEqual([question])
  })

  it("isn't asked on a Mac, without even asking the server", async () => {
    const machine = world({ [`GET ${url()}`]: answers(status()) })
    const deps = {
      ...answering(machine, true),
      system: { ...machine.deps.system, platform: "darwin" as const }
    }
    await offerDesktop(deps)
    expect(machine.questions).toEqual([])
    expect(machine.httpCalls(`GET ${url()}`)).toBe(0)
  })

  it("is asked when the account has no sudo but root itself runs setup", async () => {
    const machine = world(
      { [`GET ${url()}`]: answers(status({ missing, sudo: "none" })) },
      { isRoot: true }
    )
    await offerDesktop(answering(machine, false))
    expect(machine.questions).toEqual([question])
  })

  it("is asked on a system with no known package manager once nothing is missing there", async () => {
    const machine = world(
      { [`GET ${url()}`]: answers(status()) },
      { machine: { files: ALPINE, programs: ["apk", "sudo"] } }
    )
    await offerDesktop(answering(machine, false))
    expect(machine.questions).toEqual([question])
  })

  it("is asked when an older Codevisor's desktop config is there, which setup replaces", async () => {
    const machine = world({ [`GET ${url()}`]: answers(status({ state: "outdated" })) }, {})
    await offerDesktop(answering(machine, false))
    expect(machine.questions).toEqual([question])
  })
})
