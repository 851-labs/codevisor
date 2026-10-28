import type {
  SandboxAgentStart,
  SandboxProfile,
  StartAgentRequest,
  StartedSandboxAgent
} from "@codevisor/api"

import type { SandboxSettings } from "../infra/sandbox-settings.js"
import { HttpFailure, writeJson } from "../server-context.js"
import type { RouteContext } from "./route-context.js"
import { setupPublisher } from "./sandboxes.js"

export interface SandboxAgentPlan {
  readonly projectId: string
  readonly harnessId: string
  readonly callerSessionId: string | undefined
  readonly callerModel: string | undefined
}

export const startAgentOnSandbox = async (
  route: RouteContext,
  request: StartAgentRequest & { readonly sandboxProfile: string },
  plan: SandboxAgentPlan
): Promise<boolean> => {
  const service = route.services.sandboxes
  if (service === undefined) throw new HttpFailure(501, "Sandboxes are unavailable here")

  const profile = await profileNamed(service.catalog.settings, request.sandboxProfile)
  const sandbox = await service.sandboxes.create(
    {
      profileId: profile.id,
      projectId: plan.projectId,
      name: request.title,
      agent: sandboxAgent(request, plan)
    },
    setupPublisher(route)
  )
  const started: StartedSandboxAgent = {
    sandboxId: sandbox.id,
    title: request.title,
    projectId: plan.projectId,
    profileId: profile.id,
    state: sandbox.state
  }
  writeJson(route.response, 202, started)
  return true
}

const profileNamed = async (
  settings: Pick<SandboxSettings, "profiles">,
  wanted: string
): Promise<SandboxProfile> => {
  const profiles = await settings.profiles()
  const key = wanted.toLowerCase()
  const found = profiles.find(
    (profile) => profile.id.toLowerCase() === key || profile.name.toLowerCase() === key
  )
  if (found !== undefined) return found
  throw new HttpFailure(422, profileHint(wanted, profiles))
}

const profileHint = (wanted: string, profiles: ReadonlyArray<SandboxProfile>): string => {
  if (profiles.length === 0) return "There are no sandbox profiles yet; create one first"
  const names = profiles.map((profile) => `${profile.name} (${profile.id})`).join(", ")
  return `No sandbox profile matches "${wanted}". Profiles: ${names}`
}

const sandboxAgent = (request: StartAgentRequest, plan: SandboxAgentPlan): SandboxAgentStart => {
  const model = request.model ?? plan.callerModel
  return {
    prompt: request.prompt,
    title: request.title,
    harness: plan.harnessId,
    ...(model === undefined ? {} : { model }),
    ...(request.labels === undefined ? {} : { labels: request.labels }),
    ...(plan.callerSessionId === undefined ? {} : { parentSessionId: plan.callerSessionId })
  }
}
