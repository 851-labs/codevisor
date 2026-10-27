import { additionalAcpHarnesses } from "./harness-catalog-acp.js"
import {
  antigravityHarness,
  claudeCodeHarness,
  codexHarness,
  museCodeHarness,
  piHarness
} from "./harness-catalog-direct.js"
import { executableHarness } from "./harness-catalog-support.js"
import type { HarnessDefinition } from "./types.js"

export const OPENCODE_INSTALL_PATH = "~/.opencode/bin/opencode"

const DEVELOPMENT_TEST_HARNESS_ID = "codevisor-test-agent"

const geminiSubagentPolicy = `[[rule]]
toolName = "invoke_agent"
decision = "deny"
priority = 999
`

const auggieSubagentTools = [
  "sub-agent",
  "sub-agent-auggie-guide",
  "sub-agent-code",
  "sub-agent-context-gathering",
  "sub-agent-explore",
  "sub-agent-general-purpose",
  "sub-agent-plan",
  "sub-agent-research",
  "sub-agent-validate"
]

const removeAuggieTools = auggieSubagentTools.flatMap((tool) => ["--remove-tool", tool])

const developmentTestHarness = executableHarness(
  DEVELOPMENT_TEST_HARNESS_ID,
  "Test Agent",
  "testtube.2",
  [DEVELOPMENT_TEST_HARNESS_ID],
  DEVELOPMENT_TEST_HARNESS_ID,
  ["acp"]
)

const developmentTestHarnesses = (env: NodeJS.ProcessEnv): ReadonlyArray<HarnessDefinition> => {
  if (env.CODEVISOR_DEV_INSTANCE_ID === undefined) return []
  return [developmentTestHarness]
}

export const harnessCatalog: ReadonlyArray<HarnessDefinition> = [
  claudeCodeHarness,
  codexHarness,
  piHarness,
  museCodeHarness,
  antigravityHarness,
  executableHarness("gemini", "Gemini CLI", "diamond", ["gemini"], "gemini", ["--acp"], {
    files: [
      { contents: geminiSubagentPolicy, flag: "--admin-policy", name: "gemini-subagents.toml" }
    ],
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
    provider: "opencode",
    fallbackPaths: [OPENCODE_INSTALL_PATH],
    installMethods: [
      {
        command: "curl -fsSL https://opencode.ai/v2/install | bash",
        kind: "curl",
        recommended: true
      },
      { kind: "npm", packageName: "@opencode/cli" },
      { formula: "anomalyco/tap/opencode-v2", kind: "brew" }
    ],
    nativeMcp: {
      disableField: { enabledWhen: true, name: "enabled" },
      format: "json",
      key: "mcp",
      path: "~/.config/opencode/opencode.json",
      writable: true
    },
    skills: { alsoReadsCanonical: true, globalDir: "~/.config/opencode/skills" },
    update: {
      replaces: { brew: "anomalyco/tap/opencode", npm: "opencode-ai" },
      majorNotes:
        "OpenCode 2 is a new major version. Plugins written for OpenCode 1 stop working, it no longer runs language servers (LSP), and it reads instructions only from AGENTS.md, not CLAUDE.md. Your sign-ins and settings carry over.",
      sources: [
        {
          apply: { kind: "reinstall" },
          check: { kind: "npm", packageName: "@opencode/cli" },
          when: "brew"
        },
        {
          apply: { kind: "reinstall" },
          check: { kind: "npm", packageName: "@opencode/cli" },
          when: "npm"
        },
        {
          apply: { kind: "reinstall" },
          check: { kind: "npm", packageName: "@opencode/cli" },
          when: "curl"
        },
        {
          apply: { args: ["upgrade"], kind: "selfUpdate" },
          check: { kind: "npm", packageName: "@opencode/cli" },
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
    nativeMcp: {
      format: "yaml",
      key: "extensions",
      path: "~/.config/goose/config.yaml",
      writable: false
    },
    update: {
      sources: [
        {
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
  executableHarness("amp", "Amp", "bolt", ["amp-acp"], "amp-acp", [], {
    installHint: "npm install -g amp-acp @ampcode/cli",
    requiredBinaries: ["amp"],
    installMethods: [{ kind: "npm", packageName: "amp-acp", additionalPackages: ["@ampcode/cli"] }],
    skills: { globalDir: "~/.config/agents/skills" }
  }),
  executableHarness(
    "auggie",
    "Auggie CLI",
    "a.square",
    ["auggie"],
    "auggie",
    ["--acp", ...removeAuggieTools],
    {
      installMethods: [{ kind: "npm", packageName: "@augmentcode/auggie" }],
      skills: { globalDir: "~/.augment/skills" },
      update: {
        sources: [
          {
            apply: { kind: "reinstall" },
            check: { kind: "npm", packageName: "@augmentcode/auggie" },
            when: "any"
          }
        ]
      }
    }
  ),
  executableHarness("cline", "Cline", "terminal", ["cline"], "cline", ["--acp"], {
    installMethods: [{ kind: "npm", packageName: "cline" }],
    nativeMcp: {
      disableField: { enabledWhen: false, name: "disabled" },
      format: "json",
      key: "mcpServers",
      path: "~/.cline/data/settings/cline_mcp_settings.json",
      writable: true
    },
    skills: { globalDir: "~/.agents/skills", readsCanonical: true },
    update: {
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
    ["--acp", "--excluded-tools=task,list_agents,read_agent,write_agent"],
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
    ["--acp", "--experimental-skills", "--exclude-tools", "agent,list_agents,send_message"],
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
          {
            apply: { kind: "reinstall" },
            check: { kind: "npm", packageName: "droid" },
            when: "npm"
          },
          {
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
  executableHarness(
    "grok-build",
    "Grok Build",
    "x.square",
    ["grok"],
    "grok",
    ["agent", "--always-approve", "--no-leader", "stdio"],
    {
      installMethods: [
        { command: "curl -fsSL https://x.ai/cli/install.sh | bash", kind: "curl" },
        { kind: "npm", packageName: "@xai-official/grok" }
      ],
      provider: "grok-build"
    }
  ),
  executableHarness("kilo", "Kilo", "shippingbox", ["kilo"], "kilo", ["acp"], {
    env: { KILO_PERMISSION: JSON.stringify({ task: "deny" }) },
    installMethods: [
      { kind: "npm", packageName: "@kilocode/cli" },
      { kind: "curl", command: "curl -fsSL https://kilo.ai/cli/install | bash" },
      { kind: "brew", formula: "Kilo-Org/tap/kilo" }
    ],
    update: {
      sources: [
        {
          apply: { args: ["upgrade"], kind: "selfUpdate" },
          check: { kind: "npm", packageName: "@kilocode/cli" },
          when: "any"
        }
      ]
    }
  }),
  ...additionalAcpHarnesses,
  ...developmentTestHarnesses(process.env)
]
