import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import {
  prepareAntigravityProfile,
  writeAntigravityAuth,
  type SharedTokenBundle
} from "@codevisor/harness-manager"

export const antigravitySharedContext = async (
  id: string,
  profile: string,
  bundle: SharedTokenBundle,
  env: NodeJS.ProcessEnv
): Promise<HarnessAccountContext> => {
  const apiKey = bundle.authMethod === "apiKey" ? bundle.accessToken : undefined
  if (apiKey === undefined) await writeAntigravityAuth(profile, bundle)
  return {
    id,
    profileKind: "managed",
    env: await prepareAntigravityProfile(profile, env, apiKey),
    ...(apiKey === undefined ? { unsetEnv: ["GEMINI_API_KEY"] } : {})
  }
}
