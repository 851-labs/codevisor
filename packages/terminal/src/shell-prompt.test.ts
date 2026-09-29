import { describe, expect, it } from "vitest"

import { makeShellPrompt } from "./shell-prompt.js"

const mark = (kind: string): string => `\u001b]133;${kind}\u0007`

describe("@codevisor/terminal shell prompt", () => {
  it("follows the shell between its prompt and running commands", () => {
    const prompt = makeShellPrompt()
    // A shell without integration never says.
    prompt.observe("plain output")
    expect(prompt.running()).toBeUndefined()

    prompt.observe(`${mark("A")}➜ ${mark("B")}`)
    expect(prompt.running()).toBe(false)
    prompt.observe(`npm run dev\r\n${mark("C")}ready`)
    expect(prompt.running()).toBe(true)
    // The last mark in a chunk wins.
    prompt.observe(`${mark("D;0")}${mark("A")}➜ ${mark("B")}`)
    expect(prompt.running()).toBe(false)
  })

  it("reads a mark split across chunks once", () => {
    const prompt = makeShellPrompt()
    prompt.observe(`${mark("A")}prompt\u001b]1`)
    expect(prompt.running()).toBe(false)
    prompt.observe(`33;C\u0007output`)
    expect(prompt.running()).toBe(true)
    // Split after the mark itself, before its kind.
    prompt.observe("done\u001b]133;")
    expect(prompt.running()).toBe(true)
    prompt.observe(`D\u0007`)
    expect(prompt.running()).toBe(false)
  })
})
