import { Schema } from "effect"

import { parseRemoteSessionKey } from "./machines.js"

export const CreateExternalGatewayRequest = Schema.Struct({
  clientName: Schema.optional(Schema.String),
  project: Schema.optional(Schema.String)
})
export type CreateExternalGatewayRequest = typeof CreateExternalGatewayRequest.Type

export const ExternalGateway = Schema.Struct({
  url: Schema.String,
  bearerToken: Schema.String
})
export type ExternalGateway = typeof ExternalGateway.Type

const EXTERNAL_CLIENT_PREFIX = "external:"

export const externalClientSessionKey = (gatewayId: string): string =>
  `${EXTERNAL_CLIENT_PREFIX}${gatewayId}`

export const isExternalClientKey = (key: string): boolean => key.startsWith(EXTERNAL_CLIENT_PREFIX)

export const isFromExternalClient = (key: string): boolean => {
  if (isExternalClientKey(key)) return true
  const relayed = parseRemoteSessionKey(key)
  return relayed !== undefined && isExternalClientKey(relayed.sessionId)
}
