import { createHash } from "node:crypto"

import { describe, expect, it } from "vitest"

import { readResumeReport } from "./program-resume-report.js"

const TOKEN = "dummy-token-replace-me"
const T = 1795543200
const sign = (body: string): string =>
  `${body}:mac=${createHash("sha256").update(`${body}:${TOKEN}`).digest("hex")}`
const b64 = (text: string): string => Buffer.from(text).toString("base64")

describe("OSC 7577 reports", () => {
  it("accepts the specification's example reports", () => {
    expect(
      readResumeReport(
        "pid=74877:time=1795543200:argv=bnZpbQ==,LVM=,L2hvbWUvdXNlci8ubG9jYWwvc3RhdGUvbnZpbS9zZXNzaW9ucy84ZjJjMWQudmlt:mac=9dbb99bfb856749a87563839d7ce9062818d78cf25909db93f309e0cd3b1909b",
        TOKEN,
        T
      )
    ).toEqual({
      type: "record",
      pid: 74877,
      time: T,
      argv: ["nvim", "-S", "/home/user/.local/state/nvim/sessions/8f2c1d.vim"],
      cwd: undefined
    })
    expect(
      readResumeReport(
        "pid=74877:time=1795543200:clear=1:mac=c30603369f98fef581a4098be889175b0c74f0641e49f8b25f4326cb38f97c93",
        TOKEN,
        T
      )
    ).toEqual({ type: "clear", pid: 74877, time: T })
    expect(
      readResumeReport(
        "pid=74877:time=1795543200:argv=bGF6eWdpdA==:cwd=L2hvbWUvdXNlci9zcmMvcHJvamVjdA==:mac=35cb909805c380336efd3689a125acc774a9dec8422a1d21492ebec06ca758e1",
        TOKEN,
        T + 60
      )
    ).toMatchObject({ type: "record", argv: ["lazygit"], cwd: "/home/user/src/project" })
  })

  it.each([
    ["a wrong mac", `pid=74877:time=${T}:argv=bnZpbQ==:mac=${"0".repeat(64)}`],
    ["no mac", `pid=74877:time=${T}:argv=bnZpbQ==`],
    [
      "a mac that is not last",
      sign(`pid=74877:time=${T}:argv=bnZpbQ==`).replace(/^(.*):(mac=.*)$/u, "$2:$1")
    ],
    ["a time outside the window", sign(`pid=74877:time=${T - 61}:argv=bnZpbQ==`)],
    ["no time", sign("pid=74877:argv=bnZpbQ==")],
    [
      "a mac made with another token",
      `pid=74877:time=${T}:argv=bnZpbQ==:mac=${createHash("sha256").update(`pid=74877:time=${T}:argv=bnZpbQ==:other`).digest("hex")}`
    ],
    ["the reserved query", "?"],
    ["a body over the size limit", sign(`pid=74877:time=${T}:argv=${"QQ==,".repeat(2000)}bnZpbQ==`)]
  ])("ignores a report with %s", (_, body) => {
    expect(readResumeReport(body, TOKEN, T)).toEqual({ type: "ignored" })
  })

  it.each([
    ["a relative program path", `argv=${b64("./run.sh")}`, 74877],
    ["both argv and clear", "argv=bnZpbQ==:clear=1", 74877],
    ["neither argv nor clear", "", 74877],
    ["a relative cwd", `argv=bnZpbQ==:cwd=${b64("project")}`, 74877],
    ["an unimplemented needed key", "argv=bnZpbQ==:need=later", 74877],
    ["an empty program", "argv=", 74877],
    ["a program that looks like an option", `argv=${b64("-rf")}`, 74877],
    ["an element with a control character", `argv=bnZpbQ==,${b64("a\nb")}`, 74877],
    ["an element with bad padding", "argv=bnZpbQ=", 74877],
    ["a repeated key", "argv=bnZpbQ==:argv=bnZpbQ==", 74877],
    ["a clear value other than 1", "clear=2", 74877],
    ["a malformed pair", "argv=bnZpbQ==:junk", 74877]
  ])("rejects a report with %s", (_, rest, pid) => {
    const body = sign([`pid=${pid}`, `time=${T}`, rest].filter(Boolean).join(":"))
    expect(readResumeReport(body, TOKEN, T)).toEqual({ type: "rejected", pid, time: T })
  })

  it("rejects a report without a usable pid and keeps unknown keys out of the way", () => {
    expect(readResumeReport(sign(`pid=0:time=${T}:argv=bnZpbQ==`), TOKEN, T)).toEqual({
      type: "rejected",
      pid: undefined,
      time: T
    })
    expect(
      readResumeReport(sign(`pid=7:time=${T}:argv=bnZpbQ==,:future=x:need=argv,pid`), TOKEN, T)
    ).toMatchObject({ type: "record", argv: ["nvim", ""] })
  })
})
