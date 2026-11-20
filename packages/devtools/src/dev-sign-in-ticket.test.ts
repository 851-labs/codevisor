import { mkdtemp, rm, stat } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import { offerDevelopmentSignIn } from "./dev-sign-in-ticket.ts"

const roots: Array<string> = []
afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })))
})

const exists = (path: string) =>
  stat(path).then(
    () => true,
    () => false
  )

describe("offerDevelopmentSignIn", () => {
  it("offers each app one sign-in per device, and never again once the app takes it", async () => {
    const root = join(await mkdtemp(join(tmpdir(), "codevisor-sign-in-")), "sign-in")
    roots.push(root)

    const ticket = await offerDevelopmentSignIn({ root, app: "ios", device: "SIM-A" })
    expect(await exists(ticket)).toBe(true)

    await rm(ticket)
    expect(await offerDevelopmentSignIn({ root, app: "ios", device: "SIM-A" })).toBe(ticket)
    expect(await exists(ticket)).toBe(false)

    await offerDevelopmentSignIn({ root, app: "ios", device: "SIM-B" })
    expect(await exists(ticket)).toBe(true)

    const macTicket = await offerDevelopmentSignIn({ root, app: "macos", device: "mac" })
    expect(macTicket).not.toBe(ticket)
    expect(await exists(macTicket)).toBe(true)
  })
})
