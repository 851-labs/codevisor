import { makeAcpProvider, makeStdioAcpConnectorWithOptions } from "@codevisor/adapter-acp"
import {
  adapterPromise,
  type AgentProvider,
  type HarnessAccountContext,
  type ProviderEnvironment
} from "@codevisor/agent-runtime"

import { cursorAccessToken, systemCursorCredentialStore } from "./credentials.js"
import { makeCursorExtension } from "./extension.js"
import { readCursorUsageLimits } from "./usage.js"

export const makeCursorProvider = (environment: ProviderEnvironment): AgentProvider => ({
  ...makeAcpProvider(environment, {
    connector: makeStdioAcpConnectorWithOptions({ extension: makeCursorExtension }),
    providerId: "cursor"
  }),
  readUsageLimits: (_definition, cwd, account) =>
    adapterPromise("readUsageLimits", async () => {
      const env = await accountEnv(environment, cwd, account)
      return readCursorUsageLimits({
        accessToken: () => cursorAccessToken(systemCursorCredentialStore(env)),
        fetch: (url, init) => fetch(url, init)
      })
    })
})

const accountEnv = async (
  environment: ProviderEnvironment,
  cwd: string,
  account: HarnessAccountContext | undefined
): Promise<NodeJS.ProcessEnv> => ({ ...(await environment.envFor(cwd)), ...account?.env })
