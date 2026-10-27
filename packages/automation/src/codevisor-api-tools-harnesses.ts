import {
  AnswerOpenCodeAuthRequest,
  AnswerHarnessAuthRequest,
  AnswerPiAuthRequest,
  CreateHarnessAccountRequest,
  StartHarnessLoginRequest,
  StartOpenCodeAuthRequest,
  StartPiAuthRequest,
  UpdateHarnessAccountRequest,
  UpdateHarnessRequest
} from "@codevisor/api"

import {
  stringQuery,
  harnessInstallBody,
  apiTool,
  type CodevisorApiToolSpec
} from "./codevisor-api-tool-spec.js"

export const codevisorHarnessApiTools: ReadonlyArray<CodevisorApiToolSpec> = [
  apiTool(
    "skills.delete",
    "Delete a skill from Codevisor's skill store.",
    "DELETE",
    "/v1/skills/:name"
  ),
  apiTool("harnesses.list", "List agent harnesses and readiness state.", "GET", "/v1/harnesses", {
    query: [{ name: "include", schema: { type: "string", enum: ["lifecycle"] } }]
  }),
  apiTool(
    "harnesses.rescan",
    "Refresh the shell environment and rescan harnesses.",
    "POST",
    "/v1/harnesses/rescan"
  ),
  apiTool(
    "harnesses.auth_refresh",
    "Refresh harness authentication state.",
    "POST",
    "/v1/harnesses/auth/refresh",
    {
      query: [stringQuery("harnessId")]
    }
  ),
  apiTool(
    "harnesses.check_updates",
    "Check installed harnesses for updates.",
    "POST",
    "/v1/harnesses/check-updates"
  ),
  apiTool(
    "harnesses.update_settings",
    "Enable or disable an agent harness.",
    "PATCH",
    "/v1/harnesses/:id",
    {
      body: UpdateHarnessRequest
    }
  ),
  apiTool(
    "harnesses.install",
    "Begin installing an agent harness.",
    "POST",
    "/v1/harnesses/:id/install",
    {
      body: harnessInstallBody
    }
  ),
  apiTool(
    "harnesses.update",
    "Begin updating an installed CLI harness.",
    "POST",
    "/v1/harnesses/:id/update"
  ),
  apiTool(
    "harnesses.pending_update_apply",
    "Apply a pending harness update now.",
    "POST",
    "/v1/harnesses/:id/update/pending/apply"
  ),
  apiTool(
    "harnesses.pending_update_cancel",
    "Cancel a pending harness update.",
    "DELETE",
    "/v1/harnesses/:id/update/pending"
  ),
  apiTool(
    "harnesses.bundled_app",
    "Get bundled desktop-app information for a harness.",
    "GET",
    "/v1/harnesses/:id/bundled-app"
  ),
  apiTool(
    "harnesses.bundled_app_update",
    "Begin updating a harness's bundled desktop app.",
    "POST",
    "/v1/harnesses/:id/bundled-app/update"
  ),
  apiTool(
    "harnesses.agent_sessions",
    "List sessions from a harness's own native store.",
    "GET",
    "/v1/harnesses/:id/agent-sessions"
  ),
  apiTool(
    "harnesses.accounts_list",
    "List accounts configured for a harness.",
    "GET",
    "/v1/harnesses/:id/accounts"
  ),
  apiTool(
    "harnesses.accounts_create",
    "Create an account profile for a harness.",
    "POST",
    "/v1/harnesses/:id/accounts",
    {
      body: CreateHarnessAccountRequest
    }
  ),
  apiTool(
    "harnesses.accounts_update",
    "Rename a harness account profile.",
    "PATCH",
    "/v1/harnesses/:id/accounts/:accountId",
    {
      body: UpdateHarnessAccountRequest
    }
  ),
  apiTool(
    "harnesses.accounts_delete",
    "Delete a harness account profile.",
    "DELETE",
    "/v1/harnesses/:id/accounts/:accountId"
  ),
  apiTool(
    "harnesses.accounts_activate",
    "Make a harness account active.",
    "POST",
    "/v1/harnesses/:id/accounts/:accountId/activate"
  ),
  apiTool(
    "harnesses.accounts_probe",
    "Probe and refresh one harness account's authentication.",
    "POST",
    "/v1/harnesses/:id/accounts/:accountId/auth/probe"
  ),
  apiTool(
    "harnesses.accounts_login",
    "Start authentication for a harness account.",
    "POST",
    "/v1/harnesses/:id/accounts/:accountId/login",
    {
      body: StartHarnessLoginRequest
    }
  ),
  apiTool(
    "harnesses.accounts_login_cancel",
    "Cancel a harness-account login flow.",
    "DELETE",
    "/v1/harnesses/:id/accounts/:accountId/login/:flowId"
  ),
  apiTool(
    "harnesses.accounts_login_answer",
    "Submit the answer to an interactive harness-account login flow.",
    "POST",
    "/v1/harnesses/:id/accounts/:accountId/login/:flowId/answer",
    { body: AnswerHarnessAuthRequest }
  ),
  apiTool(
    "harnesses.accounts_logout",
    "Log out a harness account.",
    "POST",
    "/v1/harnesses/:id/accounts/:accountId/logout"
  ),
  apiTool(
    "harnesses.pi_providers",
    "List authentication providers supported by Pi.",
    "GET",
    "/v1/harnesses/pi/providers"
  ),
  apiTool(
    "harnesses.pi_login",
    "Start a Pi provider login flow.",
    "POST",
    "/v1/harnesses/pi/providers/:providerId/login",
    {
      body: StartPiAuthRequest
    }
  ),
  apiTool(
    "harnesses.pi_logout",
    "Log out a Pi provider.",
    "DELETE",
    "/v1/harnesses/pi/providers/:providerId"
  ),
  apiTool(
    "harnesses.pi_flow_get",
    "Get a Pi authentication flow.",
    "GET",
    "/v1/harnesses/pi/auth-flows/:flowId"
  ),
  apiTool(
    "harnesses.pi_flow_answer",
    "Answer a Pi authentication-flow prompt.",
    "POST",
    "/v1/harnesses/pi/auth-flows/:flowId/answer",
    {
      body: AnswerPiAuthRequest
    }
  ),
  apiTool(
    "harnesses.pi_flow_cancel",
    "Cancel a Pi authentication flow.",
    "DELETE",
    "/v1/harnesses/pi/auth-flows/:flowId"
  ),
  apiTool(
    "harnesses.opencode_providers",
    "List OpenCode authentication providers for an account.",
    "GET",
    "/v1/harnesses/opencode/accounts/:accountId/providers"
  ),
  apiTool(
    "harnesses.opencode_login",
    "Start an OpenCode provider login flow.",
    "POST",
    "/v1/harnesses/opencode/accounts/:accountId/providers/:providerId/login",
    {
      body: StartOpenCodeAuthRequest
    }
  ),
  apiTool(
    "harnesses.opencode_logout",
    "Log out an OpenCode provider.",
    "DELETE",
    "/v1/harnesses/opencode/accounts/:accountId/providers/:providerId"
  ),
  apiTool(
    "harnesses.opencode_flow_get",
    "Get an OpenCode authentication flow.",
    "GET",
    "/v1/harnesses/opencode/auth-flows/:flowId"
  ),
  apiTool(
    "harnesses.opencode_flow_answer",
    "Answer an OpenCode authentication-flow prompt.",
    "POST",
    "/v1/harnesses/opencode/auth-flows/:flowId/answer",
    {
      body: AnswerOpenCodeAuthRequest
    }
  ),
  apiTool(
    "harnesses.opencode_flow_cancel",
    "Cancel an OpenCode authentication flow.",
    "DELETE",
    "/v1/harnesses/opencode/auth-flows/:flowId"
  )
]
