import { homedir } from "node:os"
import { join } from "node:path"

import { claudeKeychainService, type ClaudeMachineLocation } from "@codevisor/harness-manager"

export const claudeMachineLocation = (
  env: NodeJS.ProcessEnv,
  dataDir: string
): ClaudeMachineLocation => {
  const genuine = !isDevelopmentServer(env) && env.CODEVISOR_CLAUDE_CONFIG_DIR === undefined
  const directory = machineDirectory(env, dataDir)
  return {
    directory,
    keychainService:
      env.CODEVISOR_CLAUDE_KEYCHAIN_SERVICE ?? keychainService(env, directory, genuine),
    isDefault: genuine
  }
}

const developmentDirectory = "claude-machine-login-devtest"

const isDevelopmentServer = (env: NodeJS.ProcessEnv): boolean =>
  env.CODEVISOR_DEV_INSTANCE_ID !== undefined || env.HERDMAN_DEV_INSTANCE_ID !== undefined

const machineDirectory = (env: NodeJS.ProcessEnv, dataDir: string): string => {
  if (env.CODEVISOR_CLAUDE_CONFIG_DIR !== undefined) return env.CODEVISOR_CLAUDE_CONFIG_DIR
  if (isDevelopmentServer(env)) return join(dataDir, developmentDirectory)
  return env.CLAUDE_CONFIG_DIR ?? join(env.HOME ?? homedir(), ".claude")
}

const keychainService = (env: NodeJS.ProcessEnv, directory: string, genuine: boolean): string =>
  claudeKeychainService(directory, genuine && env.CLAUDE_CONFIG_DIR === undefined)
