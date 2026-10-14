import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import {
  prepareAntigravityProfile,
  writeAntigravityAuth,
  type SharedTokenBundle
} from "@codevisor/harness-manager"

/// A shared Antigravity account on this machine: its managed profile gets the
/// synced Google sign-in as agy's own token file (or the synced Gemini key,
/// with agy's provider set to match), with the user's agy config linked in
/// around it.
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
    // A key exported in the user's shell isn't this account's.
    ...(apiKey === undefined ? { unsetEnv: ["GEMINI_API_KEY"] } : {})
  }
}
