import type { CodevisorApiToolSpec } from "./codevisor-api-tool-spec.js"
import { codevisorClientApiTools } from "./codevisor-api-tools-clients.js"
import { codevisorExtensionApiTools } from "./codevisor-api-tools-extensions.js"
import { codevisorHarnessApiTools } from "./codevisor-api-tools-harnesses.js"
import { codevisorJobApiTools } from "./codevisor-api-tools-jobs.js"
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
  ...codevisorServerApiTools,
  ...codevisorSessionApiTools,
  ...codevisorJobApiTools,
  ...codevisorExtensionApiTools,
  ...codevisorHarnessApiTools,
  ...codevisorClientApiTools
]

export const CODEVISOR_CONVERSATIONAL_BOT_TOOL_NAMES: ReadonlySet<string> = new Set([
  "messages.send"
])

export const CODEVISOR_BOT_TOOL_NAMES: ReadonlySet<string> = new Set([
  ...CODEVISOR_CONVERSATIONAL_BOT_TOOL_NAMES,
  "bot.projects_add",
  "bot.projects_remove"
])
