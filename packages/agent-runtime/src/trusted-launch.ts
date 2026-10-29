// oxlint-disable-next-line codevisor/no-comments
// Codevisor launches every harness trusted, so repo hooks, plugins and project config run as trusted code, as they already do in Claude Code.
export const TRUSTED_LAUNCH = {
  codexConfig: { bypass_hook_trust: true },
  cursorArgs: ["--trust"],
  geminiEnv: { GEMINI_CLI_TRUST_WORKSPACE: "true" },
  grokArgs: ["--trust"],
  museArgs: ["--trust-workspace"],
  piArgs: ["--approve"]
} as const
