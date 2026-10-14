import * as acp from "@agentclientprotocol/sdk"

import type { AcpPermissionOutcome } from "./questions.js"

export type ConfigureAcpClientApp = (app: acp.ClientApp) => acp.ClientApp

/* v8 ignore start */
export const createClientApp = (
  onSessionUpdate: (notification: acp.SessionNotification) => void,
  onPermissionRequest: (params: unknown) => Promise<AcpPermissionOutcome>,
  configure?: ConfigureAcpClientApp
): acp.ClientApp => {
  let app = acp
    .client({ name: "Codevisor" })
    .onNotification(acp.methods.client.session.update, ({ params }) => {
      onSessionUpdate(params)
    })
    .onRequest(acp.methods.client.session.requestPermission, ({ params }) =>
      onPermissionRequest(params)
    )
  return configure === undefined ? app : configure(app)
}
/* v8 ignore stop */
