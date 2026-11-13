import { GitError } from "./git-errors.js"
import { locateGit, type GitInstallation } from "./git-installation.js"

export const gitMissingMessage = "Git isn't installed on this machine"

export class GitMissingError extends GitError {
  constructor() {
    super("locate", gitMissingMessage)
    this.name = "GitMissingError"
  }
}

export type GitEnvironment = () => Promise<NodeJS.ProcessEnv>

export const useGitEnvironment = (environment: GitEnvironment): void => {
  machineEnvironment = environment
  latestEnvironment = undefined
}

export const gitInstallation = async (): Promise<GitInstallation> => {
  const environment = machineEnvironment
  const env = await environment()
  if (environment === machineEnvironment) latestEnvironment = env

  return installationOn(env)
}

export const gitInstallationFor = (env?: NodeJS.ProcessEnv): GitInstallation =>
  installationOn(env?.PATH === undefined ? machineEnvironmentNow() : env)

export const gitExecutable = (env?: NodeJS.ProcessEnv): string => {
  const installation = gitInstallationFor(env)
  if (installation.state === "missing") throw new GitMissingError()

  return installation.path
}

const machineEnvironmentNow = (): NodeJS.ProcessEnv => latestEnvironment ?? process.env

const installationOn = (env: NodeJS.ProcessEnv): GitInstallation => {
  const path = env.PATH ?? ""
  return found.get(path) ?? remember(path, locateGit(env))
}

const remember = (path: string, installation: GitInstallation): GitInstallation => {
  if (installation.state === "missing") return installation
  if (found.size >= rememberedPathLimit) found.clear()

  found.set(path, installation)
  return installation
}

const rememberedPathLimit = 64

const found = new Map<string, GitInstallation>()

let machineEnvironment: GitEnvironment = () => Promise.resolve(process.env)

let latestEnvironment: NodeJS.ProcessEnv | undefined
