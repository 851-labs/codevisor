import {
  CreateSandboxRequest,
  DEFAULT_SANDBOX_WAIT_TIMEOUT_MS,
  SaveSandboxAccountRequest,
  SaveSandboxProfileRequest,
  WaitForSandboxRequest
} from "@codevisor/api"
import { Schema } from "effect"

import { apiTool, integerQuery, type CodevisorApiToolSpec } from "./codevisor-api-tool-spec.js"

const CreateSandboxBody = Schema.Struct({
  profileId: CreateSandboxRequest.fields.profileId,
  projectId: CreateSandboxRequest.fields.projectId,
  name: CreateSandboxRequest.fields.name,
  harnessId: CreateSandboxRequest.fields.harnessId
})

export const codevisorSandboxApiTools: ReadonlyArray<CodevisorApiToolSpec> = [
  apiTool(
    "sandboxes.vendors",
    "List the sandbox vendors Codevisor supports (tart, tart-orchard, apple-container, e2b, modal, vercel, daytona) " +
      "with the fields each needs: accountFields for sandboxes.providers_create (a field of type " +
      "secret is a credential; type machine is the id of the Mac that runs it, from " +
      "machines.list()) and profileFields for sandboxes.profiles_create (with defaults, min/max " +
      "and units such as CPUs and memory in GB). capabilities says which vendors this machine " +
      "can run itself and maximums gives its CPU and memory limits per vendor.",
    "GET",
    "/v1/sandbox-providers"
  ),
  apiTool(
    "sandboxes.providers_list",
    "List the user's sandbox providers: a vendor plus the account or Mac it runs on, with " +
      "accountId (what profiles refer to), label, identity and non-secret values. Secrets are " +
      "never returned; secretsSet names the secret fields that are stored.",
    "GET",
    "/v1/sandbox-accounts"
  ),
  apiTool(
    "sandboxes.providers_create",
    "Add a sandbox provider and get its accountId. provider is a vendor id from " +
      "sandboxes.vendors(); values fills " +
      "its accountFields (for example { token } for Vercel, { apiKey } for E2B, or { machineId } " +
      "for Tart on a Mac). Codevisor checks the credentials with the vendor first. A 409 with " +
      "code sandboxChoiceNeeded names a field to pick (such as a team) before it can save. " +
      "Never echo a secret back to the user or write it to a file.",
    "POST",
    "/v1/sandbox-accounts",
    { body: SaveSandboxAccountRequest }
  ),
  apiTool(
    "sandboxes.providers_update",
    "Change a sandbox provider's label or values. Leave a secret out (or blank) to keep the " +
      "stored one. The vendor can't change.",
    "PUT",
    "/v1/sandbox-accounts/:id",
    { body: SaveSandboxAccountRequest }
  ),
  apiTool(
    "sandboxes.providers_delete",
    "Remove a sandbox provider and its stored credentials. Fails while a profile uses it or a " +
      "sandbox still runs on it. Confirm with the user first.",
    "DELETE",
    "/v1/sandbox-accounts/:id",
    { confirm: true }
  ),
  apiTool(
    "sandboxes.profiles_list",
    "List the user's sandbox profiles: id, name, vendor (provider), the provider account " +
      "(accountId) and values such as the image, CPUs (cpu) and memory (memoryGiB). Start one " +
      "with sandboxes.create() or agents.start({ sandboxProfile }).",
    "GET",
    "/v1/sandbox-profiles"
  ),
  apiTool(
    "sandboxes.profiles_availability",
    "Say which sandbox profiles this machine can start right now; the others carry a " +
      "disabledReason (another Mac runs it, it has no provider, or the vendor can't run here).",
    "GET",
    "/v1/sandbox-profiles/availability"
  ),
  apiTool(
    "sandboxes.profiles_create",
    "Create a sandbox profile: a name, a vendor (provider), the provider account (accountId " +
      "from sandboxes.providers_list(); vendors without accountFields need none) and values for " +
      "the vendor's profileFields from sandboxes.vendors(), such as image, cpu and memoryGiB. " +
      "Values are checked against the vendor's limits and this machine's CPU and memory.",
    "POST",
    "/v1/sandbox-profiles",
    { body: SaveSandboxProfileRequest }
  ),
  apiTool(
    "sandboxes.profiles_update",
    "Replace a sandbox profile's name, provider account and values (send every value you " +
      "want to keep). Running sandboxes keep the settings they started with.",
    "PUT",
    "/v1/sandbox-profiles/:id",
    { body: SaveSandboxProfileRequest }
  ),
  apiTool(
    "sandboxes.profiles_delete",
    "Delete a sandbox profile. Running sandboxes started from it keep running.",
    "DELETE",
    "/v1/sandbox-profiles/:id",
    { confirm: true }
  ),
  apiTool(
    "sandboxes.list",
    "List this machine's sandboxes: id, name, vendor (provider), profile, project, state " +
      "(creating, bootstrapping, syncing, cloning, ready, destroying, failed, archived), the " +
      "setup steps so far, error, and once ready the sandbox's machineId, its remoteProjectId " +
      "and workspaceId, and agentId when one was started on it.",
    "GET",
    "/v1/sandboxes"
  ),
  apiTool(
    "sandboxes.get",
    "Get one sandbox and its setup state, as in sandboxes.list().",
    "GET",
    "/v1/sandboxes/:id"
  ),
  apiTool(
    "sandboxes.wait",
    "Wait until a sandbox is ready or failed and return it, with timedOut: true if it is " +
      "still setting up when the wait ends. timeoutMs defaults to 60000 (at most 300000) and is " +
      "shortened to fit what is left of this execute call's budget. Call it again to keep " +
      "waiting; setup takes a few minutes.",
    "POST",
    "/v1/sandboxes/:id/wait",
    {
      body: WaitForSandboxRequest,
      budgetedWait: { field: "timeoutMs", defaultMs: DEFAULT_SANDBOX_WAIT_TIMEOUT_MS }
    }
  ),
  apiTool(
    "sandboxes.log",
    "Read a sandbox's start log (stage, stream, line) from vendor creation through install, " +
      "sign-in, sync, clone and agent start, oldest first, with invite codes redacted. Kept in " +
      "memory since this server started, for the most recent sandboxes. Use it to see why a " +
      "sandbox failed or what it's doing.",
    "GET",
    "/v1/sandboxes/:id/log",
    { query: [integerQuery("last", "Only the newest lines, at most 1000. Defaults to all kept.")] }
  ),
  apiTool(
    "sandboxes.create",
    "Start a throwaway sandbox from one of the user's sandbox profiles (sandboxes.profiles_list()) " +
      "for one project on this machine: Codevisor creates the vendor's machine, installs itself " +
      "there, joins the account, copies this machine's harnesses, skills, MCPs and sign-ins over " +
      "one way, clones the project and creates a workspace for it. harnessId (optional) is set up " +
      "first. Returns at once with state creating; follow it with sandboxes.wait() (a few minutes; " +
      "ready has machineId, remoteProjectId and workspaceId) and sandboxes.log(). Archiving its " +
      "workspace or sandboxes.destroy() deletes it. It costs the user money while it runs. To run " +
      "an agent on a new sandbox in one call, use agents.start({ sandboxProfile }).",
    "POST",
    "/v1/sandboxes",
    { body: CreateSandboxBody }
  ),
  apiTool(
    "sandboxes.retry",
    "Start a failed sandbox again with the same id, profile, project and agent. Returns at once " +
      "with state creating, like sandboxes.create().",
    "POST",
    "/v1/sandboxes/:id/retry"
  ),
  apiTool(
    "sandboxes.destroy",
    "Destroy a sandbox now: remove it from the account and delete the vendor's machine. A " +
      "sandbox still being set up stops at its next step. Its workspace's unpushed work is lost; " +
      "confirm with the user first.",
    "DELETE",
    "/v1/sandboxes/:id",
    { confirm: true }
  )
]
