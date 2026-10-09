import type { HarnessDefinition } from "./types.js"

// Claude Code is driven directly through the Agent SDK against the user's
// own `claude` binary — no npx adapter, no Node requirement.
export const claudeCodeHarness: HarnessDefinition = {
  detectBinaries: ["claude"],
  id: "claude-code",
  installHint: "curl -fsSL https://claude.ai/install.sh | bash",
  installMethods: [
    { cask: true, formula: "claude-code@latest", kind: "brew" },
    { command: "curl -fsSL https://claude.ai/install.sh | bash", kind: "curl" },
    { kind: "npm", packageName: "@anthropic-ai/claude-code" }
  ],
  name: "Claude Code",
  // Global registrations live inside ~/.claude.json (a large state file the
  // CLI rewrites constantly — edits must stay surgical); project-level ones
  // in a committed .mcp.json. No per-server enable flag exists.
  nativeMcp: {
    format: "json",
    key: "mcpServers",
    path: "~/.claude.json",
    projectFile: ".mcp.json",
    writable: true
  },
  provider: "claude",
  skills: { globalDir: "~/.claude/skills" },
  symbolName: "sparkle",
  update: {
    sources: [
      {
        // Homebrew-owned binaries deliberately refuse `claude update` and
        // exit successfully after printing the manual brew command. Infer
        // the exact owning cask so stable and @latest stay on their channel.
        apply: { kind: "reinstall" },
        check: { kind: "brew" },
        when: "brew"
      },
      {
        // npm owns this binary, so update it directly through npm rather
        // than depending on Claude's package-manager diagnostics.
        apply: { kind: "reinstall" },
        check: { kind: "npm", packageName: "@anthropic-ai/claude-code" },
        when: "npm"
      },
      {
        // Native/curl installs are owned by Claude's native updater. This
        // also remains the safe fallback for standalone/unknown layouts.
        apply: { args: ["update"], kind: "selfUpdate" },
        check: { kind: "npm", packageName: "@anthropic-ai/claude-code" },
        when: "any"
      }
    ]
  }
}

// Codex is driven directly through `codex app-server` (JSONL JSON-RPC) —
// no npx adapter, no Node requirement.
export const codexHarness: HarnessDefinition = {
  detectBinaries: ["codex"],
  // The ChatGPT/Codex desktop apps bundle the full CLI (same binary,
  // app-managed updates) and share ~/.codex auth with it — app-only users
  // get a working harness without installing the CLI. When both exist, the
  // Codex provider compares binary versions and uses the newer app-server.
  fallbackPaths: [
    "/Applications/ChatGPT.app/Contents/Resources/codex",
    "~/Applications/ChatGPT.app/Contents/Resources/codex",
    "/Applications/Codex.app/Contents/Resources/codex",
    "~/Applications/Codex.app/Contents/Resources/codex"
  ],
  id: "codex",
  installHint: "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
  installMethods: [
    { cask: true, formula: "codex", kind: "brew" },
    { command: "curl -fsSL https://chatgpt.com/codex/install.sh | sh", kind: "curl" },
    { kind: "npm", packageName: "@openai/codex" }
  ],
  name: "Codex",
  // TOML config: readable everywhere, but edits go through the verified
  // text-excision path (never a whole-file TOML re-stringify). The scanner
  // honors CODEX_HOME over the literal path.
  nativeMcp: {
    format: "toml",
    key: "mcp_servers",
    path: "~/.codex/config.toml",
    writable: true
  },
  provider: "codex",
  skills: { globalDir: "~/.codex/skills" },
  symbolName: "chevron.left.forwardslash.chevron.right",
  update: {
    sources: [
      {
        // App-bundled codex: `codex update` refuses (InstallMethod::Other),
        // so Codevisor updates the whole app bundle from its Sparkle feed.
        // The app ships its own (often pre-release) channel — never compare
        // it against the npm/brew stable line.
        apply: { kind: "appBundleSwap" },
        check: {
          appcastUrl: "https://persistent.oaistatic.com/codex-app-prod/appcast.xml",
          appcastUrlX64: "https://persistent.oaistatic.com/codex-app-prod/appcast-x64.xml",
          kind: "sparkle"
        },
        when: "appBundle"
      },
      {
        apply: { args: ["update"], kind: "selfUpdate" },
        check: { formula: "codex", kind: "brew" },
        when: "brew"
      },
      {
        // `codex update` detects npm/pnpm/bun/standalone itself.
        apply: { args: ["update"], kind: "selfUpdate" },
        check: { kind: "npm", packageName: "@openai/codex" },
        when: "any"
      }
    ]
  }
}

// Pi is driven directly over its RPC mode (`pi --mode rpc`, the Pi
// adapter), so Pi keeps ownership of its models, settings, extensions, and
// session store with nothing to install beyond Pi itself.
export const piHarness: HarnessDefinition = {
  detectBinaries: ["pi"],
  id: "pi",
  installHint: "npm install -g @earendil-works/pi-coding-agent",
  installMethods: [
    { command: "curl -fsSL https://pi.dev/install.sh | sh", kind: "curl" },
    { kind: "npm", packageName: "@earendil-works/pi-coding-agent", ignoreScripts: true }
  ],
  name: "Pi",
  provider: "pi",
  symbolName: "function",
  update: {
    sources: [
      {
        apply: { kind: "reinstall" },
        check: { kind: "npm", packageName: "@earendil-works/pi-coding-agent" },
        when: "any"
      }
    ]
  }
}
