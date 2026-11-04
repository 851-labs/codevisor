import {
  ProtocolError,
  ProtocolErrorCode,
  ResourceNotFoundError
} from "@modelcontextprotocol/server"

export const eventsExtension = "io.modelcontextprotocol/events"
export const skillsExtension = "io.modelcontextprotocol/skills"
export const uiExtension = "io.modelcontextprotocol/ui"
export const panesExtension = "dev.codevisor/panes"
export const webhooksExtension = "dev.codevisor/webhooks"

export const subscriptionIdMeta = "io.modelcontextprotocol/subscriptionId"
export const accountMeta = "dev.codevisor/account"
export const ingressMeta = "dev.codevisor/ingress"

export const mcpAppMimeType = "text/html;profile=mcp-app"

export const eventErrorCode = {
  notFound: -32023,
  forbidden: -32024,
  unsupported: -32026
} as const

export const unknownEventError = (name: string): ProtocolError =>
  new ProtocolError(eventErrorCode.notFound, `Unknown event type: ${name}`, { kind: "event" })

export const forbiddenError = (reason: string): ProtocolError =>
  new ProtocolError(eventErrorCode.forbidden, "Forbidden", { reason })

export const unsupportedDeliveryError = (mode: string): ProtocolError =>
  new ProtocolError(eventErrorCode.unsupported, "Unsupported", {
    feature: "deliveryMode",
    value: mode
  })

export const invalidParamsError = (message: string): ProtocolError =>
  new ProtocolError(ProtocolErrorCode.InvalidParams, message)

export const resourceNotFoundError = (uri: string): ProtocolError => new ResourceNotFoundError(uri)
