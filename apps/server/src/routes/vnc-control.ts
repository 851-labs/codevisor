/// One controller at a time for a VNC desktop, decided by the server (851-2338).
///
/// Every viewer's RFB stream passes through codevisor-server's socket route,
/// so the server holds the lease. Last one wins: a request hands control to
/// the requester at once and tells the previous controller who took it. Only
/// the controller's input and clipboard reach the desktop; the desktop's size
/// follows the controller, or, when nobody controls, the most recent viewer.
///
/// Viewers speak it in text frames on the same WebSocket as the RFB bytes
/// (binary frames): `{"type":"request","name":…}` and `{"type":"release"}`;
/// the server answers `{"type":"granted"}` and `{"type":"revoked","by":…}`.
/// A viewer that never sends one (an older app) isn't arbitrated, as before.
export class VNCControlArbiter {
  private readonly viewers = new Map<
    number,
    { send: (text: string) => void; arbitrated: boolean }
  >()
  private controller: number | undefined
  private nextId = 1
  private latest: number | undefined

  join(send: (text: string) => void): number {
    const id = this.nextId++
    this.viewers.set(id, { send, arbitrated: false })
    this.latest = id
    return id
  }

  leave(id: number): void {
    this.viewers.delete(id)
    if (this.controller === id) this.controller = undefined
    if (this.latest === id) this.latest = [...this.viewers.keys()].at(-1)
  }

  /// A viewer's control message (text frame); malformed ones are ignored.
  receive(id: number, text: string): void {
    const viewer = this.viewers.get(id)
    if (viewer === undefined) return
    let message: unknown
    try {
      message = JSON.parse(text)
    } catch {
      return
    }
    if (typeof message !== "object" || message === null) return
    const { type, name } = message as { type?: unknown; name?: unknown }
    viewer.arbitrated = true
    if (type === "request") {
      const previous = this.controller
      this.controller = id
      if (previous !== undefined && previous !== id) {
        const by =
          typeof name === "string" && name.trim() !== ""
            ? name.trim().slice(0, 100)
            : "Another viewer"
        this.viewers.get(previous)?.send(JSON.stringify({ type: "revoked", by }))
      }
      viewer.send(JSON.stringify({ type: "granted" }))
    } else if (type === "release" && this.controller === id) {
      this.controller = undefined
    }
  }

  /// Input and clipboard: the controller's, or any viewer that isn't arbitrated (an older app).
  mayControl(id: number): boolean {
    const viewer = this.viewers.get(id)
    return viewer !== undefined && (!viewer.arbitrated || this.controller === id)
  }

  /// The desktop's size: the controller's; with no controller, the most recent viewer's.
  mayResize(id: number): boolean {
    const viewer = this.viewers.get(id)
    if (viewer === undefined) return false
    if (!viewer.arbitrated) return true
    return this.controller === undefined ? this.latest === id : this.controller === id
  }
}

const arbiters = new Map<number, VNCControlArbiter>()

/// The arbiter for the VNC server on `port` (one per desktop, for the server's lifetime).
export const vncControlArbiter = (port: number): VNCControlArbiter => {
  let arbiter = arbiters.get(port)
  if (arbiter === undefined) {
    arbiter = new VNCControlArbiter()
    arbiters.set(port, arbiter)
  }
  return arbiter
}
