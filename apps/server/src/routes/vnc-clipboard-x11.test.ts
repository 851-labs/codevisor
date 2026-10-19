import { spawn } from "node:child_process"
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { systemX11Commands, type X11Commands, x11DesktopClipboard } from "./vnc-clipboard-x11.js"
import { MAXIMUM_CONTENT_BYTES, TEXT_TYPE } from "./vnc-clipboard.js"

const node = (script: string) => spawn(process.execPath, ["-e", script], { stdio: "pipe" })

const STAYS = "process.stdin.resume(); process.stdin.on('end', () => process.exit(0));"
const WATCHER_OK = `process.stdout.write('ready\\nnoise\\nchanged\\n'); setTimeout(() => process.stdout.write('changed\\n'), 1); ${STAYS}`
const XCLIP_OK = `const parts = []; process.stdin.on('data', (d) => parts.push(d)); process.stdin.on('end', () => { process.stdout.write('got ' + Buffer.concat(parts).length + '\\n'); process.stderr.write('Waiting for selection requests, Control-C to quit\\n'); setInterval(() => undefined, 1000) })`

interface Spawned {
  readonly command: string
  readonly args: readonly string[]
}

const commands = (
  scripts: Record<string, string>,
  outputs: Record<string, Buffer | Error> = {}
): X11Commands & { spawned: Spawned[]; children: Array<ReturnType<typeof node>> } => {
  const spawned: Spawned[] = []
  const children: Array<ReturnType<typeof node>> = []
  return {
    spawned,
    children,
    run: (args) => {
      const output = outputs[args.join(" ")]
      if (output instanceof Error) return Promise.reject(output)
      return Promise.resolve(output ?? Buffer.alloc(0))
    },
    spawn: (command, args) => {
      spawned.push({ command, args })
      const child = node(scripts[command] ?? "process.exit(1)")
      children.push(child)
      return child
    }
  }
}

describe("X11 desktop clipboard", () => {
  it("watches the clipboard until stopped", async () => {
    const changes: number[] = []
    const twoChanges = Promise.withResolvers<void>()
    const stop = await x11DesktopClipboard(commands({ python3: WATCHER_OK })).watch(() => {
      changes.push(changes.length)
      if (changes.length === 2) twoChanges.resolve()
    })
    await twoChanges.promise
    stop()
    expect(changes).toEqual([0, 1])
  })

  it("reports why the watcher couldn't start", async () => {
    await expect(
      x11DesktopClipboard(
        commands({ python3: "process.stderr.write('cannot open the display\\n'); process.exit(1)" })
      ).watch(() => undefined)
    ).rejects.toThrow("cannot open the display")
    await expect(
      x11DesktopClipboard(commands({ python3: "process.exit(1)" })).watch(() => undefined)
    ).rejects.toThrow("The clipboard watcher stopped")
    await expect(
      x11DesktopClipboard(commands({}, { "-version": new Error("spawn xclip ENOENT") })).watch(
        () => undefined
      )
    ).rejects.toThrow("ENOENT")
    const missing: X11Commands = {
      run: () => Promise.resolve(Buffer.alloc(0)),
      spawn: () => spawn(join(tmpdir(), "codevisor-missing-python"), [], { stdio: "pipe" })
    }
    await expect(x11DesktopClipboard(missing).watch(() => undefined)).rejects.toThrow("ENOENT")
  })

  it("reads every type a Mac can paste, preferring images and converting UTF-16 HTML", async () => {
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47])
    const html = Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from("<b>hi</b>", "utf16le")])
    const desktop = x11DesktopClipboard(
      commands(
        {},
        {
          "-o -t TARGETS": Buffer.from(
            "TARGETS\nimage/png\nimage/jpeg\nimage/gif\ntext/html\napplication/rtf\nUTF8_STRING\ntext/plain;charset=utf-8\n"
          ),
          "-o -t image/png": png,
          "-o -t image/jpeg": Buffer.alloc(MAXIMUM_CONTENT_BYTES),
          "-o -t text/html": html,
          "-o -t application/rtf": new Error("target not available"),
          "-o -t UTF8_STRING": Buffer.from("hi")
        }
      )
    )
    expect(await desktop.read()).toEqual([
      [
        { type: "public.png", data: png },
        { type: "public.html", data: Buffer.from("<b>hi</b>") },
        { type: TEXT_TYPE, data: Buffer.from("hi") }
      ]
    ])
    await expect(
      x11DesktopClipboard(commands({}, { "-o -t TARGETS": new Error("no owner") })).read()
    ).rejects.toThrow("empty")
    expect(
      await x11DesktopClipboard(
        commands(
          {},
          { "-o -t TARGETS": Buffer.from("text/html"), "-o -t text/html": Buffer.from("<i>") }
        )
      ).read()
    ).toEqual([[{ type: "public.html", data: Buffer.from("<i>") }]])
  })

  it("serves the best single type it was given until another copy replaces it", async () => {
    const fake = commands({ xclip: XCLIP_OK })
    const png = { type: "public.png", data: Buffer.from([1, 2, 3]) }
    const stored = await x11DesktopClipboard(fake).write([
      [{ type: TEXT_TYPE, data: Buffer.from("caption") }, png]
    ])
    expect(stored).toEqual([[png]])
    expect(fake.spawned).toEqual([
      { command: "xclip", args: ["-selection", "clipboard", "-t", "image/png", "-verbose"] }
    ])
    const [owner] = fake.children
    const exited = new Promise((resolve) => owner?.once("exit", resolve))
    owner?.kill()
    await exited
  })

  it("refuses what it can't serve and reports xclip failing", async () => {
    await expect(
      x11DesktopClipboard(commands({})).write([
        [{ type: "com.example.private", data: Buffer.from([1]) }]
      ])
    ).rejects.toThrow("can't hold")
    await expect(
      x11DesktopClipboard(
        commands({
          xclip: 'process.stderr.write("Error: Can\'t open display\\n"); process.exit(1)'
        })
      ).write([[{ type: TEXT_TYPE, data: Buffer.from("x") }]])
    ).rejects.toThrow("Can't open display")
    await expect(
      x11DesktopClipboard(commands({ xclip: "process.exit(1)" })).write([
        [{ type: TEXT_TYPE, data: Buffer.from("x") }]
      ])
    ).rejects.toThrow("xclip stopped")
    const missing: X11Commands = {
      run: () => Promise.resolve(Buffer.alloc(0)),
      spawn: () => spawn(join(tmpdir(), "codevisor-missing-xclip"), [], { stdio: "pipe" })
    }
    await expect(
      x11DesktopClipboard(missing).write([[{ type: TEXT_TYPE, data: Buffer.from("x") }]])
    ).rejects.toThrow("ENOENT")
  })
})

describe("system X11 commands", () => {
  it("runs xclip on the desktop's display and surfaces its errors", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-xclip-"))
    const xclip = join(directory, "xclip")
    writeFileSync(
      xclip,
      [
        "#!/bin/sh",
        'case "$*" in',
        "  *quiet*) exit 3 ;;",
        '  *fail*) echo "Error: target not available" >&2; exit 1 ;;',
        '  *) printf "%s %s" "$DISPLAY" "$*" ;;',
        "esac"
      ].join("\n")
    )
    chmodSync(xclip, 0o755)
    const system = systemX11Commands(7, xclip)
    expect((await system.run(["-o"])).toString()).toBe(":7 -selection clipboard -o")
    await expect(system.run(["fail"])).rejects.toThrow("Error: target not available")
    await expect(system.run(["quiet"])).rejects.toThrow("Command failed")
    const child = system.spawn("sh", ["-c", 'printf "%s" "$DISPLAY"'])
    const output: Buffer[] = []
    child.stdout.on("data", (chunk: Buffer) => output.push(chunk))
    await new Promise((resolve) => child.once("close", resolve))
    expect(Buffer.concat(output).toString()).toBe(":7")
  })
})
