import { Schema } from "effect"

export const ClientPageRequest = Schema.Union([
  Schema.Struct({ page: Schema.Literal("home") }),
  Schema.Struct({ page: Schema.Literal("new_chat"), projectId: Schema.optional(Schema.String) }),
  Schema.Struct({ page: Schema.Literal("settings"), section: Schema.optional(Schema.String) }),
  Schema.Struct({ page: Schema.Literal("dismiss") })
])
export type ClientPageRequest = typeof ClientPageRequest.Type

const positive = Schema.Number.check(Schema.isFinite(), Schema.isGreaterThan(0))
const index = Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0))
const edge = Schema.Literals(["leading", "trailing", "top", "bottom"])
export const ClientLayoutAction = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("new_tab") }),
  Schema.Struct({ kind: Schema.Literal("split"), leafId: Schema.String, edge }),
  Schema.Struct({
    kind: Schema.Literal("move"),
    leafId: Schema.String,
    targetLeafId: Schema.String,
    edge
  }),
  Schema.Struct({ kind: Schema.Literal("detach"), leafId: Schema.String }),
  Schema.Struct({
    kind: Schema.Literal("resize"),
    tabId: Schema.String,
    branchPath: Schema.Array(index),
    fractions: Schema.Array(positive),
    expectedChildren: Schema.Array(Schema.Array(Schema.String))
  }),
  Schema.Struct({ kind: Schema.Literal("reorder_tabs"), tabIds: Schema.Array(Schema.String) }),
  Schema.Struct({ kind: Schema.Literal("rename_tab"), tabId: Schema.String, title: Schema.String })
])
export const ClientLayoutRequest = Schema.Struct({
  workspaceId: Schema.String,
  action: ClientLayoutAction
})
export type ClientLayoutRequest = typeof ClientLayoutRequest.Type

export const ClientWindowRequest = Schema.Union([
  Schema.Struct({ action: Schema.Literals(["focus", "minimize", "restore"]) }),
  Schema.Struct({ action: Schema.Literal("fullscreen"), enabled: Schema.Boolean }),
  Schema.Struct({
    action: Schema.Literal("frame"),
    x: Schema.Number,
    y: Schema.Number,
    width: positive,
    height: positive
  }),
  Schema.Struct({ action: Schema.Literal("sidebar"), visible: Schema.Boolean })
])
export type ClientWindowRequest = typeof ClientWindowRequest.Type

export const ClientWindowContext = Schema.Struct({
  x: Schema.Number,
  y: Schema.Number,
  width: Schema.Number,
  height: Schema.Number,
  isMinimized: Schema.Boolean,
  isFullscreen: Schema.Boolean,
  sidebarVisible: Schema.Boolean
})
export const ClientPageContext = Schema.Struct({
  page: Schema.String,
  settingsSection: Schema.optional(Schema.String),
  presentation: Schema.optional(Schema.String)
})
export const ClientCapabilities = Schema.Struct({
  pages: Schema.Array(Schema.String),
  settingsSections: Schema.Array(Schema.String),
  layoutActions: Schema.Array(Schema.String),
  windowActions: Schema.Array(Schema.String)
})
export const ClientSplitContext = Schema.Struct({
  branchPath: Schema.Array(index),
  orientation: Schema.String,
  fractions: Schema.Array(positive),
  children: Schema.Array(Schema.Array(Schema.String))
})
