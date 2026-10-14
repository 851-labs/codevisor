export type ProviderId =
  | "acp"
  | "antigravity"
  | "claude"
  | "codex"
  | "cursor"
  | "grok-build"
  | "muse"
  | "opencode"
  | "pi"

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
      readonly env?: Readonly<Record<string, string>>
    }

export type InstallOrigin = "npm" | "brew" | "curl" | "uv" | "appBundle" | "standalone" | "unknown"

export interface HarnessInstallMethodSpec {
  readonly kind: "brew" | "npm" | "curl" | "uv"
  readonly formula?: string
  readonly cask?: boolean
  readonly packageName?: string
  readonly additionalPackages?: ReadonlyArray<string>
  readonly python?: string
  readonly ignoreScripts?: boolean
  readonly command?: string
  readonly recommended?: boolean
}

export type UpdateCheckSpec =
  | { readonly kind: "npm"; readonly packageName: string; readonly distTag?: string }
  | {
      readonly kind: "brew"
      readonly formula?: string
    }
  | { readonly kind: "github"; readonly repo: string }
  | { readonly kind: "pypi"; readonly packageName: string }
  | {
      readonly kind: "sparkle"
      readonly appcastUrl: string
      readonly appcastUrlX64?: string
    }

export type UpdateApplySpec =
  | {
      readonly kind: "selfUpdate"
      readonly args: ReadonlyArray<string>
      readonly env?: Readonly<Record<string, string>>
    }
  | { readonly kind: "reinstall" }
  | { readonly kind: "appBundleSwap"; readonly bundlePath?: string }

export interface HarnessUpdateSource {
  readonly when: InstallOrigin | "any"
  readonly check: UpdateCheckSpec
  readonly apply: UpdateApplySpec
}

export interface NativeMcpConfigSpec {
  readonly path: string
  readonly key: string
  readonly format: "json" | "toml" | "yaml"
  readonly projectFile?: string
  readonly disableField?: { readonly name: string; readonly enabledWhen: boolean }
  readonly writable: boolean
}

export interface HarnessSkillsSpec {
  readonly globalDir: string
  readonly readsCanonical?: boolean
  readonly alsoReadsCanonical?: boolean
}

export interface HarnessDefinition {
  readonly id: string
  readonly name: string
  readonly symbolName: string
  readonly detectBinaries: ReadonlyArray<string>
  readonly requiredBinaries?: ReadonlyArray<string>
  readonly fallbackPaths?: ReadonlyArray<string>
  readonly provider: ProviderId
  readonly launch?: HarnessLaunch
  readonly disabledReason?: string
  readonly installHint?: string
  readonly installMethods?: ReadonlyArray<HarnessInstallMethodSpec>
  readonly update?: {
    readonly sources: ReadonlyArray<HarnessUpdateSource>
    readonly replaces?: { readonly npm?: string; readonly brew?: string }
    readonly majorNotes?: string
  }
  readonly nativeMcp?: NativeMcpConfigSpec
  readonly skills?: HarnessSkillsSpec
}
