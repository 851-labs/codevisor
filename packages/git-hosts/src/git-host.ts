import type { GitHostProvider, GitPullRequest } from "@codevisor/api"

import type { CliPlatform } from "./cli-release.js"

export interface GitHostCli {
  readonly path: string
  readonly version: string | undefined
}

export interface GitHostTools {
  readonly toolsDir?: string | undefined
  readonly platform?: CliPlatform | undefined
  readonly releasesUrl?: string | undefined
}

export interface GitHostSignInStatus {
  readonly cliInstalled: boolean
  readonly signedIn: boolean
  readonly account?: string
}

export interface DeviceCode {
  readonly userCode: string
  readonly verificationUrl: string
}

export type GitHostLoginResult =
  | { readonly signedIn: true }
  | { readonly signedIn: false; readonly message: string }

export interface GitHostLogin {
  readonly finished: Promise<GitHostLoginResult>
  readonly cancel: () => void
}

export interface GitHost {
  readonly provider: GitHostProvider
  readonly command: string
  readonly cliName: string
  readonly detect: (env: NodeJS.ProcessEnv) => Promise<GitHostCli | undefined>
  readonly install: (env: NodeJS.ProcessEnv) => Promise<GitHostCli>
  readonly authStatus: (hostname: string, env: NodeJS.ProcessEnv) => Promise<GitHostSignInStatus>
  readonly login: (
    hostname: string,
    env: NodeJS.ProcessEnv,
    onDeviceCode: (code: DeviceCode) => void
  ) => GitHostLogin
  readonly setUpGitCredentials?: (hostname: string, env: NodeJS.ProcessEnv) => Promise<void>
}

export interface OwnedBranch {
  readonly name: string
  readonly ownedSince: string
}

export interface PullRequestHost {
  readonly findPullRequest: (
    directory: string,
    env: NodeJS.ProcessEnv,
    branch: string,
    owned?: OwnedBranch
  ) => Promise<GitPullRequest | null | undefined>
}
