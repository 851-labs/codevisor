import { Schema } from "effect"

import { ConfigField, ConfigFieldValues } from "./config-fields.js"

export const PluginOAuthSpec = Schema.Struct({
  provider: Schema.String,
  authorizeUrl: Schema.String,
  tokenUrl: Schema.String,
  scopes: Schema.Array(Schema.String),
  client: Schema.Literals(["byo", "managed"]),
  authorizeParams: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  userinfoUrl: Schema.optional(Schema.String),
  identityField: Schema.optional(Schema.String),
  setupUrl: Schema.optional(Schema.String)
})
export type PluginOAuthSpec = typeof PluginOAuthSpec.Type

export const PluginAccountSpec = Schema.Struct({
  label: Schema.String,
  oauth: Schema.optional(PluginOAuthSpec),
  fields: Schema.Array(ConfigField)
})
export type PluginAccountSpec = typeof PluginAccountSpec.Type

export const PluginToolEffects = Schema.Literals(["read", "write", "external-write"])
export type PluginToolEffects = typeof PluginToolEffects.Type

export const PluginToolDigest = Schema.Struct({
  name: Schema.String,
  description: Schema.optional(Schema.String),
  effects: Schema.optional(PluginToolEffects),
  app: Schema.optional(Schema.Boolean)
})
export type PluginToolDigest = typeof PluginToolDigest.Type

export const PluginEventDigest = Schema.Struct({
  name: Schema.String,
  description: Schema.optional(Schema.String)
})
export type PluginEventDigest = typeof PluginEventDigest.Type

export const PluginSkillDigest = Schema.Struct({
  name: Schema.String,
  description: Schema.optional(Schema.String)
})
export type PluginSkillDigest = typeof PluginSkillDigest.Type

export const PluginPane = Schema.Struct({
  type: Schema.String,
  title: Schema.String,
  resourceUri: Schema.String
})
export type PluginPane = typeof PluginPane.Type

export const PluginIngress = Schema.Struct({
  name: Schema.String,
  title: Schema.optional(Schema.String)
})
export type PluginIngress = typeof PluginIngress.Type

export const PluginCapabilities = Schema.Struct({
  tools: Schema.Array(PluginToolDigest),
  events: Schema.Array(PluginEventDigest),
  skills: Schema.Array(PluginSkillDigest),
  panes: Schema.Array(PluginPane),
  ingress: Schema.Array(PluginIngress)
})
export type PluginCapabilities = typeof PluginCapabilities.Type

export const PluginAgeRating = Schema.Literals([4, 9, 13, 16, 18])
export type PluginAgeRating = typeof PluginAgeRating.Type

export const PluginCatalogSource = Schema.Literals(["first-party", "popular"])
export type PluginCatalogSource = typeof PluginCatalogSource.Type

export const PluginInstallSpec = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("bundled") }),
  Schema.Struct({
    kind: Schema.Literal("package"),
    registryType: Schema.String,
    command: Schema.String,
    args: Schema.Array(Schema.String),
    fields: Schema.Array(ConfigField)
  }),
  Schema.Struct({
    kind: Schema.Literal("remote"),
    url: Schema.String,
    fields: Schema.Array(ConfigField)
  })
])
export type PluginInstallSpec = typeof PluginInstallSpec.Type

export const PluginCatalogEntry = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  description: Schema.String,
  publisher: Schema.String,
  version: Schema.String,
  source: PluginCatalogSource,
  transport: Schema.Literals(["http", "stdio"]),
  url: Schema.optional(Schema.String),
  iconUrl: Schema.optional(Schema.String),
  docsUrl: Schema.optional(Schema.String),
  install: PluginInstallSpec,
  ageRating: Schema.optional(PluginAgeRating),
  accounts: Schema.optional(PluginAccountSpec),
  capabilities: PluginCapabilities
})
export type PluginCatalogEntry = typeof PluginCatalogEntry.Type

export const PluginCatalogResponse = Schema.Struct({
  entries: Schema.Array(PluginCatalogEntry)
})
export type PluginCatalogResponse = typeof PluginCatalogResponse.Type

export const InstallCatalogPluginRequest = Schema.Struct({
  values: Schema.optional(Schema.Record(Schema.String, Schema.Unknown))
})
export type InstallCatalogPluginRequest = typeof InstallCatalogPluginRequest.Type

export const PluginAccountMethod = Schema.Literals(["oauth2", "fields", "mcpOAuth"])
export type PluginAccountMethod = typeof PluginAccountMethod.Type

export const PluginAccountStatus = Schema.Literals(["ok", "reauthorize"])
export type PluginAccountStatus = typeof PluginAccountStatus.Type

export const PluginAccount = Schema.Struct({
  id: Schema.String,
  plugin: Schema.String,
  label: Schema.optional(Schema.String),
  identity: Schema.optional(Schema.String),
  method: PluginAccountMethod,
  values: ConfigFieldValues,
  secretsSet: Schema.Array(Schema.String),
  scopes: Schema.optional(Schema.Array(Schema.String)),
  status: PluginAccountStatus,
  createdAt: Schema.String
})
export type PluginAccount = typeof PluginAccount.Type

export const PluginAccountsResponse = Schema.Struct({ accounts: Schema.Array(PluginAccount) })
export type PluginAccountsResponse = typeof PluginAccountsResponse.Type

export const SavePluginAccountRequest = Schema.Struct({
  label: Schema.optional(Schema.String),
  values: Schema.Record(Schema.String, Schema.Unknown)
})
export type SavePluginAccountRequest = typeof SavePluginAccountRequest.Type

export const StartPluginAccountOAuthRequest = Schema.Struct({
  accountId: Schema.optional(Schema.String),
  label: Schema.optional(Schema.String)
})
export type StartPluginAccountOAuthRequest = typeof StartPluginAccountOAuthRequest.Type

export const PluginAccountOAuthStart = Schema.Struct({
  flowId: Schema.String,
  authorizationUrl: Schema.String,
  callbackScheme: Schema.optional(Schema.String)
})
export type PluginAccountOAuthStart = typeof PluginAccountOAuthStart.Type

export const PluginEventDelivery = Schema.Literals(["poll", "push", "webhook"])
export type PluginEventDelivery = typeof PluginEventDelivery.Type

export const PluginEventType = Schema.Struct({
  plugin: Schema.String,
  pluginName: Schema.String,
  name: Schema.String,
  description: Schema.optional(Schema.String),
  delivery: Schema.Array(PluginEventDelivery),
  inputSchema: Schema.optional(Schema.Unknown),
  payloadSchema: Schema.optional(Schema.Unknown)
})
export type PluginEventType = typeof PluginEventType.Type

export const PluginEventSubscription = Schema.Struct({
  id: Schema.String,
  sessionId: Schema.String,
  plugin: Schema.String,
  pluginName: Schema.String,
  accountId: Schema.optional(Schema.String),
  event: Schema.String,
  arguments: Schema.Record(Schema.String, Schema.Unknown),
  filter: Schema.optional(Schema.String),
  explained: Schema.String,
  note: Schema.optional(Schema.String),
  once: Schema.Boolean,
  createdBy: Schema.Literals(["agent", "user"]),
  pausedReason: Schema.optional(Schema.String),
  createdAt: Schema.String
})
export type PluginEventSubscription = typeof PluginEventSubscription.Type

export const PluginEventSubscriptionsResponse = Schema.Struct({
  subscriptions: Schema.Array(PluginEventSubscription)
})
export type PluginEventSubscriptionsResponse = typeof PluginEventSubscriptionsResponse.Type

export const CreatePluginEventSubscriptionRequest = Schema.Struct({
  sessionId: Schema.String,
  plugin: Schema.String,
  event: Schema.String,
  accountId: Schema.optional(Schema.String),
  arguments: Schema.optional(Schema.Record(Schema.String, Schema.Unknown)),
  filter: Schema.optional(Schema.String),
  note: Schema.optional(Schema.String),
  once: Schema.optional(Schema.Boolean),
  createdBy: Schema.optional(Schema.Literals(["agent", "user"]))
})
export type CreatePluginEventSubscriptionRequest = typeof CreatePluginEventSubscriptionRequest.Type

export const PluginEventRecord = Schema.Struct({
  id: Schema.String,
  plugin: Schema.String,
  accountId: Schema.optional(Schema.String),
  event: Schema.String,
  sourceEventId: Schema.String,
  occurredAt: Schema.String,
  receivedAt: Schema.String,
  data: Schema.Unknown
})
export type PluginEventRecord = typeof PluginEventRecord.Type
