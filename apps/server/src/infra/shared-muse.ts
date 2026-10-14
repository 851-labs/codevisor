import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import {
  linkMuseConfigHome,
  museProfileEnv,
  writeMuseAuth,
  type SharedTokenBundle
} from "@codevisor/harness-manager"

export const museSharedContext = async (
  id: string,
  profile: string,
  bundle: SharedTokenBundle,
  env: NodeJS.ProcessEnv
): Promise<HarnessAccountContext> => {
  await linkMuseConfigHome(profile, env)
  if (bundle.authMethod === "apiKey")
    return {
      id,
      profileKind: "managed",
      env: { ...museProfileEnv(profile), META_API_KEY: bundle.accessToken }
    }
  await writeMuseAuth(profile, bundle)
  return {
    id,
    profileKind: "managed",
    env: museProfileEnv(profile),
    unsetEnv: ["META_API_KEY"]
  }
}
