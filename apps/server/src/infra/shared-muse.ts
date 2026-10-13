import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import {
  linkMuseConfigHome,
  museProfileEnv,
  writeMuseAuth,
  type SharedTokenBundle
} from "@codevisor/harness-manager"

/// A shared Muse Code account on this machine: its managed profile gets the
/// synced sign-in as Muse's own credential file (or the synced API key as
/// `META_API_KEY`), with the user's config linked in around it.
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
    // A key exported in the user's shell would outrank the shared sign-in.
    unsetEnv: ["META_API_KEY"]
  }
}
