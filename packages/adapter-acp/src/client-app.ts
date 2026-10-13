import * as acp from "@agentclientprotocol/sdk"

import type { AcpPermissionOutcome } from "./questions.js"

export type ConfigureAcpClientApp = (app: acp.ClientApp) => acp.ClientApp

/* v8 ignore start -- stdio ACP adapter is exercised by integration/packaging smoke tests. */
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
    // Permission requests are the agent explicitly deferring to the human
    // (ACP's contract — this is what makes plan mode gate anything). The
    // connector answers them under Codevisor's full-access policy
    // (permission-policy.ts) and asks the user only where that policy gates.
    .onRequest(acp.methods.client.session.requestPermission, ({ params }) =>
      onPermissionRequest(params)
    )
  return configure === undefined ? app : configure(app)
}
/* v8 ignore stop */
