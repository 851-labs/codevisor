import { chmodSync, mkdirSync, realpathSync, symlinkSync, writeFileSync } from "node:fs"
import { createServer } from "node:net"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { privateSocket } from "./private-socket.js"
import { listenPrivately, privateDirectory } from "./vnc-test-support.js"

const listening = async (directory: string = privateDirectory()): Promise<string> => {
  const server = createServer()
  const socket = await listenPrivately(server, directory)
  onTestFinished(() => new Promise<void>((resolve) => server.close(() => resolve())))
  return socket
}

const folderInside = (parent: string, name: string, mode: number): string => {
  const folder = join(parent, name)
  mkdirSync(folder)
  chmodSync(folder, mode)
  return folder
}

const exposed = { problem: "exposed" }

describe("a desktop's socket is only used when it is private to the server's account", () => {
  it("accepts a socket only its owner can open, in folders only its owner can change", async () => {
    const directory = privateDirectory()
    const socket = await listening(directory)
    expect(privateSocket(socket)).toEqual({ path: join(realpathSync(directory), "d.sock") })
  })

  it("reports a desktop that isn't running", () => {
    expect(privateSocket(join(privateDirectory(), "d.sock"))).toEqual({ problem: "missing" })
    expect(privateSocket(join(privateDirectory(), "gone", "d.sock"))).toEqual({
      problem: "missing"
    })
  })

  it.each([0o660, 0o606, 0o666])(
    "refuses a socket with mode %o, which another account could open",
    async (mode) => {
      const socket = await listening()
      chmodSync(socket, mode)
      expect(privateSocket(socket)).toEqual(exposed)
    }
  )

  it("refuses a socket that belongs to another account", async () => {
    const socket = await listening()
    const anotherAccount = process.getuid!() + 1
    expect(privateSocket(socket, anotherAccount)).toEqual(exposed)
  })

  it.each([0o770, 0o707])(
    "refuses a socket in a folder with mode %o, where another account could swap it",
    async (mode) => {
      const directory = privateDirectory()
      const socket = await listening(directory)
      chmodSync(directory, mode)
      expect(privateSocket(socket)).toEqual(exposed)
    }
  )

  it("refuses a socket whose private folder sits in a folder others can rename things in", async () => {
    const open = folderInside(privateDirectory(), "open", 0o777)
    const socket = await listening(folderInside(open, "desk", 0o700))
    expect(privateSocket(socket)).toEqual(exposed)
  })

  it("accepts a private folder inside a sticky shared folder, where only owners rename", async () => {
    const shared = folderInside(privateDirectory(), "shared", 0o1777)
    const socket = await listening(folderInside(shared, "desk", 0o700))
    expect(privateSocket(socket)).toEqual({ path: realpathSync(socket) })
  })

  it("refuses anything that isn't a socket, including a link to one", async () => {
    const directory = privateDirectory()
    const file = join(directory, "file")
    writeFileSync(file, "", { mode: 0o600 })
    expect(privateSocket(file)).toEqual(exposed)

    const socket = await listening(directory)
    const link = join(directory, "link")
    symlinkSync(socket, link)
    expect(privateSocket(link)).toEqual(exposed)
  })

  it("checks and dials the real folder when the configured one is a link", async () => {
    const parent = privateDirectory()
    const real = folderInside(parent, "real", 0o700)
    await listening(real)
    const linked = join(parent, "linked")
    symlinkSync(real, linked)
    expect(privateSocket(join(linked, "d.sock"))).toEqual({
      path: join(realpathSync(real), "d.sock")
    })

    chmodSync(real, 0o777)
    expect(privateSocket(join(linked, "d.sock"))).toEqual(exposed)
  })
})
