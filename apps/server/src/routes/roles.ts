import type { IncomingMessage, ServerResponse } from "node:http"

import { CloudRolesResponse, type MachineRolesResponse } from "@codevisor/api"
import { Schema } from "effect"

import {
  HttpFailure,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices
} from "../server-context.js"
import { liveCloudDeviceId } from "./cloud.js"

export const routeRoles = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (url.pathname !== "/v1/roles" || request.method !== "GET") return false
  const roles = services.machineRoles
  if (roles === undefined) throw new HttpFailure(501, "Roles unavailable")

  const machineId = liveCloudDeviceId(config)
  const body: MachineRolesResponse = {
    ...(machineId === undefined ? {} : { machineId }),
    roles: roles.views(),
    ...(await cloudRoles(config))
  }
  writeJson(response, 200, body)
  return true
}

const cloudRoles = async (
  config: CodevisorServerConfig
): Promise<Pick<MachineRolesResponse, "cloud" | "cloudError">> => {
  const request = config.cloud?.machineRequest
  if (request === undefined || liveCloudDeviceId(config) === undefined) {
    return { cloudError: "This machine isn't connected to Codevisor Cloud" }
  }
  try {
    const answer = await request("GET", "/api/machine/roles")
    return { cloud: Schema.decodeUnknownSync(CloudRolesResponse)(answer).roles }
  } catch (cause) {
    return { cloudError: cause instanceof Error ? cause.message : String(cause) }
  }
}
