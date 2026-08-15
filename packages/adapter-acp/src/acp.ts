/// Assembly surface for the ACP provider: the modules below were split out of
/// the original monolithic acp.ts; everything previously public is re-exported
/// here so index.ts and all consumers stay unchanged.
export {
  acpConfigSelection,
  normalizeAcpConfigOptions,
  normalizeModeState
} from "./config-options.js"
export {
  acpClientCapabilities,
  acpProtocolVersion,
  type AcpAgentConnection,
  type AcpConnector,
  type AcpHarnessLaunchRequest
} from "./connection.js"
export {
  grokAskUserQuestion,
  grokGoalNotification,
  grokModeState,
  grokPlanApprovalQuestion,
  type GrokGoalNotification
} from "./grok.js"
export {
  acpConfigOptionIds,
  acpModelConfigId,
  acpModelConfigOption,
  acpReasoningEffortConfigId,
  acpReasoningEffortConfigOption,
  applyAcpModelSelection,
  applyAcpReasoningEffortSelection,
  extractAcpModelState,
  usesAcpModelSelectionExtension
} from "./model-selection.js"
export { runtimeEventFromNotification } from "./notifications.js"
export {
  extractPiStartupInfo,
  isPiStartupInfoNotification,
  piAssistantErrorFromSessionJsonl
} from "./pi.js"
export { makeAcpProvider, type AcpProviderConfig } from "./provider.js"
export { acpPrompt, type AcpPromptCapabilities } from "./prompt.js"
export { acpPermissionOutcome, acpPermissionQuestion } from "./questions.js"
export {
  makeStdioAcpConnector,
  stdioAcpConnector,
  testAcpConnection,
  type AcpConnectionTestResult
} from "./stdio-connector.js"
