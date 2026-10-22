import { Schema } from "effect"

export const GitHostProvider = Schema.Literals(["github", "gitlab", "bitbucket"])
export type GitHostProvider = typeof GitHostProvider.Type

export const GitHostAuthStatus = Schema.Struct({
  host: Schema.String,
  provider: Schema.optional(GitHostProvider),
  cli: Schema.optional(Schema.String),
  cliInstalled: Schema.Boolean,
  supported: Schema.Boolean,
  signedIn: Schema.Boolean,
  account: Schema.optional(Schema.String)
})
export type GitHostAuthStatus = typeof GitHostAuthStatus.Type

export const GitAuthFlowState = Schema.Literals([
  "starting",
  "waiting",
  "complete",
  "error",
  "cancelled"
])
export type GitAuthFlowState = typeof GitAuthFlowState.Type

export const GitAuthFlow = Schema.Struct({
  id: Schema.String,
  host: Schema.String,
  provider: GitHostProvider,
  state: GitAuthFlowState,
  userCode: Schema.optional(Schema.String),
  verificationUrl: Schema.optional(Schema.String),
  account: Schema.optional(Schema.String),
  message: Schema.optional(Schema.String)
})
export type GitAuthFlow = typeof GitAuthFlow.Type

export const StartGitAuthRequest = Schema.Struct({
  host: Schema.String
})
export type StartGitAuthRequest = typeof StartGitAuthRequest.Type

export const gitHostProvider = (host: string): GitHostProvider | undefined => {
  const name = host.trim().toLowerCase()
  if (name === "github.com") return "github"
  if (name === "gitlab.com" || name.startsWith("gitlab.")) return "gitlab"
  if (name === "bitbucket.org") return "bitbucket"
  return undefined
}
