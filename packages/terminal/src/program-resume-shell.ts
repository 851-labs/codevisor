import { randomBytes } from "node:crypto"
import { basename, join } from "node:path"
import { fileURLToPath } from "node:url"

import type { ShellLaunch } from "./shell-integration.js"

export const RESUME_TOKEN_VARIABLE = "OSC7577_TOKEN"
export const RESUME_FILE_VARIABLE = "CODEVISOR_RESUME_FILE"
export const PROGRAM_RESUME_DIRECTORY = fileURLToPath(
  new URL("../resources/program-resume", import.meta.url)
)

export interface ProgramResumeOptions {
  readonly ghosttyResources: string
  readonly userId: number | undefined
  readonly resumeFile: string | undefined
}

export interface ProgramResumeLaunch extends ShellLaunch {
  readonly resumeToken?: string
  readonly resumesProgram: boolean
}

export const withoutInheritedResume = (env: NodeJS.ProcessEnv): NodeJS.ProcessEnv => {
  const { [RESUME_TOKEN_VARIABLE]: _token, [RESUME_FILE_VARIABLE]: _file, ...rest } = env
  return rest
}

export const withProgramResume = (
  shell: string,
  launch: ShellLaunch,
  options: ProgramResumeOptions
): ProgramResumeLaunch => {
  const hook = resumeHook(shell, launch, options.ghosttyResources)
  if (hook === undefined || !mayResume(options.userId)) return { ...launch, resumesProgram: false }

  const resumeToken = randomBytes(TOKEN_BYTES).toString("base64url")
  const env = { ...launch.env, [RESUME_TOKEN_VARIABLE]: resumeToken }
  if (options.resumeFile === undefined) {
    return { args: launch.args, env, resumeToken, resumesProgram: false }
  }
  return {
    args: launch.args,
    env: { ...env, ...hook, [RESUME_FILE_VARIABLE]: options.resumeFile },
    resumeToken,
    resumesProgram: true
  }
}

const TOKEN_BYTES = 32
const ROOT_USER_ID = 0

const mayResume = (userId: number | undefined): boolean =>
  userId !== undefined && userId !== ROOT_USER_ID

const resumeHook = (
  shell: string,
  launch: ShellLaunch,
  resources: string
): NodeJS.ProcessEnv | undefined => {
  switch (basename(shell)) {
    case "zsh":
      if (!zshIntegrated(launch, resources)) return undefined
      return { ZDOTDIR: join(PROGRAM_RESUME_DIRECTORY, "zsh") }
    case "bash":
      if (!bashIntegrated(launch, resources)) return undefined
      return { ENV: join(PROGRAM_RESUME_DIRECTORY, "bash", "codevisor-resume.bash") }
    default:
      return undefined
  }
}

const zshIntegrated = (launch: ShellLaunch, resources: string): boolean =>
  launch.args.length === 0 && launch.env.ZDOTDIR === join(resources, "shell-integration", "zsh")

const bashIntegrated = (launch: ShellLaunch, resources: string): boolean =>
  launch.args.length === 1 &&
  launch.env.ENV === join(resources, "shell-integration", "bash", "ghostty.bash")
