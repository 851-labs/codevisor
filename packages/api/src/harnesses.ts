import { Schema } from "effect"

export const HarnessReadiness = Schema.Struct({
  state: Schema.Literals(["ready", "unavailable"]),
  detail: Schema.optional(Schema.String),
  /// Resolved binary location and version for ready harnesses. Structured on
  /// purpose: clients show them, and future config-sync diffs "what's
  /// installed where" across machines.
  path: Schema.optional(Schema.String),
  version: Schema.optional(Schema.String)
})
export type HarnessReadiness = typeof HarnessReadiness.Type

export const HarnessAuthState = Schema.Literals([
  "checking",
  "authenticated",
  "unauthenticated",
  "expired",
  "notRequired",
  "unavailable",
  "error"
])
export type HarnessAuthState = typeof HarnessAuthState.Type

export const HarnessAuthMethod = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  description: Schema.optional(Schema.String),
  kind: Schema.Literals(["browser", "deviceCode", "terminal", "agent", "apiKey"])
})
export type HarnessAuthMethod = typeof HarnessAuthMethod.Type

export const HarnessAccount = Schema.Struct({
  id: Schema.String,
  harnessId: Schema.String,
  profileKind: Schema.Literals(["default", "managed"]),
  label: Schema.String,
  email: Schema.optional(Schema.String),
  organizationId: Schema.optional(Schema.String),
  authMethod: Schema.optional(Schema.String),
  authState: HarnessAuthState,
  isActive: Schema.Boolean,
  canLogin: Schema.Boolean,
  canLogout: Schema.Boolean,
  lastCheckedAt: Schema.optional(Schema.String),
  detail: Schema.optional(Schema.String)
})
export type HarnessAccount = typeof HarnessAccount.Type

export const HarnessAuth = Schema.Struct({
  state: HarnessAuthState,
  activeAccountId: Schema.optional(Schema.String),
  accounts: Schema.Array(HarnessAccount),
  loginMethods: Schema.Array(HarnessAuthMethod),
  supportsMultipleAccounts: Schema.Boolean,
  detail: Schema.optional(Schema.String)
})
export type HarnessAuth = typeof HarnessAuth.Type

/// One way Codevisor can install a harness CLI on the server's machine,
/// resolved against what's actually available there (brew/npm present, OS).
export const HarnessInstallMethod = Schema.Struct({
  /// Stable method id, currently the kind ("brew" | "npm" | "curl").
  id: Schema.String,
  kind: Schema.Literals(["brew", "npm", "curl"]),
  /// Human label for pickers, e.g. "Homebrew".
  label: Schema.String,
  /// The exact shell command that would run — shown verbatim in the confirm
  /// UI before anything executes.
  command: Schema.String,
  /// Whether the method's prerequisite tooling exists on the machine.
  available: Schema.Boolean,
  /// The resolved preference winner (brew > curl > npm among available).
  recommended: Schema.Boolean
})
export type HarnessInstallMethod = typeof HarnessInstallMethod.Type

/// Latest-version knowledge for an installed harness, checked against the
/// version channel matching its detected install origin.
export const HarnessUpdateInfo = Schema.Struct({
  installedVersion: Schema.optional(Schema.String),
  latestVersion: Schema.optional(Schema.String),
  updateAvailable: Schema.Boolean,
  /// Which channel produced latestVersion: "npm" | "brew" | "github" | "sparkle".
  source: Schema.optional(Schema.String),
  /// Detected install origin of the binary (npm/brew/curl/appBundle/…).
  installOrigin: Schema.optional(Schema.String),
  channel: Schema.optional(Schema.String),
  checkedAt: Schema.optional(Schema.String)
})
export type HarnessUpdateInfo = typeof HarnessUpdateInfo.Type

/// Live install/update state machine for one harness.
export const HarnessLifecycleState = Schema.Struct({
  phase: Schema.Literals(["idle", "installing", "updating", "pendingUpdate", "failed"]),
  targetVersion: Schema.optional(Schema.String),
  /// Install method the current/last operation used.
  methodId: Schema.optional(Schema.String),
  /// Background terminal streaming the operation's output ("Show Output").
  terminalId: Schema.optional(Schema.String),
  error: Schema.optional(Schema.String),
  startedAt: Schema.optional(Schema.String)
})
export type HarnessLifecycleState = typeof HarnessLifecycleState.Type

/// A user-defined custom ACP harness (BYO): launched as `command args…` with
/// `env` merged into the launch environment. Persisted in the user-editable
/// harnesses file and merged into the catalog with source "custom".
/// Dual-install: a desktop app that bundles a copy of the harness CLI while
/// the primary install is the user's own (brew/npm/…). The app updates via
/// its own Sparkle feed; this is the detail sheet's on-demand snapshot.
export const HarnessBundledApp = Schema.Struct({
  appName: Schema.String,
  bundlePath: Schema.String,
  installedVersion: Schema.optional(Schema.String),
  latestVersion: Schema.optional(Schema.String),
  updateAvailable: Schema.Boolean
})
export type HarnessBundledApp = typeof HarnessBundledApp.Type

export const CustomHarnessSpec = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  command: Schema.String,
  args: Schema.optional(Schema.Array(Schema.String)),
  env: Schema.optional(Schema.Record(Schema.String, Schema.String))
})
export type CustomHarnessSpec = typeof CustomHarnessSpec.Type

export const CustomHarnessTestResult = Schema.Struct({
  ok: Schema.Boolean,
  agentName: Schema.optional(Schema.String),
  protocolVersion: Schema.optional(Schema.Number),
  error: Schema.optional(Schema.String)
})
export type CustomHarnessTestResult = typeof CustomHarnessTestResult.Type

export const Harness = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  symbolName: Schema.String,
  source: Schema.String,
  launchKind: Schema.Literals(["executable", "npx", "uvx", "unknown"]),
  enabled: Schema.Boolean,
  /// Persisted user preference. `enabled` is the effective value after
  /// installation and authentication gates have been applied. Optional for
  /// compatibility with older Codevisor servers and cached client models.
  desiredEnabled: Schema.optional(Schema.Boolean),
  readiness: HarnessReadiness,
  /// Harness-owned authentication state. Optional while talking to servers
  /// that predate account management.
  auth: Schema.optional(HarnessAuth),
  /// Copyable shell command that installs the harness CLI; present only for
  /// harnesses with a well-known installer.
  installHint: Schema.optional(Schema.String),
  /// Ways Codevisor can install this harness on the server's machine.
  /// Optional while talking to servers that predate lifecycle management.
  installMethods: Schema.optional(Schema.Array(HarnessInstallMethod)),
  /// Latest-version knowledge from the periodic update check.
  updateInfo: Schema.optional(HarnessUpdateInfo),
  /// Live install/update operation state.
  lifecycle: Schema.optional(HarnessLifecycleState)
})
export type Harness = typeof Harness.Type

export const CreateHarnessAccountRequest = Schema.Struct({
  label: Schema.optional(Schema.String)
})
export type CreateHarnessAccountRequest = typeof CreateHarnessAccountRequest.Type

export const UpdateHarnessAccountRequest = Schema.Struct({
  label: Schema.optional(Schema.String)
})
export type UpdateHarnessAccountRequest = typeof UpdateHarnessAccountRequest.Type

export const StartHarnessLoginRequest = Schema.Struct({
  methodId: Schema.optional(Schema.String),
  apiKey: Schema.optional(Schema.String)
})
export type StartHarnessLoginRequest = typeof StartHarnessLoginRequest.Type

export const HarnessAuthFlow = Schema.Union([
  Schema.Struct({
    id: Schema.String,
    accountId: Schema.String,
    kind: Schema.Literal("browser"),
    url: Schema.String
  }),
  Schema.Struct({
    id: Schema.String,
    accountId: Schema.String,
    kind: Schema.Literal("deviceCode"),
    verificationUrl: Schema.String,
    userCode: Schema.String
  }),
  Schema.Struct({
    id: Schema.String,
    accountId: Schema.String,
    kind: Schema.Literal("terminal"),
    terminalId: Schema.String,
    terminalKey: Schema.optional(Schema.String)
  }),
  Schema.Struct({
    id: Schema.String,
    accountId: Schema.String,
    kind: Schema.Literal("pasteCode"),
    url: Schema.String
  }),
  Schema.Struct({
    id: Schema.String,
    accountId: Schema.String,
    kind: Schema.Literal("complete")
  })
])

/// The code a user pasted back from a pasteCode flow's browser page.
export const AnswerHarnessAuthRequest = Schema.Struct({ code: Schema.String })
export type AnswerHarnessAuthRequest = typeof AnswerHarnessAuthRequest.Type
export type HarnessAuthFlow = typeof HarnessAuthFlow.Type

export const PiAuthMethod = Schema.Literals(["api_key", "oauth"])
export type PiAuthMethod = typeof PiAuthMethod.Type

export const PiAuthProvider = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  methods: Schema.Array(PiAuthMethod),
  credentialType: Schema.optional(PiAuthMethod)
})
export type PiAuthProvider = typeof PiAuthProvider.Type

export const PiAuthPromptOption = Schema.Struct({
  id: Schema.String,
  label: Schema.String,
  description: Schema.optional(Schema.String)
})
export type PiAuthPromptOption = typeof PiAuthPromptOption.Type

export const PiAuthPrompt = Schema.Struct({
  id: Schema.String,
  type: Schema.Literals(["text", "secret", "select", "manual_code"]),
  message: Schema.String,
  placeholder: Schema.optional(Schema.String),
  options: Schema.Array(PiAuthPromptOption)
})
export type PiAuthPrompt = typeof PiAuthPrompt.Type

export const PiAuthEvent = Schema.Struct({
  type: Schema.Literals(["info", "auth_url", "device_code", "progress"]),
  message: Schema.optional(Schema.String),
  url: Schema.optional(Schema.String),
  userCode: Schema.optional(Schema.String),
  verificationUrl: Schema.optional(Schema.String)
})
export type PiAuthEvent = typeof PiAuthEvent.Type

export const PiAuthProviderFlow = Schema.Struct({
  id: Schema.String,
  providerId: Schema.String,
  state: Schema.Literals(["running", "waiting", "complete", "error"]),
  prompt: Schema.optional(PiAuthPrompt),
  event: Schema.optional(PiAuthEvent),
  error: Schema.optional(Schema.String)
})
export type PiAuthProviderFlow = typeof PiAuthProviderFlow.Type

export const StartPiAuthRequest = Schema.Struct({ method: PiAuthMethod })
export type StartPiAuthRequest = typeof StartPiAuthRequest.Type

export const AnswerPiAuthRequest = Schema.Struct({ value: Schema.String })
export type AnswerPiAuthRequest = typeof AnswerPiAuthRequest.Type

export const OpenCodeAuthPromptCondition = Schema.Struct({
  key: Schema.String,
  op: Schema.Literals(["eq", "neq"]),
  value: Schema.String
})
export type OpenCodeAuthPromptCondition = typeof OpenCodeAuthPromptCondition.Type

export const OpenCodeAuthPromptOption = Schema.Struct({
  value: Schema.String,
  label: Schema.String,
  hint: Schema.optional(Schema.String)
})
export type OpenCodeAuthPromptOption = typeof OpenCodeAuthPromptOption.Type

export const OpenCodeAuthPrompt = Schema.Struct({
  type: Schema.Literals(["text", "select"]),
  key: Schema.String,
  message: Schema.String,
  placeholder: Schema.optional(Schema.String),
  options: Schema.Array(OpenCodeAuthPromptOption),
  when: Schema.optional(OpenCodeAuthPromptCondition)
})
export type OpenCodeAuthPrompt = typeof OpenCodeAuthPrompt.Type

export const OpenCodeAuthMethod = Schema.Struct({
  id: Schema.String,
  type: Schema.Literals(["api", "oauth"]),
  label: Schema.String,
  prompts: Schema.Array(OpenCodeAuthPrompt)
})
export type OpenCodeAuthMethod = typeof OpenCodeAuthMethod.Type

export const OpenCodeAuthProvider = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  methods: Schema.Array(OpenCodeAuthMethod),
  credentialType: Schema.optional(Schema.Literals(["api", "oauth", "wellknown"]))
})
export type OpenCodeAuthProvider = typeof OpenCodeAuthProvider.Type

export const OpenCodeAuthAuthorization = Schema.Struct({
  url: Schema.String,
  method: Schema.Literals(["auto", "code"]),
  instructions: Schema.String
})
export type OpenCodeAuthAuthorization = typeof OpenCodeAuthAuthorization.Type

export const OpenCodeAuthFlow = Schema.Struct({
  id: Schema.String,
  accountId: Schema.String,
  providerId: Schema.String,
  state: Schema.Literals(["running", "waiting", "complete", "error"]),
  authorization: Schema.optional(OpenCodeAuthAuthorization),
  error: Schema.optional(Schema.String)
})
export type OpenCodeAuthFlow = typeof OpenCodeAuthFlow.Type

export const StartOpenCodeAuthRequest = Schema.Struct({
  methodId: Schema.String,
  inputs: Schema.optional(Schema.Record(Schema.String, Schema.String)),
  apiKey: Schema.optional(Schema.String)
})
export type StartOpenCodeAuthRequest = typeof StartOpenCodeAuthRequest.Type

export const AnswerOpenCodeAuthRequest = Schema.Struct({ code: Schema.String })
export type AnswerOpenCodeAuthRequest = typeof AnswerOpenCodeAuthRequest.Type

export const UpdateHarnessRequest = Schema.Struct({
  enabled: Schema.Boolean
})
export type UpdateHarnessRequest = typeof UpdateHarnessRequest.Type
