export const signInFailure = (cause: unknown, serverUrl: string): unknown => {
  if (!isFetchFailure(cause)) return cause
  return new Error(unreachableSignIn(new URL(serverUrl).host), { cause })
}

const isFetchFailure = (cause: unknown): boolean =>
  cause instanceof TypeError && cause.message === "fetch failed"

const unreachableSignIn = (host: string): string =>
  `Couldn't reach ${host}. Check your network connection and try again.`

export type McpLoopbackReason = "noCloud" | "ownClient" | "cloudRefused"

export class McpSignInNeedsMachine extends Error {
  constructor(
    readonly reason: McpLoopbackReason,
    pluginName: string
  ) {
    super(loopbackOnlyMessage(reason, pluginName))
    this.name = "McpSignInNeedsMachine"
  }
}

const loopbackOnlyMessage = (reason: McpLoopbackReason, pluginName: string): string =>
  `${pluginName} ${loopbackOnlyReasons[reason]}`

const loopbackOnlyReasons: Readonly<Record<McpLoopbackReason, string>> = {
  noCloud:
    "sign-in can't finish from this device because the machine it runs on isn't connected to Codevisor Cloud. Sign that machine in to Codevisor Cloud, or sign in from Codevisor on that machine.",
  ownClient:
    "uses your own OAuth client, which only sends sign-in back to the machine it runs on. Sign in from Codevisor on that machine.",
  cloudRefused:
    "won't send sign-in back through Codevisor Cloud, so it can only finish on the machine it runs on. Sign in from Codevisor on that machine."
}
