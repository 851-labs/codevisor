export interface TerminalSize {
  readonly cols: number
  readonly rows: number
}

/// Decides the PTY size when several clients of different sizes show one
/// terminal. The client being used owns it: the one typed on most recently,
/// or, until anyone types, the first to show the terminal. Programs then get
/// the size of the screen someone is actually looking at — a full-window
/// nvim on the Mac even while a phone shows the same terminal. Clients that
/// merely watch are told the PTY's size and fit its grid to their screen
/// rather than reflowing it.
///
/// Showing a terminal (a resize) doesn't claim it; using it — typing,
/// opening, tapping or clicking into it (`focus`) — does. A client
/// that goes off screen (`hide`) or disconnects (`release`) hands ownership
/// to the most recently active client still showing it. With nobody showing
/// the terminal, the PTY keeps its last size.
export class SizeArbiter {
  /// Clients showing the terminal and their sizes, least recently active
  /// first.
  private readonly visible = new Map<string, TerminalSize>()
  private owner: string | undefined

  constructor(private current: TerminalSize) {}

  get size(): TerminalSize {
    return this.current
  }

  /// A client shows the terminal at `size`. Returns the size to apply, if it
  /// changes.
  resize(clientId: string, size: TerminalSize): TerminalSize | undefined {
    this.visible.set(clientId, size)
    this.owner ??= clientId
    return this.owner === clientId ? this.apply(size) : undefined
  }

  /// A client is being used (typed on, focused): it takes the terminal's
  /// size, if it's showing it.
  claim(clientId: string): TerminalSize | undefined {
    const size = this.visible.get(clientId)
    if (size === undefined) return undefined
    this.visible.delete(clientId)
    this.visible.set(clientId, size)
    this.owner = clientId
    return this.apply(size)
  }

  /// A client stopped showing the terminal (hidden pane, backgrounded app).
  hide(clientId: string): TerminalSize | undefined {
    if (!this.visible.delete(clientId) || this.owner !== clientId) return undefined
    this.owner = [...this.visible.keys()].at(-1)
    return this.owner === undefined ? undefined : this.apply(this.visible.get(this.owner)!)
  }

  /// A client disconnected.
  release(clientId: string): TerminalSize | undefined {
    return this.hide(clientId)
  }

  private apply(size: TerminalSize): TerminalSize | undefined {
    if (size.cols === this.current.cols && size.rows === this.current.rows) return undefined
    this.current = size
    return size
  }
}
