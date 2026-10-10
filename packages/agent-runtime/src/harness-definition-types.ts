export type ProviderId = "acp" | "claude" | "codex" | "cursor" | "grok-build" | "opencode" | "pi"

export type HarnessLaunch =
  | {
      readonly kind: "npx"
      readonly packageName: string
      readonly args: ReadonlyArray<string>
    }
  | {
      readonly kind: "executable"
      readonly command: string
      readonly args: ReadonlyArray<string>
      /// Extra environment merged over the resolved shell env when spawning
      /// the adapter. Account env still wins.
      readonly env?: Readonly<Record<string, string>>
    }

/// How an installed harness binary got onto the machine, detected from its
/// resolved path (brew prefix, node_modules, .app bundle, …). Update behavior
/// is keyed off this so we never fight the installer that owns the binary.
export type InstallOrigin = "npm" | "brew" | "curl" | "uv" | "appBundle" | "standalone" | "unknown"

/// One way to install a harness CLI. `kind` doubles as the method id in the
/// API. Exactly one of the payload fields applies per kind.
export interface HarnessInstallMethodSpec {
  readonly kind: "brew" | "npm" | "curl" | "uv"
  /// brew formula (or cask when `cask` is true), e.g. "block-goose-cli".
  readonly formula?: string
  readonly cask?: boolean
  /// npm package installed globally, e.g. "@openai/codex".
  readonly packageName?: string
  /// Additional npm packages required by an adapter.
  readonly additionalPackages?: ReadonlyArray<string>
  /// Optional Python version for uv to provision.
  readonly python?: string
  /// Skip npm dependency lifecycle scripts when supported by the vendor.
  readonly ignoreScripts?: boolean
  /// curl: the vendor's full install command, shown verbatim to the user
  /// before running (e.g. `curl -fsSL https://claude.ai/install.sh | bash`).
  readonly command?: string
  /// The vendor's preferred method: recommended whenever it can run, ahead
  /// of the usual brew, curl, npm order.
  readonly recommended?: boolean
}

/// Where to learn the latest available version for one install origin.
export type UpdateCheckSpec =
  | { readonly kind: "npm"; readonly packageName: string; readonly distTag?: string }
  | {
      readonly kind: "brew"
      /// Omit to infer the owning formula/cask from the resolved binary's
      /// Cellar/Caskroom path. This preserves channels such as `@latest`.
      readonly formula?: string
    }
  | { readonly kind: "github"; readonly repo: string }
  | { readonly kind: "pypi"; readonly packageName: string }
  | {
      readonly kind: "sparkle"
      readonly appcastUrl: string
      readonly appcastUrlX64?: string
    }

/// How to apply an update for one install origin.
export type UpdateApplySpec =
  /// Run the harness's own updater (`codex update`, `opencode upgrade`, …).
  | {
      readonly kind: "selfUpdate"
      readonly args: ReadonlyArray<string>
      readonly env?: Readonly<Record<string, string>>
    }
  /// No native updater: rerun the install method matching the detected origin
  /// (npm reinstall at @latest, brew upgrade, curl script).
  | { readonly kind: "reinstall" }
  /// macOS app-bundled CLI (ChatGPT.app codex): replace the whole app bundle
  /// from its Sparkle feed. Server-side, darwin-only. The bundle path is
  /// derived from the detected binary (`<bundle>/Contents/Resources/<cli>`)
  /// unless pinned here.
  | { readonly kind: "appBundleSwap"; readonly bundlePath?: string }

/// Check + apply for one detected install origin; `when: "any"` is the
/// fallback row. Matching per-origin keeps version channels isolated (an
/// app-bundled alpha is never compared against the npm stable line).
export interface HarnessUpdateSource {
  readonly when: InstallOrigin | "any"
  readonly check: UpdateCheckSpec
  readonly apply: UpdateApplySpec
}

/// Where a harness keeps its user-level (global) MCP server registrations on
/// disk, plus enough shape metadata to read — and, where safe, edit — that
/// file without understanding the rest of it. Paths are `~/`-relative and
/// resolved against the scanning machine's home directory at read time.
export interface NativeMcpConfigSpec {
  /// Config file holding global MCP registrations, e.g. "~/.claude.json".
  /// Environment overrides (CODEX_HOME, XDG_CONFIG_HOME) are applied by the
  /// scanner, not encoded here.
  readonly path: string
  /// Dotted key of the server map inside the file ("mcpServers",
  /// "mcp_servers", "mcp", "extensions").
  readonly key: string
  readonly format: "json" | "toml" | "yaml"
  /// Project-level file name (relative to a project root) that also carries
  /// MCP registrations — read-only in Codevisor (team-committed state).
  readonly projectFile?: string
  /// Present only when the harness has a real per-server enable flag we can
  /// honestly toggle. `enabledWhen` is the field value that means "enabled"
  /// (opencode: {name:"enabled", enabledWhen:true}; cline: {name:"disabled",
  /// enabledWhen:false}).
  readonly disableField?: { readonly name: string; readonly enabledWhen: boolean }
  /// False when Codevisor cannot yet edit the file without risking damage to
  /// user formatting (goose YAML in v1) — such harnesses are scan-only.
  readonly writable: boolean
}

/// Where a harness reads user-level agent skills from. Only declared for
/// harnesses that document skills support — the field's presence is what
/// gates skills UI affordances.
export interface HarnessSkillsSpec {
  /// Global skills directory, `~/`-relative, e.g. "~/.claude/skills".
  readonly globalDir: string
  /// True when `globalDir` IS the canonical ~/.agents/skills store: the
  /// harness needs no symlink and must never receive one (it would
  /// double-list or self-reference).
  readonly readsCanonical?: boolean
  /// True when the harness has its own skills directory AND scans the
  /// canonical ~/.agents/skills store too (OpenCode). Every global skill is
  /// ambiently available; installing a link into its own dir would only
  /// produce duplicate-name warnings.
  readonly alsoReadsCanonical?: boolean
}

export interface HarnessDefinition {
  readonly id: string
  readonly name: string
  readonly symbolName: string
  readonly detectBinaries: ReadonlyArray<string>
  /// Extra executables required by an ACP adapter, in addition to its own binary.
  readonly requiredBinaries?: ReadonlyArray<string>
  /// Absolute paths probed when no detect binary is on PATH — CLIs bundled
  /// inside desktop apps (a leading `~/` expands via env.HOME). Lets users
  /// who installed the app but never the CLI still run the harness.
  readonly fallbackPaths?: ReadonlyArray<string>
  readonly provider: ProviderId
  /// Launch spec for the ACP provider's adapter process; native providers
  /// (claude/codex) drive the detected binary directly and omit it.
  readonly launch?: HarnessLaunch
  /// When set, the harness is reported unavailable with this reason and
  /// sessions cannot be created — used to pull a known-broken integration
  /// without deleting its catalog entry (existing sessions keep their name).
  readonly disabledReason?: string
  /// Copyable shell command that installs the harness CLI; surfaced next to
  /// "not installed" rows so users can install without leaving the app.
  /// Derived UI fallback — `installMethods` is the structured source.
  readonly installHint?: string
  /// Ways Codevisor can install this CLI, in vendor-preference order. Absent
  /// for harnesses we can't install (bundled-only).
  readonly installMethods?: ReadonlyArray<HarnessInstallMethodSpec>
  /// Update sources keyed by detected install origin. Absent = no update
  /// support (harnesses without a version channel).
  readonly update?: {
    readonly sources: ReadonlyArray<HarnessUpdateSource>
    /// Packages of an older release line this harness's packages replace
    /// (both own the same binary): updating an install of one removes it
    /// before installing the current package.
    readonly replaces?: { readonly npm?: string; readonly brew?: string }
    /// What changes for the user when an update crosses a major version;
    /// shown, and confirmed, before such an update runs.
    readonly majorNotes?: string
  }
  /// Native (harness-owned) MCP config location + shape. Absent = the harness
  /// is skipped by native MCP discovery.
  readonly nativeMcp?: NativeMcpConfigSpec
  /// Skills directory metadata. Absent = the harness is skipped by skills
  /// discovery and never offered as a skills install target.
  readonly skills?: HarnessSkillsSpec
}
