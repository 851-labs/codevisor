import { harnessCatalog } from "@codevisor/agent-runtime"
import { expect, it } from "vitest"

import { agentProviderFactories } from "./agent-providers.js"

it("registers a provider for every built-in harness", () => {
  const environment = { env: {}, executableExists: () => false, locateExecutable: () => undefined }
  const registered = new Set(agentProviderFactories.map((make) => make(environment, {}).id))
  for (const harness of harnessCatalog) expect(registered, harness.id).toContain(harness.provider)
})
