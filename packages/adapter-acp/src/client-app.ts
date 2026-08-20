import * as acp from "@agentclientprotocol/sdk"
import type { AcpTerminalHost } from "./acp-terminals.js"
import type { AcpPermissionOutcome } from "./questions.js"

export type ConfigureAcpClientApp = (app: acp.ClientApp) => acp.ClientApp

/* v8 ignore start -- stdio ACP adapter is exercised by integration/packaging smoke tests. */
export const createClientApp = (
  onSessionUpdate: (notification: acp.SessionNotification) => void,
  onPermissionRequest: (params: unknown) => Promise<AcpPermissionOutcome>,
  terminals?: AcpTerminalHost,
  configure?: ConfigureAcpClientApp
): acp.ClientApp => {
  let app = acp
    .client({ name: "Codevisor" })
    .onNotification(acp.methods.client.session.update, ({ params }) => {
      onSessionUpdate(params)
    })
    // Permission requests are the agent explicitly deferring to the human
    // (ACP's contract — this is what makes plan mode gate anything), so they
    // surface as blocking questions rather than being auto-approved.
    .onRequest(acp.methods.client.session.requestPermission, ({ params }) =>
      onPermissionRequest(params)
    )
  if (configure !== undefined) app = configure(app)
  if (terminals === undefined) {
    return app
  }
  // Client-side terminals: the agent runs shell commands in processes we own
  // (see acp-terminals.ts). Only registered when the terminal capability is
  // advertised, so agents without the capability never reach these.
  return app
    .onRequest(acp.methods.client.terminal.create, ({ params }) =>
      terminals.create({
        sessionId: params.sessionId,
        command: params.command,
        ...(params.args === undefined ? {} : { args: params.args }),
        ...(params.env === undefined || params.env === null ? {} : { env: params.env }),
        ...(params.cwd === undefined ? {} : { cwd: params.cwd }),
        ...(params.outputByteLimit === undefined ? {} : { outputByteLimit: params.outputByteLimit })
      })
    )
    .onRequest(acp.methods.client.terminal.output, ({ params }) =>
      terminals.output({ sessionId: params.sessionId, terminalId: params.terminalId })
    )
    .onRequest(acp.methods.client.terminal.waitForExit, ({ params }) =>
      terminals.waitForExit({ sessionId: params.sessionId, terminalId: params.terminalId })
    )
    .onRequest(acp.methods.client.terminal.kill, ({ params }) => {
      terminals.kill({ sessionId: params.sessionId, terminalId: params.terminalId })
      return {}
    })
    .onRequest(acp.methods.client.terminal.release, ({ params }) => {
      terminals.release({ sessionId: params.sessionId, terminalId: params.terminalId })
      return {}
    })
}
/* v8 ignore stop */
