# Harness catalog audit — 2026-09-13

Codevisor now lists 38 harnesses, up from 17, with 65 install options. The catalog
covers 34 of the ACP registry's 42 entries (including aliases) and four additional
agents from ACP's public directory. Six registry entries are quarantined
upstream, and two are omitted at the user’s request; the exclusions are
recorded below.

## Sources and scope

- [ACP agent directory](https://agentclientprotocol.com/get-started/agents), from
  `agentclientprotocol/agent-client-protocol` revision
  `ada6b108389a63a2625298f2be3eacde33a1d8c5`.
- [ACP release registry](https://github.com/agentclientprotocol/registry), revision
  `408ececf2b8bde9451ef96f0c8c4d5e7e910825f`, saved as `.repos/acp-registry`.
  Inspect `*/agent.json` for distribution commands and `quarantine.json` for
  failures. The [published index](https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json)
  can lag repository changes.
- [Codex source](https://github.com/openai/codex), revision
  `3abbf9fe2c6b6910e9de61f6a0c5bb468f74b5c8`.
- Vendor installation pages, package metadata (`bin` names and dependencies),
  and Homebrew's formula/cask metadata linked below.

These are local macOS/Linux server installations; iOS manages the selected
server's harnesses. Windows package managers, Docker containers, source builds,
and project-specific environment setup are not one-click install methods.
Native Claude, Codex, Cursor, and Grok providers keep their existing integrations.
Registry IDs `claude-acp`, `codex-acp`, `amp-acp`, and `pi-acp` map to Codevisor's
existing `claude-code`, `codex`, `amp`, and `pi` IDs.

An entry confirms a documented ACP launch path. It does not certify every model,
provider, authentication flow, or optional protocol capability. Credentials and
vendor configuration remain prerequisites for using an installed agent.

## Existing harnesses

| Harness            | Install choices                    | Source and notes                                                                                                                                                                                                                                                 |
| ------------------ | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Claude Code        | Homebrew, script, npm              | [Setup](https://code.claude.com/docs/en/setup). Preserve the existing `claude-code@latest` channel; updates follow the actual owning cask.                                                                                                                       |
| Codex              | Homebrew, **script added**, npm    | [CLI installation](https://developers.openai.com/codex/cli). Script: `https://chatgpt.com/codex/install.sh`, run with `sh`. App-bundled detection and updates remain supported.                                                                                  |
| Pi                 | **Script added**, npm              | [README](https://github.com/earendil-works/pi/tree/main/packages/coding-agent). npm uses the vendor's `--ignore-scripts` option. ACP bridge advanced from `pi-acp@0.0.31` to registry release `0.0.33`; that bridge still needs npx.                             |
| Gemini CLI         | npm, Homebrew                      | [Installation](https://github.com/google-gemini/gemini-cli). Launch remains `gemini --acp`.                                                                                                                                                                      |
| OpenCode           | Script, npm, **Homebrew added**    | [Install](https://opencode.ai/docs/#install). Use the vendor's `anomalyco/tap/opencode` formula.                                                                                                                                                                 |
| Goose              | Homebrew, **script added**         | [Installation](https://github.com/aaif-goose/goose/blob/main/documentation/docs/getting-started/installation.md). `CONFIGURE=false` skips interactive provider setup in the installer.                                                                           |
| Cursor             | Script                             | [Installation](https://cursor.com/docs/cli/installation). Existing native provider and launch arguments retained.                                                                                                                                                |
| Amp                | **npm added**                      | [Adapter](https://github.com/tao12345666333/amp-acp), [CLI](https://ampcode.com/manual). Install `amp-acp` and `@ampcode/cli` together. Readiness requires both binaries.                                                                                        |
| Auggie CLI         | npm                                | [Install](https://docs.augmentcode.com/cli/setup-auggie/install-auggie-cli). No additional documented package-manager route found.                                                                                                                               |
| Cline              | npm                                | [Install](https://docs.cline.bot/getting-started/installing-cline#cli).                                                                                                                                                                                          |
| GitHub Copilot CLI | npm, **Homebrew and script added** | [README](https://github.com/github/copilot-cli). `copilot-cli` is a formula. Homebrew updates use `brew upgrade`.                                                                                                                                                |
| Qwen Code          | npm, **Homebrew and script added** | [README](https://github.com/QwenLM/qwen-code). The standalone script does not require npm. Updates use the detected installer.                                                                                                                                   |
| Kimi CLI           | Script, **Homebrew and uv added**  | [Source](https://github.com/MoonshotAI/kimi-cli), [formula](https://formulae.brew.sh/formula/kimi-cli). The legacy installer now offers migration to Kimi Code; `KIMI_CLI_FORCE_OLD=1` keeps this entry on the registry's Python CLI. uv provisions Python 3.13. |
| Factory Droid      | Script, **Homebrew and npm added** | [Quickstart](https://docs.factory.ai/droid-cli/quickstart), [update behavior](https://docs.factory.ai/droid-cli/cli-reference). Use `droid` cask/npm package; npm builds require npm updates.                                                                    |
| Devin              | Script                             | [CLI](https://docs.devin.ai/cli), [registry](https://github.com/agentclientprotocol/registry/tree/main/devin). Existing `devin acp` route retained.                                                                                                              |
| Grok Build         | Script, **npm added**              | [Source](https://github.com/xai-org/grok-build), [registry](https://github.com/agentclientprotocol/registry/tree/main/grok-build). Official package: `@xai-official/grok`.                                                                                       |
| Kilo               | npm, **script and Homebrew added** | [README](https://github.com/Kilo-Org/kilocode). Use `Kilo-Org/tap/kilo`.                                                                                                                                                                                         |

## Added harnesses

Unless otherwise linked, commands and package identities come from the pinned
[registry manifests](https://github.com/agentclientprotocol/registry/tree/408ececf2b8bde9451ef96f0c8c4d5e7e910825f).
Every npm entry's executable name was checked against its published package.

| Harness                        | ACP command                     | Install choices / prerequisites                                                                                                                                                                                                   |
| ------------------------------ | ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Autohand Code                  | `autohand-acp`                  | npm installs `@autohandai/autohand-acp` and `autohand-cli`. Both binaries are required. `AUTOHAND_PERMISSION_MODE=external` forwards approvals to the client. [Adapter requirements](https://github.com/autohandai/autohand-acp). |
| Blackbox AI                    | `blackbox --experimental-acp`   | [Script](https://docs.blackbox.ai/features/blackbox-cli/getting-started), [ACP configuration](https://docs.blackbox.ai/features/blackbox-cli/acp-integration).                                                                    |
| CodeBuddy Code                 | `codebuddy --acp`               | npm `@tencent-ai/codebuddy-code`.                                                                                                                                                                                                 |
| Construct                      | `construct acp`                 | [Vendor script](https://github.com/construct-worlds/construct). Uses its configured daemon/harness.                                                                                                                               |
| Cortex Code                    | `cortex acp serve`              | [Snowflake script](https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code-cli).                                                                                                                                         |
| DimCode                        | `dimcode acp`                   | npm `dimcode`.                                                                                                                                                                                                                    |
| Dirac                          | `dirac --acp`                   | npm `dirac-cli`.                                                                                                                                                                                                                  |
| GitHub Copilot Language Server | `copilot-language-server --acp` | npm `@github/copilot-language-server`. A separate upstream distribution from Copilot CLI.                                                                                                                                         |
| GLM Agent                      | `glm-acp-agent`                 | npm `glm-acp-agent`.                                                                                                                                                                                                              |
| Harn                           | `harn serve acp`                | [Vendor script](https://github.com/burin-labs/harn).                                                                                                                                                                              |
| Junie                          | `junie --acp=true`              | [JetBrains script](https://junie.jetbrains.com/docs/junie-cli.html).                                                                                                                                                              |
| Kimchi                         | `kimchi --mode acp`             | [Homebrew tap and script](https://github.com/getkimchi/kimchi).                                                                                                                                                                   |
| Kiro CLI                       | `kiro-cli acp`                  | [Script](https://kiro.dev/docs/cli/), Homebrew cask. [ACP instructions](https://kiro.dev/docs/cli/acp/).                                                                                                                          |
| MiniMax Code                   | `mcode acp`                     | npm `@minimax-ai/code`; executable is `mcode`.                                                                                                                                                                                    |
| Mistral Vibe                   | `vibe-acp`                      | [Script and uv](https://github.com/mistralai/mistral-vibe), [Homebrew](https://formulae.brew.sh/formula/mistral-vibe). These install the CLI with its ACP executable, bypassing the registry's inaccessible standalone archive.   |
| Nova                           | `nova acp`                      | npm `@compass-ai/nova`.                                                                                                                                                                                                           |
| OpenHands                      | `openhands acp`                 | [Script and uv with Python 3.12](https://github.com/OpenHands/OpenHands-CLI).                                                                                                                                                     |
| Poolside                       | `pool acp`                      | [Vendor script](https://github.com/poolsideai/pool).                                                                                                                                                                              |
| siGit Code                     | `sigit`                         | npm `@smbcloud/sigit`; registry declares no extra arguments.                                                                                                                                                                      |
| Stakpak                        | `stakpak acp`                   | [Vendor script and Homebrew tap](https://github.com/stakpak/agent).                                                                                                                                                               |
| VT Code                        | `vtcode acp`                    | [Script and Homebrew tap](https://github.com/vinhnx/VTCode). Registry quarantine concerns missing Windows builds, which does not affect these macOS/Linux routes.                                                                 |

## Reviewed entries not offered as built-ins

[Registry quarantine](https://github.com/agentclientprotocol/registry/blob/408ececf2b8bde9451ef96f0c8c4d5e7e910825f/quarantine.json)
records these six unresolved distributions. Recheck their current releases before
adding them; the reasons apply to registry validation and do not prove every
newer or manually configured installation is broken.

| Registry ID       | Recorded reason                                                                                    |
| ----------------- | -------------------------------------------------------------------------------------------------- |
| `agoragentic-acp` | Postinstall script flagged by registry validation.                                                 |
| `crow-cli`        | ACP initialization fails in 0.1.25.                                                                |
| `deepagents`      | Missing npm dependency.                                                                            |
| `fast-agent`      | Initialization times out after 120 seconds.                                                        |
| `minion-code`     | Python dependency issue.                                                                           |
| `qoder`           | ACP initialization fails in 0.2.15/0.2.16; newer npm releases require a fresh compatibility check. |

These public-directory entries need additional integration work or a user-specific
custom harness command:

| Entry                                                                                                 | Remaining requirement                                                                             |
| ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| [AgentPool](https://github.com/phil65/agentpool)                                                      | `agentpool serve-acp` requires a user-authored agent configuration file.                          |
| [AutoDev](https://github.com/phodal/auto-dev)                                                         | Multiple IDE/CLI products; a current installed executable and ACP invocation were not verified.   |
| [Bub](https://github.com/bubbuild/bub-contrib/tree/main/packages/bub-acp-server)                      | `bub acp` requires a separately installed plugin in the same Python environment.                  |
| [Claw Orchestrator](https://github.com/Enderfga/claw-orchestrator/blob/main/skills/references/acp.md) | `clawo acp` needs configured underlying harnesses and orchestration setup.                        |
| [Docker cagent](https://github.com/docker/cagent)                                                     | Current product is Docker Agent; a usable ACP configuration/agent definition must be supplied.    |
| [fount](https://github.com/steve02081504/fount)                                                       | Persona/worker configuration and an installed ACP entry point need verification.                  |
| [Kaagum](https://git.systemreboot.net/kaagum/about/)                                                  | Installation and a standalone ACP command were not verified.                                      |
| [localharness](https://github.com/compusophy/localharness)                                            | Documented `localharness acp --as <name>` needs an identity and wallet setup.                     |
| [OpenClaw](https://github.com/openclaw/openclaw/blob/main/docs/cli/acp.md)                            | Its bridge needs a running Gateway and rejects per-session MCP servers, which Codevisor supplies. |
| [Raxol](https://github.com/DROOdotFOO/raxol/blob/master/docs/features/CODING_AGENT.md)                | Requires an ACP-enabled build and provider setup; no verified general installer.                  |
| [stdio Bus](https://github.com/stdiobus/stdiobus)                                                     | A routing kernel/worker framework rather than a single configured coding-agent command.           |

Hermes Agent, Google Antigravity, Corust Agent, and Code Assistant are omitted
from the catalog for now at the user’s request. The latter three had no
built-in installer. Their native icon assets have also been removed.

## Bundled icons

Both native apps include 37 branded harness icons. Ten were added from
`.repos/lobe-icons/packages/static-svg/icons` at pinned revision
`4aaf4ee1fb2678a7f989ea570f0f6ce14a9abf75`. The SVGs retain their upstream artwork;
web-only sizing attributes are removed to match the existing native assets.
Poolside's alpha-mask gradient stops use white so Apple's luminance-mask
renderer preserves the artwork instead of producing an empty icon.
They use vector preservation and template rendering for light/dark appearance.
LobeHub's MIT notice is included in each app's resources.

| Harness                        | Lobe icon                     |
| ------------------------------ | ----------------------------- |
| CodeBuddy Code                 | `codebuddy.svg`               |
| GitHub Copilot Language Server | `githubcopilot.svg`           |
| Junie                          | `junie.svg`                   |
| Kiro CLI                       | `kiro.svg`                    |
| OpenHands                      | `openhands.svg`               |
| Cortex Code                    | `snowflake.svg` (vendor logo) |
| GLM Agent                      | `zai.svg` (vendor logo)       |
| MiniMax Code                   | `minimax.svg` (vendor logo)   |
| Mistral Vibe                   | `mistral.svg` (vendor logo)   |
| Poolside                       | `poolside.svg` (vendor logo)  |

Twelve more icons were sourced from official websites, upstream repositories,
and the ACP registry. Their exact sources, modifications, and license notices
are recorded in [Harness icon sources](harness-icon-sources.md). Construct is the
only remaining SF Symbol fallback. Nova now uses the Compass Agentic Platform
mark from the ACP registry; Lobe's unrelated Amazon Nova mark is not used.

Icon verification passed in both rebuilt native apps: all ten retained additions were
visible in macOS onboarding (dark appearance) and iOS harness settings (light
appearance). Existing branded icons and generic fallbacks still rendered. This
check caught the Poolside mask issue above; the corrected SVG was rebuilt and
verified on both platforms. All 20 retained image sets passed SVG/manifest validation
and matched across platforms.

The twelve retained website/upstream additions also passed verification in both rebuilt
apps on `62b6580c` with the local changes above. macOS Settings → Harnesses
(dark appearance) and iPhone 17 Pro / iOS 27.0 Settings → Harnesses (light
appearance) displayed all twelve retained marks. Scrolling retained correct row layout,
existing branded assets remained visible, and Construct kept its fallback.
The siGit registry SVG had a stray background shape; the final asset uses the
clean favicon published on the siGit Code website instead. Both native builds
passed, license notices were bundled, and all 37 SVG/manifest pairs matched
between platforms. No runtime code changed in this icon follow-up.

## Lifecycle and verification

- `uv` is a structured install choice with executable prerequisite detection,
  optional Python provisioning, PyPI version checks, and `uv tool upgrade` for
  detected uv tool environments.
- Homebrew casks are unavailable on Linux even when `brew` exists. Formulae
  remain available there. Existing preference stays Homebrew, script, npm, then uv
  among available choices.
- Copilot CLI, Qwen, and Droid Homebrew installs update through their owning
  package. Existing versioned casks retain their channel.
- All 25 catalog script URLs returned shell scripts and passed their declared
  shell's syntax check. This checks endpoints and syntax, not complete execution
  of every third-party installer.
- An isolated installation of `glm-acp-agent` completed a real ACP v1 initialize
  exchange and returned authentication methods and capabilities. Paid model
  prompts and all vendors' sign-in flows were not exercised.
- Automated verification passed: 557 tests across agent-runtime, adapter-acp,
  harness-manager, updater, and API; affected-package typechecks and coverage
  checks; repository lint (existing warnings), formatting, and size ratchet.
- Native verification used the final local changes on `62b6580c` in the `flan`
  worktree, launched with `bun run dev --no-containers`. Both native builds passed.
  macOS onboarding and iPhone 17 Pro / iOS 27.0 harness settings displayed the
  expanded catalog. Mistral Vibe's picker offered script, Homebrew, and uv on both
  platforms, and selecting uv worked. The macOS command preview matched the
  runtime's install command. Existing installed harnesses remained visible.
  The development instance was left running for inspection.
- After removing Hermes, Google Antigravity, Corust Agent, and Code Assistant,
  the catalog contains 38 harnesses, each with install methods, and 65 install
  choices. Nine catalog installation tests passed. Both native apps rebuilt
  successfully, and Settings → Harnesses showed the final list on macOS (dark)
  and an isolated iPhone 17 Pro / iOS 27.0 simulator (light). VT Code, Kiro CLI,
  OpenHands, and Construct remained visible at the bottom; the removed entries
  and their “CLI not found on PATH” labels were absent.
