import { type ChildProcessWithoutNullStreams, execFile, spawn } from "node:child_process"
import { createInterface } from "node:readline"

import type { DesktopClipboard } from "./vnc-clipboard-bridge.js"
import { type ClipboardRepresentation, MAXIMUM_CONTENT_BYTES, TEXT_TYPE } from "./vnc-clipboard.js"

const READ_TARGETS: ReadonlyArray<readonly [string, string]> = [
  ["image/png", "public.png"],
  ["image/jpeg", "public.jpeg"],
  ["image/gif", "com.compuserve.gif"],
  ["text/html", "public.html"],
  ["text/rtf", "public.rtf"],
  ["application/rtf", "public.rtf"],
  ["UTF8_STRING", TEXT_TYPE],
  ["text/plain;charset=utf-8", TEXT_TYPE]
]

const WRITE_TARGETS: ReadonlyArray<readonly [string, string]> = [
  ["public.png", "image/png"],
  ["public.jpeg", "image/jpeg"],
  ["com.compuserve.gif", "image/gif"],
  [TEXT_TYPE, "UTF8_STRING"],
  ["public.html", "text/html"],
  ["public.rtf", "text/rtf"]
]

const WATCHER = `
import ctypes, ctypes.util, os, select, sys
x11 = ctypes.CDLL(ctypes.util.find_library("X11"))
fixes = ctypes.CDLL(ctypes.util.find_library("Xfixes"))
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XInternAtom.restype = ctypes.c_ulong
x11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
x11.XDefaultRootWindow.restype = ctypes.c_ulong
x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
for name in ("XConnectionNumber", "XPending", "XFlush"):
    getattr(x11, name).argtypes = [ctypes.c_void_p]
x11.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
fixes.XFixesQueryExtension.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
fixes.XFixesQueryVersion.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
fixes.XFixesSelectSelectionInput.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
display = x11.XOpenDisplay(None)
if not display:
    sys.exit("cannot open the display")
event_base, error_base = ctypes.c_int(), ctypes.c_int()
major, minor = ctypes.c_int(5), ctypes.c_int(0)
if not fixes.XFixesQueryExtension(display, ctypes.byref(event_base), ctypes.byref(error_base)):
    sys.exit("the display has no XFixes")
fixes.XFixesQueryVersion(display, ctypes.byref(major), ctypes.byref(minor))
clipboard = x11.XInternAtom(display, b"CLIPBOARD", 0)
fixes.XFixesSelectSelectionInput(display, x11.XDefaultRootWindow(display), clipboard, 7)
x11.XFlush(display)
print("ready", flush=True)
event = ctypes.create_string_buffer(256)
connection = x11.XConnectionNumber(display)
while True:
    readable = select.select([connection, sys.stdin.fileno()], [], [])[0]
    if sys.stdin.fileno() in readable and not os.read(sys.stdin.fileno(), 4096):
        break
    while x11.XPending(display):
        x11.XNextEvent(display, event)
        if int.from_bytes(event.raw[:4], sys.byteorder) == event_base.value:
            print("changed", flush=True)
`

export interface X11Commands {
  readonly run: (args: readonly string[]) => Promise<Buffer>
  readonly spawn: (command: string, args: readonly string[]) => ChildProcessWithoutNullStreams
}

export const systemX11Commands = (display: number, xclip = "xclip"): X11Commands => {
  const env = { ...process.env, DISPLAY: `:${display}` }
  return {
    run: (args) =>
      new Promise((resolve, reject) =>
        execFile(
          xclip,
          ["-selection", "clipboard", ...args],
          { env, encoding: "buffer", maxBuffer: MAXIMUM_CONTENT_BYTES + 1, timeout: 5000 },
          (error, stdout, stderr) => {
            if (error) reject(new Error(stderr.toString("utf8").trim() || error.message))
            else resolve(stdout)
          }
        )
      ),
    spawn: (command, args) => spawn(command, [...args], { env, stdio: "pipe" })
  }
}

const utf8Html = (data: Buffer): Buffer =>
  data[0] === 0xff && data[1] === 0xfe
    ? Buffer.from(data.subarray(2).toString("utf16le"), "utf8")
    : data

export const x11DesktopClipboard = (commands: X11Commands): DesktopClipboard => ({
  watch: async (changed) => {
    await commands.run(["-version"])
    const watcher = commands.spawn("python3", ["-c", WATCHER])
    let errors = ""
    watcher.stderr.on("data", (chunk: Buffer) => {
      errors = (errors + chunk.toString("utf8")).slice(-512)
    })
    await new Promise<void>((resolve, reject) => {
      createInterface({ input: watcher.stdout }).on("line", (line) => {
        if (line === "ready") resolve()
        else if (line === "changed") changed()
      })
      watcher.once("error", reject)
      watcher.once("exit", () =>
        reject(new Error(errors.trim() || "The clipboard watcher stopped"))
      )
    })
    return () => {
      watcher.stdin.end()
      watcher.kill()
    }
  },
  read: async () => {
    const offered = new Set(
      (await commands.run(["-o", "-t", "TARGETS"]).catch(() => Buffer.alloc(0)))
        .toString("utf8")
        .split("\n")
    )
    const item: ClipboardRepresentation[] = []
    let remaining = MAXIMUM_CONTENT_BYTES
    for (const [target, type] of READ_TARGETS) {
      if (!offered.has(target) || item.some((representation) => representation.type === type))
        continue
      const raw = await commands.run(["-o", "-t", target]).catch(() => Buffer.alloc(0))
      const data = type === "public.html" ? utf8Html(raw) : raw
      if (data.length === 0 || data.length > remaining) continue
      remaining -= data.length
      item.push({ type, data })
    }
    if (item.length === 0)
      throw new Error("The desktop's clipboard is empty or holds nothing a Mac can paste.")
    return [item]
  },
  write: async (content) => {
    const representations = content.flat()
    const chosen = WRITE_TARGETS.flatMap(([type, target]) => {
      const representation = representations.find((candidate) => candidate.type === type)
      return representation === undefined ? [] : [{ representation, target }]
    })[0]
    if (chosen === undefined) throw new Error("The desktop's clipboard can't hold what was copied.")
    const owner = commands.spawn("xclip", [
      "-selection",
      "clipboard",
      "-t",
      chosen.target,
      "-verbose"
    ])
    await new Promise<void>((resolve, reject) => {
      let output = ""
      const listen = (chunk: Buffer) => {
        output = (output + chunk.toString("utf8")).slice(-512)
        if (output.includes("Waiting for selection request")) resolve()
      }
      owner.stdout.on("data", listen)
      owner.stderr.on("data", listen)
      owner.once("error", reject)
      owner.once("exit", () => reject(new Error(output.trim() || "xclip stopped")))
      owner.stdin.end(chosen.representation.data)
    })
    return [[chosen.representation]]
  }
})
