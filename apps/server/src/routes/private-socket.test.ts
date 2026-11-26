import { chmodSync, mkdirSync, symlinkSync, writeFileSync } from "node:fs"
import { createServer } from "node:net"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { privateSocketProblem } from "./private-socket.js"
import { listenPrivately, privateDirectory } from "./vnc-test-support.js"

const listening = async (directory: string = privateDirectory()): Promise<string> => {
  const server = createServer()
  const socket = await listenPrivately(server, directory)
  onTestFinished(() => new Promise<void>((resolve) => server.close(() => resolve())))
  return socket
}

describe("a desktop's socket is only used when it is private to the server's account", () => {
  it("accepts a socket only its owner can open, in a folder only its owner can change", async () => {
    expect(privateSocketProblem(await listening())).toBeUndefined()
  })

  it("reports a desktop that isn't running", () => {
    expect(privateSocketProblem(join(privateDirectory(), "d.sock"))).toBe("missing")
  })

  it.each([0o660, 0o606, 0o666])(
    "refuses a socket with mode %o, which another account could open",
    async (mode) => {
      const socket = await listening()
      chmodSync(socket, mode)
      expect(privateSocketProblem(socket)).toBe("exposed")
    }
  )

  it("refuses a socket that belongs to another account", async () => {
    const socket = await listening()
    const anotherAccount = process.getuid!() + 1
    expect(privateSocketProblem(socket, anotherAccount)).toBe("exposed")
  })

  it.each([0o770, 0o707])(
    "refuses a socket in a folder with mode %o, where another account could swap it",
    async (mode) => {
      const directory = privateDirectory()
      const socket = await listening(directory)
      chmodSync(directory, mode)
      expect(privateSocketProblem(socket)).toBe("exposed")
    }
  )

  it("refuses anything that isn't a socket, including a link to one", async () => {
    const directory = privateDirectory()
    const file = join(directory, "file")
    writeFileSync(file, "", { mode: 0o600 })
    expect(privateSocketProblem(file)).toBe("exposed")

    const socket = await listening(directory)
    const link = join(directory, "link")
    symlinkSync(socket, link)
    expect(privateSocketProblem(link)).toBe("exposed")
  })

  it("refuses a socket reached through a linked folder", async () => {
    const parent = privateDirectory()
    const real = join(parent, "real")
    mkdirSync(real, { mode: 0o700 })
    await listening(real)
    const linked = join(parent, "linked")
    symlinkSync(real, linked)
    expect(privateSocketProblem(join(linked, "d.sock"))).toBe("exposed")
  })
})
