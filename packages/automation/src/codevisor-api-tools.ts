import type { CodevisorApiToolSpec } from "./codevisor-api-tool-spec.js"
import { codevisorAgentApiTools } from "./codevisor-api-tools-agents.js"
import { codevisorBotApiTools } from "./codevisor-api-tools-bots.js"
import { codevisorClientApiTools } from "./codevisor-api-tools-clients.js"
import { codevisorExtensionApiTools } from "./codevisor-api-tools-extensions.js"
import { codevisorHarnessApiTools } from "./codevisor-api-tools-harnesses.js"
import { codevisorJobApiTools } from "./codevisor-api-tools-jobs.js"
import { codevisorMachineApiTools } from "./codevisor-api-tools-machine.js"
import { codevisorSandboxApiTools } from "./codevisor-api-tools-sandboxes.js"
import { codevisorServerApiTools } from "./codevisor-api-tools-server.js"
import { codevisorSessionApiTools } from "./codevisor-api-tools-sessions.js"

export { objectSchema } from "./codevisor-api-tool-spec.js"
export type {
  CodevisorApiToolSpec,
  HttpMethod,
  JsonSchema,
  QueryParameter
} from "./codevisor-api-tool-spec.js"

export const CODEVISOR_API_TOOLS: ReadonlyArray<CodevisorApiToolSpec> = [
  ...codevisorAgentApiTools,
  ...codevisorServerApiTools,
  ...codevisorSandboxApiTools,
  ...codevisorSessionApiTools,
  ...codevisorBotApiTools,
  ...codevisorJobApiTools,
  ...codevisorExtensionApiTools,
  ...codevisorHarnessApiTools,
  ...codevisorClientApiTools,
  ...codevisorMachineApiTools
]

export const CODEVISOR_BOT_TOOL_NAMES: ReadonlySet<string> = new Set([
  "messages.send",
  "messages.list",
  "bot.projects_add",
  "bot.projects_remove"
])
