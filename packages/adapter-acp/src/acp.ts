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
export { type ConfigureAcpClientApp } from "./client-app.js"
export { runtimeEventFromNotification } from "./notifications.js"
export { turnLifecycleEvent } from "./internal.js"
export {
  extractPiStartupInfo,
  isPiStartupInfoNotification,
  piAssistantErrorFromSessionJsonl
} from "./pi.js"
export { makeAcpProvider, type AcpProviderConfig } from "./provider.js"
export { acpPrompt, type AcpPromptCapabilities } from "./prompt.js"
export { acpPermissionOutcome, acpPermissionQuestion, type AcpMappedQuestion } from "./questions.js"
export {
  type AcpConnectionExtensionContext,
  type AcpQuestionControls,
  type AcpSdkConnectionCustomization,
  type AcpSetConfigOptionContext
} from "./sdk-connection.js"
export {
  makeStdioAcpConnector,
  makeStdioAcpConnectorWithOptions,
  stdioAcpConnector,
  testAcpConnection,
  type AcpConnectionTestResult,
  type AcpStdioExtension,
  type AcpStdioExtensionContext,
  type AcpStdioExtensionFactory,
  type StdioAcpConnectorOptions
} from "./stdio-connector.js"
