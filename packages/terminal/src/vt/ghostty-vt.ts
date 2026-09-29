import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"

/// libghostty-vt compiled to WebAssembly (ReleaseSmall), built from the
/// pinned Ghostty revision in resources/GHOSTTY-VT-REF by
/// scripts/build-ghostty-vt-wasm.sh. Parsing runs in wasm so the server needs
/// no per-platform native build, and a parser fault cannot take the process
/// down with it.
export const GHOSTTY_VT_WASM_PATH = fileURLToPath(
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

interface FieldLayout {
  readonly offset: number
}
interface StructLayout {
  readonly size: number
  readonly fields: Record<string, FieldLayout>
}
interface EnumLayout {
  readonly values: Record<string, number>
}
interface TypeLayout {
  readonly types: Record<string, StructLayout & EnumLayout>
}

/// A (i32, i32, i32, i32) -> void wasm function that forwards to the JS
/// import `js.cb`. JS functions cannot be placed in a wasm function table
/// directly, so callbacks libghostty invokes through a C function pointer
/// (the write-PTY reply callback) go through this one-function module.
const CALLBACK_TRAMPOLINE = new Uint8Array([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
  // type section: (i32 i32 i32 i32) -> ()
  0x01, 0x08, 0x01, 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x00,
  // import "js" "cb" as function of type 0
  0x02, 0x09, 0x01, 0x02, 0x6a, 0x73, 0x02, 0x63, 0x62, 0x00, 0x00,
  // one defined function of type 0
  0x03, 0x02, 0x01, 0x00,
  // export it as "t" (function index 1)
  0x07, 0x05, 0x01, 0x01, 0x74, 0x00, 0x01,
  // body: local.get 0..3; call 0; end
  0x0a, 0x0e, 0x01, 0x0c, 0x00, 0x20, 0x00, 0x20, 0x01, 0x20, 0x02, 0x20, 0x03, 0x10, 0x00, 0x0b
])

/// Terminal state libghostty tracks that callers act on.
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
  /// Scrollback retained for reconstruction (libghostty prunes by page, so
  /// slightly more survives).
  readonly scrollbackLines?: number
  /// Replies the terminal generates for queries it parsed (device
  /// attributes, cursor position reports, color queries).
  readonly onReply?: (reply: Uint8Array) => void
}

export interface VtTerminal {
  write(data: string | Uint8Array): void
  resize(cols: number, rows: number): void
  /// VT bytes that rebuild this terminal's screen, scrollback, modes, and
  /// cursor from a reset, followed by any escape sequence still unfinished at
  /// the end of the last write, so live output can resume right after them.
  reconstruct(): Uint8Array
  /// The screen and scrollback as plain text.
  text(): string
  state(): VtState
  free(): void
}

export const DEFAULT_SCROLLBACK_LINES = 10_000
/// Continuation tracking bound: an unfinished sequence longer than this (an
/// enormous OSC 52 paste mid-stream) is dropped from reconstruction.
const CONTINUATION_MAX_BYTES = 64 * 1024
/// Full reset plus erase of saved lines, so a renderer that already shows
/// older output starts from a blank terminal.
const RESET_PREFIX = new TextEncoder().encode("\u001bc\u001b[3J")

const encoder = new TextEncoder()
const decoder = new TextDecoder()

class GhosttyVt {
  readonly exports: GhosttyExports
  private readonly layout: TypeLayout
  private readonly replyHandlers = new Map<number, (reply: Uint8Array) => void>()
  private replyCallbackIndex: number | undefined
  private nextHandle = 1

  constructor(bytes: Uint8Array<ArrayBuffer>) {
    const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), {})
    this.exports = instance.exports as unknown as GhosttyExports
    const jsonPtr = this.exports.ghostty_type_json()
    const memory = this.bytes()
    let end = jsonPtr
    while (memory[end] !== 0) end += 1
    this.layout = JSON.parse(decoder.decode(memory.subarray(jsonPtr, end))) as TypeLayout
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

  /* v8 ignore start -- defensive: lookups name types the checked-in build defines, which these tests exercise. */
  enumValue(type: string, name: string): number {
    const value = this.layout.types[type]?.values[name]
    if (value === undefined) throw new Error(`libghostty-vt has no ${type}.${name}`)
    return value
  }

  struct(name: string): StructLayout {
    const layout = this.layout.types[name]
    if (layout === undefined) throw new Error(`libghostty-vt has no struct ${name}`)
    return layout
  }
  /* v8 ignore stop */

  check(result: number, operation: string): void {
    if (result !== 0) throw new Error(`libghostty-vt ${operation} failed (${result})`)
  }

  /// Runs `fill` with a pointer slot for an opaque handle and returns it.
  takeOpaque(operation: string, fill: (slot: number) => number): number {
    const slot = this.exports.ghostty_wasm_alloc_opaque()
    try {
      this.check(fill(slot), operation)
      return this.exports.ghostty_wasm_take_opaque(slot)
    } finally {
      this.exports.ghostty_wasm_free_opaque(slot)
    }
  }

  /// Runs an `_alloc` style call and copies the returned buffer out.
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
      // Fields are as narrow as a bool or u16: zero the slot so the unused
      // high bytes read as zero.
      this.bytes().fill(0, ptr, ptr + 8)
      this.check(this.exports.ghostty_terminal_get(terminal, this.data(data), ptr), data)
      return this.view().getUint32(ptr, true)
    } finally {
      this.exports.ghostty_wasm_free(ptr, 8)
    }
  }

  /// Registers `handler` for replies from the terminal with userdata
  /// `handle`, installing the shared trampoline on first use.
  registerReplies(terminal: number, handle: number, handler: (reply: Uint8Array) => void): void {
    if (this.replyCallbackIndex === undefined) {
      const trampoline = new WebAssembly.Instance(new WebAssembly.Module(CALLBACK_TRAMPOLINE), {
        js: {
          cb: (_terminal: number, userdata: number, ptr: number, len: number) => {
            this.replyHandlers.get(userdata)?.(this.bytes().slice(ptr, ptr + len))
          }
        }
      })
      const table = this.exports.__indirect_function_table
      const index = table.grow(1)
      table.set(index, trampoline.exports.t as () => void)
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
        ptr + options.fields.emit!.offset,
        this.enumValue("GhosttyFormatterFormat", emit),
        true
      )
      view.setUint8(ptr + options.fields.trim!.offset, 1)
      const extraPtr = ptr + options.fields.extra!.offset
      view.setUint32(extraPtr, extra.size, true)
      const screenPtr = extraPtr + extra.fields.screen!.offset
      view.setUint32(screenPtr, screen.size, true)
      if (emit === "VT") {
        // Not "palette": the server's palette is libghostty's default, and
        // emitting all 256 entries would repaint the client's theme colors.
        for (const field of ["modes", "scrolling_region", "tabstops", "pwd", "keyboard"]) {
          view.setUint8(extraPtr + extra.fields[field]!.offset, 1)
        }
        for (const field of [
          "cursor",
          "style",
          "hyperlink",
          "protection",
          "kitty_keyboard",
          "charsets"
        ]) {
          view.setUint8(screenPtr + screen.fields[field]!.offset, 1)
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

/// Loads the wasm module once per process. `bytes` is injectable so tests
/// and packaging checks can load a specific build.
export const loadGhosttyVt = (bytes?: Uint8Array<ArrayBuffer>): void => {
  shared = new GhosttyVt(bytes ?? readFileSync(GHOSTTY_VT_WASM_PATH))
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
  vt.setSize(terminal, "SCROLLBACK_MAX_LINES", options.scrollbackLines ?? DEFAULT_SCROLLBACK_LINES)
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
