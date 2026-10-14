import { Schema } from "effect"

export const TerminalCreateRequest = Schema.Struct({
  sessionId: Schema.String,
  cwd: Schema.String,
  cols: Schema.Number,
  rows: Schema.Number,
  shell: Schema.optional(Schema.String),
  args: Schema.optional(Schema.Array(Schema.String)),
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
    claim: Schema.optional(Schema.Boolean)
  }),
  Schema.Struct({
    ...TerminalClientFrameBase,
    type: Schema.Literal("resize"),
    cols: Schema.Number,
    rows: Schema.Number
  }),
  Schema.Struct({ ...TerminalClientFrameBase, type: Schema.Literal("close") }),
  Schema.Struct({ ...TerminalClientFrameBase, type: Schema.Literal("hide") }),
  Schema.Struct({ ...TerminalClientFrameBase, type: Schema.Literal("focus") }),
  Schema.Struct({ ...TerminalClientFrameBase, type: Schema.Literal("clear") })
])
export type TerminalClientFrame = typeof TerminalClientFrame.Type

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
    reset: Schema.optional(Schema.Boolean)
  }),
  Schema.Struct({
    type: Schema.Literal("exit"),
    seq: Schema.Number,
    exitCode: Schema.optional(Schema.Number)
  }),
  Schema.Struct({ type: Schema.Literal("error"), seq: Schema.Number, message: Schema.String }),
  Schema.Struct({ type: Schema.Literal("ack"), seq: Schema.Number, clientSeq: Schema.Number }),
  Schema.Struct({
    type: Schema.Literal("size"),
    seq: Schema.Number,
    cols: Schema.Number,
    rows: Schema.Number
  })
])
export type TerminalServerFrame = typeof TerminalServerFrame.Type
