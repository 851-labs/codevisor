import type { HarnessDefinition } from "./types.js"

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
        apply: { kind: "reinstall" },
        check: { kind: "brew" },
        when: "brew"
      },
      {
        apply: { kind: "reinstall" },
        check: { kind: "npm", packageName: "@anthropic-ai/claude-code" },
        when: "npm"
      },
      {
        apply: { args: ["update"], kind: "selfUpdate" },
        check: { kind: "npm", packageName: "@anthropic-ai/claude-code" },
        when: "any"
      }
    ]
  }
}

export const codexHarness: HarnessDefinition = {
  detectBinaries: ["codex"],
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
        apply: { args: ["update"], kind: "selfUpdate" },
        check: { kind: "npm", packageName: "@openai/codex" },
        when: "any"
      }
    ]
  }
}

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

export const museCodeHarness: HarnessDefinition = {
  detectBinaries: ["muse"],
  fallbackPaths: ["~/.local/bin/muse"],
  id: "muse-code",
  installHint: "curl -fsSL https://dev.meta.ai/install.sh | sh",
  installMethods: [{ command: "curl -fsSL https://dev.meta.ai/install.sh | sh", kind: "curl" }],
  name: "Muse Code",
  provider: "muse",
  skills: { globalDir: "~/.agents/skills", readsCanonical: true },
  symbolName: "sparkles",
  update: {
    sources: [
      {
        apply: { kind: "reinstall" },
        check: { kind: "npm", packageName: "@muse-code/sdk" },
        when: "any"
      }
    ]
  }
}

export const antigravityHarness: HarnessDefinition = {
  detectBinaries: ["agy"],
  fallbackPaths: ["~/.local/bin/agy"],
  id: "antigravity",
  installHint: "curl -fsSL https://antigravity.google/cli/install.sh | bash",
  installMethods: [
    { command: "curl -fsSL https://antigravity.google/cli/install.sh | bash", kind: "curl" }
  ],
  name: "Antigravity",
  nativeMcp: {
    format: "json",
    key: "mcpServers",
    path: "~/.gemini/config/mcp_config.json",
    projectFile: ".agents/mcp_config.json",
    writable: false
  },
  provider: "antigravity",
  skills: { globalDir: "~/.gemini/config/skills" },
  symbolName: "atom",
  update: {
    sources: [
      {
        apply: { args: ["update"], kind: "selfUpdate" },
        check: { kind: "github", repo: "google-antigravity/antigravity-cli" },
        when: "any"
      }
    ]
  }
}
