import { ErrorCode } from "@modelcontextprotocol/sdk/types.js"

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

export const resourceNotFoundCode = -32002

export class PluginProtocolError extends Error {
  constructor(
    readonly code: number,
    message: string,
    readonly data?: Record<string, unknown>
  ) {
    super(message)
  }
}

export const unknownEventError = (name: string): PluginProtocolError =>
  new PluginProtocolError(eventErrorCode.notFound, `Unknown event type: ${name}`, { kind: "event" })

export const forbiddenError = (reason: string): PluginProtocolError =>
  new PluginProtocolError(eventErrorCode.forbidden, "Forbidden", { reason })

export const unsupportedDeliveryError = (mode: string): PluginProtocolError =>
  new PluginProtocolError(eventErrorCode.unsupported, "Unsupported", {
    feature: "deliveryMode",
    value: mode
  })

export const invalidParamsError = (message: string): PluginProtocolError =>
  new PluginProtocolError(ErrorCode.InvalidParams, message)

export const resourceNotFoundError = (uri: string): PluginProtocolError =>
  new PluginProtocolError(resourceNotFoundCode, `Resource not found: ${uri}`, { uri })
