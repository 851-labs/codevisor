import { makeAcpProvider } from "@codevisor/adapter-acp"
import { makeClaudeProvider } from "@codevisor/adapter-claude"
import { makeCodexProvider } from "@codevisor/adapter-codex"
import { makeCursorProvider } from "@codevisor/adapter-cursor"
import { makeGrokBuildProvider } from "@codevisor/adapter-grok-build"
import { makeOpenCodeProvider } from "@codevisor/adapter-opencode"
import { makePiProvider } from "@codevisor/adapter-pi"
import type { ProviderFactory } from "@codevisor/agent-runtime"

/// Every agent provider the server registers. Each harness's catalog entry
/// names one of these; a harness whose provider is missing can't run.
export const agentProviderFactories: ReadonlyArray<ProviderFactory> = [
  makeAcpProvider,
  makeClaudeProvider,
  makeCodexProvider,
  makeCursorProvider,
  makeGrokBuildProvider,
  makeOpenCodeProvider,
  // Pi runs its own tools; it takes nothing from the factory context.
  (environment) => makePiProvider(environment)
]
