import { testAcpConnection } from "@codevisor/adapter-acp"
import { resolveShellEnv, type AgentRuntimeService } from "@codevisor/agent-runtime"
import {
  customHarnessDefinition,
  loadCustomHarnesses,
  saveCustomHarnesses,
  type CustomHarnessStore
} from "@codevisor/harness-manager"
import { Effect } from "effect"

import { codevisorRoot } from "./data-dir.js"

/// Custom-harness persistence + handshake probe backing the
/// /v1/harnesses/custom routes. The file stays the source of truth;
/// `replace()` swaps the runtime catalog live so no restart is needed.
///
/// `root` resolves the directory holding `harnesses.json`. Tests point it at a
/// temporary directory so they never read or rewrite the developer's own
/// ~/.codevisor/harnesses.json. `probe` is the handshake boundary: the real
/// one spawns the agent binary under the login-shell environment; tests
/// substitute an in-memory fake.
export interface CustomHarnessProbe {
  readonly resolveShellEnv: () => Promise<NodeJS.ProcessEnv>
  readonly testAcpConnection: typeof testAcpConnection
}

const liveProbe: CustomHarnessProbe = { resolveShellEnv, testAcpConnection }

export const makeCustomHarnessStore = (
  agents: AgentRuntimeService,
  root: () => string = codevisorRoot,
  probe: CustomHarnessProbe = liveProbe
): CustomHarnessStore => ({
  list: async () => (await loadCustomHarnesses(root())).specs,
  replace: async (specs) => {
    await saveCustomHarnesses(root(), specs)
    agents.setExtraHarnesses(specs.map(customHarnessDefinition))
    await Effect.runPromise(agents.refreshEnvironment)
  },
  test: async (spec) =>
    probe.testAcpConnection(
      {
        args: spec.args === undefined ? [] : [...spec.args],
        command: spec.command,
        ...(spec.env === undefined ? {} : { env: spec.env })
      },
      { env: await probe.resolveShellEnv() }
    )
})
