import { executableHarness } from "./harness-catalog-support.js"
import type { HarnessDefinition } from "./types.js"

// Reviewed against ACP's agent directory and registry on 2026-09-13.
// docs/harness-catalog-audit.md records sources and integration limitations.
const npmHarness = (
  id: string,
  name: string,
  command: string,
  packageName: string,
  args: ReadonlyArray<string> = []
): HarnessDefinition =>
  executableHarness(id, name, "terminal", [command], command, args, {
    installMethods: [{ kind: "npm", packageName }],
    update: {
      sources: [{ when: "npm", check: { kind: "npm", packageName }, apply: { kind: "reinstall" } }]
    }
  })

export const additionalAcpHarnesses: ReadonlyArray<HarnessDefinition> = [
  executableHarness(
    "blackbox",
    "Blackbox AI",
    "shippingbox",
    ["blackbox"],
    "blackbox",
    ["--experimental-acp"],
    {
      installMethods: [
        { kind: "curl", command: "curl -fsSL https://blackbox.ai/install.sh | bash" }
      ]
    }
  ),
  {
    ...npmHarness("autohand", "Autohand Code", "autohand-acp", "@autohandai/autohand-acp"),
    requiredBinaries: ["autohand"],
    installMethods: [
      { kind: "npm", packageName: "@autohandai/autohand-acp", additionalPackages: ["autohand-cli"] }
    ],
    launch: {
      kind: "executable",
      command: "autohand-acp",
      args: [],
      env: { AUTOHAND_PERMISSION_MODE: "external" }
    }
  },
  npmHarness("codebuddy-code", "CodeBuddy Code", "codebuddy", "@tencent-ai/codebuddy-code", [
    "--acp"
  ]),
  npmHarness("dimcode", "DimCode", "dimcode", "dimcode", ["acp"]),
  npmHarness("dirac", "Dirac", "dirac", "dirac-cli", ["--acp"]),
  npmHarness(
    "github-copilot",
    "GitHub Copilot Language Server",
    "copilot-language-server",
    "@github/copilot-language-server",
    ["--acp"]
  ),
  npmHarness("glm-acp-agent", "GLM Agent", "glm-acp-agent", "glm-acp-agent"),
  npmHarness("minimax-code", "MiniMax Code", "mcode", "@minimax-ai/code", ["acp"]),
  npmHarness("nova", "Nova", "nova", "@compass-ai/nova", ["acp"]),
  npmHarness("sigit", "siGit Code", "sigit", "@smbcloud/sigit"),
  executableHarness(
    "cortex-code",
    "Cortex Code",
    "snowflake",
    ["cortex"],
    "cortex",
    ["acp", "serve"],
    {
      installMethods: [
        {
          kind: "curl",
          command: "curl -fsSL https://ai.snowflake.com/static/cc-scripts/install.sh | sh"
        }
      ]
    }
  ),
  executableHarness("harn", "Harn", "terminal", ["harn"], "harn", ["serve", "acp"], {
    installMethods: [{ kind: "curl", command: "curl -fsSL https://harnlang.com/install.sh | sh" }]
  }),
  executableHarness("junie", "Junie", "j.square", ["junie"], "junie", ["--acp=true"], {
    installMethods: [
      { kind: "curl", command: "curl -fsSL https://junie.jetbrains.com/install.sh | bash" }
    ]
  }),
  executableHarness("kimchi", "Kimchi", "terminal", ["kimchi"], "kimchi", ["--mode", "acp"], {
    installMethods: [
      { kind: "brew", formula: "getkimchi/tap/kimchi" },
      {
        kind: "curl",
        command:
          "curl -fsSL https://github.com/getkimchi/kimchi/releases/latest/download/install.sh | bash"
      }
    ]
  }),
  executableHarness("poolside", "Poolside", "water.waves", ["pool"], "pool", ["acp"], {
    installMethods: [
      { kind: "curl", command: "curl -fsSL https://downloads.poolside.ai/pool/install.sh | sh" }
    ]
  }),
  executableHarness("stakpak", "Stakpak", "shippingbox", ["stakpak"], "stakpak", ["acp"], {
    installMethods: [
      { kind: "brew", formula: "stakpak/stakpak/stakpak" },
      { kind: "curl", command: "curl -fsSL https://stakpak.dev/install.sh | sh" }
    ]
  }),
  // The registry's Vibe archive is unavailable; the vendor's CLI distribution
  // includes vibe-acp and remains installable through these other channels.
  executableHarness("mistral-vibe", "Mistral Vibe", "m.square", ["vibe-acp"], "vibe-acp", [], {
    installMethods: [
      { kind: "curl", command: "curl -LsSf https://mistral.ai/vibe/install.sh | bash" },
      { kind: "brew", formula: "mistral-vibe" },
      { kind: "uv", packageName: "mistral-vibe" }
    ],
    update: {
      sources: [
        { when: "brew", check: { kind: "brew" }, apply: { kind: "reinstall" } },
        {
          when: "uv",
          check: { kind: "pypi", packageName: "mistral-vibe" },
          apply: { kind: "reinstall" }
        }
      ]
    }
  }),
  // Registry quarantine is for missing Windows builds. Our macOS/Linux CLI
  // installs use the vendor's supported script or Homebrew tap.
  executableHarness("vtcode", "VT Code", "v.square", ["vtcode"], "vtcode", ["acp"], {
    installMethods: [
      {
        kind: "curl",
        command:
          "curl -fsSL https://raw.githubusercontent.com/vinhnx/vtcode/main/scripts/install.sh | bash"
      },
      { kind: "brew", formula: "vinhnx/tap/vtcode" }
    ]
  }),
  // Listed in ACP's public agent directory, outside the release registry.
  executableHarness("kiro", "Kiro CLI", "k.square", ["kiro-cli"], "kiro-cli", ["acp"], {
    installMethods: [
      { kind: "curl", command: "curl -fsSL https://cli.kiro.dev/install | bash" },
      { kind: "brew", formula: "kiro-cli", cask: true }
    ]
  }),
  executableHarness("openhands", "OpenHands", "hand.raised", ["openhands"], "openhands", ["acp"], {
    installMethods: [
      { kind: "curl", command: "curl -fsSL https://install.openhands.dev/install.sh | sh" },
      { kind: "uv", packageName: "openhands", python: "3.12" }
    ],
    update: {
      sources: [
        { when: "brew", check: { kind: "brew" }, apply: { kind: "reinstall" } },
        {
          when: "uv",
          check: { kind: "pypi", packageName: "openhands" },
          apply: { kind: "reinstall" }
        }
      ]
    }
  }),
  executableHarness("construct", "Construct", "building.2", ["construct"], "construct", ["acp"], {
    installMethods: [
      {
        kind: "curl",
        command:
          "curl -fsSL https://raw.githubusercontent.com/construct-worlds/construct/main/install.sh | sh"
      }
    ]
  })
]
