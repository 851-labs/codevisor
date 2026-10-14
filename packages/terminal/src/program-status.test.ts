import { describe, expect, it } from "vitest"

import {
  makeProgramStatusRecords,
  makeProgramStatusScanner,
  MAX_PROGRAM_STATUS_RECORDS,
  parseProgramStatus,
  type ProgramStatusEvent,
  type ProgramStatusRecords
} from "./program-status.js"

const b64 = (text: string): string => Buffer.from(text).toString("base64")

const report = (state: string, id?: string): ProgramStatusEvent => ({
  type: "report",
  state: state as "idle",
  id
})

const set = (records: ProgramStatusRecords, state: string, id?: string) =>
  records.apply({ type: "report", state: state as "idle", id })

describe("parseProgramStatus", () => {
  it.each([
    ["state=idle", "idle", undefined],
    [
      `state=blocked:kind=permission:app=terraform:msg=${b64("Apply 3 to add?")}`,
      "blocked",
      undefined
    ],
    ["state=working:id=deploy/us-east:progress=40", "working", "deploy/us-east"],
    ["state=clear:id=deploy", "clear", "deploy"],
    [" state = working :state=done", "done", undefined],
    ["state=error:future=yes:oops:=x:Bad=1:note=a;b", "error", undefined],
    [`state=done:msg=${b64("ok").replace(/=+$/u, "")}`, "done", undefined],
    ["state=working:progress=101:kind=nope:app=bad!name", "working", undefined]
  ])("reads %j", (body, state, id) => {
    expect(parseProgramStatus(body)).toEqual({ type: "report", state, id })
  })

  it("recognizes the support query", () => {
    expect(parseProgramStatus("?")).toEqual({ type: "query" })
  })

  it.each([
    ["no state", "kind=permission"],
    ["an unknown state", "state=thinking"],
    ["an invalid id", "state=clear:id=a//b"],
    ["an id segment too long", `state=idle:id=${"a".repeat(33)}`],
    ["an id too deep", `state=idle:id=${Array(9).fill("a").join("/")}`],
    ["an id too long", `state=idle:id=${Array(5).fill("a".repeat(30)).join("/")}`],
    ["an overlong key", `state=idle:${"k".repeat(17)}=1`],
    ["an overlong app, even replaced", `state=idle:app=${"a".repeat(33)}:app=ok`],
    ["an overlong encoded title", `state=idle:title=${"QUFB".repeat(65)}`],
    ["an overlong encoded msg", `state=idle:msg=${"QUFB".repeat(684)}`],
    ["a msg over 2048 bytes decoded", `state=idle:msg=${"QUFB".repeat(683)}`],
    ["a title that isn't base64", "state=idle:title=a-b"],
    ["msg that isn't base64", "state=idle:msg=a-b"],
    ["msg with impossible length", "state=idle:msg=QUFBQ"],
    ["msg with a newline", `state=idle:msg=${b64("one\ntwo")}`],
    ["msg with a C1 control", `state=idle:msg=${b64("bad\u0085")}`],
    ["msg that isn't UTF-8", `state=idle:msg=${Buffer.from([0xff, 0xfe]).toString("base64")}`],
    ["a body over the sequence limit", `state=idle:x=${"a".repeat(4096)}`]
  ])("ignores a report with %s", (_reason, body) => {
    expect(parseProgramStatus(body)).toBeUndefined()
  })
})

describe("makeProgramStatusScanner", () => {
  it("reads reports, queries, prompts, and resets in order, ignoring other sequences", () => {
    const scanner = makeProgramStatusScanner()
    expect(
      scanner.scan(
        "\u001b]2;title\u0007\u001b[31mred" +
          "\u001b]7501;state=working\u001b\\" +
          "\u001b]7501;?\u0007" +
          "\u001b]7501;?\u001b\\" +
          "\u001b]133;A;cl=m\u0007" +
          "\u001b]7501;state=bogus\u0007" +
          "\u001bc"
      )
    ).toEqual([
      report("working"),
      { type: "query", terminator: "\u0007" },
      { type: "query", terminator: "\u001b\\" },
      { type: "prompt" },
      { type: "reset" }
    ])
  })

  it.each([
    ["\u001b]7501;state=done:id=build\u001b\\", report("done", "build")],
    ["\u001b]133;A;cl=m\u0007", { type: "prompt" }]
  ] as const)("completes %j split anywhere across chunks", (sequence, event) => {
    for (let split = 1; split < sequence.length; split += 1) {
      const scanner = makeProgramStatusScanner()
      expect([
        ...scanner.scan(`out${sequence.slice(0, split)}`),
        ...scanner.scan(`${sequence.slice(split)}more`)
      ]).toEqual([event])
    }
  })

  it("carries only sequences it could read", () => {
    const scanner = makeProgramStatusScanner()
    expect(scanner.scan("\u001b]2;7501;state=idle")).toEqual([])
    expect(scanner.scan("\u0007\u001b]133;A;" + "x".repeat(256))).toEqual([])
    expect(scanner.scan("\u0007")).toEqual([])
  })

  it("drops an OSC that another escape aborts", () => {
    const scanner = makeProgramStatusScanner()
    expect(scanner.scan("\u001b]7501;state=idle\u001b[0m\u001b]7501;state=error\u0007")).toEqual([
      report("error")
    ])
  })

  it("stops carrying a sequence once it outgrows the limit", () => {
    const scanner = makeProgramStatusScanner()
    expect(scanner.scan(`\u001b]7501;state=idle:x=${"a".repeat(4096)}`)).toEqual([])
    expect(scanner.scan("\u001b\\\u001b]7501;state=done\u0007")).toEqual([report("done")])
  })
})

describe("makeProgramStatusRecords", () => {
  const records = makeProgramStatusRecords

  it("shows the most urgent record, and nothing until a program reports", () => {
    const r = records()
    expect(r.summary()).toBeUndefined()
    set(r, "idle")
    expect(r.summary()).toBe("idle")
    set(r, "done", "a")
    expect(r.summary()).toBe("done")
    set(r, "working", "b")
    expect(r.summary()).toBe("working")
    set(r, "blocked", "c")
    expect(r.summary()).toBe("blocked")
    set(r, "error", "d")
    expect(r.summary()).toBe("error")
    set(r, "idle", "d")
    expect(r.summary()).toBe("blocked")
  })

  it("clears a record with those beneath it, or every record without an id", () => {
    const r = records()
    set(r, "idle")
    set(r, "working", "deploy")
    set(r, "blocked", "deploy/eu-west")
    set(r, "error", "deploy-old")
    set(r, "clear", "deploy")
    expect(r.summary()).toBe("error")
    set(r, "clear")
    expect(r.summary()).toBeUndefined()
  })

  it("drops all but done and error at a new shell prompt", () => {
    const r = records()
    set(r, "working")
    set(r, "blocked", "a")
    set(r, "idle", "b")
    r.apply({ type: "prompt" })
    expect(r.summary()).toBeUndefined()

    set(r, "done")
    set(r, "working", "a")
    r.apply({ type: "prompt" })
    expect(r.summary()).toBe("done")
    set(r, "error", "b")
    r.apply({ type: "prompt" })
    expect(r.summary()).toBe("error")
  })

  it("drops everything on a full reset", () => {
    const r = records()
    set(r, "error")
    r.apply({ type: "reset" })
    expect(r.summary()).toBeUndefined()
  })

  it("evicts the least recently updated record past the cap", () => {
    const r = records()
    set(r, "error", "oldest")
    for (let index = 1; index < MAX_PROGRAM_STATUS_RECORDS; index += 1) set(r, "idle", `r${index}`)
    expect(r.summary()).toBe("error")
    set(r, "idle", "one-more")
    expect(r.summary()).toBe("idle")
  })
})
