/// Assembly surface for the Claude provider: the modules below were split
/// out of the original monolithic claude.ts; everything previously public is
/// re-exported here so index.ts and all consumers stay unchanged.
export { extractAllStringFields, extractStringField } from "./diff-stats.js"
export { makeClaudeProvider, type ClaudeProviderConfig } from "./provider.js"
export type { ClaudeQueryFn } from "./session.js"
export { webSearchSources, type WebSearchSource } from "./tool-presentation.js"
export { claudeUsageLimitsFrom } from "./usage.js"
