import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"

const GHOSTTY_VT_WASM_PATH = fileURLToPath(
  new URL("../../resources/ghostty-vt.wasm", import.meta.url)
)

interface GhosttyExports {
  readonly memory: WebAssembly.Memory
  readonly __indirect_function_table: WebAssembly.Table
  readonly ghostty_type_json: () => number
  readonly ghostty_wasm_alloc: (len: number) => number
  readonly ghostty_wasm_free: (ptr: number, len: number) => void
  readonly ghostty_wasm_alloc_opaque: () => number
  readonly ghostty_wasm_free_opaque: (ptr: number) => void
  readonly ghostty_wasm_take_opaque: (slot: number) => number
  readonly ghostty_free: (allocator: number, ptr: number, len: number) => void
  readonly ghostty_terminal_new: (
    allocator: number,
    out: number,
    cols: number,
    rows: number
  ) => number
  readonly ghostty_terminal_free: (terminal: number) => void
  readonly ghostty_terminal_resize: (
    terminal: number,
    cols: number,
    rows: number,
    cellWidth: number,
    cellHeight: number
  ) => number
  readonly ghostty_terminal_vt_write: (terminal: number, ptr: number, len: number) => void
  readonly ghostty_terminal_set: (terminal: number, option: number, value: number) => number
  readonly ghostty_terminal_get: (terminal: number, data: number, out: number) => number
  readonly ghostty_terminal_continuation_alloc: (
    terminal: number,
    allocator: number,
    outPtr: number,
    outLen: number
  ) => number
  readonly ghostty_formatter_terminal_new: (
    allocator: number,
    out: number,
    terminal: number,
    options: number
  ) => number
  readonly ghostty_formatter_format_alloc: (
    formatter: number,
    allocator: number,
    outPtr: number,
    outLen: number
  ) => number
  readonly ghostty_formatter_free: (formatter: number) => void
}

const GHOSTTY_FUNCTIONS = [
  "ghostty_type_json",
  "ghostty_wasm_alloc",
  "ghostty_wasm_free",
  "ghostty_wasm_alloc_opaque",
  "ghostty_wasm_free_opaque",
  "ghostty_wasm_take_opaque",
  "ghostty_free",
  "ghostty_terminal_new",
  "ghostty_terminal_free",
  "ghostty_terminal_resize",
  "ghostty_terminal_vt_write",
  "ghostty_terminal_set",
  "ghostty_terminal_get",
  "ghostty_terminal_continuation_alloc",
  "ghostty_formatter_terminal_new",
  "ghostty_formatter_format_alloc",
  "ghostty_formatter_free"
] as const satisfies ReadonlyArray<keyof GhosttyExports>

export const isGhosttyExports = (
  exports: WebAssembly.Exports
): exports is WebAssembly.Exports & GhosttyExports =>
  exports.memory instanceof WebAssembly.Memory &&
  exports.__indirect_function_table instanceof WebAssembly.Table &&
  GHOSTTY_FUNCTIONS.every((name) => typeof exports[name] === "function")

interface StructLayout {
  readonly size: number
  readonly offset: (field: string) => number
}

const CALLBACK_TRAMPOLINE = new Uint8Array([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x01, 0x60, 0x04, 0x7f, 0x7f, 0x7f,
  0x7f, 0x00, 0x02, 0x09, 0x01, 0x02, 0x6a, 0x73, 0x02, 0x63, 0x62, 0x00, 0x00, 0x03, 0x02, 0x01,
  0x00, 0x07, 0x05, 0x01, 0x01, 0x74, 0x00, 0x01, 0x0a, 0x0e, 0x01, 0x0c, 0x00, 0x20, 0x00, 0x20,
  0x01, 0x20, 0x02, 0x20, 0x03, 0x10, 0x00, 0x0b
])

export interface VtState {
  readonly cols: number
  readonly rows: number
  readonly cursorX: number
  readonly cursorY: number
  readonly cursorVisible: boolean
  readonly alternateScreen: boolean
}

export interface VtTerminalOptions {
  readonly cols: number
  readonly rows: number
  readonly onReply?: (reply: Uint8Array) => void
}

export interface VtTerminal {
  write(data: string | Uint8Array): void
  resize(cols: number, rows: number): void
  reconstruct(): Uint8Array
  text(): string
  title(): string
  state(): VtState
  free(): void
}

const SCROLLBACK_LINES = 10_000
const CONTINUATION_MAX_BYTES = 64 * 1024
const RESET_PREFIX = new TextEncoder().encode("\u001bc\u001b[3J")

const encoder = new TextEncoder()
const decoder = new TextDecoder()

/* v8 ignore start */
const layoutField = (value: unknown, key: string): unknown =>
  typeof value === "object" && value !== null ? Reflect.get(value, key) : undefined
/* v8 ignore stop */

const allocated = (ptr: number): number => {
  if (ptr === 0) throw new Error("libghostty-vt is out of memory")
  return ptr >>> 0
}

class GhosttyVt {
  readonly exports: GhosttyExports
  private readonly layout: unknown
  private readonly replyHandlers = new Map<number, (reply: Uint8Array) => void>()
  private replyCallbackIndex: number | undefined
  private nextHandle = 1

  constructor(bytes: Uint8Array<ArrayBuffer>) {
    const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), {})
    const raw = instance.exports
    if (!isGhosttyExports(raw)) throw new Error("libghostty-vt exports are incompatible")
    this.exports = {
      ...raw,
      ghostty_type_json: () => raw.ghostty_type_json() >>> 0,
      ghostty_wasm_alloc: (len) => allocated(raw.ghostty_wasm_alloc(len)),
      ghostty_wasm_alloc_opaque: () => allocated(raw.ghostty_wasm_alloc_opaque()),
      ghostty_wasm_take_opaque: (slot) => raw.ghostty_wasm_take_opaque(slot) >>> 0
    }
    const jsonPtr = this.exports.ghostty_type_json()
    const memory = this.bytes()
    let end = jsonPtr
    while (memory[end] !== 0) end += 1
    this.layout = JSON.parse(decoder.decode(memory.subarray(jsonPtr, end)))
  }

  bytes(): Uint8Array {
    return new Uint8Array(this.exports.memory.buffer)
  }

  view(): DataView {
    return new DataView(this.exports.memory.buffer)
  }

  option(name: string): number {
    return this.enumValue("GhosttyTerminalOption", name)
  }

  data(name: string): number {
    return this.enumValue("GhosttyTerminalData", name)
  }

  /* v8 ignore start */
  layoutType(name: string): unknown {
    return layoutField(layoutField(this.layout, "types"), name)
  }

  enumValue(type: string, name: string): number {
    const value = layoutField(layoutField(this.layoutType(type), "values"), name)
    if (typeof value !== "number") throw new Error(`libghostty-vt has no ${type}.${name}`)
    return value
  }

  struct(name: string): StructLayout {
    const layout = this.layoutType(name)
    const size = layoutField(layout, "size")
    if (typeof size !== "number") throw new Error(`libghostty-vt has no struct ${name}`)
    const offset = (field: string): number => {
      const value = layoutField(layoutField(layoutField(layout, "fields"), field), "offset")
      if (typeof value !== "number") throw new Error(`libghostty-vt has no ${name}.${field}`)
      return value
    }
    return { size, offset }
  }
  /* v8 ignore stop */

  check(result: number, operation: string): void {
    if (result !== 0) throw new Error(`libghostty-vt ${operation} failed (${result})`)
  }

  takeOpaque(operation: string, fill: (slot: number) => number): number {
    const slot = this.exports.ghostty_wasm_alloc_opaque()
    try {
      this.check(fill(slot), operation)
      return this.exports.ghostty_wasm_take_opaque(slot)
    } finally {
      this.exports.ghostty_wasm_free_opaque(slot)
    }
  }

  takeBuffer(operation: string, fill: (outPtr: number, outLen: number) => number): Uint8Array {
    const outPtr = this.exports.ghostty_wasm_alloc_opaque()
    const outLen = this.exports.ghostty_wasm_alloc(4)
    try {
      this.check(fill(outPtr, outLen), operation)
      const ptr = this.exports.ghostty_wasm_take_opaque(outPtr)
      const len = this.view().getUint32(outLen, true)
      const copy = this.bytes().slice(ptr, ptr + len)
      if (ptr !== 0) this.exports.ghostty_free(0, ptr, len)
      return copy
    } finally {
      this.exports.ghostty_wasm_free_opaque(outPtr)
      this.exports.ghostty_wasm_free(outLen, 4)
    }
  }

  withBytes<A>(data: Uint8Array, run: (ptr: number) => A): A {
    const ptr = this.exports.ghostty_wasm_alloc(Math.max(1, data.length))
    try {
      this.bytes().set(data, ptr)
      return run(ptr)
    } finally {
      this.exports.ghostty_wasm_free(ptr, Math.max(1, data.length))
    }
  }

  setSize(terminal: number, option: string, value: number): void {
    const ptr = this.exports.ghostty_wasm_alloc(4)
    try {
      this.view().setUint32(ptr, value, true)
      this.check(this.exports.ghostty_terminal_set(terminal, this.option(option), ptr), option)
    } finally {
      this.exports.ghostty_wasm_free(ptr, 4)
    }
  }

  getU32(terminal: number, data: string): number {
    const ptr = this.exports.ghostty_wasm_alloc(8)
    try {
      this.bytes().fill(0, ptr, ptr + 8)
      this.check(this.exports.ghostty_terminal_get(terminal, this.data(data), ptr), data)
      return this.view().getUint32(ptr, true)
    } finally {
      this.exports.ghostty_wasm_free(ptr, 8)
    }
  }

  getString(terminal: number, data: string): string {
    const layout = this.struct("GhosttyString")
    const ptr = this.exports.ghostty_wasm_alloc(layout.size)
    try {
      this.bytes().fill(0, ptr, ptr + layout.size)
      this.check(this.exports.ghostty_terminal_get(terminal, this.data(data), ptr), data)
      const view = this.view()
      const start = view.getUint32(ptr + layout.offset("ptr"), true)
      const len = view.getUint32(ptr + layout.offset("len"), true)
      return decoder.decode(this.bytes().subarray(start, start + len))
    } finally {
      this.exports.ghostty_wasm_free(ptr, layout.size)
    }
  }

  registerReplies(terminal: number, handle: number, handler: (reply: Uint8Array) => void): void {
    if (this.replyCallbackIndex === undefined) {
      const trampoline = new WebAssembly.Instance(new WebAssembly.Module(CALLBACK_TRAMPOLINE), {
        js: {
          cb: (_terminal: number, userdata: number, ptr: number, len: number) => {
            const start = ptr >>> 0
            this.replyHandlers.get(userdata)?.(this.bytes().slice(start, start + len))
          }
        }
      })
      const table = this.exports.__indirect_function_table
      const index = table.grow(1)
      table.set(index, trampoline.exports.t)
      this.replyCallbackIndex = index
    }
    this.replyHandlers.set(handle, handler)
    this.check(
      this.exports.ghostty_terminal_set(terminal, this.option("USERDATA"), handle),
      "USERDATA"
    )
    this.check(
      this.exports.ghostty_terminal_set(
        terminal,
        this.option("WRITE_PTY"),
        this.replyCallbackIndex
      ),
      "WRITE_PTY"
    )
  }

  unregisterReplies(handle: number): void {
    this.replyHandlers.delete(handle)
  }

  allocateHandle(): number {
    const handle = this.nextHandle
    this.nextHandle += 1
    return handle
  }

  format(terminal: number, emit: "PLAIN" | "VT"): Uint8Array {
    const options = this.struct("GhosttyFormatterTerminalOptions")
    const extra = this.struct("GhosttyFormatterTerminalExtra")
    const screen = this.struct("GhosttyFormatterScreenExtra")
    const ptr = this.exports.ghostty_wasm_alloc(options.size)
    let formatter: number
    try {
      this.bytes().fill(0, ptr, ptr + options.size)
      const view = this.view()
      view.setUint32(ptr, options.size, true)
      view.setInt32(
        ptr + options.offset("emit"),
        this.enumValue("GhosttyFormatterFormat", emit),
        true
      )
      view.setUint8(ptr + options.offset("trim"), 1)
      const extraPtr = ptr + options.offset("extra")
      view.setUint32(extraPtr, extra.size, true)
      const screenPtr = extraPtr + extra.offset("screen")
      view.setUint32(screenPtr, screen.size, true)
      if (emit === "VT") {
        for (const field of ["modes", "scrolling_region", "tabstops", "pwd", "keyboard"]) {
          view.setUint8(extraPtr + extra.offset(field), 1)
        }
        for (const field of [
          "cursor",
          "style",
          "hyperlink",
          "protection",
          "kitty_keyboard",
          "charsets"
        ]) {
          view.setUint8(screenPtr + screen.offset(field), 1)
        }
      }
      formatter = this.takeOpaque("formatter_terminal_new", (slot) =>
        this.exports.ghostty_formatter_terminal_new(0, slot, terminal, ptr)
      )
    } finally {
      this.exports.ghostty_wasm_free(ptr, options.size)
    }
    try {
      return this.takeBuffer("formatter_format_alloc", (outPtr, outLen) =>
        this.exports.ghostty_formatter_format_alloc(formatter, 0, outPtr, outLen)
      )
    } finally {
      this.exports.ghostty_formatter_free(formatter)
    }
  }
}

let shared: GhosttyVt | undefined

export const loadGhosttyVt = (): void => {
  shared = new GhosttyVt(readFileSync(GHOSTTY_VT_WASM_PATH))
}

const ghostty = (): GhosttyVt => {
  if (shared === undefined) loadGhosttyVt()
  return shared!
}

export const createVtTerminal = (options: VtTerminalOptions): VtTerminal => {
  const vt = ghostty()
  const exports = vt.exports
  const terminal = vt.takeOpaque("terminal_new", (slot) =>
    exports.ghostty_terminal_new(0, slot, options.cols, options.rows)
  )
  vt.setSize(terminal, "SCROLLBACK_MAX_LINES", SCROLLBACK_LINES)
  vt.setSize(terminal, "CONTINUATION_MAX_BYTES", CONTINUATION_MAX_BYTES)
  const handle = vt.allocateHandle()
  if (options.onReply !== undefined) vt.registerReplies(terminal, handle, options.onReply)
  let freed = false
  const live = (): number => {
    if (freed) throw new Error("libghostty-vt terminal was freed")
    return terminal
  }
  return {
    write: (data) => {
      const bytes = typeof data === "string" ? encoder.encode(data) : data
      if (bytes.length === 0) return
      vt.withBytes(bytes, (ptr) => exports.ghostty_terminal_vt_write(live(), ptr, bytes.length))
    },
    resize: (cols, rows) => {
      vt.check(exports.ghostty_terminal_resize(live(), cols, rows, 0, 0), "terminal_resize")
    },
    reconstruct: () => {
      const screen = vt.format(live(), "VT")
      const continuation = vt.takeBuffer("continuation_alloc", (outPtr, outLen) =>
        exports.ghostty_terminal_continuation_alloc(live(), 0, outPtr, outLen)
      )
      const out = new Uint8Array(RESET_PREFIX.length + screen.length + continuation.length)
      out.set(RESET_PREFIX, 0)
      out.set(screen, RESET_PREFIX.length)
      out.set(continuation, RESET_PREFIX.length + screen.length)
      return out
    },
    text: () => decoder.decode(vt.format(live(), "PLAIN")),
    title: () => vt.getString(live(), "TITLE"),
    state: () => {
      const id = live()
      return {
        cols: vt.getU32(id, "COLS"),
        rows: vt.getU32(id, "ROWS"),
        cursorX: vt.getU32(id, "CURSOR_X"),
        cursorY: vt.getU32(id, "CURSOR_Y"),
        cursorVisible: vt.getU32(id, "CURSOR_VISIBLE") !== 0,
        alternateScreen: vt.getU32(id, "ACTIVE_SCREEN") !== 0
      }
    },
    free: () => {
      if (freed) return
      freed = true
      vt.unregisterReplies(handle)
      exports.ghostty_terminal_free(terminal)
    }
  }
}
