import { additionalAcpHarnesses } from "./harness-catalog-acp.js"
import { executableHarness } from "./harness-catalog-support.js"
import type { HarnessDefinition } from "./types.js"

// Install commands and ACP launch arguments audited against upstream on 2026-09-13.
// Sources, registry revision, and exclusions: docs/harness-catalog-audit.md.
export const harnessCatalog: ReadonlyArray<HarnessDefinition> = [
  // Claude Code is driven directly through the Agent SDK against the user's
  // own `claude` binary — no npx adapter, no Node requirement.
  {
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
  },
  // Codex is driven directly through `codex app-server` (JSONL JSON-RPC) —
  // no npx adapter, no Node requirement.
  {
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
  },
  // Pi exposes an RPC mode but not ACP directly. The pinned adapter bridges
  // Codevisor's existing ACP provider to the user's installed `pi` binary, so
  // Pi keeps ownership of its models, settings, extensions, and session store.
  {
    detectBinaries: ["pi"],
    id: "pi",
    installHint: "npm install -g @earendil-works/pi-coding-agent",
    installMethods: [
      { command: "curl -fsSL https://pi.dev/install.sh | sh", kind: "curl" },
      { kind: "npm", packageName: "@earendil-works/pi-coding-agent", ignoreScripts: true }
    ],
    launch: { args: [], kind: "npx", packageName: "pi-acp@0.0.33" },
    name: "Pi",
    provider: "acp",
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
  },
  executableHarness("gemini", "Gemini CLI", "diamond", ["gemini"], "gemini", ["--acp"], {
    installMethods: [
      { kind: "npm", packageName: "@google/gemini-cli" },
      { formula: "gemini-cli", kind: "brew" }
    ],
    nativeMcp: {
      format: "json",
      key: "mcpServers",
      path: "~/.gemini/settings.json",
      writable: true
    },
    skills: { globalDir: "~/.gemini/skills" },
    update: {
      // Gemini CLI has no self-update command (explicitly "not planned"
      // upstream) — reinstall via the detected origin.
      sources: [
        {
          apply: { kind: "reinstall" },
          check: { formula: "gemini-cli", kind: "brew" },
          when: "brew"
        },
        {
          apply: { kind: "reinstall" },
          check: { kind: "npm", packageName: "@google/gemini-cli" },
          when: "any"
        }
      ]
    }
  }),
  executableHarness("opencode", "OpenCode", "curlybraces", ["opencode"], "opencode", ["acp"], {
    installMethods: [
      { command: "curl -fsSL https://opencode.ai/install | bash", kind: "curl" },
      { kind: "npm", packageName: "opencode-ai" },
      { formula: "anomalyco/tap/opencode", kind: "brew" }
    ],
    // OpenCode has a real per-server `enabled` flag — the one JSON harness
    // where a native disable toggle is honest. XDG_CONFIG_HOME is honored by
    // the scanner.
    nativeMcp: {
      disableField: { enabledWhen: true, name: "enabled" },
      format: "json",
      key: "mcp",
      path: "~/.config/opencode/opencode.json",
      writable: true
    },
    // OpenCode scans ~/.agents/skills (and ~/.claude/skills) in addition to
    // its own directory — every global skill is ambiently available.
    skills: { alsoReadsCanonical: true, globalDir: "~/.config/opencode/skills" },
    update: {
      // `opencode upgrade` detects curl/npm/pnpm/bun/brew itself.
      sources: [
        {
          apply: { args: ["upgrade"], kind: "selfUpdate" },
          check: { kind: "npm", packageName: "opencode-ai" },
          when: "any"
        }
      ]
    }
  }),
  executableHarness("goose", "goose", "bird", ["goose"], "goose", ["acp"], {
    installMethods: [
      { formula: "block-goose-cli", kind: "brew" },
      {
        command:
          "curl -fsSL https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh | CONFIGURE=false bash",
        kind: "curl"
      }
    ],
    // Read-only in v1: comment-preserving YAML edits aren't wired up yet, and
    // goose configs commonly carry hand-written comments.
    nativeMcp: {
      format: "yaml",
      key: "extensions",
      path: "~/.config/goose/config.yaml",
      writable: false
    },
    update: {
      sources: [
        {
          // `goose update` blindly replaces the binary in place — on a brew
          // install that clobbers the Cellar copy, so delegate to brew.
          apply: { kind: "reinstall" },
          check: { formula: "block-goose-cli", kind: "brew" },
          when: "brew"
        },
        {
          apply: { args: ["update"], kind: "selfUpdate" },
          check: { kind: "github", repo: "block/goose" },
          when: "any"
        }
      ]
    }
  }),
  {
    detectBinaries: ["cursor-agent"],
    id: "cursor",
    installHint: "curl https://cursor.com/install -fsS | bash",
    installMethods: [{ command: "curl https://cursor.com/install -fsS | bash", kind: "curl" }],
    launch: {
      args: ["--force", "--sandbox", "disabled", "acp"],
      command: "cursor-agent",
      kind: "executable"
    },
    name: "Cursor",
    provider: "cursor",
    symbolName: "cursorarrow.rays"
  },
  // Amp's adapter requires the separately installed Amp CLI. Keep detection
  // on the adapter; the complete npm install brings in both executables.
  executableHarness("amp", "Amp", "bolt", ["amp-acp"], "amp-acp", [], {
    installHint: "npm install -g amp-acp @ampcode/cli",
    requiredBinaries: ["amp"],
    installMethods: [{ kind: "npm", packageName: "amp-acp", additionalPackages: ["@ampcode/cli"] }],
    skills: { globalDir: "~/.config/agents/skills" }
  }),
  executableHarness("auggie", "Auggie CLI", "a.square", ["auggie"], "auggie", ["--acp"], {
    installMethods: [{ kind: "npm", packageName: "@augmentcode/auggie" }],
    skills: { globalDir: "~/.augment/skills" },
    update: {
      // No self-update command; auggie's own background auto-updater covers
      // most installs, reinstall covers the rest.
      sources: [
        {
          apply: { kind: "reinstall" },
          check: { kind: "npm", packageName: "@augmentcode/auggie" },
          when: "any"
        }
      ]
    }
  }),
  executableHarness("cline", "Cline", "terminal", ["cline"], "cline", ["--acp"], {
    installMethods: [{ kind: "npm", packageName: "cline" }],
    // Cline CLI stores MCPs in its data dir and has a real `disabled` flag.
    // Its skills dir IS the canonical ~/.agents/skills store — never symlink.
    nativeMcp: {
      disableField: { enabledWhen: false, name: "disabled" },
      format: "json",
      key: "mcpServers",
      path: "~/.cline/data/settings/cline_mcp_settings.json",
      writable: true
    },
    skills: { globalDir: "~/.agents/skills", readsCanonical: true },
    update: {
      // `cline update` detects npm/pnpm/yarn/bun itself (npm-only distro).
      sources: [
        {
          apply: { args: ["update"], kind: "selfUpdate" },
          check: { kind: "npm", packageName: "cline" },
          when: "any"
        }
      ]
    }
  }),
  executableHarness(
    "github-copilot-cli",
    "GitHub Copilot",
    "ellipsis.curlybraces",
    ["copilot"],
    "copilot",
    ["--acp"],
    {
      installMethods: [
        { kind: "npm", packageName: "@github/copilot" },
        { kind: "brew", formula: "copilot-cli" },
        { kind: "curl", command: "curl -fsSL https://gh.io/copilot-install | bash" }
      ],
      nativeMcp: {
        format: "json",
        key: "mcpServers",
        path: "~/.copilot/mcp-config.json",
        writable: true
      },
      skills: { globalDir: "~/.copilot/skills" },
      update: {
        // `copilot update` exists but is closed source; failures surface
        // gracefully as a failed lifecycle state.
        sources: [
          { when: "brew", check: { kind: "brew" }, apply: { kind: "reinstall" } },
          {
            apply: { args: ["update"], kind: "selfUpdate" },
            check: { kind: "npm", packageName: "@github/copilot" },
            when: "any"
          }
        ]
      }
    }
  ),
  executableHarness(
    "qwen-code",
    "Qwen Code",
    "q.square",
    ["qwen"],
    "qwen",
    ["--acp", "--experimental-skills"],
    {
      installMethods: [
        { kind: "npm", packageName: "@qwen-code/qwen-code" },
        { kind: "brew", formula: "qwen-code" },
        {
          kind: "curl",
          command:
            "curl -fsSL https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen-standalone.sh | bash"
        }
      ],
      skills: { globalDir: "~/.qwen/skills" },
      update: {
        // Reinstall through the owner of the detected binary.
        sources: [
          { when: "brew", check: { kind: "brew" }, apply: { kind: "reinstall" } },
          {
            apply: { kind: "reinstall" },
            check: { kind: "npm", packageName: "@qwen-code/qwen-code" },
            when: "any"
          }
        ]
      }
    }
  ),
  executableHarness("kimi", "Kimi CLI", "k.square", ["kimi"], "kimi", ["acp"], {
    installMethods: [
      {
        command: "curl -LsSf https://code.kimi.com/install.sh | KIMI_CLI_FORCE_OLD=1 bash",
        kind: "curl"
      },
      { kind: "brew", formula: "kimi-cli" },
      { kind: "uv", packageName: "kimi-cli", python: "3.13" }
    ],
    update: {
      sources: [
        { when: "brew", check: { kind: "brew" }, apply: { kind: "reinstall" } },
        {
          when: "uv",
          check: { kind: "pypi", packageName: "kimi-cli" },
          apply: { kind: "reinstall" }
        }
      ]
    }
  }),
  executableHarness(
    "factory-droid",
    "Factory Droid",
    "wrench.and.screwdriver",
    ["droid"],
    "droid",
    ["exec", "--output-format", "acp-daemon"],
    {
      installMethods: [
        { command: "curl -fsSL https://app.factory.ai/cli | sh", kind: "curl" },
        { kind: "brew", formula: "droid", cask: true },
        { kind: "npm", packageName: "droid" }
      ],
      update: {
        sources: [
          { when: "brew", check: { kind: "brew" }, apply: { kind: "reinstall" } },
          // Droid's npm builds have auto-update disabled at build time
          // (deliberately pinned) — reinstall is the vendor-blessed path.
          {
            apply: { kind: "reinstall" },
            check: { kind: "npm", packageName: "droid" },
            when: "npm"
          },
          {
            // Standalone/curl installs self-update via `droid update`.
            apply: { args: ["update"], kind: "selfUpdate" },
            check: { kind: "npm", packageName: "droid" },
            when: "any"
          }
        ]
      }
    }
  ),
  executableHarness("devin", "Devin", "brain", ["devin"], "devin", ["acp"], {
    installMethods: [{ command: "curl -fsSL https://cli.devin.ai/install.sh | bash", kind: "curl" }]
  }),
  executableHarness("grok-build", "Grok Build", "x.square", ["grok"], "grok", ["agent", "stdio"], {
    installMethods: [
      { command: "curl -fsSL https://x.ai/cli/install.sh | bash", kind: "curl" },
      { kind: "npm", packageName: "@xai-official/grok" }
    ],
    provider: "grok-build"
  }),
  executableHarness("kilo", "Kilo", "shippingbox", ["kilo"], "kilo", ["acp"], {
    installMethods: [
      { kind: "npm", packageName: "@kilocode/cli" },
      { kind: "curl", command: "curl -fsSL https://kilo.ai/cli/install | bash" },
      { kind: "brew", formula: "Kilo-Org/tap/kilo" }
    ],
    update: {
      // `kilo upgrade` detects curl/npm/yarn/pnpm/bun/brew itself.
      sources: [
        {
          apply: { args: ["upgrade"], kind: "selfUpdate" },
          check: { kind: "npm", packageName: "@kilocode/cli" },
          when: "any"
        }
      ]
    }
  }),
  ...additionalAcpHarnesses
]
