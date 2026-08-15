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
  Schema.Struct({ ...TerminalClientFrameBase, type: Schema.Literal("input"), data: Schema.String }),
  Schema.Struct({
    ...TerminalClientFrameBase,
    type: Schema.Literal("resize"),
    cols: Schema.Number,
    rows: Schema.Number
  }),
  Schema.Struct({ ...TerminalClientFrameBase, type: Schema.Literal("close") })
])
export type TerminalClientFrame = typeof TerminalClientFrame.Type

export const TerminalServerFrame = Schema.Union([
  Schema.Struct({ type: Schema.Literal("output"), seq: Schema.Number, data: Schema.String }),
  Schema.Struct({
    type: Schema.Literal("exit"),
    seq: Schema.Number,
    exitCode: Schema.optional(Schema.Number)
  }),
  Schema.Struct({ type: Schema.Literal("error"), seq: Schema.Number, message: Schema.String })
])
export type TerminalServerFrame = typeof TerminalServerFrame.Type
