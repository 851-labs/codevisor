import {
  type ClipboardContent,
  ClipboardTransfer,
  isRecord,
  parseClipboardMessage,
  sameClipboard
} from "./vnc-clipboard.js"

const CHANGE_SETTLE_MS = 150

export interface DesktopClipboard {
  readonly watch: (changed: () => void) => Promise<() => void>
  readonly read: () => Promise<ClipboardContent>
  readonly write: (content: ClipboardContent) => Promise<ClipboardContent>
}

export interface ClipboardClock {
  readonly now: () => number
  readonly setTimeout: (run: () => void, milliseconds: number) => () => void
  readonly setInterval: (run: () => void, milliseconds: number) => () => void
}

export const systemClipboardClock: ClipboardClock = {
  now: () => performance.now(),
  setTimeout: (run, milliseconds) => {
    const timer = setTimeout(run, milliseconds)
    return () => clearTimeout(timer)
  },
  setInterval: (run, milliseconds) => {
    const timer = setInterval(run, milliseconds)
    return () => clearInterval(timer)
  }
}

export class VNCClipboardBridge {
  private readonly transfer: ClipboardTransfer
  private sharing = false
  private shared: ClipboardContent | undefined
  private sendingContent: ClipboardContent | undefined
  private changed = false
  private closed = false
  private stops: Array<() => void> = []

  constructor(
    private readonly desktop: DesktopClipboard,
    private readonly sendText: (text: string) => void,
    private readonly mayControl: () => boolean,
    private readonly clock: ClipboardClock = systemClipboardClock
  ) {
    this.transfer = new ClipboardTransfer({
      send: (message) => {
        if (this.closed) return false
        this.sendText(JSON.stringify({ type: "clipboard", version: 1, message }))
        return true
      },
      now: clock.now,
      canReceiveUnsolicited: mayControl,
      read: () => desktop.read(),
      write: async (content) => {
        this.shared = await desktop.write(content)
      },
      onFinished: (error) => this.finished(error)
    })
  }

  async start(): Promise<void> {
    let settle: (() => void) | undefined
    const stopWatching = await this.desktop.watch(() => {
      settle?.()
      settle = this.clock.setTimeout(() => {
        settle = undefined
        this.desktopChanged()
      }, CHANGE_SETTLE_MS)
    })
    if (this.closed) {
      stopWatching()
      return
    }
    this.stops.push(stopWatching, () => settle?.())
    this.stops.push(this.clock.setInterval(() => this.transfer.tick(), 1000))
    this.sendText(JSON.stringify({ type: "clipboard-host", richContent: true }))
  }

  receive(text: string): boolean {
    let frame: unknown
    try {
      frame = JSON.parse(text)
    } catch {
      return false
    }
    if (!isRecord(frame)) return false
    const { type, version, message, sharing } = frame
    if (typeof type !== "string" || !type.startsWith("clipboard")) return false
    if (this.closed) return true
    if (type === "clipboard-viewer" && typeof sharing === "boolean") {
      if (sharing && !this.sharing) this.shared = undefined
      this.sharing = sharing
    } else if (type === "clipboard" && version === 1) {
      const parsed = parseClipboardMessage(message)
      if (parsed === undefined) return true
      if ("begin" in parsed && this.transfer.sending) this.transfer.cancel()
      this.transfer.receive(parsed)
    }
    return true
  }

  close(): void {
    if (this.closed) return
    this.closed = true
    this.transfer.cancel()
    for (const stop of this.stops.splice(0)) stop()
  }

  private desktopChanged(): void {
    if (this.closed || !this.sharing || !this.mayControl()) return
    if (this.transfer.busy) {
      this.changed = true
      return
    }
    this.changed = false
    this.desktop.read().then(
      (content) => {
        if (this.closed || !this.sharing || this.transfer.busy) return
        if (this.shared !== undefined && sameClipboard(content, this.shared)) return
        this.sendingContent = content
        this.transfer.sendContent(content)
      },
      () => undefined
    )
  }

  private finished(error: string | undefined): void {
    if (error === undefined && this.sendingContent !== undefined) this.shared = this.sendingContent
    this.sendingContent = undefined
    if (this.changed) this.desktopChanged()
  }
}
