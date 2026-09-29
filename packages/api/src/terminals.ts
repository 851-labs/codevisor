import { Schema } from "effect"

export const TerminalCreateRequest = Schema.Struct({
  sessionId: Schema.String,
  cwd: Schema.String,
  cols: Schema.Number,
  rows: Schema.Number,
  shell: Schema.optional(Schema.String),
  args: Schema.optional(Schema.Array(Schema.String)),
  /** Attach to an existing (possibly exited) terminal under `sessionId`
   *  without ever spawning a shell — used for agent-owned background-task
   *  terminals, where the process lifecycle belongs to the agent runtime.
   *  Fails when nothing is registered yet; clients retry. */
  attachOnly: Schema.optional(Schema.Boolean)
})
export type TerminalCreateRequest = typeof TerminalCreateRequest.Type

export const TerminalCreateResponse = Schema.Struct({
  terminalId: Schema.String,
  websocketPath: Schema.String,
  nextOutputSeq: Schema.Number
})
export type TerminalCreateResponse = typeof TerminalCreateResponse.Type

const TerminalClientFrameBase = {
  clientId: Schema.String,
  clientSeq: Schema.Number
} as const

export const TerminalClientFrame = Schema.Union([
  Schema.Struct({
    ...TerminalClientFrameBase,
    type: Schema.Literal("input"),
    data: Schema.String,
    /** False for a terminal's reply to a program's query: input, but not a
     *  sign the client is being used, so it doesn't take the PTY's size. */
    claim: Schema.optional(Schema.Boolean)
  }),
  Schema.Struct({
    ...TerminalClientFrameBase,
    type: Schema.Literal("resize"),
    cols: Schema.Number,
    rows: Schema.Number
  }),
  Schema.Struct({ ...TerminalClientFrameBase, type: Schema.Literal("close") }),
  /** The client stopped showing the terminal (a hidden pane, a backgrounded
   *  app): its size no longer constrains the PTY until it resizes again. */
  Schema.Struct({ ...TerminalClientFrameBase, type: Schema.Literal("hide") }),
  /** The client is being used (the terminal was opened, tapped, or clicked
   *  into on it): it takes the PTY's size, as typing on it does. */
  Schema.Struct({ ...TerminalClientFrameBase, type: Schema.Literal("focus") }),
  /** Clear the terminal for every client (⌘K): scrollback always; the screen
   *  too, with the shell redrawing its prompt, when the shell is in the
   *  foreground. */
  Schema.Struct({ ...TerminalClientFrameBase, type: Schema.Literal("clear") })
])
export type TerminalClientFrame = typeof TerminalClientFrame.Type

/** Round-trip probe, answered with `{ type: "pong", seq: 0, t }`. `srtt` is
 *  the client's smoothed round trip in milliseconds; the server uses it to
 *  pace output on slow links. Not sequenced: probes are never replayed. */
export const TerminalPingFrame = Schema.Struct({
  type: Schema.Literal("ping"),
  t: Schema.Number,
  srtt: Schema.optional(Schema.Number)
})
export type TerminalPingFrame = typeof TerminalPingFrame.Type

export const TerminalServerFrame = Schema.Union([
  Schema.Struct({
    type: Schema.Literal("output"),
    seq: Schema.Number,
    data: Schema.String,
    /** The server's reconstruction of the terminal's current screen and
     *  scrollback, sent when a client's replay cursor is older than the
     *  retained output. It starts with a full reset, so renderers replace
     *  what they show; like replayed history, it may contain queries that
     *  were already answered and must not be answered again. */
    reset: Schema.optional(Schema.Boolean)
  }),
  Schema.Struct({
    type: Schema.Literal("exit"),
    seq: Schema.Number,
    exitCode: Schema.optional(Schema.Number)
  }),
  Schema.Struct({ type: Schema.Literal("error"), seq: Schema.Number, message: Schema.String }),
  /** The PTY's current size, sent on attach and whenever it changes. The
   *  client being typed on sets it; a client showing a larger PTY than its
   *  own screen fits that grid to its screen instead of reflowing it. */
  /** Protocol 2: the client frame with this `clientSeq` (and every earlier
   *  one) was handled, so the client can stop keeping it for resending. */
  Schema.Struct({ type: Schema.Literal("ack"), seq: Schema.Number, clientSeq: Schema.Number }),
  Schema.Struct({
    type: Schema.Literal("size"),
    seq: Schema.Number,
    cols: Schema.Number,
    rows: Schema.Number
  })
])
export type TerminalServerFrame = typeof TerminalServerFrame.Type
