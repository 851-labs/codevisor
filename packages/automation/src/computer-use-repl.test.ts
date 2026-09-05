import { afterEach, describe, expect, it } from "vitest"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { makeComputerUseRepls } from "./computer-use-repl.js"

const reply = (value: unknown): CallToolResult => ({
  content: [{ type: "text", text: JSON.stringify(value) }]
})
const text = (result: CallToolResult) =>
  result.content
    .filter((c) => c.type === "text")
    .map((c) => c.text)
    .join("\n")
const pools: ReturnType<typeof makeComputerUseRepls>[] = []
const pool = () => {
  const value = makeComputerUseRepls()
  pools.push(value)
  return value
}
afterEach(async () => {
  await Promise.all(pools.splice(0).map((value) => value.close()))
})

describe("Computer Use REPL", () => {
  it("records an observed window across cells and returns the video artifact without hidden observations", async () => {
    const repl = pool()
    const calls: { method: string; args: Record<string, unknown> }[] = []
    const video = {
      recordingId: "r",
      status: "stopped",
      file: { path: "/recordings/fix.mp4", url: "https://attachments.codevisor.invalid/f" },
      markdown: "![Fix](https://attachments.codevisor.invalid/f)"
    }
    const invoke = async (method: string, args: Record<string, unknown>) => {
      calls.push({ method, args })
      if (method === "get_app_state")
        return reply({ windowId: 42, snapshotId: "s", text: "window" })
      if (method === "start_recording") return reply({ recordingId: "r", status: "recording" })
      if (method === "stop_recording") return reply(video)
      return reply({ status: "recording" })
    }
    await repl.execute(
      "a",
      'let app = await computer.getApp("Codevisor", {emit:false}); let recording = await app.startRecording({fps:24}); computer.write(recording);',
      invoke
    )
    await repl.execute("a", 'await app.pressKey("Return"); await recording.status();', invoke)
    const result = await repl.execute(
      "a",
      "let video = await recording.stop(); computer.write(video);",
      invoke
    )
    expect(JSON.parse(text(result))).toEqual(video)
    expect(calls.map((c) => c.method)).toEqual([
      "get_app_state",
      "start_recording",
      "press_key",
      "recording_status",
      "stop_recording"
    ])
    expect(calls[1]?.args).toEqual({ window_id: 42, fps: 24 })
    expect(calls[4]?.args).toEqual({ recording_id: "r" })
  })

  it("discovers displays and recovers native recordings after clearing JavaScript bindings", async () => {
    const repl = pool()
    const calls: { method: string; args: Record<string, unknown> }[] = []
    const invoke = async (method: string, args: Record<string, unknown>) => {
      calls.push({ method, args })
      return reply(
        method === "list_recording_targets"
          ? { displays: [{ displayId: 10 }] }
          : { recordingId: "r" }
      )
    }
    await repl.execute(
      "a",
      "let targets = await computer.listRecordingTargets(); let r = await computer.startRecording({display_id:targets.displays[0].displayId});",
      invoke
    )
    await repl.reset("a")
    await repl.execute(
      "a",
      'await computer.recordingStatus(); await computer.recordingStatus("r"); await computer.stopRecording("r");',
      invoke
    )
    expect(calls).toEqual([
      { method: "list_recording_targets", args: {} },
      { method: "start_recording", args: { display_id: 10 } },
      { method: "recording_status", args: {} },
      { method: "recording_status", args: { recording_id: "r" } },
      { method: "stop_recording", args: { recording_id: "r" } }
    ])
    expect(
      (
        await repl.execute(
          "a",
          'let app=await computer.getApp("Music",{emit:false}); await app.startRecording();',
          invoke
        )
      ).isError
    ).toBe(true)
  })

  it("releases a long-lived session after repeated large screenshot observations", async () => {
    const repl = pool()
    const invoke = async () => ({
      content: [
        ...reply({ snapshotId: "s", text: "1 AXWindow" }).content,
        { type: "image" as const, mimeType: "image/png", data: "A".repeat(4_000_000) }
      ]
    })
    await repl.execute(
      "large",
      'let app = await computer.getApp("Music", {emit:false}); let s;',
      invoke
    )
    for (let index = 0; index < 30; index++) {
      const result = await repl.execute(
        "large",
        "s = await app.getState(); computer.write(s.image);",
        invoke
      )
      expect(result.isError, text(result)).toBeUndefined()
    }
    await repl.reset("large")
  })
  it("keeps app bindings and follows menu -> submenu -> selection without hidden input or observations", async () => {
    const repl = pool()
    const calls: { method: string; args: Record<string, unknown> }[] = []
    let stage = 0
    const invoke = async (method: string, args: Record<string, unknown>) => {
      calls.push({ method, args })
      if (method === "get_app_state")
        return reply({
          snapshotId: `s${stage}`,
          resolvedApp: { id: "com.apple.Music" },
          windowId: 20,
          text: [
            "10 AXMenuButton Song",
            "11 AXMenuItem Add to Playlist",
            "12 AXMenuItem agents only (codevisor)",
            "13 AXStaticText 1 song"
          ][stage]
        })
      expect(method).toBe("click")
      expect(args.snapshot_id).toBe(`s${stage}`)
      expect(args.window_id).toBe(20)
      expect(args.element_index).toBe(10 + stage)
      expect(args.delivery_mode).toBe("foreground")
      stage++
      return reply({ status: "delivered", verified: false })
    }
    expect(
      (
        await repl.execute(
          "a",
          'const music = await computer.getApp("Music", { emit: false, delivery_mode: "foreground" });',
          invoke
        )
      ).isError
    ).toBeUndefined()
    for (const index of [10, 11, 12]) {
      const result = await repl.execute(
        "a",
        `await music.click(${index}); computer.write(await music.getAXState());`,
        invoke
      )
      expect(result.isError, text(result)).toBeUndefined()
    }
    expect(calls.map((c) => c.method)).toEqual([
      "get_app_state",
      "click",
      "get_app_state",
      "click",
      "get_app_state",
      "click",
      "get_app_state"
    ])
    expect(stage).toBe(3)
  })

  it("isolates sessions, preserves helper functions and destructuring, and resets explicitly", async () => {
    const repl = pool()
    const invoke = async () => reply({})
    await repl.execute(
      "a",
      "let {value: count} = {value: 2}; function twice(n) { return n * 2; }",
      invoke
    )
    expect(text(await repl.execute("a", "count = twice(count); count", invoke))).toBe("4")
    expect((await repl.execute("b", "count", invoke)).isError).toBe(true)
    await repl.reset("a")
    expect((await repl.execute("a", "count", invoke)).isError).toBe(true)
  })

  it("retains bindings after an uncertain action and surfaces native details without retrying", async () => {
    const repl = pool()
    let actions = 0
    const invoke = async (method: string) =>
      method === "get_app_state"
        ? reply({ snapshotId: "s1", windowId: 1, text: "1 AXMenuButton Song" })
        : (actions++, reply({ status: "uncertain", nativeErrorCode: -25204, delivered: null }))
    await repl.execute("a", 'let app = await computer.getApp("Music", {emit:false});', invoke)
    const result = await repl.execute("a", "await app.click(1)", invoke)
    expect(text(result)).toContain('"status":"uncertain"')
    expect(actions).toBe(1)
    expect((await repl.execute("a", "app.id", invoke)).isError).toBeUndefined()
  })

  it("preserves app bindings after an ordinary wait timeout", async () => {
    const repl = pool()
    const invoke = async (method: string) =>
      reply({
        snapshotId: "s",
        text: "1 AXWindow",
        ...(method === "wait_for" ? { matched: false } : {})
      })
    await repl.execute("a", 'let app=await computer.getApp("Music",{emit:false})', invoke)
    expect(
      (await repl.execute("a", 'await app.waitFor({text:"Missing",timeout_ms:0})', invoke)).isError
    ).toBe(true)
    expect(text(await repl.execute("a", "app.id", invoke))).toBe("Music")
  })

  it("carries explicit windows, key sequences, drag endpoints and rich text through the sandbox", async () => {
    const repl = pool()
    const calls: { method: string; args: Record<string, unknown> }[] = []
    const invoke = async (method: string, args: Record<string, unknown>) => {
      calls.push({ method, args })
      return reply(
        method === "get_app_state"
          ? { snapshotId: "w2", windowId: args.window_id ?? 1, text: "2 AXTextArea Editor" }
          : { status: "delivered" }
      )
    }
    const result = await repl.execute(
      "a",
      `
      const app = await computer.getApp("Notes", {emit:false});
      const win = app.getWindow(2);
      await win.getState();
      await win.pressKey(["Down", "Right", "Return"], {delivery_mode:"foreground"});
      await win.drag(2, {x:80,y:90});
      await win.pasteText("Hello", {html:"<b>Hello</b>"});
    `,
      invoke
    )
    expect(result.isError, text(result)).toBeUndefined()
    expect(calls[2]?.args).toMatchObject({ window_id: 2, keys: ["Down", "Right", "Return"] })
    expect(calls[2]?.args).not.toHaveProperty("snapshot_id")
    expect(calls[3]?.args).toMatchObject({
      snapshot_id: "w2",
      from_element_index: 2,
      to_x: 80,
      to_y: 90
    })
    expect(calls[4]?.args).toMatchObject({ html: "<b>Hello</b>", delivery_mode: "foreground" })
  })

  it("returns images once, reports errors concisely, and cannot access host capabilities", async () => {
    const repl = pool()
    const image = { type: "image" as const, mimeType: "image/png", data: "AA==" }
    const invoke = async () => ({
      content: [...reply({ snapshotId: "s", text: "1 AXWindow" }).content, image]
    })
    const result = await repl.execute("a", 'await computer.getApp("Music")', invoke)
    expect(result.content.filter((c) => c.type === "image")).toEqual([image])
    expect((await repl.execute("a", "process.env", invoke)).isError).toBe(true)
    expect((await repl.execute("a", "let computer = {}", invoke)).isError).toBe(true)
    expect(text(await repl.execute("a", "typeof fetch", invoke))).toBe("undefined")
    const failure = await repl.execute("a", 'await computer.getApp("Missing")', async () => ({
      isError: true,
      content: [{ type: "text", text: "App not found" }]
    }))
    expect(text(failure)).toBe("Error: App not found")
  })

  it("returns explicit state images and supports window recovery without retaining a closed window", async () => {
    const repl = pool()
    const image = { type: "image" as const, mimeType: "image/png", data: "AA==" }
    let reads = 0
    const invoke = async (_method: string, args: Record<string, unknown>) => {
      expect(args).not.toHaveProperty("window_id")
      return {
        content: [
          ...reply({
            snapshotId: `s${++reads}`,
            windowId: reads === 2 ? undefined : reads,
            text: "Window"
          }).content,
          image
        ]
      }
    }
    await repl.execute("a", 'let app = await computer.getApp("Music", {emit:false})', invoke)
    const closed = await repl.execute("a", "await app.getState()", invoke)
    expect(closed.content.filter((c) => c.type === "image")).toEqual([image])
    expect(text(await repl.execute("a", "await app.getState(); app.windowId", invoke))).toBe("3")
    expect(text(await repl.execute("a", "({image:null,text:'No screenshot'})", invoke))).toContain(
      "No screenshot"
    )
  })

  it("rejects recursive and unrelated bridge calls, and handles empty observations", async () => {
    const repl = pool()
    await repl.reset("unused")
    const invoke = async () => ({ content: [] })
    for (const path of ["browser.click", "computer.js", "computer.reset"]) {
      const result = await repl.execute(
        "a",
        `await globalThis.__codevisor_invokeTool(${JSON.stringify(path)})`,
        invoke
      )
      expect(result.isError).toBe(true)
      expect(text(result)).toContain("Only Computer Use")
    }
    const empty = await repl.execute(
      "a",
      "await globalThis.__codevisor_invokeTool('computer.list_apps')",
      invoke
    )
    expect(empty).toEqual({ content: [] })
    // Unsupported output entries must not leak into the MCP content stream.
    expect(
      (await repl.execute("a", "globalThis.__codevisor_outputs.push(null, {});", invoke)).content
    ).toEqual([{ type: "text", text: "2" }])
  })
})
